import Foundation
import CryptoKit

// MARK: - Chained record

/// One audit event with its place in the chain.
///
/// `prevDigest` links a record to the one before it, so altering, deleting or reordering any
/// record breaks every link after it. `digest` is stored as well as computed: without it, editing
/// the *last* record would leave nothing to disagree with until the next append.
struct AuditChainedEvent: Codable, Identifiable, Equatable {
    let sequence: Int
    let prevDigest: String
    let event: AuditEvent
    /// The digest as it was written. Absent for a record this process just built.
    private(set) var storedDigest: String?

    var id: UUID { event.eventID }

    var digest: String { AuditChain.digest(sequence: sequence, prevDigest: prevDigest, event: event) }

    init(sequence: Int, prevDigest: String, event: AuditEvent) {
        self.sequence = sequence
        self.prevDigest = prevDigest
        self.event = event
        self.storedDigest = nil
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, prevDigest, digest, event
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(prevDigest, forKey: .prevDigest)
        try container.encode(digest, forKey: .digest)
        try container.encode(event, forKey: .event)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(Int.self, forKey: .sequence)
        prevDigest = try container.decode(String.self, forKey: .prevDigest)
        event = try container.decode(AuditEvent.self, forKey: .event)
        storedDigest = try container.decodeIfPresent(String.self, forKey: .digest)
    }
}

// MARK: - Verdict

/// What a verification pass concluded about a stored log.
enum AuditChainVerification: Equatable {
    case intact
    /// A record was altered, removed from the middle, or reordered. `at` is the sequence number of
    /// the first record that no longer agrees with the one before it.
    case broken(at: Int)
    /// Nothing is stored, but a checkpoint says there should be. `expectedCount` is how many
    /// records the checkpoint last saw.
    case truncated(expectedCount: Int)
    /// A valid but older log — a restored backup, or a tail lopped off — put back in place of the
    /// one the checkpoint last saw.
    case rolledBack

    var isIntact: Bool { self == .intact }

    /// Fixed token for the audit record this verdict produces. Never localized, never free text.
    var auditToken: String {
        switch self {
        case .intact: return "INTACT"
        case .broken: return "BROKEN"
        case .truncated: return "TRUNCATED"
        case .rolledBack: return "ROLLED_BACK"
        }
    }
}

// MARK: - The chain

/// Sequence-and-digest chaining for the medical-compliance audit log (roadmap W05.3).
///
/// **This is tamper-EVIDENT, not immutable evidence.** The chain and its checkpoint both live on
/// the device the log is written on: someone with the device, the app's keychain and enough
/// patience can rebuild a consistent chain and reseal a checkpoint over it. What this does buy is
/// what the roadmap's exit gate asks for — a managed deployment's reviewer can tell, from the log
/// and the checkpoint alone, that records were altered, deleted, reordered, truncated or rolled
/// back by anything short of a deliberate forgery, and can tell it without trusting the app that
/// wrote them. Evidence that survives a motivated local attacker needs a checkpoint stored
/// somewhere this device cannot reach, which is a managed-deployment integration and is recorded
/// as owed.
enum AuditChain {

    /// The `prevDigest` of the first record ever written.
    static let genesisDigest = String(repeating: "0", count: 64)

    /// The digest inputs, in a fixed order, joined by a separator that cannot occur inside any of
    /// them (every field is a token, a fingerprint, a number or a formatted timestamp). Field
    /// order is part of the format: changing it changes every digest, which is why it is written
    /// out once here rather than derived from an encoder's key order.
    static func digest(sequence: Int, prevDigest: String, event: AuditEvent) -> String {
        let material = [
            String(sequence),
            prevDigest,
            event.eventID.uuidString,
            AuditEvent.timestampFormatter.string(from: event.at),
            event.kind.rawValue,
            event.actorClass.rawValue,
            event.targetClass.rawValue,
            event.purpose ?? "",
            event.policyVersion,
            event.result.rawValue,
            event.correlationID ?? "",
            event.decision?.rawValue ?? "",
            event.count.map(String.init) ?? "",
            event.subjectDigest ?? "",
            event.legacyAction ?? "",
            event.detailFingerprint ?? "",
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Extend a chain. `tail` is the last record currently held, or nil for a fresh log; `from`
    /// lets a cleared log carry on from the checkpoint's sequence instead of restarting at zero,
    /// so an authorized clear does not read as a rollback.
    static func append(_ event: AuditEvent, to tail: AuditChainedEvent?,
                       continuingFrom fallbackSequence: Int = 0) -> AuditChainedEvent {
        AuditChainedEvent(sequence: tail.map { $0.sequence + 1 } ?? fallbackSequence,
                          prevDigest: tail?.digest ?? genesisDigest,
                          event: event)
    }

    /// Rebuild a chain over records that have none — the migration path for a pre-schema log.
    static func rebuild(_ events: [AuditEvent], from startSequence: Int = 0) -> [AuditChainedEvent] {
        var chained: [AuditChainedEvent] = []
        for event in events {
            chained.append(append(event, to: chained.last, continuingFrom: startSequence))
        }
        return chained
    }

    /// Verify a stored log against itself and, when there is one, against the checkpoint.
    ///
    /// The two are different questions. Self-consistency catches an edit, a deletion from the
    /// middle and a reorder; only the checkpoint catches a log replaced wholesale by an older —
    /// and internally perfectly valid — copy of itself.
    static func verify(events: [AuditChainedEvent],
                       checkpoint: AuditCheckpoint?) -> AuditChainVerification {
        for (index, entry) in events.enumerated() {
            if index > 0 {
                let previous = events[index - 1]
                guard entry.sequence == previous.sequence + 1,
                      entry.prevDigest == previous.digest else {
                    return .broken(at: entry.sequence)
                }
            }
            if let stored = entry.storedDigest, stored != entry.digest {
                return .broken(at: entry.sequence)
            }
        }

        guard let checkpoint else { return .intact }
        guard let head = events.last else {
            return .truncated(expectedCount: checkpoint.sequence + 1)
        }
        guard head.sequence >= checkpoint.sequence else { return .rolledBack }
        if let atCheckpoint = events.first(where: { $0.sequence == checkpoint.sequence }),
           atCheckpoint.digest != checkpoint.headDigest {
            return .broken(at: checkpoint.sequence)
        }
        // A checkpointed record older than the retention window is simply gone; the records that
        // remain still have to be self-consistent, and they are, or we returned above.
        return .intact
    }
}

// MARK: - Checkpoint

/// A sealed statement of where the log had got to: how many records, and what the last one
/// digested to.
///
/// The seal is an HMAC over the three fields, keyed by a device-local secret. It does not make the
/// checkpoint unforgeable on this device — the key is here too — but it does mean the stored blob
/// cannot be edited or replayed from a copy taken outside the keychain.
struct AuditCheckpoint: Codable, Equatable, Sendable {
    let sequence: Int
    let headDigest: String
    let at: Date
    let seal: String

    init(sequence: Int, headDigest: String, at: Date, key: SymmetricKey) {
        self.sequence = sequence
        self.headDigest = headDigest
        let truncated = Date(timeIntervalSinceReferenceDate:
                                (at.timeIntervalSinceReferenceDate * 1000).rounded() / 1000)
        self.at = truncated
        self.seal = Self.seal(sequence: sequence, headDigest: headDigest, at: truncated, key: key)
    }

    func isSealed(with key: SymmetricKey) -> Bool {
        seal == Self.seal(sequence: sequence, headDigest: headDigest, at: at, key: key)
    }

    static func seal(sequence: Int, headDigest: String, at: Date, key: SymmetricKey) -> String {
        let material = [String(sequence), headDigest,
                        AuditEvent.timestampFormatter.string(from: at)].joined(separator: "\u{1F}")
        return HMAC<SHA256>.authenticationCode(for: Data(material.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a checkpoint could not be read or written.
enum AuditCheckpointFault: Error, Equatable {
    /// The stored blob does not match its seal — edited, or copied from another device.
    case sealMismatch
    /// Protected storage would not answer.
    case unavailable
}

/// Where the checkpoint lives. A seam because the production home is the keychain, which is not
/// available to a headless test process, and because a managed deployment will eventually want a
/// second, off-device home for the same value.
protocol AuditCheckpointStore: AnyObject {
    func load() throws -> AuditCheckpoint?
    func save(sequence: Int, headDigest: String, at: Date) throws
    func clear() throws
}

/// Production: the keychain, this device only, readable only while unlocked — the same class the
/// audit log's own file protection uses, so the checkpoint is never readable when the log is not.
/// Never synced to iCloud, so a restored backup cannot carry an old checkpoint forward with it.
final class KeychainAuditCheckpointStore: AuditCheckpointStore {

    private let checkpointAccount: String
    private let keyAccount: String

    init(checkpointAccount: String = "medical.audit.checkpoint",
         keyAccount: String = "medical.audit.checkpoint.key") {
        self.checkpointAccount = checkpointAccount
        self.keyAccount = keyAccount
    }

    func load() throws -> AuditCheckpoint? {
        let data: Data?
        do {
            data = try KeychainService.readData(for: checkpointAccount)
        } catch {
            throw AuditCheckpointFault.unavailable
        }
        guard let data else { return nil }
        guard let checkpoint = try? JSONDecoder().decode(AuditCheckpoint.self, from: data) else {
            throw AuditCheckpointFault.sealMismatch
        }
        guard checkpoint.isSealed(with: try sealingKey()) else {
            throw AuditCheckpointFault.sealMismatch
        }
        return checkpoint
    }

    func save(sequence: Int, headDigest: String, at: Date) throws {
        let checkpoint = AuditCheckpoint(sequence: sequence, headDigest: headDigest, at: at,
                                         key: try sealingKey())
        do {
            try KeychainService.writeData(try JSONEncoder().encode(checkpoint),
                                          for: checkpointAccount,
                                          accessibility: .whenUnlockedThisDeviceOnly)
        } catch {
            throw AuditCheckpointFault.unavailable
        }
    }

    func clear() throws {
        do {
            try KeychainService.deleteItem(checkpointAccount)
        } catch {
            throw AuditCheckpointFault.unavailable
        }
    }

    /// Created on first use and never rotated: rotating it would invalidate the checkpoint it is
    /// there to protect, which is the opposite of the point.
    private func sealingKey() throws -> SymmetricKey {
        if let existing = try? KeychainService.readData(for: keyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        do {
            try KeychainService.writeData(bytes, for: keyAccount,
                                          accessibility: .whenUnlockedThisDeviceOnly)
        } catch {
            throw AuditCheckpointFault.unavailable
        }
        return key
    }
}
