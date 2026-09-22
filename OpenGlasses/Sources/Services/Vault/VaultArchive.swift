import CryptoKit
import Foundation

/// Plan FS §2 — the vault archive a publisher builds off the phone, as the app **reads** it.
///
/// The format is a zip of an ordinary vault folder (`manifest.json`, the core markdown, an
/// optional `procedures/`, and the manuals a customer would otherwise have to extract themselves)
/// plus two files the app adds nothing to and only ever checks:
///
/// - `vault-archive.json` — this header: what the archive claims to be, and the SHA-256 and byte
///   size of every other file in it.
/// - `vault-archive.sig` — base64 of an Ed25519 signature over the header and the files, absent on
///   an unsigned archive.
///
/// The app never *writes* one. There is no share-as-link, no QR generation and no upload anywhere
/// in this app (owner decision, 2026-09-21): a vault link is something a publisher's site issues
/// and this phone receives. `Scripts/make-vault-archive.swift` is the builder, and it runs on a
/// computer with a publisher's private key that never comes near the repository or the phone.
struct VaultArchiveHeader: Codable, Equatable {

    /// One file in the archive, as the header claims it. Every entry is checked against the bytes
    /// actually in the zip before anything is installed.
    struct Entry: Codable, Equatable {
        /// Path relative to the vault root, exactly as the zip stores it.
        let path: String
        /// Lowercase hex SHA-256 of the file's bytes.
        let sha256: String
        let bytes: Int

        init(path: String, sha256: String, bytes: Int) {
            self.path = path
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    /// A manual, named the way the review sheet has to name it: by the title a technician would
    /// recognise, before a single byte of the vault is installed.
    struct Manual: Codable, Equatable {
        let title: String
        /// Whether the manufacturer's own PDF rides along beside the extracted text.
        let hasOriginal: Bool

        init(title: String, hasOriginal: Bool) {
            self.title = title
            self.hasOriginal = hasOriginal
        }

        enum CodingKeys: String, CodingKey {
            case title
            case hasOriginal = "has_original"
        }
    }

    /// Bumped when a change would make an older app misread an archive. An app refuses a version
    /// it does not know rather than guessing.
    let formatVersion: Int
    let vaultId: String
    let vaultName: String
    let vaultVersion: String
    /// The publisher's id in the vendor's signed catalog. Empty on an unsigned archive.
    let publisherId: String
    /// What the publisher calls itself. Shown only when the signature verifies against the
    /// catalog's key for `publisherId` — an unverified archive can claim any name it likes.
    let publisherName: String
    let files: [Entry]
    let totalBytes: Int
    /// Whether the archive carries the pre-extracted manual text. The whole point of receiving a
    /// vault rather than building one is that it does.
    let manualTextIncluded: Bool
    /// Whether the manufacturers' original PDFs ride along beside the text.
    let originalDocumentsIncluded: Bool
    let manuals: [Manual]

    static let filename = "vault-archive.json"
    static let signatureFilename = "vault-archive.sig"
    static let supportedFormatVersion = 1

    init(formatVersion: Int = VaultArchiveHeader.supportedFormatVersion,
         vaultId: String, vaultName: String, vaultVersion: String,
         publisherId: String = "", publisherName: String = "",
         files: [Entry], totalBytes: Int,
         manualTextIncluded: Bool = true, originalDocumentsIncluded: Bool = false,
         manuals: [Manual] = []) {
        self.formatVersion = formatVersion
        self.vaultId = vaultId
        self.vaultName = vaultName
        self.vaultVersion = vaultVersion
        self.publisherId = publisherId
        self.publisherName = publisherName
        self.files = files
        self.totalBytes = totalBytes
        self.manualTextIncluded = manualTextIncluded
        self.originalDocumentsIncluded = originalDocumentsIncluded
        self.manuals = manuals
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case vaultId = "vault_id"
        case vaultName = "vault_name"
        case vaultVersion = "vault_version"
        case publisherId = "publisher_id"
        case publisherName = "publisher_name"
        case files
        case totalBytes = "total_bytes"
        case manualTextIncluded = "manual_text_included"
        case originalDocumentsIncluded = "original_documents_included"
        case manuals
    }

    /// Hand-written so an archive that omits the optional keys still reads, and so a missing
    /// `publisher_id` means "unsigned" rather than "unreadable".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        vaultName = try c.decode(String.self, forKey: .vaultName)
        vaultVersion = try c.decode(String.self, forKey: .vaultVersion)
        publisherId = try c.decodeIfPresent(String.self, forKey: .publisherId) ?? ""
        publisherName = try c.decodeIfPresent(String.self, forKey: .publisherName) ?? ""
        files = try c.decode([Entry].self, forKey: .files)
        totalBytes = try c.decode(Int.self, forKey: .totalBytes)
        manualTextIncluded = try c.decodeIfPresent(Bool.self, forKey: .manualTextIncluded) ?? true
        originalDocumentsIncluded = try c.decodeIfPresent(Bool.self, forKey: .originalDocumentsIncluded) ?? false
        manuals = try c.decodeIfPresent([Manual].self, forKey: .manuals) ?? []
    }

    /// The bytes the signature covers, and the bytes any two implementations must agree on.
    ///
    /// Deliberately a **re-encoding** rather than the file's own bytes: the publisher's script and
    /// the phone then agree regardless of how the JSON was laid out, indented or ordered on the
    /// way through a web server. `sortedKeys` makes the encoding a function of the value.
    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// The signature over an archive: the pack message shape, with the canonical header in the
/// manifest position and every other file hashed into the sorted tail.
///
/// One message construction, one key format and one signing implementation serve skill packs,
/// vault packs and now vault archives — the difference is whose key signs. A pack is signed by the
/// vendor; an archive is signed by a **publisher**, whose public key reaches the app through the
/// vendor's signed catalog (`VaultPublisher`), so a publisher can be listed or revoked without an
/// app release.
enum VaultArchiveSignature {

    static func signingMessage(header: VaultArchiveHeader, files: [String: Data]) throws -> Data {
        SkillPackSignature.signingMessage(manifestData: try header.canonicalData(), payloadFiles: files)
    }

    static func verify(signatureBase64: String, header: VaultArchiveHeader,
                       files: [String: Data], publicKeyBase64: String) -> Bool {
        guard let canonical = try? header.canonicalData() else { return false }
        return SkillPackSignature.verify(signatureBase64: signatureBase64, manifestData: canonical,
                                         payloadFiles: files, publicKeyBase64: publicKeyBase64)
    }

    /// Publisher/test side only — the app holds no private key.
    static func sign(header: VaultArchiveHeader, files: [String: Data],
                     privateKeyBase64: String) throws -> String {
        try SkillPackSignature.sign(manifestData: try header.canonicalData(),
                                    payloadFiles: files, privateKeyBase64: privateKeyBase64)
    }
}

/// Zip bytes → header, detached signature and every other file, under hard limits.
///
/// The reader is the one the packs already use, and so are its refusals: a path that escapes the
/// vault root, an entry larger than the profile allows, more entries than a vault can plausibly
/// have, and — added here because a received archive carries whole manuals — a cap on the total
/// uncompressed size, so a small download cannot inflate into a full disk.
enum VaultArchiveReader {

    struct Extracted: Equatable {
        let header: VaultArchiveHeader
        let signature: String?
        /// Every file except the header and the detached signature, by relative path.
        let files: [String: Data]
    }

    enum ArchiveError: Error, Equatable {
        case notAZip
        case missingHeader
        case unreadableHeader
        case unsupportedFormatVersion(Int)
        case missingVaultManifest
        case tooManyEntries(Int)
        case entryTooLarge(String)
        case totalTooLarge(Int)
        case unsafeEntryPath(String)
        /// The zip holds a file the header does not list, or lists one the zip has not got.
        case fileListMismatch(String)
        case checksumMismatch(String)
        case sizeMismatch(String)
    }

    /// A single manual can be a large PDF; a single *entry* still has a ceiling well under the
    /// archive's, so one forged central-directory size cannot ask for an unbounded allocation.
    static let maxEntryBytes = 96 * 1024 * 1024
    static let maxEntryCount = 512

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Read the archive. `maximumTotalBytes` is the hard ceiling on everything the zip inflates
    /// to — `Config.vaultLinkMaxBytes` on every production path.
    static func extract(zipData: Data,
                        maximumTotalBytes: Int) -> Result<Extracted, ArchiveError> {
        guard let archive = ZipArchiveReader(data: zipData) else { return .failure(.notAZip) }
        guard archive.entryNames.count <= maxEntryCount else {
            return .failure(.tooManyEntries(archive.entryNames.count))
        }
        guard let headerData = archive.entryData(named: VaultArchiveHeader.filename,
                                                 maximumUncompressedSize: maxEntryBytes) else {
            return .failure(.missingHeader)
        }
        guard let header = try? JSONDecoder().decode(VaultArchiveHeader.self, from: headerData) else {
            return .failure(.unreadableHeader)
        }
        guard header.formatVersion <= VaultArchiveHeader.supportedFormatVersion else {
            return .failure(.unsupportedFormatVersion(header.formatVersion))
        }

        var signature: String?
        var files: [String: Data] = [:]
        var total = 0
        for name in archive.entryNames {
            let normalized = normalize(name)
            if normalized.hasSuffix("/") || normalized.hasPrefix("__MACOSX") { continue }
            if normalized == VaultArchiveHeader.filename { continue }
            guard isSafeRelativePath(normalized) else { return .failure(.unsafeEntryPath(name)) }
            guard let data = archive.entryData(named: name, maximumUncompressedSize: maxEntryBytes) else {
                return .failure(.entryTooLarge(normalized))
            }
            total += data.count
            guard total <= maximumTotalBytes else { return .failure(.totalTooLarge(total)) }
            if normalized == VaultArchiveHeader.signatureFilename {
                signature = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            files[normalized] = data
        }
        guard files["manifest.json"] != nil else { return .failure(.missingVaultManifest) }
        return .success(Extracted(header: header, signature: signature, files: files))
    }

    /// Every file the header lists is present with exactly the bytes it claims, and the archive
    /// carries nothing the header did not declare.
    ///
    /// Both halves matter. The first is the tamper check. The second is what stops a signed
    /// archive being reopened and a *new* file dropped in beside the declared ones — the signature
    /// covers what was in the zip when it was signed, but an app that installed undeclared files
    /// would be installing content nobody reviewed.
    static func checkFiles(header: VaultArchiveHeader, files: [String: Data]) -> ArchiveError? {
        var declared = Set<String>()
        for entry in header.files {
            guard isSafeRelativePath(entry.path) else { return .unsafeEntryPath(entry.path) }
            guard declared.insert(entry.path).inserted else { return .fileListMismatch(entry.path) }
            guard let data = files[entry.path] else { return .fileListMismatch(entry.path) }
            guard data.count == entry.bytes else { return .sizeMismatch(entry.path) }
            guard sha256Hex(data) == entry.sha256.lowercased() else { return .checksumMismatch(entry.path) }
        }
        for path in files.keys.sorted() where !declared.contains(path) {
            return .fileListMismatch(path)
        }
        return nil
    }

    /// A zip entry name that stays inside the vault root: relative, no `..` component, no drive or
    /// root prefix, and no backslash a filesystem might read as a separator.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains("\0"), !path.hasPrefix("__MACOSX") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    private static func normalize(_ name: String) -> String {
        name.hasPrefix("./") ? String(name.dropFirst(2)) : name
    }

    /// The reason an archive could not be read, in the words the review sheet shows. Never
    /// includes the URL, a path from the source site or anything else the link carried.
    static func describe(_ error: ArchiveError) -> String {
        switch error {
        case .notAZip: return "That file isn't a readable vault archive."
        case .missingHeader: return "The archive has no vault-archive.json header."
        case .unreadableHeader: return "The archive's header is unreadable."
        case .unsupportedFormatVersion(let version):
            return "This archive uses vault format \(version); this app build reads up to format \(VaultArchiveHeader.supportedFormatVersion). Update the app."
        case .missingVaultManifest: return "The archive has no manifest.json."
        case .tooManyEntries(let count): return "The archive holds \(count) files, more than a vault may contain."
        case .entryTooLarge(let path): return "One file in the archive is too large to read: \(path)."
        case .totalTooLarge: return "The archive is larger than this app will unpack."
        case .unsafeEntryPath: return "The archive contains a file path that would write outside the vault — refusing it."
        case .fileListMismatch(let path): return "The archive's contents don't match its header (\(path))."
        case .sizeMismatch(let path): return "A file in the archive is not the size its header claims (\(path))."
        case .checksumMismatch(let path): return "A file in the archive doesn't match its checksum (\(path))."
        }
    }
}
