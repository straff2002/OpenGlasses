import Foundation

/// What a read-back found of a plan's writes in the system (Plan MM §6): the idempotency keys the
/// system shows as already applied, from the job's part lines or the adjustments since the batch
/// was queued. A retry sends only what is not here (`PartsUsedWritePlan.remaining(after:)`).
struct StockSystemReadBack: Equatable, Sendable {

    /// A write the system shows under one of the plan's keys that is not the write the plan holds
    /// (Plan MM P1). It is neither trusted as applied nor sent again: a person looks at it.
    struct Mismatch: Equatable, Sendable {
        enum Difference: String, Equatable, Sendable {
            /// Another item.
            case item
            /// Another location.
            case location
            /// Another amount.
            case quantity
            /// Another kind of movement (another state, another kind of change).
            case movement
            /// The key shows more than once.
            case duplicate
        }
        let idempotencyKey: String
        let difference: Difference
    }

    let applied: Set<String>
    let mismatched: [Mismatch]

    init(applied: Set<String>, mismatched: [Mismatch] = []) {
        self.applied = applied
        self.mismatched = mismatched
    }

    /// The keys a person has to look at.
    var needsAttention: Set<String> { Set(mismatched.map(\.idempotencyKey)) }
}

/// The seam every stock connector sits behind (Plan MM P0). Each system is plain HTTPS through the
/// common transport (Plan MM §7, P2), driving that system's `StockSystemAdapter` (P1) with
/// `StockSystemPlanDriver`. Tests use a fake.
///
/// A connector reads stock and locations, and writes only what a `PartsUsedWritePlan` holds: part
/// lines on a job, or adjustments with a reason (`Contracts/stock-systems.md`). It reads back
/// before any retry.
protocol StockSystemConnector: Sendable {
    /// What the system can take back.
    var capabilities: StockSystemCapabilities { get }

    /// The system's locations, for "Which stock is here?".
    func locations() async throws -> [StockSystemLocation]

    /// A whole snapshot of the chosen locations' stock.
    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot

    /// The current figures for just `itemIDs` at `locationIDs` (Plan MM P3): what a `check` asks
    /// for while the snapshot is old. Reads only.
    func pullLines(itemIDs: [String], locationIDs: [String]) async throws -> StockSystemFreshLines

    /// Test connection (Plan MM P2): the locations, then the smallest read of each kind the
    /// snapshot needs. Reads only. A missing permission is reported per kind, not thrown.
    func probe() async throws -> StockSystemProbe

    /// Sends the plan's steps, each with its idempotency key, and returns what the system
    /// accepted. `confirmedAt` is when the person confirmed the batch. Throws when the outcome is
    /// uncertain, so the caller reads back before trying again.
    func apply(_ steps: [PartsUsedWritePlan.Step], confirmedAt: Date) async throws -> StockSystemReadBack

    /// Which of the plan's steps the system already shows, read from its history since
    /// `queuedAt`, when the batch was queued.
    func readBack(_ plan: PartsUsedWritePlan, queuedAt: Date) async throws -> StockSystemReadBack
}

extension StockSystemConnector {
    /// A connector with no read of its own for a few lines pulls the whole snapshot and keeps
    /// theirs: slower, and an unknown figure comes back as no figure, which the merge reads as
    /// keeping the reason it already had.
    func pullLines(itemIDs: [String], locationIDs: [String]) async throws -> StockSystemFreshLines {
        let snapshot = try await pullSnapshot(locationIDs: locationIDs, pulledAt: Date())
        var counts: [String: [String: String]] = [:]
        for line in snapshot.lines where itemIDs.contains(line.itemID) {
            for level in line.levels where locationIDs.contains(level.locationID) {
                if let quantity = level.value.quantity { counts[line.itemID, default: [:]][level.locationID] = quantity.decimalString }
            }
        }
        return StockSystemFreshLines(itemIDs: itemIDs, locationIDs: locationIDs, counts: counts)
    }
}

/// What Test connection found (Plan MM P2): the system's locations, and for each kind of read the
/// snapshot needs, whether the key may make it. Common: every system's probe reads this way.
struct StockSystemProbe: Equatable, Sendable {

    struct Check: Equatable, Sendable {
        let purpose: StockSystemEndpoint.Purpose
        /// The permission the key lacks for this read, in the system's own word; nil when it worked.
        let missingScope: String?

        var passed: Bool { missingScope == nil }
    }

    let locations: [StockSystemLocation]
    let checks: [Check]

    var passed: Bool { checks.allSatisfy(\.passed) }

    /// The one line Settings shows after Test connection, with the system's name: "Connected to
    /// <system>. Stock ✓ Items ✓ — sending back is off." A missing permission is named in
    /// `StockSystemFailure.missingScope`'s own sentence.
    func line(system: String, sendingBack: Bool) -> String {
        if let missing = checks.first(where: { !$0.passed }), let scope = missing.missingScope {
            return StockSystemFailure.missingScope(scope).sentence(system: system)
        }
        let ticks = checks.map { "\(Self.word($0.purpose)) ✓" }.joined(separator: " ")
        let back = sendingBack ? "sending back is on" : "sending back is off"
        return ticks.isEmpty ? "Connected to \(system) — \(back)." : "Connected to \(system). \(ticks) — \(back)."
    }

    /// How a kind of read is named in that line.
    static func word(_ purpose: StockSystemEndpoint.Purpose) -> String {
        switch purpose {
        case .locations: return "Locations"
        case .catalogue: return "Items"
        case .stock: return "Stock"
        case .history: return "History"
        case .write: return "Sending"
        }
    }
}
