import CryptoKit
import Foundation

/// Retains the last administrator-authorised office generation independently of vault content.
/// A production caller must first check the current managed enrolment, licence and lease, and
/// verify a binding against the phone's actual keys. This store is only the rollback boundary.
actor OfficePeerHighWaterStore {
    struct HighWater: Codable, Equatable, Sendable {
        let scopeID: String
        let generation: Int64
        let payloadSHA256: String
    }

    enum Decision: Equatable, Sendable {
        case accepted(HighWater)
        case replay(HighWater)
    }

    enum Refusal: Error, Equatable {
        case invalidScope
        case corruptState
        case rollback
        case generationConflict
    }

    static let shared = OfficePeerHighWaterStore()
    private let keyPrefix: String

    init(keyPrefix: String = "office.peer.highwater.v1.") {
        self.keyPrefix = keyPrefix
    }

    static func scopeID(organizationID: String, enrolmentID: String) throws -> String {
        guard OfficeManualAssignment.safeIdentifier(organizationID),
              OfficeManualAssignment.safeIdentifier(enrolmentID) else { throw Refusal.invalidScope }
        let bytes = Data((organizationID + "\0" + enrolmentID).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func read(organizationID: String, enrolmentID: String) throws -> HighWater? {
        let scope = try Self.scopeID(organizationID: organizationID, enrolmentID: enrolmentID)
        guard let bytes = try KeychainService.readData(for: keyPrefix + scope) else { return nil }
        guard bytes.count <= 1_024,
              let state = try? JSONDecoder().decode(HighWater.self, from: bytes),
              state.scopeID == scope, state.generation > 0,
              state.generation <= OfficePeerBinding.maximumSafeInteger,
              state.payloadSHA256.utf8.count == 64,
              state.payloadSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Refusal.corruptState
        }
        return state
    }

    /// Commit before opening a share or accepting content. Exact repeats are idempotent;
    /// replacing an office or its keys requires a higher administrator-signed generation.
    func accept(_ binding: OfficePeerBinding.Verified) throws -> Decision {
        let p = binding.payload
        let scope = try Self.scopeID(organizationID: p.organizationID, enrolmentID: p.enrolmentID)
        if let previous = try read(organizationID: p.organizationID, enrolmentID: p.enrolmentID) {
            guard p.generation >= previous.generation else { throw Refusal.rollback }
            if p.generation == previous.generation {
                guard binding.payloadSHA256 == previous.payloadSHA256 else { throw Refusal.generationConflict }
                return .replay(previous)
            }
        }
        let next = HighWater(scopeID: scope, generation: p.generation,
                             payloadSHA256: binding.payloadSHA256)
        let bytes = try JSONEncoder().encode(next)
        try KeychainService.upsertDataAtomically(bytes, for: keyPrefix + scope,
                                                  accessibility: .afterFirstUnlockThisDeviceOnly)
        return .accepted(next)
    }
}
