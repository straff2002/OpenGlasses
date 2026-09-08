import Foundation

/// What to do with an op once the server's current state is known.
enum ConflictDecision: Equatable {
    case accept(newVersion: Int)   // last-writer-wins — adopt the server version and deliver
    case conflict(reason: String)  // server advanced while we were offline — surface it
}

/// Where a `ConflictResolver` keeps its per-session baselines. Small on purpose: the resolver reads
/// through it on every call, so there is no cached copy that can drift from what's on disk.
@MainActor
protocol ConflictBaselineStore: AnyObject {
    func baseline(for sessionId: String) -> Int?
    func setBaseline(_ version: Int, for sessionId: String)
}

/// Non-durable baselines — the default, and all a unit test or a single flush needs.
@MainActor
final class InMemoryConflictBaselineStore: ConflictBaselineStore {
    private var versions: [String: Int] = [:]

    func baseline(for sessionId: String) -> Int? { versions[sessionId] }

    func setBaseline(_ version: Int, for sessionId: String) { versions[sessionId] = version }
}

/// Single-writer conflict detection (Plan T), reduced from the vector-clock idea to a per-session
/// version counter. The technician's device is the only writer in v1; the only "conflict" is the
/// server having moved on (e.g. tasks reassigned, a procedure version bumped) while the device was
/// offline. Pure and deterministic — a real networked `SyncSink` consults this; v1's local sink
/// doesn't need it. Multi-writer reconciliation is explicitly out of scope.
///
/// Two properties the callers depend on:
/// - **The baseline outlives the process.** Backed by `OfflineQueue`, it lives in the queue's own
///   SQLite file, beside the ops it gates, so a relaunch mid-outage doesn't reset every session to
///   version 0 and manufacture (or miss) conflicts on the first flush after restart.
/// - **A conflict never advances the baseline.** Every later op in the same session keeps comparing
///   against the version the device actually synced to, so a flush surfaces all of the affected ops
///   instead of silently last-writer-wins-ing everything after the first. Adoption is an explicit,
///   separate step: `acknowledge(serverVersion:for:)`, called once the wearer has seen the conflict
///   and resolved it.
@MainActor
final class ConflictResolver {
    private let store: ConflictBaselineStore

    /// `nil` gets the non-durable default (a default *argument* can't build one — it would be
    /// evaluated outside the main actor). Pass `OfflineQueue` for baselines that survive a relaunch.
    init(store: ConflictBaselineStore? = nil) {
        self.store = store ?? InMemoryConflictBaselineStore()
    }

    /// Record the server version the device last synced to for a session.
    func setKnownVersion(_ version: Int, for sessionId: String) {
        store.setBaseline(version, for: sessionId)
    }

    func knownVersion(for sessionId: String) -> Int {
        store.baseline(for: sessionId) ?? 0
    }

    /// Adopt a server version the wearer has been shown — the resolution step after `resolve`
    /// returned `.conflict`. This is the only way a conflicting version becomes the new baseline.
    func acknowledge(serverVersion: Int, for sessionId: String) {
        store.setBaseline(serverVersion, for: sessionId)
    }

    /// Decide an op against the server's current version for its session. If the server advanced
    /// beyond what we knew, it's a conflict and the baseline stays put; otherwise accept
    /// (last-writer-wins) and keep the baseline current.
    func resolve(op: QueuedOp, serverVersion: Int) -> ConflictDecision {
        let known = knownVersion(for: op.sessionId)
        if serverVersion > known {
            let delta = serverVersion - known
            return .conflict(reason: "\(delta) change\(delta == 1 ? "" : "s") happened on the server while you were offline")
        }
        // Server is at or behind what we knew — our write wins; keep the baseline current.
        setKnownVersion(max(known, serverVersion), for: op.sessionId)
        return .accept(newVersion: max(known, serverVersion))
    }
}
