import Foundation
import CryptoKit

/// Plan CT 3a — the short key a technician types instead of a signed licence code.
///
/// A licence code is about 400 characters of base64; nobody types that on a job site. The key is
/// `K7Q3-X9PD-M2VA-8RTN`: fifteen random Crockford base32 characters (75 bits) and one check
/// character. It *resolves* to the licence without a vendor server:
///
/// - the static host already serving the catalogs holds one file per key, named
///   hex(SHA-256(`"openglasses.activation-id.v1\n"` + key));
/// - the file is the licence code sealed with AES-GCM under HKDF-SHA256(key, info
///   `"openglasses.activation-key.v1"`), base64 encoded.
///
/// Nothing on the host maps back to a key, and what it serves still has to verify against the
/// embedded licence key, so the host can withhold a licence but never forge one.
///
/// "Key" in both derivations means the sixteen canonical characters: upper case, no dashes, aliases
/// (`O`, `I`, `L`) already mapped. `Scripts/generate-field-license.swift --activation-key` mirrors
/// this file and must stay byte-for-byte compatible with it.
struct ActivationKey: Equatable, Sendable {

    /// Crockford's base32: no I, L, O or U.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 16
    static let fileIdDomain = "openglasses.activation-id.v1\n"
    static let sealingInfo = "openglasses.activation-key.v1"
    /// Where the sealed files are published (`activation/` in `Scripts/stage-pages-site.sh`).
    static let defaultDirectory = URL(string: "https://straff2002.github.io/OpenGlasses/activation/")!

    /// The longest input still read as an attempt at a key — sixteen characters plus dashes and a
    /// few spaces. Anything longer is a licence code, whatever its characters.
    private static let longestAttempt = 24

    /// The sixteen canonical characters.
    let canonical: String

    enum Problem: Error, Equatable, LocalizedError {
        /// The right characters, the wrong number of them.
        case length(Int)
        /// A character outside the alphabet, or one that fails the check — a typo either way.
        case mistyped

        var errorDescription: String? {
            switch self {
            case .length(let count):
                return "An activation key is \(ActivationKey.length) characters — that one has \(count)."
            case .mistyped:
                return "Check the key — one character looks wrong."
            }
        }
    }

    /// What some typed or pasted text is.
    enum Reading: Equatable {
        case key(ActivationKey)
        /// An attempt at a key that cannot be one. Refused before anything is fetched.
        case invalid(Problem)
        /// Not an attempt at a key — a licence code, most likely. The licence path decides.
        case notAKey
    }

    private init(canonical: String) {
        self.canonical = canonical
    }

    // MARK: - Reading what was typed

    static func read(_ text: String) -> Reading {
        let compact = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard !compact.isEmpty, compact.count <= longestAttempt,
              compact.allSatisfy({ alphabet.contains($0) || "OILU".contains($0) }) else {
            return .notAKey
        }
        guard compact.count == length else { return .invalid(.length(compact.count)) }
        var values: [Int] = []
        for character in compact {
            guard let value = value(of: character) else { return .invalid(.mistyped) }
            values.append(value)
        }
        guard checkValue(Array(values.prefix(length - 1))) == values[length - 1] else {
            return .invalid(.mistyped)
        }
        return .key(ActivationKey(canonical: String(values.map { alphabet[$0] })))
    }

    /// A character's value, reading `O` as `0` and `I`/`L` as `1`. `U` has none.
    private static func value(of character: Character) -> Int? {
        switch character {
        case "O": return 0
        case "I", "L": return 1
        default: return alphabet.firstIndex(of: character)
        }
    }

    /// A new key from fifteen random characters and their check character.
    static func generate<R: RandomNumberGenerator>(using generator: inout R) -> ActivationKey {
        let values = (0..<(length - 1)).map { _ in Int.random(in: 0..<32, using: &generator) }
        return ActivationKey(canonical: String((values + [checkValue(values)]).map { alphabet[$0] }))
    }

    static func generate() -> ActivationKey {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// `K7Q3-X9PD-M2VA-8RTN`, the form a key is handed out in.
    var display: String {
        stride(from: 0, to: canonical.count, by: 4).map { start -> String in
            let from = canonical.index(canonical.startIndex, offsetBy: start)
            let to = canonical.index(from, offsetBy: 4)
            return String(canonical[from..<to])
        }.joined(separator: "-")
    }

    // MARK: - The check character

    /// Σ αⁱ·vᵢ over GF(32) (x⁵ + x² + 1), for the fifteen data values at i = 1…15.
    ///
    /// Every weight is a distinct non-zero element, so any single wrong character and any swap of
    /// two different adjacent characters (the check character included) changes the sum: both
    /// typing mistakes are always caught, not caught 31 times in 32.
    static func checkValue(_ values: [Int]) -> Int {
        var weight = 1
        var sum = 0
        for value in values {
            weight = gfMultiply(weight, 2)
            sum ^= gfMultiply(weight, value)
        }
        return sum
    }

    private static func gfMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        var product = 0
        while b > 0 {
            if b & 1 == 1 { product ^= a }
            b >>= 1
            a <<= 1
            if a & 0b10_0000 != 0 { a ^= 0b10_0101 }
        }
        return product
    }

    // MARK: - The sealed file

    /// The sealed file's name on the static host. Knowing it tells nobody the key.
    var fileName: String {
        SHA256.hash(data: Data((Self.fileIdDomain + canonical).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var sealingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)),
                               info: Data(Self.sealingInfo.utf8),
                               outputByteCount: 32)
    }

    /// The file's contents: base64 of AES-GCM's combined nonce, ciphertext and tag.
    func seal(_ licenceCode: String) throws -> String {
        guard let combined = try AES.GCM.seal(Data(licenceCode.utf8), using: sealingKey).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined.base64EncodedString()
    }

    /// The licence code inside a fetched file, or nil when the file is not one this key sealed.
    func open(_ file: Data) -> String? {
        guard let text = String(data: file, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let combined = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: sealingKey) else {
            return nil
        }
        return String(data: plain, encoding: .utf8)
    }
}

/// Fetches and opens the sealed licence for an activation key.
///
/// The fetch goes through `BoundedHTTPClient` under a profile sized for a few hundred bytes. The
/// licence that comes back is only a candidate: whoever called goes on to verify it exactly as if it
/// had been typed.
struct ActivationKeyResolver: Sendable {

    enum Failure: Error, Equatable, LocalizedError {
        /// No file for this key: never issued, withdrawn, or mistyped past the check character.
        case unknownKey
        /// The host could not be reached, or answered with an error.
        case unreachable
        /// A file was there, but this key did not seal it.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unknownKey, .unreadable:
                return "That activation key isn't recognised. Check it with whoever gave it to you."
            case .unreachable:
                return "Couldn't look up the activation key. An activation key needs the internet once — connect and try again."
            }
        }
    }

    /// The HTTP status and body of one GET.
    typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

    var directory: URL = ActivationKey.defaultDirectory
    var fetch: Fetch = ActivationKeyResolver.boundedFetch

    func resolve(_ key: ActivationKey) async throws -> String {
        let address = directory.appendingPathComponent(key.fileName)
        let reply: (status: Int, body: Data)
        do {
            reply = try await fetch(address)
        } catch let error as BoundedHTTPClient.ClientError
                    where error == .unacceptableMIMEType || error == .responseTooLarge {
            // The static host answers a missing file with its HTML error page. A sealed file is
            // never HTML and never large, so either means there is no file for this key.
            throw Failure.unknownKey
        } catch {
            throw Failure.unreachable
        }
        switch reply.status {
        case 200...299:
            guard let code = key.open(reply.body) else { throw Failure.unreadable }
            return code
        case 404, 410:
            throw Failure.unknownKey
        default:
            throw Failure.unreachable
        }
    }

    static let boundedFetch: Fetch = { address in
        let (body, response) = try await BoundedHTTPClient().fetchData(address, profile: .activationKey)
        return (response.statusCode, body)
    }
}
