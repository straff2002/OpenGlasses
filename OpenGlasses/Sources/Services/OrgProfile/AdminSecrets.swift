import Foundation
import CryptoKit
import CommonCrypto

/// Plan CT 3b — the single-purpose presentations a profile can name.
enum ProfileEdition: String, Equatable, Sendable {
    /// The technician sees Field Assist, Job and a short Settings list; the rest waits behind the
    /// organisation's administrator gate.
    case fieldAssist
}

/// Plan CT 3b — how the organisation's administrator gets past the edition, checked.
///
/// **A guard, not a lock.** What these open is only what the edition hides — never a ceiling. A
/// short passcode can be brute-forced from its verifier by anyone holding the profile, and against
/// the stated threat (a technician changing settings by accident) that does not matter; the card's
/// 128-bit secret is out of reach either way.
struct AdminCredentials: Equatable, Sendable {
    struct Passcode: Equatable, Sendable {
        let salt: Data
        let iterations: Int
        let hash: Data
    }

    var passcode: Passcode?
    /// SHA-256 of the card's secret under its domain prefix.
    var cardDigest: Data?

    /// How administrator settings open on this phone.
    enum Method: Equatable, Sendable {
        case card
        case passcode
        case cardOrPasscode
        /// Neither was issued: the device owner's own Face ID or passcode, which anyone who can
        /// unlock the phone passes. The review sheet says so before the profile is applied.
        case deviceOwner
    }

    var method: Method {
        switch (cardDigest != nil, passcode != nil) {
        case (true, true): return .cardOrPasscode
        case (true, false): return .card
        case (false, true): return .passcode
        case (false, false): return .deviceOwner
        }
    }
}

/// The edition and the credentials that open it, as the profile in force states them.
struct AdminPolicy: Equatable, Sendable {
    let edition: ProfileEdition
    let credentials: AdminCredentials
}

/// Plan CT 3b — the cryptography behind the passcode verifier and the admin card, shared with
/// `Scripts/make-org-profile.swift`, which must produce byte-identical results.
enum AdminSecrets {
    /// The iterations a verifier may claim. Fewer is a verifier too cheap to brute-force against;
    /// more is one that would stall the phone on every attempt.
    static let iterationRange = 10_000...5_000_000
    static let cardPrefix = "og-admin:"
    static let cardDomain = "openglasses.admin-card.v1\n"
    /// Crockford base32 characters in a card's secret: 26 × 5 = 130 random bits.
    static let cardSecretLength = 26

    /// PBKDF2-HMAC-SHA256 through CommonCrypto (CryptoKit has none). Nil for an empty passcode or
    /// an iteration count outside what CommonCrypto takes.
    static func pbkdf2(_ passcode: String, salt: Data, iterations: Int, length: Int = 32) -> Data? {
        let password = Data(passcode.utf8)
        guard !password.isEmpty, !salt.isEmpty, iterations > 0, iterations <= Int(UInt32.max) else { return nil }
        var derived = Data(count: length)
        let status: Int32 = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                                         password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations),
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         length)
                }
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// The digest a profile carries for a card secret.
    static func cardDigest(secret: String) -> Data {
        Data(SHA256.hash(data: Data((cardDomain + secret).utf8)))
    }

    /// The secret in a scanned card, canonical, or nil when the text is not an admin card.
    static func cardSecret(from scanned: String) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(cardPrefix) else { return nil }
        let body = trimmed.dropFirst(cardPrefix.count).uppercased()
        guard body.count == cardSecretLength,
              body.allSatisfy({ ActivationKey.alphabet.contains($0) }) else { return nil }
        return body
    }

    /// Compare two digests without stopping at the first difference.
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    /// Check a profile's `adminPasscode`.
    static func resolve(_ verifier: ConfigProfile.PasscodeVerifier) -> Result<AdminCredentials.Passcode, ProfileApplier.Drop.Reason> {
        guard let saltText = verifier.salt, let salt = Data(base64Encoded: saltText), salt.count >= 16,
              let hashText = verifier.hash, let hash = Data(base64Encoded: hashText), hash.count == 32,
              let iterations = verifier.iterations else {
            return .failure(.unreadableValue)
        }
        guard iterationRange.contains(iterations) else {
            return .failure(.invalidValue("its iteration count is outside \(iterationRange.lowerBound)–\(iterationRange.upperBound)"))
        }
        return .success(.init(salt: salt, iterations: iterations, hash: hash))
    }

    /// Check a profile's `adminCard`: 64 hex characters.
    static func resolveCard(_ text: String) -> Result<Data, ProfileApplier.Drop.Reason> {
        let hex = text.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            return .failure(.invalidValue("it is not a card digest"))
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return .failure(.unreadableValue) }
            bytes.append(byte)
            index = next
        }
        return .success(Data(bytes))
    }
}
