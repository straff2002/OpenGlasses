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
    /// Plan JS P2: the phones using this code are counted against `seats` (`SeatWire`). Only with a
    /// `profile`, whose origin is the seat service. Absent on every code minted before P2.
    public var seatCheck: Bool?
    public init(feature: String = "field_assist", licensee: String, issued: Date, expires: Date?,
                tier: String? = nil, plan: String? = nil, seats: Int? = nil, reference: String? = nil,
                packs: [String]? = nil, profile: String? = nil, organizationID: String? = nil, profileID: String? = nil,
                seatCheck: Bool? = nil) {
        self.feature = feature; self.licensee = licensee; self.issued = issued; self.expires = expires
        self.tier = tier; self.plan = plan; self.seats = seats; self.reference = reference
        self.packs = packs; self.profile = profile; self.organizationID = organizationID; self.profileID = profileID
        self.seatCheck = seatCheck
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
    public static func seal(_ code: String, canonical: String) throws -> String {
        let values = canonical.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 16, checkValue(Array(values.prefix(15))) == values[15] else {
            throw IssuanceWire.WireError.invalidActivationKey
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)),
                                       info: Data("openglasses.activation-key.v1".utf8), outputByteCount: 32)
        guard let combined = try AES.GCM.seal(Data(code.utf8), using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined.base64EncodedString()
    }
}
