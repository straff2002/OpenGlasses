import CryptoKit
import Foundation

/// A part used on a job at a system-held place, noted on the phone and not yet sent (Plan MM §6).
struct StagedStockUse: Codable, Equatable, Identifiable, Sendable {

    /// How the use reached the phone.
    enum Source: String, Codable, Equatable, Sendable {
        case spoken, typed, scanned
    }

    /// The staged line's own id: half of each write's idempotency key, so it never changes.
    let id: String
    /// The system's id for the item, from the snapshot. Nil when the system does not carry it.
    let itemID: String?
    let part: String?
    let description: String
    let quantity: StockQuantity
    let unit: VanStockUnit
    /// What the lookup of the number said against the vault (Plan MK §4). Never a gate.
    let verification: VanStockVerification
    let source: Source

    init(id: String = UUID().uuidString, itemID: String?, part: String?, description: String,
         quantity: StockQuantity, unit: VanStockUnit, verification: VanStockVerification = .notChecked,
         source: Source) {
        self.id = id
        self.itemID = itemID
        self.part = part
        self.description = description
        self.quantity = quantity
        self.unit = unit
        self.verification = verification
        self.source = source
    }

    /// "Capacitor 45/5 (ZX-1001)".
    var name: String {
        let described = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let part, !part.isEmpty else { return described.isEmpty ? "Unnamed item" : described }
        return described.isEmpty ? part : "\(described) (\(part))"
    }
}

/// Why a part used and not sold leaves stock, from the closed list a connector maps onto its own
/// reasons (Plan MM §6). A connector says which of these its system keeps.
enum StockAdjustmentReason: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case internalUse = "internal_use"
    case waste
    case damage
}

/// What a connected system can take back, as its connector declares it (Plan MM §6, §8).
struct StockSystemCapabilities: Equatable, Sendable {
    /// The connector's id; a job's `ExternalJobReference.system` must match it for a part line.
    let connectorID: String
    /// How people name the system: "not in <name>'s catalogue".
    let displayName: String
    /// The system has jobs (a garage or trade system); a till or an inventory system has none.
    let hasJobs: Bool
    /// The system keeps whole numbers only, so a fraction of a unit cannot be sent.
    let wholeNumbersOnly: Bool
    /// The adjustment reasons the system keeps.
    let adjustmentReasons: Set<StockAdjustmentReason>
    /// The reason the organisation chose for parts used and not sold. Nil until one is chosen.
    let chosenReason: StockAdjustmentReason?
    /// The system's adjustment has a note or reference field the job number can go in.
    let adjustmentNote: Bool

    init(connectorID: String, displayName: String, hasJobs: Bool, wholeNumbersOnly: Bool,
         adjustmentReasons: Set<StockAdjustmentReason>, chosenReason: StockAdjustmentReason?,
         adjustmentNote: Bool = false) {
        self.connectorID = connectorID
        self.displayName = displayName
        self.hasJobs = hasJobs
        self.wholeNumbersOnly = wholeNumbersOnly
        self.adjustmentReasons = adjustmentReasons
        self.chosenReason = chosenReason
        self.adjustmentNote = adjustmentNote
    }
}

/// How a batch was confirmed. A person, by voice or on the screen, and nothing else (Decision 5):
/// there is no case an agent path could produce.
enum StockUseConfirmation: Equatable, Sendable {
    case person(Channel)

    enum Channel: String, Equatable, Sendable {
        case voice, screen
    }
}

/// The parts used on one job (or one premises day), read back and confirmed by a person.
struct ConfirmedStockUseBatch: Equatable, Sendable {
    /// The phone's own id for the job or the day's list: half of each write's idempotency key.
    let jobID: String
    /// The number people use for the job, carried in an adjustment's note where the system has one.
    let jobNumber: String?
    /// The system's location the parts came from.
    let locationID: String
    let lines: [StagedStockUse]
    let confirmation: StockUseConfirmation
}

/// A confirmed batch as the only writes a connector may make (Plan MM §6;
/// `Contracts/stock-systems.md`). Pure.
///
/// Each staged line becomes exactly one entry: one write, or a note of why it was not sent. A
/// write is a part line on the system's job or an adjustment with a reason, never both for one
/// line, chosen once for the whole batch by `route(capabilities:reference:)` (Decision 4). There
/// is no step for a count, a set level, a sale, a price, a new catalogue item or a change to a
/// job's status (Decisions 6 and 7): those cannot be built.
struct PartsUsedWritePlan: Codable, Equatable, Sendable {

    /// The two shapes a write can take.
    enum Route: Equatable, Sendable {
        /// Part lines on the system's job, which the system takes out of stock by its own rules.
        case jobPartLines(externalJobID: String)
        /// Adjustments out of stock at the location, with the organisation's reason.
        case adjustments(StockAdjustmentReason?)
    }

    /// A part line on the system's own job, linked to the inventory item.
    struct JobPartLine: Codable, Equatable, Sendable {
        let idempotencyKey: String
        let stagedLineID: String
        let externalJobID: String
        let itemID: String
        /// `StockQuantity.decimalString`.
        let quantity: String
        let unit: VanStockUnit
    }

    /// One adjustment out of stock at a location.
    struct Adjustment: Codable, Equatable, Sendable {
        let idempotencyKey: String
        let stagedLineID: String
        let itemID: String
        let locationID: String
        /// `StockQuantity.decimalString`.
        let quantity: String
        let unit: VanStockUnit
        let reason: StockAdjustmentReason
        /// The job's number, where the system has a note field.
        let note: String?
    }

    /// The only writes there are.
    enum Step: Equatable, Sendable {
        case jobPartLine(JobPartLine)
        case adjustment(Adjustment)

        /// The step's kind, as its idempotency key and the contract name it.
        var kind: Kind {
            switch self {
            case .jobPartLine: return .jobPartLine
            case .adjustment: return .adjustment
            }
        }

        var idempotencyKey: String {
            switch self {
            case .jobPartLine(let line): return line.idempotencyKey
            case .adjustment(let adjustment): return adjustment.idempotencyKey
            }
        }

        var stagedLineID: String {
            switch self {
            case .jobPartLine(let line): return line.stagedLineID
            case .adjustment(let adjustment): return adjustment.stagedLineID
            }
        }
    }

    /// The closed list of kinds, as written.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case jobPartLine = "job_part_line"
        case adjustment
    }

    /// Why a line was kept on the phone.
    enum NotSentReason: Equatable, Sendable {
        /// The system does not carry the item.
        case notCarried
        /// The quantity could not be written (`StockSystemOutRefusal`).
        case quantity(StockSystemOutRefusal)
        /// No adjustment reason is chosen, or the system does not keep the chosen one.
        case noReason

        var code: String {
            switch self {
            case .notCarried: return "not_carried"
            case .quantity(.unitNotKept): return "unit_not_kept"
            case .quantity(.fractional): return "fractional"
            case .quantity(.outOfRange): return "out_of_range"
            case .noReason: return "no_reason"
            }
        }
    }

    struct NotSent: Equatable, Sendable {
        let stagedLineID: String
        let reason: NotSentReason
        /// What the record and the person are told: "not in Fixture Till's catalogue, so not sent".
        let sentence: String
    }

    enum Entry: Equatable, Sendable {
        case write(Step)
        case notSent(NotSent)

        var stagedLineID: String {
            switch self {
            case .write(let step): return step.stagedLineID
            case .notSent(let notSent): return notSent.stagedLineID
            }
        }
    }

    let jobID: String
    let connectorID: String
    let entries: [Entry]

    var steps: [Step] {
        entries.compactMap { if case .write(let step) = $0 { return step } else { return nil } }
    }

    var notSent: [NotSent] {
        entries.compactMap { if case .notSent(let notSent) = $0 { return notSent } else { return nil } }
    }

    // MARK: - Building

    /// Decision 4, in one place: part lines on the job when the system has jobs and the job
    /// carries that system's reference; otherwise adjustments with the organisation's reason, when
    /// the system keeps it.
    static func route(capabilities: StockSystemCapabilities, reference: ExternalJobReference?) -> Route {
        if capabilities.hasJobs, let reference,
           reference.system.lowercased() == capabilities.connectorID.lowercased(),
           !reference.jobID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .jobPartLines(externalJobID: reference.jobID)
        }
        let reason = capabilities.chosenReason.flatMap { capabilities.adjustmentReasons.contains($0) ? $0 : nil }
        return .adjustments(reason)
    }

    /// The plan for a confirmed batch. `snapshot` is the system's current stock: a line whose item
    /// it does not carry, or carries in another unit, is not sent.
    init(batch: ConfirmedStockUseBatch, reference: ExternalJobReference?, capabilities: StockSystemCapabilities,
         snapshot: StockSystemSnapshot) {
        let route = Self.route(capabilities: capabilities, reference: reference)
        let system = capabilities.displayName
        var entries: [Entry] = []
        var seen = Set<String>()
        for use in batch.lines where seen.insert(use.id).inserted {
            func notSent(_ reason: NotSentReason, _ sentence: String) -> Entry {
                .notSent(NotSent(stagedLineID: use.id, reason: reason, sentence: sentence))
            }
            guard let itemID = use.itemID, let line = snapshot.lines.first(where: { $0.itemID == itemID }) else {
                entries.append(notSent(.notCarried, "\(use.name): not in \(system)'s catalogue, so not sent."))
                continue
            }
            let quantity: String
            switch StockSystemQuantityConversion.outgoing(use.quantity, unit: use.unit, itemUnit: line.unit,
                                                          wholeNumbersOnly: capabilities.wholeNumbersOnly) {
            case .success(let text):
                quantity = text
            case .failure(let refusal):
                entries.append(notSent(.quantity(refusal), "\(use.name): "
                    + refusal.sentence(system: system, quantity: use.quantity, unit: use.unit)))
                continue
            }
            switch route {
            case .jobPartLines(let externalJobID):
                entries.append(.write(.jobPartLine(JobPartLine(
                    idempotencyKey: Self.idempotencyKey(jobID: batch.jobID, stagedLineID: use.id, kind: .jobPartLine),
                    stagedLineID: use.id, externalJobID: externalJobID, itemID: itemID,
                    quantity: quantity, unit: use.unit))))
            case .adjustments(let reason?):
                let note = capabilities.adjustmentNote ? batch.jobNumber.flatMap { $0.isEmpty ? nil : $0 } : nil
                entries.append(.write(.adjustment(Adjustment(
                    idempotencyKey: Self.idempotencyKey(jobID: batch.jobID, stagedLineID: use.id, kind: .adjustment),
                    stagedLineID: use.id, itemID: itemID, locationID: batch.locationID,
                    quantity: quantity, unit: use.unit, reason: reason, note: note))))
            case .adjustments(nil):
                entries.append(notSent(.noReason, "\(use.name): no reason for parts used is chosen for \(system), "
                    + "so not sent."))
            }
        }
        self.jobID = batch.jobID
        self.connectorID = capabilities.connectorID
        self.entries = entries
    }

    /// Lower-case SHA-256 hex over the UTF-8 of the job id, the staged line id and the step kind,
    /// each followed by one zero byte (`Contracts/stock-systems.md`). The same batch always gives
    /// the same keys, so a resend is recognised.
    static func idempotencyKey(jobID: String, stagedLineID: String, kind: Kind) -> String {
        var bytes = Data()
        for part in [jobID, stagedLineID, kind.rawValue] {
            bytes.append(contentsOf: Array(part.utf8))
            bytes.append(0)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The steps still to send after a read-back: every step whose key the system did not show as
    /// applied. A retry sends only these, never the whole plan again.
    func remaining(after readBack: StockSystemReadBack) -> [Step] {
        steps.filter { readBack.applied.contains($0.idempotencyKey) == false }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey { case jobID, connectorID, entries }

    private struct StoredEntry: Codable {
        let kind: String
        let jobPartLine: JobPartLine?
        let adjustment: Adjustment?
        let stagedLineID: String?
        let reason: String?
        let sentence: String?
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(connectorID, forKey: .connectorID)
        try container.encode(entries.map { entry -> StoredEntry in
            switch entry {
            case .write(.jobPartLine(let line)):
                return StoredEntry(kind: Kind.jobPartLine.rawValue, jobPartLine: line, adjustment: nil,
                                   stagedLineID: nil, reason: nil, sentence: nil)
            case .write(.adjustment(let adjustment)):
                return StoredEntry(kind: Kind.adjustment.rawValue, jobPartLine: nil, adjustment: adjustment,
                                   stagedLineID: nil, reason: nil, sentence: nil)
            case .notSent(let notSent):
                return StoredEntry(kind: "not_sent", jobPartLine: nil, adjustment: nil,
                                   stagedLineID: notSent.stagedLineID, reason: notSent.reason.code, sentence: notSent.sentence)
            }
        }, forKey: .entries)
    }

    /// A stored plan read back. An entry of any other kind is refused, so a plan can never come
    /// back holding a write this build cannot make.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        connectorID = try container.decode(String.self, forKey: .connectorID)
        entries = try container.decode([StoredEntry].self, forKey: .entries).map { stored in
            switch stored.kind {
            case Kind.jobPartLine.rawValue:
                guard let line = stored.jobPartLine else { break }
                return .write(.jobPartLine(line))
            case Kind.adjustment.rawValue:
                guard let adjustment = stored.adjustment else { break }
                return .write(.adjustment(adjustment))
            case "not_sent":
                guard let id = stored.stagedLineID, let code = stored.reason, let sentence = stored.sentence,
                      let reason = NotSentReason(code: code) else { break }
                return .notSent(NotSent(stagedLineID: id, reason: reason, sentence: sentence))
            default:
                break
            }
            throw DecodingError.dataCorruptedError(forKey: .entries, in: container,
                                                   debugDescription: "Unknown or incomplete entry: \(stored.kind)")
        }
    }
}

private extension PartsUsedWritePlan.NotSentReason {
    init?(code: String) {
        switch code {
        case "not_carried": self = .notCarried
        case "unit_not_kept": self = .quantity(.unitNotKept)
        case "fractional": self = .quantity(.fractional)
        case "out_of_range": self = .quantity(.outOfRange)
        case "no_reason": self = .noReason
        default: return nil
        }
    }
}
