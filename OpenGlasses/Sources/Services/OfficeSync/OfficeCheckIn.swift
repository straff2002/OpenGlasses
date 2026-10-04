import CryptoKit
import Foundation

/// The messages of the office check-in, renewal and removal contract
/// (Contracts/office-check-in.md) as this phone reads them: the challenge an office sets, the
/// check-in the phone answers with, the administrator-signed result that carries a renewed peer
/// binding, and the administrator-signed removal with the phone's receipt.
///
/// Messages only. Every key is the caller's — the office and phone application keys from a
/// binding verified just now, the administrator key from the vendor-verified profile — and never
/// one a message carries. Verifying a message here commits nothing: a result's binding still has
/// to pass `OfficePeerBinding.verify` and the pairing gate, which is `OfficePairingService`'s.
enum OfficeCheckIn {
    static let challengeDomain = Data("Avenkin.OfficeCheckInChallenge.v1\0".utf8)
    static let checkInDomain = Data("Avenkin.OfficeCheckIn.v1\0".utf8)
    static let resultDomain = Data("Avenkin.OfficeCheckInResult.v1\0".utf8)
    static let removalDomain = Data("Avenkin.OfficeRemoval.v1\0".utf8)
    static let removalReceiptDomain = Data("Avenkin.OfficeRemovalReceipt.v1\0".utf8)

    static let challengeKind = "avenkin.office-check-in-challenge"
    static let checkInKind = "avenkin.office-check-in"
    static let resultKind = "avenkin.office-check-in-result"
    static let removalKind = "avenkin.office-removal"
    static let removalReceiptKind = "avenkin.office-removal-receipt"

    /// The only outcome a result has in v1.
    static let outcomeRenewed = "renewed"
    static let reasonRemoved = "removed"
    static let reasonRevoked = "revoked"

    /// The cap on every message but the result.
    static let maximumMessageBytes = 4_096
    static let maximumResultBytes = 65_536
    static let maximumBindingBytes = 32_768
    static let maximumChallengeLifetime: Int64 = 7 * 86_400
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    struct Challenge: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let challengeID: String
        let nonce: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let generation: Int64
        let bindingSHA256: String
        let issuedAt: Int64
        let expiresAt: Int64
    }

    struct CheckIn: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let challengeID: String
        let challengeSHA256: String
        let nonce: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let generation: Int64
        let bindingSHA256: String
        let leaseRenewBy: Int64
        let appVersion: String
        let appBuild: String
        let createdAt: Int64
    }

    struct Result: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let challengeID: String
        let checkInSHA256: String
        let organizationID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let outcome: String
        let peerBinding: String
        let issuedAt: Int64
    }

    struct Removal: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let removalID: String
        let organizationID: String
        let profileID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let reason: String
        let issuedAt: Int64
    }

    struct RemovalReceipt: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let removalID: String
        let removalSHA256: String
        let organizationID: String
        let enrolmentID: String
        let phoneTransportID: String
        let actedAt: Int64
    }

    /// The binding this phone holds, as a check-in is checked against it. Supply only from a
    /// binding `OfficePairingService.currentApprovedPeer()` has verified at that moment, with the
    /// administrator key of the vendor-verified profile.
    struct Held: Equatable, Sendable {
        let organizationID: String
        let profileID: String
        let enrolmentID: String
        let officeID: String
        let phoneTransportID: String
        let generation: Int64
        /// SHA-256 of the binding's decoded payload bytes: the value kept with the generation
        /// high-water mark.
        let bindingSHA256: String
        let officeApplicationKey: Data
        let phoneApplicationKey: Data
        let administratorKey: Data
    }

    /// The one check-in the phone is waiting on, as far as a result is matched to it.
    struct Waiting: Equatable, Sendable {
        let challengeID: String
        /// The message digest of the check-in as published.
        let checkInSHA256: String
        /// The binding the check-in named.
        let generation: Int64
        let bindingSHA256: String
    }

    struct VerifiedChallenge: Equatable, Sendable {
        let payload: Challenge
        /// The message digest: SHA-256 of the exact envelope bytes.
        let messageSHA256: String
    }

    struct VerifiedResult: Sendable {
        let payload: Result
        /// The renewed peer-binding envelope, unchanged. Not yet verified as a binding.
        let peerBinding: Data
    }

    /// A removal that verified. Created only by `removal(_:…)`, so nothing else can be handed to
    /// the code that revokes an enrolment.
    struct VerifiedRemoval: Sendable {
        let payload: Removal
        let messageSHA256: String
        fileprivate init(payload: Removal, messageSHA256: String) {
            self.payload = payload
            self.messageSHA256 = messageSHA256
        }
    }

    enum Refusal: Error, Equatable {
        case malformed
        case badSignature
        case invalidFields
        /// For another binding, phone, enrolment or exchange.
        case wrongBinding
        /// Not valid on this phone's clock now. It waits; it is not remembered as refused.
        case notCurrentlyValid
        /// The binding a result carries is not a renewal of the binding held.
        case notARenewal
    }

    /// The message digest of an envelope: lower-case hexadecimal SHA-256 of its exact bytes.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Challenge

    private static let challengeFields: Set<String> = [
        "version", "kind", "challengeID", "nonce", "organizationID", "enrolmentID", "officeID",
        "phoneTransportID", "generation", "bindingSHA256", "issuedAt", "expiresAt"]

    /// The phone's check of a challenge (contract §4.2): signed by the office application key the
    /// binding names, naming this phone's organisation, enrolment, office and transport identity
    /// and exactly the generation and binding digest it holds, and live on the phone's clock.
    static func challenge(_ data: Data, held: Held, now: Int64) throws -> VerifiedChallenge {
        let raw = try open(data, domain: challengeDomain, key: held.officeApplicationKey,
                           fields: challengeFields, limit: maximumMessageBytes)
        guard let c = try? JSONDecoder().decode(Challenge.self, from: raw) else { throw Refusal.malformed }
        guard c.version == 1, c.kind == challengeKind, hex(c.challengeID, count: 32), nonce(c.nonce),
              [c.organizationID, c.enrolmentID, c.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              canonicalDeviceID(c.phoneTransportID), instant(c.generation), hex(c.bindingSHA256, count: 64),
              instant(c.issuedAt), instant(c.expiresAt), c.expiresAt > c.issuedAt,
              c.expiresAt - c.issuedAt <= maximumChallengeLifetime else { throw Refusal.invalidFields }
        guard c.organizationID == held.organizationID, c.enrolmentID == held.enrolmentID,
              c.officeID == held.officeID, c.phoneTransportID == held.phoneTransportID,
              c.generation == held.generation, c.bindingSHA256 == held.bindingSHA256 else {
            throw Refusal.wrongBinding
        }
        guard now >= c.issuedAt, now < c.expiresAt else { throw Refusal.notCurrentlyValid }
        return VerifiedChallenge(payload: c, messageSHA256: digest(data))
    }

    // MARK: - Check-in

    private static let checkInFields: Set<String> = [
        "version", "kind", "challengeID", "challengeSHA256", "nonce", "organizationID", "enrolmentID",
        "officeID", "phoneTransportID", "generation", "bindingSHA256", "leaseRenewBy", "appVersion",
        "appBuild", "createdAt"]

    /// The check-in these exact bytes state, or nil unless they are a closed, flat check-in
    /// payload within the field rules. The phone signs nothing else under the check-in domain.
    static func checkInPayload(_ raw: Data) -> CheckIn? {
        guard !raw.isEmpty, raw.count <= maximumMessageBytes,
              OfficeManualAssignment.flatObject(raw, keys: checkInFields),
              let c = try? JSONDecoder().decode(CheckIn.self, from: raw), valid(c) else { return nil }
        return c
    }

    /// Whether a check-in answers exactly this challenge under exactly the binding held.
    static func answers(_ c: CheckIn, challenge: VerifiedChallenge, held: Held) -> Bool {
        c.challengeID == challenge.payload.challengeID && c.challengeSHA256 == challenge.messageSHA256
            && c.organizationID == held.organizationID && c.enrolmentID == held.enrolmentID
            && c.officeID == held.officeID && c.phoneTransportID == held.phoneTransportID
            && c.generation == held.generation && c.bindingSHA256 == held.bindingSHA256
    }

    /// A published check-in read back: its envelope is closed and signed, over its exact payload
    /// bytes, by the phone application key the binding names — never a key from the check-in.
    static func checkIn(_ data: Data, phoneApplicationKey: Data) throws -> CheckIn {
        let raw = try open(data, domain: checkInDomain, key: phoneApplicationKey,
                           fields: checkInFields, limit: maximumMessageBytes)
        guard let c = try? JSONDecoder().decode(CheckIn.self, from: raw) else { throw Refusal.malformed }
        guard valid(c) else { throw Refusal.invalidFields }
        return c
    }

    private static func valid(_ c: CheckIn) -> Bool {
        c.version == 1 && c.kind == checkInKind && hex(c.challengeID, count: 32)
            && hex(c.challengeSHA256, count: 64) && nonce(c.nonce)
            && [c.organizationID, c.enrolmentID, c.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && canonicalDeviceID(c.phoneTransportID) && instant(c.generation) && hex(c.bindingSHA256, count: 64)
            && instant(c.leaseRenewBy) && printable(c.appVersion, maximum: 64)
            && printable(c.appBuild, maximum: 64) && instant(c.createdAt)
    }

    // MARK: - Result

    private static let resultFields: Set<String> = [
        "version", "kind", "challengeID", "checkInSHA256", "organizationID", "enrolmentID", "officeID",
        "phoneTransportID", "outcome", "peerBinding", "issuedAt"]

    /// The phone's check of a result as far as the message goes (contract §7, steps 1 and 2):
    /// signed by the administrator key from the vendor-verified profile, naming this phone's
    /// organisation, enrolment, office and transport identity, and for exactly the one check-in
    /// the phone is waiting on. The binding it carries is returned unverified: step 3 is
    /// `OfficePeerBinding.verify` and the pairing gate.
    static func result(_ data: Data, administratorKey: Data, organizationID: String, enrolmentID: String,
                       officeID: String, phoneTransportID: String, waiting: Waiting) throws -> VerifiedResult {
        let raw = try open(data, domain: resultDomain, key: administratorKey,
                           fields: resultFields, limit: maximumResultBytes)
        guard let r = try? JSONDecoder().decode(Result.self, from: raw) else { throw Refusal.malformed }
        guard r.version == 1, r.kind == resultKind, hex(r.challengeID, count: 32), hex(r.checkInSHA256, count: 64),
              [r.organizationID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              canonicalDeviceID(r.phoneTransportID), r.outcome == outcomeRenewed,
              !r.peerBinding.isEmpty, r.peerBinding.utf8.count <= maximumBindingBytes,
              instant(r.issuedAt) else { throw Refusal.invalidFields }
        guard r.organizationID == organizationID, r.enrolmentID == enrolmentID, r.officeID == officeID,
              r.phoneTransportID == phoneTransportID, r.challengeID == waiting.challengeID,
              r.checkInSHA256 == waiting.checkInSHA256 else { throw Refusal.wrongBinding }
        return VerifiedResult(payload: r, peerBinding: Data(r.peerBinding.utf8))
    }

    // MARK: - Removal

    private static let removalFields: Set<String> = [
        "version", "kind", "removalID", "organizationID", "profileID", "enrolmentID", "officeID",
        "phoneTransportID", "reason", "issuedAt"]
    private static let removalReceiptFields: Set<String> = [
        "version", "kind", "removalID", "removalSHA256", "organizationID", "enrolmentID",
        "phoneTransportID", "actedAt"]

    /// The phone's check of a removal (contract §8): signed by the administrator key from its
    /// vendor-verified profile, and naming its own organisation, profile, enrolment and transport
    /// identity. No clock and no generation: a removal is final, and an exact repeat changes
    /// nothing.
    static func removal(_ data: Data, administratorKey: Data, organizationID: String, profileID: String,
                        enrolmentID: String, phoneTransportID: String) throws -> VerifiedRemoval {
        let raw = try open(data, domain: removalDomain, key: administratorKey,
                           fields: removalFields, limit: maximumMessageBytes)
        guard let r = try? JSONDecoder().decode(Removal.self, from: raw) else { throw Refusal.malformed }
        guard r.version == 1, r.kind == removalKind, hex(r.removalID, count: 32),
              [r.organizationID, r.profileID, r.enrolmentID, r.officeID].allSatisfy(OfficeManualAssignment.safeIdentifier),
              canonicalDeviceID(r.phoneTransportID), r.reason == reasonRemoved || r.reason == reasonRevoked,
              instant(r.issuedAt) else { throw Refusal.invalidFields }
        guard r.organizationID == organizationID, r.profileID == profileID, r.enrolmentID == enrolmentID,
              r.phoneTransportID == phoneTransportID else { throw Refusal.wrongBinding }
        return VerifiedRemoval(payload: r, messageSHA256: digest(data))
    }

    /// The receipt these exact bytes state, or nil unless they are a closed, flat removal-receipt
    /// payload within the field rules. The phone signs nothing else under the receipt domain.
    static func removalReceiptPayload(_ raw: Data) -> RemovalReceipt? {
        guard !raw.isEmpty, raw.count <= maximumMessageBytes,
              OfficeManualAssignment.flatObject(raw, keys: removalReceiptFields),
              let r = try? JSONDecoder().decode(RemovalReceipt.self, from: raw), valid(r) else { return nil }
        return r
    }

    /// The office's check of a removal receipt: signed by the phone application key from the
    /// binding, never from the receipt, and for exactly the removal sent.
    static func removalReceipt(_ data: Data, phoneApplicationKey: Data,
                               removal: VerifiedRemoval) throws -> RemovalReceipt {
        let raw = try open(data, domain: removalReceiptDomain, key: phoneApplicationKey,
                           fields: removalReceiptFields, limit: maximumMessageBytes)
        guard let r = try? JSONDecoder().decode(RemovalReceipt.self, from: raw) else { throw Refusal.malformed }
        guard valid(r) else { throw Refusal.invalidFields }
        guard receipt(r, isFor: removal) else { throw Refusal.wrongBinding }
        return r
    }

    /// Whether a receipt is for exactly this removal.
    static func receipt(_ r: RemovalReceipt, isFor removal: VerifiedRemoval) -> Bool {
        r.removalID == removal.payload.removalID && r.removalSHA256 == removal.messageSHA256
            && r.organizationID == removal.payload.organizationID
            && r.enrolmentID == removal.payload.enrolmentID
            && r.phoneTransportID == removal.payload.phoneTransportID
    }

    private static func valid(_ r: RemovalReceipt) -> Bool {
        r.version == 1 && r.kind == removalReceiptKind && hex(r.removalID, count: 32)
            && hex(r.removalSHA256, count: 64)
            && [r.organizationID, r.enrolmentID].allSatisfy(OfficeManualAssignment.safeIdentifier)
            && canonicalDeviceID(r.phoneTransportID) && instant(r.actedAt)
    }

    // MARK: - Signed bytes

    /// An envelope's payload after the closed-object and encoding checks and the signature check
    /// under `key`, over `domain` (which ends in its zero byte) and the exact payload bytes.
    private static func open(_ data: Data, domain: Data, key: Data, fields: Set<String>,
                             limit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= limit,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let raw = Data(base64Encoded: envelope.payload),
              raw.base64EncodedString() == envelope.payload,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              signature.base64EncodedString() == envelope.signature else { throw Refusal.malformed }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              publicKey.isValidSignature(signature, for: domain + raw) else { throw Refusal.badSignature }
        guard OfficeManualAssignment.flatObject(raw, keys: fields) else { throw Refusal.malformed }
        return raw
    }

    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func instant(_ value: Int64) -> Bool { value > 0 && value <= maximumSafeInteger }

    /// 256 random bits as 43 characters of URL-safe base64 without padding.
    private static func nonce(_ value: String) -> Bool {
        guard value.utf8.count == 43, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return bytes.base64EncodedString() == standard
    }

    private static func printable(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
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
