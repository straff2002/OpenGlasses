import CryptoKit
import Foundation

/// Signed transport reference for one immutable .ogjob file. Verification permits staging the
/// exact bytes for JobFileService review; it never adds a job or counts as technician acceptance.
enum OfficeManagedJob {
    static let domain = Data("Avenkin.ManagedJob.v1\0".utf8)
    static let maximumEnvelopeBytes = 131_072
    static let maximumJobBytes: Int64 = 65_536
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let messageID: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let officeTransportID: String
        let phoneTransportID: String
        let sequence: Int64
        let issuedAt: Int64
        let expiresAt: Int64
        let jobSHA256: String
        let jobBytes: Int64
    }
    struct Envelope: Codable {
        let payload: String
        let signature: String
    }
    /// Supply only after OfficePairingService.currentApprovedPeer() has rechecked its binding.
    struct Trust: Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let officeTransportID: String
        let phoneTransportID: String
        let officeApplicationKey: Data

    }
    struct HighWater: Equatable, Sendable {
        let generation: Int64
        let sequence: Int64
        let payloadSHA256: String
    }
    struct Verified: Sendable {
        let payload: Payload
        let payloadSHA256: String
        let isReplay: Bool
        var highWater: HighWater {
            HighWater(generation: payload.generation, sequence: payload.sequence,
                      payloadSHA256: payloadSHA256)
        }
    }
    enum Refusal: Error, Equatable {
        case malformed, badSignature, wrongBinding, invalidFields, notCurrentlyValid
        case rollback, sequenceConflict, contentMismatch
    }

    static func verify(_ data: Data, trust: Trust, now: Int64,
                       highWater: HighWater? = nil) throws -> Verified {
        guard data.count <= maximumEnvelopeBytes,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = Data(base64Encoded: envelope.payload),
              raw.base64EncodedString() == envelope.payload,
              raw.count <= maximumEnvelopeBytes,
              OfficeManualAssignment.flatObject(raw, keys: ["version", "kind", "messageID",
                "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID",
                "phoneTransportID", "sequence", "issuedAt", "expiresAt", "jobSHA256", "jobBytes"]),
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64 else {
            throw Refusal.malformed
        }
        guard signature.base64EncodedString() == envelope.signature else {
            throw Refusal.malformed
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.officeApplicationKey),
              key.isValidSignature(signature, for: domain + raw) else { throw Refusal.badSignature }
        guard let p = try? JSONDecoder().decode(Payload.self, from: raw) else { throw Refusal.malformed }
        guard p.organizationID == trust.organizationID, p.enrolmentID == trust.enrolmentID,
              p.officeID == trust.officeID, p.generation == trust.generation,
              p.officeTransportID == trust.officeTransportID,
              p.phoneTransportID == trust.phoneTransportID else { throw Refusal.wrongBinding }
        guard p.version == 1, p.kind == "avenkin.managed-job",
              hex(p.messageID, count: 32), hex(p.jobSHA256, count: 64),
              [p.organizationID, p.enrolmentID, p.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              canonicalDeviceID(p.officeTransportID), canonicalDeviceID(p.phoneTransportID),
              p.generation > 0, p.generation <= maximumSafeInteger,
              p.sequence > 0, p.sequence <= maximumSafeInteger,
              p.issuedAt > 0, p.expiresAt > p.issuedAt, p.expiresAt <= maximumSafeInteger,
              p.expiresAt - p.issuedAt <= 30 * 86_400,
              p.jobBytes > 0, p.jobBytes <= maximumJobBytes else { throw Refusal.invalidFields }
        guard now >= p.issuedAt, now < p.expiresAt else { throw Refusal.notCurrentlyValid }
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        var replay = false
        if let highWater {
            guard p.generation >= highWater.generation,
                  p.generation != highWater.generation || p.sequence >= highWater.sequence else {
                throw Refusal.rollback
            }
            if p.generation == highWater.generation, p.sequence == highWater.sequence {
                guard digest == highWater.payloadSHA256 else { throw Refusal.sequenceConflict }
                replay = true
            }
        }
        return Verified(payload: p, payloadSHA256: digest, isReplay: replay)
    }

    static func verifyBytes(_ job: Data, for verified: Verified) throws {
        let digest = SHA256.hash(data: job).map { String(format: "%02x", $0) }.joined()
        guard Int64(job.count) == verified.payload.jobBytes,
              digest == verified.payload.jobSHA256 else { throw Refusal.contentMismatch }
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func canonicalDeviceID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 8 && parts.allSatisfy { part in
            part.utf8.count == 7 && part.utf8.allSatisfy {
                (65...90).contains($0) || (50...55).contains($0)
            }
        }
    }
}
