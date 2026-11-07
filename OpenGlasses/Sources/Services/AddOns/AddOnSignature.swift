import Foundation
import CryptoKit

/// Signed add-ons: an ed25519 signature over the **exact file bytes**, carried in a small JSON
/// envelope, resolved to a trust class.
///
/// The scheme is the skill pack's (`SkillPackSignature`: Curve25519 signing keys, raw 32-byte
/// public keys in base64, injectable so tests sign with ephemeral pairs) with one addition —
/// **domain separation**. The signed message is `signingDomain` followed by the file bytes, so no
/// skill-pack, catalog or profile signature over the same bytes can be replayed as an add-on
/// signature, and an add-on signature can't be replayed as one of those.
///
/// The envelope (`envelopeFormat`), strict-decoded — any other key refuses it:
///
/// ```json
/// { "format": "avenkin.addon-signed/1",
///   "keyId": "vendor-2026-09",
///   "signer": "vendor",                      // or "organisation"
///   "organizationID": "acme-heating",        // organisation only, forbidden for vendor
///   "file": "<base64 of the exact add-on bytes>",
///   "signature": "<base64 ed25519 over signingDomain + those bytes>" }
/// ```
///
/// The file travels base64-wrapped so no JSON re-serialisation can change the bytes signed.
///
/// **A failed signature is not an error by itself.** Whatever goes wrong — a bad signature, one
/// edited byte, an unknown key id, an organisation the phone does not trust, a key id that belongs
/// to another organisation — the result is the same file bytes in the `community` class, with the
/// failure named. The validator then reads it as a community file: if it names a reserved
/// capability it is refused, otherwise it is an ordinary add-on that shows the approval sheet.
/// Only an envelope that is not the envelope format at all (so there are no bytes to fall back
/// to) is refused outright.
///
/// Pure: keys and the trusted organisations are inputs. The app never holds a private key;
/// `sign` exists for tests and the signing tool only, sharing the exact message construction.
enum AddOnSignature {

    /// **Signing domain — never change it.** Every signed add-on already issued was signed over
    /// this prefix; a new value makes all of them demote to community.
    static let signingDomain = Data("avenkin.addon-signature/1\n".utf8)

    /// The envelope's `format` tag.
    static let envelopeFormat = "avenkin.addon-signed/1"

    /// The add-on file inside an envelope is at most this many bytes.
    static let maxFileBytes = 256 * 1024
    /// An envelope is at most this many bytes (base64 of the largest file, plus the fields).
    static let maxEnvelopeBytes = 384 * 1024

    /// The key id the vendor signs add-ons under.
    static let vendorKeyID = "vendor-2026-09"

    /// The vendor's add-on keys, by key id. **The vendor signs add-ons with the same key as skill
    /// packs and the pack catalogs** (`SkillPackSignature.productionPublicKeyBase64`, rotated
    /// 2026-09-03) — one vendor signing key, separated per artifact by `signingDomain`. Not the
    /// licence key (`LicenseService`), which signs licence codes only. More than one may be live
    /// so the key can be rotated: add the new id, re-sign, then retire the old one.
    static let productionVendorKeys: [String: String] = [
        vendorKeyID: SkillPackSignature.productionPublicKeyBase64,
    ]

    // MARK: Types

    enum Signer: String, Equatable, Sendable {
        case vendor
        case organisation
    }

    /// A decoded envelope. Nothing in it is trusted until `verify` checks the signature.
    struct Envelope: Equatable, Sendable {
        let keyId: String
        let signer: Signer
        let organizationID: String?
        let file: Data
        let signature: Data
    }

    /// Why an envelope's signature did not put the file in a signed class.
    enum Failure: Error, Equatable, Sendable {
        /// The signature does not verify over the file bytes — an edited byte, a different file,
        /// or a signature made for another kind of document.
        case badSignature
        /// The key id names no key the phone trusts for this signer.
        case unknownKeyID(String)
        /// The envelope names an organisation the phone does not trust.
        case unknownOrganisation(String)
        /// The key id is the key of a different trusted organisation than the one the envelope names.
        case organisationMismatch(named: String, keyBelongsTo: String)
        /// The trusted key for this signer is not a valid ed25519 public key.
        case trustedKeyInvalid
    }

    /// Why bytes that say they are an envelope are not one. There is no file to fall back to.
    enum EnvelopeError: Error, Equatable, Sendable {
        case tooLarge
        case notJSON
        case unknownKey(String)
        case missing(String)
        case wrongType(String)
        case unsupportedFormat(String)
        case invalid(field: String, reason: String)
    }

    /// What a file's signature resolved to: the class and the exact bytes to validate and install.
    struct Resolution: Equatable, Sendable {
        let trust: AddOnTrustClass
        /// The add-on file itself — the envelope's `file`, or the bare file as received.
        let fileBytes: Data
        /// Why an envelope demoted to community; nil when it verified or the file was bare.
        let failure: Failure?
        /// Whether the file arrived in an envelope at all.
        let wasSigned: Bool
    }

    // MARK: Resolve

    /// Resolve whatever arrived — a signed envelope or a bare add-on file.
    ///
    /// - `vendorKeys`: key id → base64 raw ed25519 public key.
    /// - `trustedOrganisations`: organisation id → its administrator's base64 raw ed25519 public
    ///   key — the organisations the phone is enrolled with.
    ///
    /// Throws `EnvelopeError` only when the bytes carry the envelope's `format` tag but are not a
    /// well-formed envelope. Anything else that is not an envelope is returned as a bare
    /// `community` file for the validator to judge (it refuses what is not an add-on).
    static func resolve(_ data: Data,
                        vendorKeys: [String: String] = productionVendorKeys,
                        trustedOrganisations: [String: String] = [:]) throws -> Resolution {
        guard looksLikeEnvelope(data) else {
            return Resolution(trust: .community, fileBytes: data, failure: nil, wasSigned: false)
        }
        let envelope = try decodeEnvelope(data)
        return verify(envelope, vendorKeys: vendorKeys, trustedOrganisations: trustedOrganisations)
    }

    /// Check an envelope's signature and resolve its class. Never fails: a failure demotes the
    /// same bytes to `community` and names why.
    static func verify(_ envelope: Envelope,
                       vendorKeys: [String: String] = productionVendorKeys,
                       trustedOrganisations: [String: String] = [:]) -> Resolution {
        func demoted(_ failure: Failure) -> Resolution {
            Resolution(trust: .community, fileBytes: envelope.file, failure: failure, wasSigned: true)
        }
        let keyBase64: String
        let trust: AddOnTrustClass
        switch envelope.signer {
        case .vendor:
            guard let key = vendorKeys[envelope.keyId] else { return demoted(.unknownKeyID(envelope.keyId)) }
            keyBase64 = key
            trust = .vendorSigned
        case .organisation:
            guard let orgID = envelope.organizationID else { return demoted(.unknownOrganisation("")) }
            guard let key = trustedOrganisations[orgID] else { return demoted(.unknownOrganisation(orgID)) }
            guard isValidPublicKey(key), let expectedID = keyID(forOrganisationKey: key) else {
                return demoted(.trustedKeyInvalid)
            }
            guard envelope.keyId == expectedID else {
                let owner = trustedOrganisations.keys.sorted().first { other in
                    other != orgID && trustedOrganisations[other].flatMap(keyID(forOrganisationKey:)) == envelope.keyId
                }
                if let owner { return demoted(.organisationMismatch(named: orgID, keyBelongsTo: owner)) }
                return demoted(.unknownKeyID(envelope.keyId))
            }
            keyBase64 = key
            trust = .organisationSigned(organizationID: orgID)
        }
        guard isValidPublicKey(keyBase64), let keyData = Data(base64Encoded: keyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return demoted(.trustedKeyInvalid)
        }
        guard publicKey.isValidSignature(envelope.signature, for: signingMessage(fileBytes: envelope.file)) else {
            return demoted(.badSignature)
        }
        return Resolution(trust: trust, fileBytes: envelope.file, failure: nil, wasSigned: true)
    }

    /// The exact bytes a signature covers: the domain prefix, then the file.
    static func signingMessage(fileBytes: Data) -> Data {
        signingDomain + fileBytes
    }

    /// The key id an organisation signs under: `org-` and the first 16 hex digits of the SHA-256
    /// of its raw public key. It binds the envelope to the key that signed it, so a rotated or a
    /// different organisation's key is named rather than silently tried. Nil for an invalid key.
    static func keyID(forOrganisationKey publicKeyBase64: String) -> String? {
        guard isValidPublicKey(publicKeyBase64), let raw = Data(base64Encoded: publicKeyBase64) else { return nil }
        let hex = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        return "org-" + String(hex.prefix(16))
    }

    /// The organisation profile's administrator-key check (`ProfileVerification.validOfficeAuthority`):
    /// canonical base64 of exactly 32 bytes that CryptoKit accepts as an ed25519 public key.
    static func isValidPublicKey(_ base64: String) -> Bool {
        guard let key = Data(base64Encoded: base64), key.count == 32,
              key.base64EncodedString() == base64,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else { return false }
        return true
    }

    /// The organisation id rule, matching the organisation profile's: 1–80 of `A–Z a–z 0–9 - _ .`,
    /// and not `.` or `..`.
    static func isValidOrganizationID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    // MARK: Envelope decoding

    /// Whether `data` is a JSON object whose `format` is the envelope's tag.
    static func looksLikeEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["format"] as? String == envelopeFormat
    }

    /// Strict decode: exactly the envelope's keys, the right types, canonical base64, a 64-byte
    /// signature, an organisation id exactly when the signer is an organisation.
    static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard data.count <= maxEnvelopeBytes else { throw EnvelopeError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnvelopeError.notJSON
        }
        let allowed: Set<String> = ["format", "keyId", "signer", "organizationID", "file", "signature"]
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw EnvelopeError.unknownKey(unknown)
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] else { throw EnvelopeError.missing(key) }
            guard let text = value as? String else { throw EnvelopeError.wrongType(key) }
            return text
        }
        let format = try string("format")
        guard format == envelopeFormat else { throw EnvelopeError.unsupportedFormat(format) }

        let keyId = try string("keyId")
        guard (1...64).contains(keyId.count),
              keyId.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  || $0 == 45 || $0 == 95 || $0 == 46 }) else {
            throw EnvelopeError.invalid(field: "keyId", reason: "1–64 letters, digits, - _ .")
        }

        let signerText = try string("signer")
        guard let signer = Signer(rawValue: signerText) else {
            throw EnvelopeError.invalid(field: "signer", reason: "vendor or organisation")
        }

        var organizationID: String?
        switch signer {
        case .vendor:
            if object["organizationID"] != nil {
                throw EnvelopeError.invalid(field: "organizationID", reason: "only an organisation signer names one")
            }
        case .organisation:
            let id = try string("organizationID")
            guard isValidOrganizationID(id) else {
                throw EnvelopeError.invalid(field: "organizationID", reason: "not an organisation id")
            }
            organizationID = id
        }

        let fileText = try string("file")
        guard let file = Data(base64Encoded: fileText), file.base64EncodedString() == fileText else {
            throw EnvelopeError.invalid(field: "file", reason: "canonical base64")
        }
        guard !file.isEmpty, file.count <= maxFileBytes else {
            throw EnvelopeError.invalid(field: "file", reason: "1–\(maxFileBytes) bytes")
        }

        let signatureText = try string("signature")
        guard let signature = Data(base64Encoded: signatureText), signature.base64EncodedString() == signatureText,
              signature.count == 64 else {
            throw EnvelopeError.invalid(field: "signature", reason: "base64 of a 64-byte ed25519 signature")
        }
        return Envelope(keyId: keyId, signer: signer, organizationID: organizationID, file: file, signature: signature)
    }

    // MARK: Signing (tests and the signing tool only)

    enum SigningError: Error, Equatable { case badKey }

    /// Sign `fileBytes` and wrap them in an envelope. The app never calls this — it holds no
    /// private key — but it is the authoritative byte contract `verify` checks.
    static func sign(fileBytes: Data, keyId: String, signer: Signer, organizationID: String? = nil,
                     privateKeyBase64: String) throws -> Data {
        guard let keyData = Data(base64Encoded: privateKeyBase64),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            throw SigningError.badKey
        }
        let signature = try privateKey.signature(for: signingMessage(fileBytes: fileBytes))
        return try envelopeData(fileBytes: fileBytes, keyId: keyId, signer: signer,
                                organizationID: organizationID, signature: signature)
    }

    /// The envelope JSON around a file and a signature, keys sorted.
    static func envelopeData(fileBytes: Data, keyId: String, signer: Signer, organizationID: String?,
                             signature: Data) throws -> Data {
        var object: [String: Any] = [
            "format": envelopeFormat,
            "keyId": keyId,
            "signer": signer.rawValue,
            "file": fileBytes.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ]
        if let organizationID { object["organizationID"] = organizationID }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
