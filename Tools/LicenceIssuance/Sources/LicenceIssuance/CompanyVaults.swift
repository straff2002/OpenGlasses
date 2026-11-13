import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

// Plan LR — company vaults and manuals from the licence portal. The wire contract between the
// licence service, which publishes a company's vaults and manuals, and the phone, which installs
// them. The phone restates every part of it in its own types (no production verifier depends on
// this package); `CompanyVaultContractTests` in the app holds the two to the same bytes, and the
// golden fixtures under `Contracts/fixtures/company-vaults-v1/` are read by both sides' tests.
//
// Three documents:
//
// 1. The profile's pointer, `ProfileContract.CompanyVaults` (`companyVaults` in the signed
//    profile): the catalog's address, its generation and the oldest build that can read it. A
//    pointer, never content; absent on every profile that has no company vaults.
// 2. The company vault catalog (`CompanyVaultContract.Catalog`), signed with the vendor's
//    pack-catalog key under `catalogDomain` and bound to one `profileId` and one `generation`.
// 3. A sealed manual (`CompanyVaultContract.ManualSeal`): AES-GCM under a key derived from the
//    company secret, in 1 MiB chunks, so a 128 MB manual never sits in memory twice.

public enum CompanyVaultContract {

    // MARK: - Identifiers

    /// The catalog payload's `format`. **Signed identifier, not a product name: never change it.**
    public static let catalogFormat = "openglasses.company-vault-catalog"
    /// The newest catalog `version` this contract describes.
    public static let catalogVersion = 1
    /// **Signing domain.** The pack-catalog key signs these bytes, then the exact payload bytes.
    /// The public vault-pack catalog is signed over its payload with no prefix, and a payload is
    /// JSON (it starts with `{`), so neither document's signature can verify as the other's.
    public static let catalogDomain = "openglasses.company-vault-catalog.v1\n"
    /// The prefix every vault pack id carries (`VaultPackManifest.productPrefix` in the app).
    public static let packIdPrefix = "com.openglasses.vault."

    // MARK: - Limits (Plan LR decision 2)

    /// The size limits, enforced by the service before anything is stored and again by the phone,
    /// because a signed catalog is not a reason to trust a size.
    public enum Limits {
        /// One PDF manual: the phone's own captured-manual PDF cap (`CapturedManualContract.maximumPDFBytes`).
        public static let pdfBytes = 128 * 1_048_576
        /// One Word manual (`ManualFileUpload.maximumWordBytes`); its text copy is held to `textBytes`.
        public static let wordBytes = 100 * 1_048_576
        /// One Markdown or text manual, and a Word manual's text copy (`ManualFileUpload.maximumTextBytes`).
        public static let textBytes = 20 * 1_048_576
        /// A vault's core files as one pack archive (`Config.vaultLinkMaxBytes`).
        public static let vaultCoreBytes = 250 * 1_048_576
        /// Each file inside a pack (`VaultPackArchive.maxEntryBytes`).
        public static let vaultCoreFileBytes = 20 * 1_048_576
        /// Everything one company stores, to start; the vendor can raise it per company.
        public static let companyTotalBytes: Int64 = 1_073_741_824
        /// A catalog envelope, before it is parsed.
        public static let catalogEnvelopeBytes = 1_048_576
        /// Rows in one catalog.
        public static let vaultsPerCatalog = 64
        public static let manualsPerCatalog = 2_000

        /// The cap for one manual of `kind`.
        public static func manualBytes(_ kind: ManualKind) -> Int {
            switch kind {
            case .pdf: return pdfBytes
            case .docx: return wordBytes
            case .md: return textBytes
            }
        }
    }

    /// What a manual file is. The file name's extension must say the same.
    public enum ManualKind: String, Codable, CaseIterable, Sendable {
        case pdf, docx, md

        public var extensions: Set<String> {
            switch self {
            case .pdf: return ["pdf"]
            case .docx: return ["docx"]
            case .md: return ["md", "markdown"]
            }
        }
    }

    // MARK: - The catalog

    /// One vault: an EG vault pack in every byte (core files only, never manuals), so the phone
    /// installs it through the same path as a public pack. Field for field the public catalog's
    /// row (`VaultPackCatalogEntry`), with `sizeBytes` required.
    public struct Vault: Codable, Equatable, Sendable {
        /// The pack id, `com.openglasses.vault.<something>`.
        public let id: String
        public let vaultId: String
        public let version: String
        public let name: String
        public let summary: String?
        public let author: String?
        public let minAppBuild: Int?
        /// The pack archive's length in bytes.
        public let sizeBytes: Int
        public let downloadURL: String
        /// Lowercase hex SHA-256 of the pack archive.
        public let sha256: String
        /// The pack signature (`VaultPackSignature`), base64, by the pack-catalog key.
        public let packSignature: String

        public init(id: String, vaultId: String, version: String, name: String, summary: String? = nil,
                    author: String? = nil, minAppBuild: Int? = nil, sizeBytes: Int, downloadURL: String,
                    sha256: String, packSignature: String) {
            self.id = id; self.vaultId = vaultId; self.version = version; self.name = name
            self.summary = summary; self.author = author; self.minAppBuild = minAppBuild
            self.sizeBytes = sizeBytes; self.downloadURL = downloadURL; self.sha256 = sha256
            self.packSignature = packSignature
        }
    }

    /// One manual file in one vault. One row per file, so adding or changing a manual moves only
    /// that file.
    public struct Manual: Codable, Equatable, Sendable {
        /// The vault the manual belongs to; it must be a `Vault.vaultId` in the same catalog.
        public let vaultId: String
        /// The file's name in the vault, its identity there. The citation title is this without
        /// its extension.
        public let fileName: String
        /// Lowercase hex SHA-256 of the manual's plaintext bytes. A new revision is a new hash.
        public let revision: String
        /// The plaintext length in bytes.
        public let sizeBytes: Int
        /// Lowercase hex SHA-256 of the sealed file as served.
        public let sealedSha256: String
        public let downloadURL: String
        public let kind: ManualKind

        public init(vaultId: String, fileName: String, revision: String, sizeBytes: Int, sealedSha256: String,
                    downloadURL: String, kind: ManualKind) {
            self.vaultId = vaultId; self.fileName = fileName; self.revision = revision; self.sizeBytes = sizeBytes
            self.sealedSha256 = sealedSha256; self.downloadURL = downloadURL; self.kind = kind
        }
    }

    /// The signed payload.
    public struct Catalog: Codable, Equatable, Sendable {
        public let format: String
        public let version: Int
        /// The one company this catalog is for: the profile's `profileId`.
        public let profileId: String
        /// Rises with every change the partner makes; matches the profile pointer's `generation`.
        public let generation: Int
        public let issued: Date
        /// The company's "Manuals on any network" setting (Plan LR decision 3). False: manuals wait
        /// for a network the phone does not call expensive, unless the technician taps Download now.
        public let manualsOnAnyNetwork: Bool
        public let vaults: [Vault]
        public let manuals: [Manual]

        public init(profileId: String, generation: Int, issued: Date, manualsOnAnyNetwork: Bool = false,
                    vaults: [Vault], manuals: [Manual],
                    format: String = CompanyVaultContract.catalogFormat,
                    version: Int = CompanyVaultContract.catalogVersion) {
            self.format = format; self.version = version; self.profileId = profileId; self.generation = generation
            self.issued = issued; self.manualsOnAnyNetwork = manualsOnAnyNetwork; self.vaults = vaults
            self.manuals = manuals
        }
    }

    /// The envelope on the wire: base64 of the exact payload bytes, and of the Ed25519 signature
    /// over `catalogDomain` followed by those bytes.
    public struct Envelope: Codable, Equatable, Sendable {
        public let payload: String
        public let signature: String
        public init(payload: String, signature: String) { self.payload = payload; self.signature = signature }
    }

    public enum Refusal: Error, Equatable {
        /// Not an envelope, or larger than `Limits.catalogEnvelopeBytes`.
        case notAnEnvelope
        case badSignature
        /// The payload did not decode, or its `format` is not a catalog's.
        case unreadable
        /// A `version` newer than this contract.
        case unsupportedVersion(Int)
        /// Signed for another company's profile.
        case otherCompany
        /// Older than a generation this phone has already applied: a replay.
        case replayed(generation: Int, highWater: Int)
        /// Older than the generation the profile points at: the host has not caught up yet.
        case behindProfile(generation: Int, profileGeneration: Int)
        /// The service refuses to sign this; the message says why.
        case invalid(String)
    }

    /// Payloads are encoded with sorted keys, ISO 8601 dates and unescaped slashes. The phone
    /// verifies the exact bytes, so the encoding is the service's choice; this is the one the
    /// fixtures pin.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder { IssuanceWire.decoder() }

    // MARK: Checks

    /// What the service holds a catalog to before signing it. The phone checks the same rows again
    /// and leaves out any that fail.
    public static func check(_ catalog: Catalog, companyTotalBytes: Int64 = Limits.companyTotalBytes) throws {
        func refuse(_ message: String) -> Refusal { .invalid(message) }
        guard catalog.format == catalogFormat, catalog.version == catalogVersion else {
            throw refuse("format must be \(catalogFormat), version \(catalogVersion)")
        }
        guard ProfileContract.isSafeIdentifier(catalog.profileId) else { throw refuse("profileId is not a safe identifier") }
        guard catalog.generation >= 1 else { throw refuse("generation must be 1 or more") }
        guard catalog.vaults.count <= Limits.vaultsPerCatalog else {
            throw refuse("a catalog lists at most \(Limits.vaultsPerCatalog) vaults")
        }
        guard catalog.manuals.count <= Limits.manualsPerCatalog else {
            throw refuse("a catalog lists at most \(Limits.manualsPerCatalog) manuals")
        }
        var packIds = Set<String>(), vaultIds = Set<String>()
        var total: Int64 = 0
        for vault in catalog.vaults {
            if let problem = problem(with: vault) { throw refuse(problem) }
            guard packIds.insert(vault.id).inserted, vaultIds.insert(vault.vaultId).inserted else {
                throw refuse("\(vault.vaultId) is listed twice")
            }
            total += Int64(vault.sizeBytes)
        }
        var files = Set<String>()
        for manual in catalog.manuals {
            if let problem = problem(with: manual) { throw refuse(problem) }
            guard vaultIds.contains(manual.vaultId) else {
                throw refuse("\(manual.fileName) names \(manual.vaultId), which is not a vault in this catalog")
            }
            guard files.insert(manual.vaultId + "\u{0}" + manual.fileName.lowercased()).inserted else {
                throw refuse("\(manual.fileName) is listed twice in \(manual.vaultId)")
            }
            total += Int64(manual.sizeBytes)
        }
        guard total <= companyTotalBytes else {
            throw refuse("the company's vaults and manuals come to \(total) bytes, over its \(companyTotalBytes)-byte limit")
        }
    }

    /// Why one vault row cannot be installed, or nil.
    public static func problem(with vault: Vault) -> String? {
        guard vault.id.hasPrefix(packIdPrefix), vault.id.count > packIdPrefix.count,
              ProfileContract.isSafeIdentifier(vault.id) else { return "\(vault.id) is not a vault pack id" }
        guard ProfileContract.isSafeIdentifier(vault.vaultId) else { return "\(vault.vaultId) is not a safe vault id" }
        guard isPrintable(vault.version, maximum: 80), isPrintable(vault.name, maximum: 200, spaces: true) else {
            return "\(vault.vaultId) needs a version and a name"
        }
        guard (1...Limits.vaultCoreBytes).contains(vault.sizeBytes) else {
            return "\(vault.vaultId)'s core files are \(vault.sizeBytes) bytes; the limit is \(Limits.vaultCoreBytes)"
        }
        guard isHexDigest(vault.sha256), !vault.packSignature.isEmpty else { return "\(vault.vaultId) has no checksum or signature" }
        guard isDownloadURL(vault.downloadURL) else { return "\(vault.vaultId)'s download address must be HTTPS" }
        if let build = vault.minAppBuild, build < 1 { return "\(vault.vaultId)'s minAppBuild must be positive" }
        return nil
    }

    /// Why one manual row cannot be delivered, or nil.
    public static func problem(with manual: Manual) -> String? {
        guard ProfileContract.isSafeIdentifier(manual.vaultId) else { return "\(manual.vaultId) is not a safe vault id" }
        guard isSafeFileName(manual.fileName) else { return "\(manual.fileName) is not a file name a vault can hold" }
        let ext = (manual.fileName as NSString).pathExtension.lowercased()
        guard manual.kind.extensions.contains(ext) else { return "\(manual.fileName) is not a \(manual.kind.rawValue) file" }
        let limit = Limits.manualBytes(manual.kind)
        guard (1...limit).contains(manual.sizeBytes) else {
            return "\(manual.fileName) is \(manual.sizeBytes) bytes; a \(manual.kind.rawValue) manual may be at most \(limit)"
        }
        guard isHexDigest(manual.revision), isHexDigest(manual.sealedSha256) else { return "\(manual.fileName) has no revision or checksum" }
        guard isDownloadURL(manual.downloadURL) else { return "\(manual.fileName)'s download address must be HTTPS" }
        return nil
    }

    /// The pack archive's own files: each within `Limits.vaultCoreFileBytes`, together within
    /// `Limits.vaultCoreBytes`. For the service to run on an uploaded archive before storing it.
    public static func checkPackFiles(_ sizes: [String: Int]) throws {
        var total = 0
        for (path, size) in sizes {
            guard size <= Limits.vaultCoreFileBytes else {
                throw Refusal.invalid("\(path) is \(size) bytes; each file in a vault may be at most \(Limits.vaultCoreFileBytes)")
            }
            total += size
        }
        guard total <= Limits.vaultCoreBytes else {
            throw Refusal.invalid("the vault's files come to \(total) bytes; the limit is \(Limits.vaultCoreBytes)")
        }
    }

    /// 1–160 UTF-8 bytes; no path separator, no colon, no control character, not hidden.
    public static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 160, !name.hasPrefix("."), name != "..",
              name.trimmingCharacters(in: .whitespaces) == name else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !["/", "\\", ":"].contains(Character(scalar))
        }
    }

    static func isHexDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isPrintable(_ text: String, maximum: Int, spaces: Bool = false) -> Bool {
        !text.isEmpty && text.count <= maximum
            && text.unicodeScalars.allSatisfy { $0.value >= (spaces ? 0x20 : 0x21) && $0.value != 0x7F }
    }

    /// HTTPS, a host, no credentials and no fragment.
    public static func isDownloadURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }

    // MARK: Signing and opening

    /// Check, encode and sign a catalog with the pack-catalog key. Returns the envelope's JSON.
    public static func sign(_ catalog: Catalog, signer: ByteSigner,
                            companyTotalBytes: Int64 = Limits.companyTotalBytes) throws -> Data {
        try check(catalog, companyTotalBytes: companyTotalBytes)
        let payload = try encoder().encode(catalog)
        let signature = try signer(Data(catalogDomain.utf8) + payload)
        guard signature.count == 64 else { throw IssuanceWire.WireError.signatureLength }
        let envelope = Envelope(payload: payload.base64EncodedString(), signature: signature.base64EncodedString())
        return try encoder().encode(envelope)
    }

    /// Verify an envelope for `profileId`. `highWater` is the newest generation already applied
    /// (nil for none); `profileGeneration` the one the profile points at. A catalog older than
    /// either is refused. Mirrors `CompanyVaultCatalog.verify` in the app.
    public static func open(_ envelope: Data, publicKeyBase64: String, profileId: String,
                            highWater: Int? = nil, profileGeneration: Int = 0) throws -> Catalog {
        guard envelope.count <= Limits.catalogEnvelopeBytes,
              let wrapper = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let payload = Data(base64Encoded: wrapper.payload) else { throw Refusal.notAnEnvelope }
        guard let signature = Data(base64Encoded: wrapper.signature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: Data(catalogDomain.utf8) + payload) else { throw Refusal.badSignature }
        struct Head: Decodable { let format: String; let version: Int }
        guard let head = try? decoder().decode(Head.self, from: payload), head.format == catalogFormat else {
            throw Refusal.unreadable
        }
        guard head.version <= catalogVersion else { throw Refusal.unsupportedVersion(head.version) }
        guard let catalog = try? decoder().decode(Catalog.self, from: payload) else { throw Refusal.unreadable }
        guard catalog.profileId == profileId else { throw Refusal.otherCompany }
        if let highWater, catalog.generation < highWater {
            throw Refusal.replayed(generation: catalog.generation, highWater: highWater)
        }
        guard catalog.generation >= profileGeneration else {
            throw Refusal.behindProfile(generation: catalog.generation, profileGeneration: profileGeneration)
        }
        return catalog
    }

    // MARK: - The manual seal

    /// A manual's file, sealed for one company's phones.
    ///
    /// ```
    /// key      = HKDF-SHA256(ikm: company secret, salt: none, info: "openglasses.company-manual.v1"), 32 bytes
    /// sealed   = header ‖ chunk₀ ‖ chunk₁ ‖ … ‖ chunkₙ₋₁
    /// header   = "OGCM" ‖ 0x01 ‖ chunkSize (UInt32, big-endian; 1 MiB in version 1)
    /// chunkᵢ   = nonce (12 random bytes) ‖ ciphertext ‖ tag (16 bytes)
    /// AADᵢ     = UTF-8("openglasses.company-manual.v1\n" + profileId + "\n" + vaultId + "\n" + fileName + "\n" + revision + "\n")
    ///            ‖ header ‖ i (UInt64, big-endian) ‖ (0x01 for the last chunk, else 0x00)
    /// ```
    ///
    /// Every chunk but the last holds exactly `chunkSize` plaintext bytes; the last holds 1 to
    /// `chunkSize`. A file of n plaintext bytes seals to `sealedLength(plaintextBytes: n)` bytes. The
    /// index stops reordering, the last-chunk flag stops truncation, and the authenticated context
    /// stops a sealed file being moved to another company, vault, file name or revision.
    public enum ManualSeal {
        /// **Key-derivation and authentication domain.** Never change it: every manual already
        /// sealed would stop opening.
        public static let domain = "openglasses.company-manual.v1"
        public static let magic = Data("OGCM".utf8)
        public static let formatVersion: UInt8 = 1
        public static let chunkSize = 1_048_576
        public static let headerLength = 9
        public static let chunkOverhead = 12 + 16

        public struct Context: Equatable, Sendable {
            public let profileId: String
            public let vaultId: String
            public let fileName: String
            /// The plaintext's SHA-256, lowercase hex: the catalog row's `revision`.
            public let revision: String
            public init(profileId: String, vaultId: String, fileName: String, revision: String) {
                self.profileId = profileId; self.vaultId = vaultId; self.fileName = fileName; self.revision = revision
            }
            public init(profileId: String, manual: Manual) {
                self.init(profileId: profileId, vaultId: manual.vaultId, fileName: manual.fileName, revision: manual.revision)
            }
        }

        public enum Problem: Error, Equatable {
            case invalidSecret, empty, malformed, unreadable, wrongRevision, io
        }

        public static func header(chunkSize: Int = ManualSeal.chunkSize) -> Data {
            var bytes = magic
            bytes.append(formatVersion)
            let size = UInt32(chunkSize)
            bytes.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
            return bytes
        }

        static func key(_ secret: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data(domain.utf8), outputByteCount: 32)
        }

        static func authenticated(_ context: Context, header: Data, index: UInt64, isLast: Bool) -> Data {
            var bytes = Data((domain + "\n" + context.profileId + "\n" + context.vaultId + "\n" + context.fileName
                              + "\n" + context.revision + "\n").utf8)
            bytes.append(header)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((index >> UInt64(shift)) & 0xFF)) }
            bytes.append(isLast ? 1 : 0)
            return bytes
        }

        /// The sealed file's exact length for `plaintextBytes` (at least 1).
        public static func sealedLength(plaintextBytes: Int) -> Int {
            let chunks = (plaintextBytes + chunkSize - 1) / chunkSize
            return headerLength + plaintextBytes + chunks * chunkOverhead
        }

        /// Lowercase hex SHA-256: a manual's `revision`, or a sealed file's `sealedSha256`.
        public static func digest(_ data: Data) -> String { IssuanceWire.digest(data) }

        /// Seal bytes already in memory. `nonce` exists for the golden fixtures only; leave it out.
        public static func seal(_ plaintext: Data, context: Context, companySecret: Data,
                                nonce: ((UInt64) throws -> AES.GCM.Nonce)? = nil) throws -> Data {
            guard companySecret.count == ProfileContract.Credential.secretLength else { throw Problem.invalidSecret }
            guard !plaintext.isEmpty else { throw Problem.empty }
            guard digest(plaintext) == context.revision else { throw Problem.wrongRevision }
            let head = header()
            var output = head
            let key = key(companySecret)
            var index: UInt64 = 0
            var offset = plaintext.startIndex
            while offset < plaintext.endIndex {
                let end = plaintext.index(offset, offsetBy: chunkSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
                let isLast = end == plaintext.endIndex
                let box = try AES.GCM.seal(plaintext[offset..<end], using: key, nonce: try nonce?(index) ?? AES.GCM.Nonce(),
                                           authenticating: authenticated(context, header: head, index: index, isLast: isLast))
                guard let combined = box.combined else { throw Problem.malformed }
                output.append(combined)
                offset = end
                index += 1
            }
            return output
        }

        /// Open bytes already in memory, checking the plaintext against `context.revision`.
        public static func open(_ sealed: Data, context: Context, companySecret: Data) throws -> Data {
            var plain = Data()
            try open(length: sealed.count, read: { range in sealed.subdata(in: range) }, context: context,
                     companySecret: companySecret) { plain.append($0) }
            guard digest(plain) == context.revision else { throw Problem.wrongRevision }
            return plain
        }

        /// The streaming form both sides build on: `read` returns the bytes in a range of the sealed
        /// file and `sink` receives each opened chunk in order. Nothing from a chunk reaches `sink`
        /// until its tag has verified. The caller checks the revision over what `sink` received.
        public static func open(length: Int, read: (Range<Int>) throws -> Data, context: Context, companySecret: Data,
                                sink: (Data) throws -> Void) throws {
            guard companySecret.count == ProfileContract.Credential.secretLength else { throw Problem.invalidSecret }
            guard length > headerLength + chunkOverhead else { throw Problem.malformed }
            let head = try read(0..<headerLength)
            guard head == header() else { throw Problem.malformed }
            let body = length - headerLength
            let full = chunkSize + chunkOverhead
            let chunks = (body + full - 1) / full
            let lastLength = body - (chunks - 1) * full
            guard lastLength > chunkOverhead else { throw Problem.malformed }
            let key = key(companySecret)
            for index in 0..<chunks {
                let start = headerLength + index * full
                let end = index == chunks - 1 ? length : start + full
                let isLast = index == chunks - 1
                guard let box = try? AES.GCM.SealedBox(combined: try read(start..<end)),
                      let plain = try? AES.GCM.open(box, using: key,
                                                    authenticating: authenticated(context, header: head, index: UInt64(index), isLast: isLast)) else {
                    throw Problem.unreadable
                }
                try sink(plain)
            }
        }

        /// Seal a file on disk to another file, one chunk in memory at a time, and return the
        /// catalog row's `revision`, `sizeBytes` and `sealedSha256`. For the service's uploads.
        public static func sealFile(at input: URL, to output: URL, profileId: String, vaultId: String,
                                    fileName: String, companySecret: Data) throws -> (revision: String, sizeBytes: Int, sealedSha256: String) {
            guard companySecret.count == ProfileContract.Credential.secretLength else { throw Problem.invalidSecret }
            guard let reader = try? FileHandle(forReadingFrom: input) else { throw Problem.io }
            defer { try? reader.close() }
            var plainHash = SHA256()
            var size = 0
            while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
                plainHash.update(data: chunk)
                size += chunk.count
            }
            guard size > 0 else { throw Problem.empty }
            let revision = plainHash.finalize().map { String(format: "%02x", $0) }.joined()
            let context = Context(profileId: profileId, vaultId: vaultId, fileName: fileName, revision: revision)
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                  let writer = try? FileHandle(forWritingTo: output) else { throw Problem.io }
            defer { try? writer.close() }
            try reader.seek(toOffset: 0)
            let head = header()
            var sealedHash = SHA256()
            try writer.write(contentsOf: head)
            sealedHash.update(data: head)
            let key = key(companySecret)
            var index: UInt64 = 0
            var remaining = size
            while remaining > 0, let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
                remaining -= chunk.count
                let box = try AES.GCM.seal(chunk, using: key,
                                           authenticating: authenticated(context, header: head, index: index, isLast: remaining == 0))
                guard let combined = box.combined else { throw Problem.malformed }
                try writer.write(contentsOf: combined)
                sealedHash.update(data: combined)
                index += 1
            }
            guard remaining == 0 else { throw Problem.io }
            return (revision, size, sealedHash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}

// MARK: - The seat renewal's installed vaults (Plan LR P2)

/// One company vault installed on a phone, as its daily seat renewal reports it, so the portal can
/// show "7 of 9 phones on version 4". Only the company's own vault ids and versions: never a
/// manual's name, never anything the technician added.
public struct SeatInstalledVault: Codable, Equatable, Sendable {
    public let vaultId: String
    public let version: String
    public init(vaultId: String, version: String) { self.vaultId = vaultId; self.version = version }

    /// At most this many travel on one renewal; the rest are left out rather than the request
    /// outgrowing `SeatWire.maximumRequestBytes`.
    public static let maximumPerRenewal = 16

    /// Whether the service should keep this entry: a safe vault id and a short printable version.
    public var isWellFormed: Bool {
        ProfileContract.isSafeIdentifier(vaultId) && CompanyVaultContract.isPrintable(version, maximum: 80)
    }
}

extension SeatPolicy {
    /// The fleet view: for each company vault, how many held seats report each version.
    public static func fleetVersions(_ seats: [SeatRecord], profileId: String, now: Date) -> [String: [String: Int]] {
        var counts: [String: [String: Int]] = [:]
        for seat in seats where seat.profileId == profileId && isHeld(seat, now: now) {
            for vault in seat.vaults ?? [] where vault.isWellFormed {
                counts[vault.vaultId, default: [:]][vault.version, default: 0] += 1
            }
        }
        return counts
    }
}
