import CryptoKit
import Foundation

/// A vendor-profile-rooted, administrator-signed pairing contract. Verification does not
/// grant an entitlement or install a job/manual; those remain independent production gates.
enum OfficePeerBinding {
    static let domain = Data("Avenkin.OfficePeerBinding.v1\0".utf8)
    static let maximumEnvelopeBytes = 32_768
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Payload: Codable, Equatable, Sendable {
        let version: Int
        let kind: String
        let organizationID: String
        let profileID: String
        let enrolmentID: String
        let officeID: String
        let generation: Int64
        let officeTransportID: String
        let officeApplicationKey: String
        let phoneTransportID: String
        let phoneApplicationKey: String
        let issuedAt: Int64
        let expiresAt: Int64
    }

    struct Envelope: Codable, Sendable {
        let payload: String
        let signature: String
    }

    /// Created only by rechecking the vendor signature on the profile document. An office
    /// invitation, QR label or Syncthing device ID cannot construct this value.
    struct VendorRoot: Sendable {
        let organizationID: String
        let profileID: String
        let administratorPublicKey: Data
        let transportPolicy: String
        let policyExpiry: Date?
        fileprivate init(profile: ConfigProfile, authority: ConfigProfile.OfficeAuthority,
                         administratorPublicKey: Data) {
            organizationID = authority.organizationID
            profileID = profile.profileId
            self.administratorPublicKey = administratorPublicKey
            transportPolicy = authority.transportPolicy
            policyExpiry = profile.policyExpiry
        }
    }

    /// Values must come from the actual local phone identity and the reviewed office response.
    /// The signed document is never allowed to supply its own expected recipient or peer keys.
    struct ExpectedPeer: Sendable {
        let enrolmentID: String
        let officeID: String
        let officeTransportID: String
        let officeApplicationKey: Data
        let phoneTransportID: String
        let phoneApplicationKey: Data
        let minimumGeneration: Int64
    }

    struct Verified: Sendable {
        let payload: Payload
        let payloadSHA256: String
        fileprivate init(payload: Payload, payloadSHA256: String) {
            self.payload = payload
            self.payloadSHA256 = payloadSHA256
        }
    }

    enum Refusal: Error, Equatable {
        case untrustedProfile
        case profileExpired
        case malformed
        case badSignature
        case wrongOrganizationOrProfile
        case wrongPeer
        case invalidFields
        case notCurrentlyValid
        case rollback
    }

    static func vendorRoot(profileDocument: String,
                           vendorKeys: [String: String] = ProfileVerification.productionKeys,
                           now: Date) throws -> VendorRoot {
        guard let document = try? ProfileVerification.verify(profileDocument, keys: vendorKeys),
              case .profile(let profile) = document,
              profile.schemaVersion == 2,
              let authority = profile.officeAuthority,
              ProfileVerification.validOfficeAuthority(authority),
              let administratorPublicKey = Data(base64Encoded: authority.administratorPublicKey),
              OfficeManualAssignment.safeIdentifier(profile.profileId) else { throw Refusal.untrustedProfile }
        if let expiry = profile.policyExpiry, now >= expiry { throw Refusal.profileExpired }
        return VendorRoot(profile: profile, authority: authority,
                          administratorPublicKey: administratorPublicKey)
    }

    static func verify(_ data: Data, root: VendorRoot, expected: ExpectedPeer,
                       now: Int64) throws -> Verified {
        guard data.count <= maximumEnvelopeBytes,
              OfficeManualAssignment.flatObject(data, keys: ["payload", "signature"]),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let bytes = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature) else { throw Refusal.malformed }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: root.administratorPublicKey),
              key.isValidSignature(signature, for: domain + bytes) else { throw Refusal.badSignature }
        guard OfficeManualAssignment.flatObject(bytes, keys: ["version", "kind", "organizationID",
              "profileID", "enrolmentID", "officeID", "generation", "officeTransportID",
              "officeApplicationKey", "phoneTransportID", "phoneApplicationKey", "issuedAt", "expiresAt"]),
              let payload = try? JSONDecoder().decode(Payload.self, from: bytes) else { throw Refusal.malformed }
        guard payload.organizationID == root.organizationID,
              payload.profileID == root.profileID else { throw Refusal.wrongOrganizationOrProfile }
        guard payload.enrolmentID == expected.enrolmentID,
              payload.officeID == expected.officeID,
              payload.officeTransportID == expected.officeTransportID,
              payload.officeApplicationKey == expected.officeApplicationKey.base64EncodedString(),
              payload.phoneTransportID == expected.phoneTransportID,
              payload.phoneApplicationKey == expected.phoneApplicationKey.base64EncodedString() else {
            throw Refusal.wrongPeer
        }
        guard payload.version == 1, payload.kind == "avenkin.office-peer-binding",
              OfficeManualAssignment.safeIdentifier(payload.enrolmentID),
              OfficeManualAssignment.safeIdentifier(payload.officeID),
              [payload.officeApplicationKey, payload.phoneApplicationKey].allSatisfy({ value in
                  guard let bytes = Data(base64Encoded: value), bytes.count == 32 else { return false }
                  return bytes.base64EncodedString() == value
              }),
              !payload.officeTransportID.isEmpty, payload.officeTransportID.utf8.count <= 128,
              !payload.phoneTransportID.isEmpty, payload.phoneTransportID.utf8.count <= 128,
              payload.generation > 0, payload.generation <= maximumSafeInteger,
              payload.issuedAt > 0, payload.issuedAt <= maximumSafeInteger,
              payload.expiresAt > payload.issuedAt, payload.expiresAt <= maximumSafeInteger,
              payload.expiresAt - payload.issuedAt <= 30 * 86_400 else { throw Refusal.invalidFields }
        guard payload.generation >= expected.minimumGeneration else { throw Refusal.rollback }
        guard now >= payload.issuedAt, now < payload.expiresAt,
              root.policyExpiry.map({ Date(timeIntervalSince1970: TimeInterval(now)) < $0
                  && Date(timeIntervalSince1970: TimeInterval(payload.expiresAt)) <= $0 }) ?? true else {
            throw Refusal.notCurrentlyValid
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Verified(payload: payload, payloadSHA256: digest)
    }
}
