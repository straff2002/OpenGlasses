import Foundation
import CryptoKit

/// Offline license-code validation for the Field Assist (B2B) feature.
///
/// A license code is `base64(payloadJSON).base64(signature)` where the signature is an Ed25519
/// (Curve25519) signature over the payload bytes, produced by the vendor's **private** key. The app
/// embeds only the matching **public** key, so codes can be validated fully offline yet cannot be
/// forged by reverse-engineering the binary. Codes are issued out-of-band (e.g. on purchase order)
/// with `Scripts/generate-field-license.swift`.
///
/// On successful activation the code is persisted and drives the UI. Entitlement decisions do not
/// read the `Config.fieldAssistLicenseValid` mirror this also writes: the stored *code* is the
/// evidence, re-verified through `decode(code:publicKeyBase64:)` on every gate read.
@MainActor
final class LicenseService: ObservableObject {
    static let shared = LicenseService()

    /// Vendor's production public key (base64, Curve25519 raw representation). The private half is
    /// held only by the vendor and never ships in the app.
    ///
    /// `nonisolated` so it can be used as the default argument of `init` (default-argument
    /// expressions evaluate in a nonisolated context) — required under the Swift 6 language mode.
    nonisolated static let productionPublicKeyBase64 = "KJyr5gDejBhxO2zpXbaBgvOeSjs9b3I93PJgauHubhY="

    /// Feature identifier a license must name to unlock Field Assist.
    nonisolated static let featureId = "field_assist"

    /// The verifying key in use. Overridable so tests can sign with an ephemeral keypair.
    let publicKeyBase64: String

    /// The currently active license payload, if any (drives UI; nil = not licensed).
    @Published private(set) var activeLicense: LicensePayload?

    /// Where the activated code lives. Shared with the entitlement provider, which re-verifies it at
    /// read time rather than trusting any cached verdict.
    nonisolated static let storageKey = "fieldAssistLicenseCode"

    private let defaults = UserDefaults.standard

    struct LicensePayload: Codable, Equatable {
        let feature: String
        let licensee: String
        let issued: Date
        let expires: Date?   // nil = perpetual
    }

    enum LicenseError: LocalizedError {
        case malformed
        case badSignature
        case wrongFeature
        case expired(Date)

        var errorDescription: String? {
            switch self {
            case .malformed: return "That doesn't look like a valid license code."
            case .badSignature: return "This license code failed verification. Check for typos or request a new code."
            case .wrongFeature: return "This code is for a different product."
            case .expired(let date): return "This license expired on \(date.formatted(date: .abbreviated, time: .omitted))."
            }
        }
    }

    init(publicKeyBase64: String = productionPublicKeyBase64) {
        self.publicKeyBase64 = publicKeyBase64
        loadStored()
    }

    // MARK: - Activation

    /// Validate `code`; on success persist it, publish the payload, and flip the entitlement flag.
    @discardableResult
    func activate(code: String) throws -> LicensePayload {
        let payload = try verify(code: code)
        defaults.set(code.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.storageKey)
        activeLicense = payload
        Config.setFieldAssistLicenseValid(true)
        return payload
    }

    /// Remove the stored license and drop the entitlement.
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
        activeLicense = nil
        Config.setFieldAssistLicenseValid(false)
    }

    /// Re-validate the stored code (called at launch and init). Clears entitlement on expiry/failure.
    func loadStored() {
        guard let code = defaults.string(forKey: Self.storageKey) else {
            Config.setFieldAssistLicenseValid(false)
            return
        }
        if let payload = try? verify(code: code) {
            activeLicense = payload
            Config.setFieldAssistLicenseValid(true)
        } else {
            activeLicense = nil
            Config.setFieldAssistLicenseValid(false)
        }
    }

    // MARK: - Verification

    /// Full validation against this service's key: signature, feature id, and expiry as of now.
    func verify(code: String) throws -> LicensePayload {
        let payload = try Self.decode(code: code, publicKeyBase64: publicKeyBase64)
        if let expires = payload.expires, expires < Date() { throw LicenseError.expired(expires) }
        return payload
    }

    /// Signature and feature verification without the expiry check.
    ///
    /// `nonisolated` and expiry-free so the entitlement provider can re-verify a stored code from any
    /// isolation domain and hand the *signed* expiry claim to the evaluator — the clock belongs in one
    /// place, not in every verifier.
    nonisolated static func decode(code: String, publicKeyBase64: String) throws -> LicensePayload {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: String(parts[0])),
              let signature = Data(base64Encoded: String(parts[1])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        else { throw LicenseError.malformed }

        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseError.badSignature
        }
        guard let payload = try? decoder.decode(LicensePayload.self, from: payloadData) else {
            throw LicenseError.malformed
        }
        guard payload.feature == featureId else { throw LicenseError.wrongFeature }
        return payload
    }

    // MARK: - Issuance (vendor / tests)

    /// Encode + sign a payload into a license code. The app never calls this in production (it has no
    /// private key); it's the authoritative format used by the generator script and the tests.
    static func makeCode(payload: LicensePayload, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw LicenseError.malformed
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let payloadData = try encoder.encode(payload)
        let signature = try privateKey.signature(for: payloadData)
        return "\(payloadData.base64EncodedString()).\(signature.base64EncodedString())"
    }

    // MARK: - Codable config (shared by sign + verify so the format stays in lockstep)

    /// `nonisolated(unsafe)` because `decode(code:publicKeyBase64:)` runs off the main actor; both
    /// are configured once here and only read afterwards.
    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
