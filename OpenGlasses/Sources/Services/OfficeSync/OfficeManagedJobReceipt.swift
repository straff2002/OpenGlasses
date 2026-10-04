import CryptoKit
import Foundation

/// The phone's signed statement that it verified one managed job and committed its exact bytes
/// (Contracts/README.md, "Managed job receipt"). The transport builds the payload and hands it
/// over as exact bytes; the phone application key signs `domain` followed by those bytes, and
/// nothing is re-encoded. A receipt is not the technician accepting the job, and a finished
/// transfer never produces one.
enum OfficeManagedJobReceipt {
    static let domain = Data("Avenkin.ManagedJobReceipt.v1\0".utf8)
    static let kind = "avenkin.managed-job-receipt"
    /// The only outcome in v1: verified and durably committed.
    static let outcomeReceived = "received"
    static let maximumBytes = 8_192
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let fields: Set<String> = [
        "version", "kind", "messageID", "organizationID", "enrolmentID", "officeID", "generation",
        "phoneTransportID", "sequence", "payloadSHA256", "jobSHA256", "outcome", "receivedAt"]

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let messageID: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
        let sequence: Int64
        let payloadSHA256: String
        let jobSHA256: String
        let outcome: String
        let receivedAt: Int64
    }
    struct Envelope: Codable {
        let payload: String
        let signature: String
    }
    /// The office's side of the check: the binding the job was sent under and the phone
    /// application key that binding names. Never taken from the receipt.
    struct Trust: Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
        let phoneApplicationKey: Data
    }
    /// The office's own record of the message a receipt must be for.
    struct Expected: Sendable {
        let messageID: String
        let sequence: Int64
        let payloadSHA256: String
        let jobSHA256: String
    }
    enum Refusal: Error, Equatable {
        case malformed, badSignature, wrongBinding, invalidFields, wrongMessage
    }

    /// The receipt these exact bytes state, or nil unless they are a closed, flat receipt payload
    /// within the field rules. The phone signs nothing else under the receipt domain.
    static func payload(_ raw: Data) -> Payload? {
        guard !raw.isEmpty, raw.count <= maximumBytes,
              OfficeManualAssignment.flatObject(raw, keys: fields),
              let receipt = try? JSONDecoder().decode(Payload.self, from: raw),
              valid(receipt) else { return nil }
        return receipt
    }

    /// The office's check, in the contract's order: closed envelope and payload, the signature
    /// over the exact payload bytes under the binding's phone application key, the binding, the
    /// field rules, and that the receipt is for exactly the message the office sent.
    static func verify(_ data: Data, trust: Trust, expected: Expected) throws -> Payload {
        guard data.count <= maximumBytes,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = Data(base64Encoded: envelope.payload),
              raw.base64EncodedString() == envelope.payload,
              OfficeManualAssignment.flatObject(raw, keys: fields),
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              signature.base64EncodedString() == envelope.signature else { throw Refusal.malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.phoneApplicationKey),
              key.isValidSignature(signature, for: domain + raw) else { throw Refusal.badSignature }
        guard let r = try? JSONDecoder().decode(Payload.self, from: raw) else { throw Refusal.malformed }
        guard r.organizationID == trust.organizationID, r.enrolmentID == trust.enrolmentID,
              r.officeID == trust.officeID, r.generation == trust.generation,
              r.phoneTransportID == trust.phoneTransportID else { throw Refusal.wrongBinding }
        guard valid(r) else { throw Refusal.invalidFields }
        guard r.messageID == expected.messageID, r.sequence == expected.sequence,
              r.payloadSHA256 == expected.payloadSHA256,
              r.jobSHA256 == expected.jobSHA256 else { throw Refusal.wrongMessage }
        return r
    }

    private static func valid(_ r: Payload) -> Bool {
        r.version == 1 && r.kind == kind
            && hex(r.messageID, count: 32) && hex(r.payloadSHA256, count: 64) && hex(r.jobSHA256, count: 64)
            && [r.organizationID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && canonicalDeviceID(r.phoneTransportID)
            && r.generation > 0 && r.generation <= maximumSafeInteger
            && r.sequence > 0 && r.sequence <= maximumSafeInteger
            && r.outcome == outcomeReceived
            && r.receivedAt > 0 && r.receivedAt <= maximumSafeInteger
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
