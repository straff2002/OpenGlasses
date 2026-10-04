import CryptoKit
import Foundation

/// What an office says about a recorded-job bundle (Contracts/recorded-session.md §6): that it
/// has it, that it refuses it, or what later came of it.
///
/// Messages only. A receipt that verifies is the one thing that lets a phone let go of a
/// recording, so it is read against the office application key of the binding held now and
/// against the phone's own record of the manifest it sealed — never against anything the receipt
/// says about itself.
enum OfficeRecordingReceipt {
    static let domain = Data("Avenkin.RecordingReceipt.v1\0".utf8)
    static let kind = "avenkin.recording-receipt"
    static let maximumMessageBytes = 8_192
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let refusalReasons = ["signature", "binding", "digest", "too_large", "policy"]

    enum Status: String, Sendable {
        /// The office holds every file and has checked every digest.
        case received
        /// The office will not take the bundle; `reason` says why.
        case refused
        case reviewed
        /// A procedure went out from the recording, as the vault named.
        case published
        case rejected
    }

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    /// The closed payload. Every member is always present; one that does not apply is empty.
    struct Receipt: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let bundleID: String
        let manifestSHA256: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let phoneTransportID: String
        let status: String
        let reason: String
        let vaultID: String
        let vaultVersion: String
        let at: Int64
    }

    /// The binding a receipt is read against, from the pairing gate passing now. The generation is
    /// not part of it: a receipt names the generation of the manifest it answers.
    struct Trust: Equatable, Sendable {
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let officeApplicationKey: Data
    }

    /// The phone's own record of the manifest it sealed.
    struct Sent: Equatable, Sendable {
        let bundleID: String
        let manifestSHA256: String
        let generation: Int64
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case invalidFields
        /// For another organisation, enrolment, office or phone.
        case wrongBinding
        /// For another bundle, another manifest, or a manifest sealed under another generation.
        case anotherBundle
    }

    private static let fields: Set<String> = [
        "version", "kind", "bundleID", "manifestSHA256", "organizationID", "enrolmentID", "officeID",
        "generation", "phoneTransportID", "status", "reason", "vaultID", "vaultVersion", "at"]

    /// The phone's check of a receipt (contract §6).
    static func read(_ data: Data, trust: Trust, sent: Sent) throws -> Receipt {
        guard !data.isEmpty, data.count <= maximumMessageBytes,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = Data(base64Encoded: envelope.payload), raw.base64EncodedString() == envelope.payload,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              signature.base64EncodedString() == envelope.signature else { throw Refusal.malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: trust.officeApplicationKey),
              key.isValidSignature(signature, for: domain + raw) else { throw Refusal.badSignature }
        guard OfficeManualAssignment.flatObject(raw, keys: fields),
              let r = try? JSONDecoder().decode(Receipt.self, from: raw) else { throw Refusal.malformed }
        guard r.organizationID == trust.organizationID, r.enrolmentID == trust.enrolmentID,
              r.officeID == trust.officeID, r.phoneTransportID == trust.phoneTransportID else {
            throw Refusal.wrongBinding
        }
        guard valid(r) else { throw Refusal.invalidFields }
        guard r.bundleID == sent.bundleID, r.manifestSHA256 == sent.manifestSHA256,
              r.generation == sent.generation else { throw Refusal.anotherBundle }
        return r
    }

    private static func valid(_ r: Receipt) -> Bool {
        guard r.version == 1, r.kind == kind, hex(r.bundleID, count: 32), hex(r.manifestSHA256, count: 64),
              [r.organizationID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              instant(r.generation), instant(r.at), let status = Status(rawValue: r.status) else { return false }
        let noVault = r.vaultID.isEmpty && r.vaultVersion.isEmpty
        switch status {
        case .received, .reviewed, .rejected:
            return r.reason.isEmpty && noVault
        case .refused:
            return refusalReasons.contains(r.reason) && noVault
        case .published:
            return r.reason.isEmpty && OfficeManualAssignment.safeIdentifier(r.vaultID)
                && OfficeManualAssignment.safeIdentifier(r.vaultVersion)
        }
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func instant(_ value: Int64) -> Bool { value > 0 && value <= maximumSafeInteger }
}
