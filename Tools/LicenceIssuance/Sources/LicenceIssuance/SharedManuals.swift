import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

// Plan LV P3 — shared manuals: one encrypted copy, a key per company (envelope encryption).
//
// A partner who may distribute a manual uploads it once. The service encrypts it once under a
// random content key (`SharedManualSeal`) and gives each subscribed company only that key, wrapped
// with a key derived from the company's secret (`SharedManualKey`), on the company's own manual row
// (`Manual.shared`). The phone unwraps the key with its company secret, opens the one shared file
// and lays the manual in as any company manual. `Contracts/company-vaults.md` §8; the phone restates
// both halves (`CompanySharedManualSeal`, `CompanySharedManualKey`) and is pinned to the
// `company-vaults-v3` fixtures.

extension CompanyVaultContract {

    /// The manual row's `shared` field: which shared file this row's manual is, under which content
    /// key, and that key wrapped for this company. With it, the row's `sealedSha256` describes the
    /// shared file as served, `sizeBytes` and `revision` its plaintext, as for any manual.
    public struct SharedManual: Codable, Equatable, Sendable {
        /// The shared file's id on the service, a safe identifier. The same for every company.
        public let contentId: String
        /// The content key's number, 1 or more. A rotation re-encrypts the file under a new key with
        /// a higher `keyId`, so a key a phone kept opens nothing still served.
        public let keyId: Int
        /// The content key wrapped for this company (`SharedManualKey.wrap`): base64 of
        /// nonce ‖ ciphertext ‖ tag, `SharedManualKey.wrappedKeyLength` bytes.
        public let wrappedKey: String

        public init(contentId: String, keyId: Int, wrappedKey: String) {
            self.contentId = contentId; self.keyId = keyId; self.wrappedKey = wrappedKey
        }
    }

    /// Why a row's `shared` field cannot be used, or nil.
    static func sharedProblem(_ shared: SharedManual, fileName: String) -> String? {
        guard ProfileContract.isSafeIdentifier(shared.contentId) else { return "\(fileName)'s shared contentId is not a safe identifier" }
        guard shared.keyId >= 1 else { return "\(fileName)'s shared keyId must be 1 or more" }
        guard let wrapped = Data(base64Encoded: shared.wrappedKey), wrapped.count == SharedManualKey.wrappedKeyLength else {
            return "\(fileName)'s wrapped key is not \(SharedManualKey.wrappedKeyLength) bytes of base64"
        }
        return nil
    }

    // MARK: - The shared file

    /// The one shared file: the chunked seal of §3 in every byte (`ChunkedSeal`), under
    /// `openglasses.shared-manual.v1`, magic `OGSM`, keyed from the content key rather than a company
    /// secret.
    ///
    /// ```
    /// key      = HKDF-SHA256(ikm: content key, salt: none, info: "openglasses.shared-manual.v1"), 32 bytes
    /// header   = "OGSM" ‖ 0x01 ‖ chunkSize (UInt32, big-endian; 1 MiB)
    /// AADᵢ     = UTF-8("openglasses.shared-manual.v1\n" + contentId + "\n" + keyId + "\n")
    ///            ‖ header ‖ i (UInt64, big-endian) ‖ (0x01 for the last chunk, else 0x00)
    /// ```
    ///
    /// `keyId` is written in decimal. The context names no company: the file is the same for every
    /// company. The plaintext is checked against the row's `revision` after opening.
    public enum SharedManualSeal {
        /// **Key-derivation and authentication domain.** Never change it: every shared manual
        /// already delivered would stop opening.
        public static let domain = "openglasses.shared-manual.v1"
        public static let magic = Data("OGSM".utf8)
        /// A content key's length: 32 random bytes.
        public static let contentKeyLength = 32

        static let construction = ChunkedSeal(domain: domain, magic: magic)

        public typealias Problem = ManualSeal.Problem

        public struct Context: Equatable, Sendable {
            public let contentId: String
            public let keyId: Int
            public init(contentId: String, keyId: Int) { self.contentId = contentId; self.keyId = keyId }
            public init(shared: SharedManual) { self.init(contentId: shared.contentId, keyId: shared.keyId) }

            var fields: [String] { [contentId, String(keyId)] }
        }

        /// A new random content key, for a new shared file or a rotation.
        public static func newContentKey() -> Data {
            Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        }

        public static func header() -> Data { construction.header() }

        /// The shared file's exact length for `plaintextBytes` (at least 1): the same as any sealed manual.
        public static func sealedLength(plaintextBytes: Int) -> Int { ChunkedSeal.sealedLength(plaintextBytes: plaintextBytes) }

        /// Seal bytes already in memory. `nonce` exists for the golden fixtures only; leave it out.
        public static func seal(_ plaintext: Data, context: Context, contentKey: Data,
                                nonce: ((UInt64) throws -> AES.GCM.Nonce)? = nil) throws -> Data {
            guard contentKey.count == contentKeyLength else { throw Problem.invalidSecret }
            return try construction.seal(plaintext, fields: context.fields, companySecret: contentKey, nonce: nonce)
        }

        /// Open bytes already in memory, checking the plaintext against `revision`.
        public static func open(_ sealed: Data, context: Context, contentKey: Data, revision: String) throws -> Data {
            var plain = Data()
            try open(length: sealed.count, read: { range in sealed.subdata(in: range) }, context: context,
                     contentKey: contentKey) { plain.append($0) }
            guard IssuanceWire.digest(plain) == revision else { throw Problem.wrongRevision }
            return plain
        }

        /// The streaming form, as `ManualSeal.open(length:read:context:companySecret:sink:)`. The
        /// caller checks the revision over what `sink` received.
        public static func open(length: Int, read: (Range<Int>) throws -> Data, context: Context, contentKey: Data,
                                sink: (Data) throws -> Void) throws {
            guard contentKey.count == contentKeyLength else { throw Problem.invalidSecret }
            try construction.open(length: length, read: read, fields: context.fields, companySecret: contentKey, sink: sink)
        }

        /// Seal a manual on disk to the shared file, one chunk in memory at a time, and return every
        /// company's row's `revision`, `sizeBytes` and `sealedSha256`. For the service's uploads and
        /// rotations; the content key is then wrapped for each company with `SharedManualKey.wrap`.
        public static func sealFile(at input: URL, to output: URL, context: Context,
                                    contentKey: Data) throws -> (revision: String, sizeBytes: Int, sealedSha256: String) {
            guard contentKey.count == contentKeyLength else { throw Problem.invalidSecret }
            return try construction.sealFile(at: input, to: output, companySecret: contentKey) { _ in context.fields }
        }
    }

    // MARK: - The key, per company

    /// The content key wrapped for one company.
    ///
    /// ```
    /// context  = UTF-8("openglasses.shared-manual-key.v1\n" + profileId + "\n" + contentId + "\n" + keyId + "\n")
    /// KEK      = HKDF-SHA256(ikm: company secret, salt: none, info: context), 32 bytes
    /// wrapped  = base64(nonce (12 random bytes) ‖ AES-256-GCM(KEK, content key, AAD: context) ‖ tag (16))
    /// ```
    ///
    /// 60 bytes, 80 characters of standard base64. A key wrapped for another company, another
    /// profile, another file or another `keyId` does not unwrap.
    public enum SharedManualKey {
        /// **Key-derivation and authentication domain.** Never change it: every wrapped key already
        /// delivered would stop unwrapping.
        public static let domain = "openglasses.shared-manual-key.v1"
        /// nonce (12) ‖ ciphertext (32) ‖ tag (16).
        public static let wrappedKeyLength = 12 + SharedManualSeal.contentKeyLength + 16

        public typealias Problem = ManualSeal.Problem

        public struct Context: Equatable, Sendable {
            public let profileId: String
            public let contentId: String
            public let keyId: Int
            public init(profileId: String, contentId: String, keyId: Int) {
                self.profileId = profileId; self.contentId = contentId; self.keyId = keyId
            }
            public init(profileId: String, shared: SharedManual) {
                self.init(profileId: profileId, contentId: shared.contentId, keyId: shared.keyId)
            }

            var bytes: Data { Data((SharedManualKey.domain + "\n" + [profileId, contentId, String(keyId)].map { $0 + "\n" }.joined()).utf8) }
        }

        static func kek(_ companySecret: Data, context: Context) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: companySecret), info: context.bytes, outputByteCount: 32)
        }

        /// Wrap `contentKey` for one company. `nonce` exists for the golden fixtures only; leave it out.
        public static func wrap(_ contentKey: Data, context: Context, companySecret: Data,
                                nonce: AES.GCM.Nonce? = nil) throws -> String {
            guard companySecret.count == ProfileContract.Credential.secretLength,
                  contentKey.count == SharedManualSeal.contentKeyLength else { throw Problem.invalidSecret }
            let box = try AES.GCM.seal(contentKey, using: kek(companySecret, context: context), nonce: nonce ?? AES.GCM.Nonce(),
                                       authenticating: context.bytes)
            guard let combined = box.combined, combined.count == wrappedKeyLength else { throw Problem.malformed }
            return combined.base64EncodedString()
        }

        /// The content key, or `malformed` (not 60 bytes of base64) or `unreadable` (wrapped for
        /// another company, profile, file or key: the phone's `tampered`).
        public static func unwrap(_ wrapped: String, context: Context, companySecret: Data) throws -> Data {
            guard companySecret.count == ProfileContract.Credential.secretLength else { throw Problem.invalidSecret }
            guard let bytes = Data(base64Encoded: wrapped), bytes.count == wrappedKeyLength else { throw Problem.malformed }
            guard let box = try? AES.GCM.SealedBox(combined: bytes),
                  let key = try? AES.GCM.open(box, using: kek(companySecret, context: context), authenticating: context.bytes),
                  key.count == SharedManualSeal.contentKeyLength else { throw Problem.unreadable }
            return key
        }
    }
}
