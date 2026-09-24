import Foundation
import CryptoKit

/// Plan CT P1 — verifying what is hosted at a profile's URL: a profile, or a revocation of one.
///
/// A document is `base64(payloadJSON).base64(signature)`, the licence code's shape, but the
/// signature covers a **typed domain prefix** followed by the payload bytes, and it is made with a
/// key distinct from the licence key. So a profile and a licence code can never be replayed as one
/// another, a profile and a revocation can never be replayed as one another, and compromising
/// either key does not yield the other.
///
/// Pure and `nonisolated`: keys are injectable so tests sign with an ephemeral pair, and nothing
/// here reads the clock except through `now`.
enum ProfileVerification {

    /// The vendor's profile-signing public keys, by `keyId`. The private halves are held off-repo
    /// on the licence key's terms and never ship.
    ///
    /// More than one may be live at once so a key can be rotated or retired without breaking every
    /// profile already issued: add the new key, re-mint, then remove the old id. The key is one
    /// vendor key, not one per customer — the per-customer key is the organisation's own
    /// job-signing key, which a profile signed by this one *carries*.
    static let productionKeys: [String: String] = [
        "og-profile-2026-09": "XyEMx0oOtxilcQO7A+C/b5R51Ui85U56BTQ8lISb5v8=",
    ]

    /// The key id new profiles are minted under.
    static let currentKeyId = "og-profile-2026-09"

    static let profileDomain = Data("openglasses.org-profile.v1\n".utf8)
    static let revocationDomain = Data("openglasses.org-revocation.v1\n".utf8)

    /// A verified hosted document.
    enum Document: Equatable, Sendable {
        case profile(ConfigProfile)
        case revocation(ProfileRevocation)
    }

    enum Failure: Error, Equatable, LocalizedError, Sendable {
        case malformed
        case unknownKey(String)
        case badSignature
        case unsupportedSchema(Int)
        /// The organisation's own term has passed.
        case policyExpired(Date)
        /// The licence the profile carries has passed its signed expiry.
        case licenceExpired(Date)
        /// The licence the profile carries does not verify against the licence key.
        case licenceInvalid

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "That isn't an OpenGlasses organisation profile."
            case .unknownKey:
                return "This profile was signed with a key this version of the app doesn't know. Update the app, or ask your organisation for a new code."
            case .badSignature:
                return "This profile failed verification. It may have been altered — ask your organisation for a new code."
            case .unsupportedSchema:
                return "This profile needs a newer version of the app."
            case .policyExpired(let date):
                return "Your organisation's profile ended on \(date.formatted(date: .abbreviated, time: .omitted)). Ask them for a new code."
            case .licenceExpired(let date):
                return "The licence in this profile expired on \(date.formatted(date: .abbreviated, time: .omitted)). Ask your organisation to renew it."
            case .licenceInvalid:
                return "The licence in this profile failed verification. Ask your organisation for a new code."
            }
        }
    }

    // MARK: - Verification

    /// Verify a hosted document's signature and shape. Expiry is not checked here — the clocks
    /// belong to `enrolmentRefusal(for:now:licenceKey:)` and to the envelope, which treat them
    /// differently: an expired profile is a refusal at enrolment, but a lapse on an enrolled phone
    /// locks content and keeps the rules.
    static func verify(_ text: String, keys: [String: String] = productionKeys) throws -> Document {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payload = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])),
              let header = try? decoder.decode(Header.self, from: payload) else {
            throw Failure.malformed
        }

        let domain: Data
        switch header.format {
        case ConfigProfile.formatId: domain = profileDomain
        case ProfileRevocation.formatId: domain = revocationDomain
        default: throw Failure.malformed
        }

        guard let keyBase64 = keys[header.keyId] else { throw Failure.unknownKey(header.keyId) }
        guard let keyData = Data(base64Encoded: keyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw Failure.unknownKey(header.keyId)
        }
        guard publicKey.isValidSignature(signature, for: domain + payload) else {
            throw Failure.badSignature
        }

        if header.format == ProfileRevocation.formatId {
            guard let revocation = try? decoder.decode(ProfileRevocation.self, from: payload) else {
                throw Failure.malformed
            }
            return .revocation(revocation)
        }

        guard let profile = try? decoder.decode(ConfigProfile.self, from: payload) else {
            throw Failure.malformed
        }
        guard profile.schemaVersion <= ConfigProfile.supportedSchemaVersion else {
            throw Failure.unsupportedSchema(profile.schemaVersion)
        }
        return .profile(profile)
    }

    /// Why a verified profile must not be enrolled right now, naming which clock ran out — or nil.
    ///
    /// The two clocks are checked independently: the organisation's `policyExpiry`, and the signed
    /// `expires` of the licence code the profile carries. A profile with no licence is valid on
    /// its own — it bounds the device without entitling anything.
    static func enrolmentRefusal(
        for profile: ConfigProfile,
        now: Date,
        licenceKey: String = LicenseService.productionPublicKeyBase64
    ) -> Failure? {
        if let policyExpiry = profile.policyExpiry, policyExpiry < now {
            return .policyExpired(policyExpiry)
        }
        guard let code = profile.licenceCode else { return nil }
        guard let licence = try? LicenseService.decode(code: code, publicKeyBase64: licenceKey) else {
            return .licenceInvalid
        }
        if let expires = licence.expires, expires < now { return .licenceExpired(expires) }
        return nil
    }

    // MARK: - Issuance (script / tests)

    /// Sign a profile. The app never calls this in production — it holds no private key — but it
    /// is the authoritative format `Scripts/make-org-profile.swift` mirrors and the tests use.
    static func makeDocument(_ profile: ConfigProfile, privateKeyBase64: String) throws -> String {
        try sign(try encoder.encode(profile), domain: profileDomain, privateKeyBase64: privateKeyBase64)
    }

    /// Sign a whole-link revocation.
    static func makeDocument(_ revocation: ProfileRevocation, privateKeyBase64: String) throws -> String {
        try sign(try encoder.encode(revocation), domain: revocationDomain, privateKeyBase64: privateKeyBase64)
    }

    private static func sign(_ payload: Data, domain: Data, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else { throw Failure.malformed }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let signature = try privateKey.signature(for: domain + payload)
        return "\(payload.base64EncodedString()).\(signature.base64EncodedString())"
    }

    // MARK: - Codable config

    /// The two fields read before the signature is checked — to choose the domain and the key.
    /// Nothing else is trusted until the signature verifies over the same bytes.
    private struct Header: Decodable {
        let format: String
        let keyId: String
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
