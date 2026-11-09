import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

/// Vendor-side only. No production verifier depends on this package.
public struct IssuedLicensePayload: Codable, Equatable {
    public let feature: String
    public let licensee: String
    public let issued: Date
    public let expires: Date?
    public var tier: String?
    public var plan: String?
    public var seats: Int?
    public var reference: String?
    public var packs: [String]?
    public var profile: String?
    public var organizationID: String?
    public var profileID: String?
    public init(feature: String = "field_assist", licensee: String, issued: Date, expires: Date?,
                tier: String? = nil, plan: String? = nil, seats: Int? = nil, reference: String? = nil,
                packs: [String]? = nil, profile: String? = nil, organizationID: String? = nil, profileID: String? = nil) {
        self.feature = feature; self.licensee = licensee; self.issued = issued; self.expires = expires
        self.tier = tier; self.plan = plan; self.seats = seats; self.reference = reference
        self.packs = packs; self.profile = profile; self.organizationID = organizationID; self.profileID = profileID
    }
}

/// Inject an isolated signer; policy and billing never receive a private key.
public typealias ByteSigner = (Data) throws -> Data
public enum IssuanceWire {
    public static func encoder(profile: Bool = false) -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = profile ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sign(_ payload: Data, domain: String = "", signer: ByteSigner) throws -> String {
        let signature = try signer(Data(domain.utf8) + payload)
        guard signature.count == 64 else { throw WireError.signatureLength }
        return payload.base64EncodedString() + "." + signature.base64EncodedString()
    }
    public static func code(_ payload: IssuedLicensePayload, signer: ByteSigner) throws -> String {
        try sign(encoder().encode(payload), signer: signer)
    }
    public static func profile<T: Encodable>(_ payload: T, signer: ByteSigner) throws -> String {
        try sign(encoder(profile: true).encode(payload), domain: "openglasses.org-profile.v1\n", signer: signer)
    }
    public enum WireError: Error { case signatureLength, invalidProfile, invalidActivationKey }
    /// No expiry, revocation or erasure policy: an unpaid licence must never cause a profile lapse.
    public static func minimalProfile(id: String, licensee: String, issued: Date, code: String,
                                      keyID: String, leaseDays: Int = 365, signer: ByteSigner) throws -> String {
        guard !id.isEmpty, !keyID.isEmpty, (60...365).contains(leaseDays) else { throw WireError.invalidProfile }
        struct Profile: Encodable {
            let format = "openglasses.org-profile"
            let schemaVersion = 1
            let keyId: String
            let profileId: String
            let organizationName: String
            let issued: Date
            let leaseDays: Int
            let licenceCode: String
            let settings: [String: String] = [:]
        }
        return try profile(Profile(keyId: keyID, profileId: id, organizationName: licensee,
                                   issued: issued, leaseDays: leaseDays, licenceCode: code), signer: signer)
    }
}

/// Shared with the manual generator. Matches the deployed ActivationKey contract.
public enum ActivationKeyMint {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static func gfMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs, b = rhs, product = 0
        while b > 0 {
            if b & 1 == 1 { product ^= a }; b >>= 1; a <<= 1
            if a & 0b10_0000 != 0 { a ^= 0b10_0101 }
        }
        return product
    }
    public static func checkValue(_ values: [Int]) -> Int {
        var weight = 1, sum = 0
        for v in values { weight = gfMultiply(weight, 2); sum ^= gfMultiply(weight, v) }
        return sum
    }
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let v = (0..<15).map { _ in Int.random(in: 0..<32, using: &rng) }
        return String((v + [checkValue(v)]).map { alphabet[$0] })
    }
    public static func display(_ key: String) -> String {
        let c = Array(key)
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min($0 + 4, c.count)]) }.joined(separator: "-")
    }
    public static func fileName(_ key: String) -> String {
        IssuanceWire.digest(Data(("openglasses.activation-id.v1\n" + key).utf8))
    }
    /// The HKDF `info` the file's sealing key is derived with. Never changes: every issued key derives with it.
    public static let sealingDomain = "openglasses.activation-key.v1"
    /// The `format` of a version 2 file's plaintext. A version 1 file's plaintext is the bare licence code.
    public static let contentsFormat = "openglasses.activation"

    /// What an activation file opens to. Version 1 files carry no company secret.
    public struct Contents: Equatable {
        public let licenceCode: String
        public let companySecret: Data?
        public init(licenceCode: String, companySecret: Data?) { self.licenceCode = licenceCode; self.companySecret = companySecret }
    }
    struct Version2: Codable {
        var format = ActivationKeyMint.contentsFormat
        var version = 2
        let licenceCode: String
        let companySecret: String
    }

    static func sealingKey(canonical: String) throws -> SymmetricKey {
        let values = canonical.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 16, canonical.count == 16, checkValue(Array(values.prefix(15))) == values[15] else {
            throw IssuanceWire.WireError.invalidActivationKey
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)),
                                      info: Data(sealingDomain.utf8), outputByteCount: 32)
    }
    static func box(_ plain: Data, canonical: String) throws -> String {
        guard let combined = try AES.GCM.seal(plain, using: sealingKey(canonical: canonical)).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined.base64EncodedString()
    }

    /// Version 1: the bare licence code. The manual generator's format; the service seals version 2.
    public static func seal(_ code: String, canonical: String) throws -> String {
        try box(Data(code.utf8), canonical: canonical)
    }

    /// Version 2: the licence code and the company's secret (`ProfileContract.Credential`), which opens the
    /// credentials the profile carries sealed. The file is the only place the secret travels.
    public static func seal(_ code: String, companySecret: Data, canonical: String) throws -> String {
        guard companySecret.count == ProfileContract.Credential.secretLength else { throw IssuanceWire.WireError.invalidActivationKey }
        let plain = try IssuanceWire.encoder().encode(Version2(licenceCode: code, companySecret: companySecret.base64EncodedString()))
        return try box(plain, canonical: canonical)
    }

    /// Either version, or nil when this key did not seal the file. Mirrors `ActivationKey.open` in the app.
    public static func open(_ file: String, canonical: String) -> Contents? {
        guard let key = try? sealingKey(canonical: canonical),
              let combined = Data(base64Encoded: file.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(sealed, using: key) else { return nil }
        if plain.first == UInt8(ascii: "{") {
            guard let v2 = try? IssuanceWire.decoder().decode(Version2.self, from: plain), v2.format == contentsFormat, v2.version == 2,
                  let secret = Data(base64Encoded: v2.companySecret), secret.count == ProfileContract.Credential.secretLength,
                  !v2.licenceCode.isEmpty else { return nil }
            return Contents(licenceCode: v2.licenceCode, companySecret: secret)
        }
        guard let code = String(data: plain, encoding: .utf8), !code.isEmpty else { return nil }
        return Contents(licenceCode: code, companySecret: nil)
    }
}
