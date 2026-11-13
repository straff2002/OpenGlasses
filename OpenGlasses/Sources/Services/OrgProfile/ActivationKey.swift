import Foundation
import CryptoKit

/// Plan CT 3a — the short key a technician types instead of a signed licence code.
///
/// A licence code is about 400 characters of base64; nobody types that on a job site. The key is
/// `K7Q3-X9PD-M2VA-8RTN`: fifteen random Crockford base32 characters (75 bits) and one check
/// character. It *resolves* to the licence without a vendor server:
///
/// - the licence host, and before Plan LS the public site, holds one file per key, named
///   hex(SHA-256(`"openglasses.activation-id.v1\n"` + key));
/// - the file is sealed with AES-GCM under HKDF-SHA256(key, info `"openglasses.activation-key.v1"`),
///   base64 encoded. Version 1's plaintext is the bare licence code; version 2's is sorted-key JSON
///   `{"companySecret", "format": "openglasses.activation", "licenceCode", "version": 2}`, whose
///   company secret opens the credentials the profile carries sealed (`OrgCredentialSeal`). Both
///   are read; `ActivationKeyMint` in Tools/LicenceIssuance writes version 2.
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
    /// **Signing domain, not a product name.** The prefix hashed with a key to name its sealed
    /// file on the host, mirrored in `Scripts/generate-field-license.swift`.
    ///
    /// **Never change this value** (including in a rename): every activation key already issued
    /// would look for a file name nothing was published under, and stop activating. Pinned by
    /// `StorageIdentifierGuardTests`.
    static let fileIdSigningDomain = "openglasses.activation-id.v1\n"
    /// **Signing domain, not a product name.** The HKDF `info` the sealing key is derived with,
    /// mirrored in `Scripts/generate-field-license.swift`. **Never change this value:** every
    /// activation key already issued would derive the wrong key and fail to open its licence.
    /// Pinned by `StorageIdentifierGuardTests`.
    static let sealingSigningDomain = "openglasses.activation-key.v1"
    /// Where a sealed file is looked for, in order (Plan LS). The licence host serves a key's file
    /// before the portal shows the key, and is the authority. The public site (`activation/` in
    /// `Scripts/stage-pages-site.sh`) holds keys issued before the change, and is asked only when
    /// the licence host has no file or cannot answer; it goes when no build in use needs it.
    static let defaultSources = [LicenceHost.activationDirectory, PublicSite.activationDirectory]

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
        let compact = compacted(text)
        guard isAttempt(compact) else { return .notAKey }
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

    /// Upper case, with spaces, line breaks and dashes taken out.
    private static func compacted<S: StringProtocol>(_ text: S) -> String {
        text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Whether compacted text is an attempt at a key: short enough, and only the alphabet or the
    /// letters people type for it (`O`, `I`, `L`, `U`).
    private static func isAttempt(_ compact: String) -> Bool {
        !compact.isEmpty && compact.count <= longestAttempt
            && compact.allSatisfy { alphabet.contains($0) || "OILU".contains($0) }
    }

    // MARK: - Formatting as it is typed

    /// What a key field shows once `text` is typed or pasted into it, `previous` being what it
    /// showed before the edit.
    ///
    /// While the text reads as an attempt at a key (`read` would not say `.notAKey`), it is upper
    /// cased and grouped in fours, `K7Q3-X9PD-…`, whatever spaces or dashes it came with. Lookalike
    /// letters stay as typed, since `read` maps them, so the field never shows a character the
    /// person did not type. Anything else, a pasted licence code above all, comes back exactly as
    /// it is.
    ///
    /// Backspacing over a dash would only have the dash put straight back, so it takes the
    /// character before the dash instead.
    static func formatEntry(_ text: String, previous: String = "") -> String {
        var characters = Array(compacted(text))
        guard isAttempt(String(characters)) else { return text }
        if let dash = deletedDash(from: previous, leaving: text) {
            let before = compacted(previous.prefix(dash)).count
            if before > 0 { characters.remove(at: before - 1) }
        }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// The offset in `previous` of a single dash deleted to leave `text`, or nil for any other edit.
    private static func deletedDash(from previous: String, leaving text: String) -> Int? {
        let old = Array(previous)
        let new = Array(text)
        guard old.count == new.count + 1 else { return nil }
        let at = zip(old, new).prefix(while: { $0.0 == $0.1 }).count
        guard old[at] == "-", old[(at + 1)...].elementsEqual(new[at...]) else { return nil }
        return at
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
        SHA256.hash(data: Data((Self.fileIdSigningDomain + canonical).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var sealingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)),
                               info: Data(Self.sealingSigningDomain.utf8),
                               outputByteCount: 32)
    }

    /// The `format` of a version 2 file's plaintext.
    static let contentsFormat = "openglasses.activation"

    /// What a file opens to. A version 1 file carries no company secret.
    struct Contents: Equatable, Sendable {
        let licenceCode: String
        let companySecret: Data?
    }

    private struct Version2: Codable {
        var format = ActivationKey.contentsFormat
        var version = 2
        let licenceCode: String
        let companySecret: String
    }

    /// A version 1 file: base64 of AES-GCM's combined nonce, ciphertext and tag over the bare code.
    func seal(_ licenceCode: String) throws -> String {
        try seal(plain: Data(licenceCode.utf8))
    }

    /// A version 2 file, as the licence service writes it (tests and fixtures only on the phone).
    func seal(_ licenceCode: String, companySecret: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try seal(plain: encoder.encode(Version2(licenceCode: licenceCode,
                                                       companySecret: companySecret.base64EncodedString())))
    }

    private func seal(plain: Data) throws -> String {
        guard let combined = try AES.GCM.seal(plain, using: sealingKey).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined.base64EncodedString()
    }

    /// The licence code inside a fetched file, or nil when the file is not one this key sealed.
    func open(_ file: Data) -> String? {
        openContents(file)?.licenceCode
    }

    /// Either version's contents, or nil when the file is not one this key sealed. A version 2 file
    /// whose secret is not 32 bytes is not one the service wrote, and is refused whole.
    func openContents(_ file: Data) -> Contents? {
        guard let text = String(data: file, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let combined = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: sealingKey) else {
            return nil
        }
        if plain.first == UInt8(ascii: "{") {
            guard let v2 = try? JSONDecoder().decode(Version2.self, from: plain),
                  v2.format == Self.contentsFormat, v2.version == 2, !v2.licenceCode.isEmpty,
                  let secret = Data(base64Encoded: v2.companySecret),
                  secret.count == OrgCredentialSeal.secretLength else {
                return nil
            }
            return Contents(licenceCode: v2.licenceCode, companySecret: secret)
        }
        guard let code = String(data: plain, encoding: .utf8), !code.isEmpty else { return nil }
        return Contents(licenceCode: code, companySecret: nil)
    }
}

/// Fetches and opens the sealed licence for an activation key.
///
/// The fetch goes through `BoundedHTTPClient` under a profile sized for a few hundred bytes. The
/// licence that comes back is only a candidate: whoever called goes on to verify it exactly as if it
/// had been typed.
///
/// Plan LS: the sources are asked one after the other, and the next only when the one before has no
/// file for the key or could not answer, so a key the licence host serves never reaches the public
/// site. A file that does not open, or a withdrawn key (410), ends the lookup. With no file anywhere,
/// the first source decides what the technician is told: it is the authority, so only its "no such
/// key" makes the key unknown; when it could not look, the lookup could not either.
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

    /// What one source said about a key.
    enum Answer: Equatable, Sendable {
        /// A 2xx with a body: a file, still to be opened.
        case file(Data)
        /// The source looked and has no file of that name (404, or a reply that is never a file).
        case missing
        /// The source looked and the key was withdrawn (410). Final.
        case withdrawn
        /// The source could not be asked, or could not look (no network, a timeout, a 5xx).
        case unreachable
    }

    /// The directories asked, in order. Never empty in use; an empty list resolves nothing.
    var sources: [URL]
    var fetch: Fetch

    init(sources: [URL] = ActivationKey.defaultSources,
         fetch: @escaping Fetch = ActivationKeyResolver.boundedFetch) {
        self.sources = sources
        self.fetch = fetch
    }

    /// One directory only (tests and fixtures).
    init(directory: URL, fetch: @escaping Fetch = ActivationKeyResolver.boundedFetch) {
        self.init(sources: [directory], fetch: fetch)
    }

    func resolve(_ key: ActivationKey) async throws -> String {
        try await resolveContents(key).licenceCode
    }

    /// The licence code and, from a version 2 file, the company secret. The secret is kept only once
    /// the enrolment it came with has been applied (`OrgEnrolmentService.confirm`).
    func resolveContents(_ key: ActivationKey) async throws -> ActivationKey.Contents {
        var authority: Answer?
        for directory in sources {
            let answer = await ask(directory, for: key)
            if authority == nil { authority = answer }
            switch answer {
            case .file(let body):
                guard let contents = key.openContents(body) else { throw Failure.unreadable }
                return contents
            case .withdrawn:
                throw Failure.unknownKey
            case .missing, .unreachable:
                continue
            }
        }
        throw authority == .missing ? Failure.unknownKey : Failure.unreachable
    }

    /// One source's answer for one key.
    func ask(_ directory: URL, for key: ActivationKey) async -> Answer {
        let reply: (status: Int, body: Data)
        do {
            reply = try await fetch(directory.appendingPathComponent(key.fileName))
        } catch let error as BoundedHTTPClient.ClientError
                    where error == .unacceptableMIMEType || error == .responseTooLarge {
            // A 2xx that is HTML or large is a page, never a sealed file: there is no file here.
            return .missing
        } catch {
            return .unreachable
        }
        switch reply.status {
        case 200...299: return .file(reply.body)
        case 404: return .missing
        case 410: return .withdrawn
        default: return .unreachable
        }
    }

    static let boundedFetch: Fetch = { address in
        let (body, response) = try await BoundedHTTPClient().fetchData(address, profile: .activationKey)
        return (response.statusCode, body)
    }
}
