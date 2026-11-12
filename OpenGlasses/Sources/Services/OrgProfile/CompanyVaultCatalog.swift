import CryptoKit
import Foundation

/// Plan LR — the company vault catalog, as the phone reads it.
///
/// The licence service publishes, for one company, the vaults it has (EG vault packs in every byte:
/// core files only) and the manuals in them (one row per file, each sealed for that company). The
/// profile names the catalog (`ConfigProfile.companyVaults`) and its `generation`; the catalog is
/// signed by the vendor's pack-catalog key under its own domain and authenticates the company's
/// `profileId` and the `generation`, so one company's catalog cannot be served to another and an
/// older catalog cannot be replayed.
///
/// The format is the licence core's (`Tools/LicenceIssuance`, `CompanyVaultContract`), restated
/// here because no production verifier depends on that package; `CompanyVaultContractTests` holds
/// the two to the same bytes and reads the same golden fixtures.
enum CompanyVaultCatalog {
    /// **Signed identifier, not a product name.** Never change it.
    static let formatId = "openglasses.company-vault-catalog"
    static let supportedVersion = 1
    /// **Signing domain.** The pack-catalog key signs these bytes and then the exact payload.
    static let signingDomain = Data("openglasses.company-vault-catalog.v1\n".utf8)
    /// An envelope larger than this is not read.
    static let maximumEnvelopeBytes = 1_048_576

    /// What a manual file is; the file name's extension must say the same.
    enum ManualKind: String, Codable, CaseIterable, Sendable {
        case pdf, docx, md

        var extensions: Set<String> {
            switch self {
            case .pdf: return ["pdf"]
            case .docx: return ["docx"]
            case .md: return ["md", "markdown"]
            }
        }

        /// The phone's own cap for one manual of this kind (Plan LR decision 2).
        var maximumBytes: Int {
            switch self {
            case .pdf: return CompanyVaultLimits.pdfBytes
            case .docx: return CompanyVaultLimits.wordBytes
            case .md: return CompanyVaultLimits.textBytes
            }
        }
    }

    /// One manual file in one company vault.
    struct Manual: Codable, Equatable, Sendable {
        let vaultId: String
        /// The file's name in the vault and its identity there.
        let fileName: String
        /// SHA-256 (lowercase hex) of the plaintext.
        let revision: String
        /// The plaintext's length.
        let sizeBytes: Int
        /// SHA-256 (lowercase hex) of the sealed file as served.
        let sealedSha256: String
        let downloadURL: String
        let kind: ManualKind

        /// What a citation calls it: the file name without its extension.
        var title: String {
            let base = (fileName as NSString).deletingPathExtension
            return base.isEmpty ? fileName : base
        }
    }

    /// One vault row: the public pack catalog's row, with its size required.
    struct Vault: Codable, Equatable, Sendable {
        let id: String
        let vaultId: String
        let version: String
        let name: String
        let summary: String?
        let author: String?
        let minAppBuild: Int?
        let sizeBytes: Int
        let downloadURL: String
        let sha256: String
        let packSignature: String

        /// The row as `VaultPackCatalogService` installs it.
        var entry: VaultPackCatalogEntry {
            VaultPackCatalogEntry(id: id, vaultId: vaultId, version: version, name: name, summary: summary ?? "",
                                  author: author, minAppBuild: minAppBuild, sizeBytes: sizeBytes,
                                  downloadURL: downloadURL, sha256: sha256, packSignature: packSignature)
        }
    }

    struct Payload: Codable, Equatable, Sendable {
        let format: String
        let version: Int
        let profileId: String
        let generation: Int
        let issued: Date
        let manualsOnAnyNetwork: Bool
        let vaults: [Vault]
        let manuals: [Manual]
    }

    /// A catalog that verified for this company at this generation, with the rows the phone will
    /// not use left out and named.
    struct Verified: Equatable, Sendable {
        let profileId: String
        let generation: Int
        let issued: Date
        let manualsOnAnyNetwork: Bool
        let vaults: [Vault]
        let manuals: [Manual]
        /// Rows left out, by vault id: the reason, in words for the managed row.
        let problems: [String: String]

        func vault(_ vaultId: String) -> Vault? { vaults.first { $0.vaultId == vaultId } }
        func manuals(in vaultId: String) -> [Manual] { manuals.filter { $0.vaultId == vaultId } }
    }

    enum Refusal: Error, Equatable {
        case notAnEnvelope
        case badSignature
        case unreadable
        case unsupportedVersion(Int)
        case otherCompany
        case replayed(generation: Int, highWater: Int)
        case behindProfile(generation: Int, profileGeneration: Int)

        /// For the managed row.
        var explanation: String {
            switch self {
            case .notAnEnvelope, .unreadable: return String(localized: "The vault list could not be read.")
            case .badSignature: return String(localized: "The vault list isn't signed by Avenkin, so nothing in it was used.")
            case .unsupportedVersion: return String(localized: "The vault list needs a newer version of the app.")
            case .otherCompany: return String(localized: "The vault list is for another company, so nothing in it was used.")
            case .replayed: return String(localized: "An older vault list was served, so nothing in it was used.")
            case .behindProfile: return String(localized: "The vault list isn't up to date yet. It tries again later.")
            }
        }
    }

    private struct Envelope: Codable {
        let payload: String
        let signature: String
    }

    /// Verify an envelope for `profileId`. `highWater` is the newest generation this phone has
    /// verified before; `profileGeneration` is the one the profile points at. A catalog older than
    /// either is refused. The same generation again is not a replay: a retry re-reads it.
    static func verify(_ envelope: Data, publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64,
                       profileId: String, highWater: Int?, profileGeneration: Int) -> Result<Verified, Refusal> {
        guard envelope.count <= maximumEnvelopeBytes,
              let wrapper = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let payload = Data(base64Encoded: wrapper.payload) else { return .failure(.notAnEnvelope) }
        guard let signature = Data(base64Encoded: wrapper.signature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: signingDomain + payload) else { return .failure(.badSignature) }
        struct Head: Decodable { let format: String; let version: Int }
        guard let head = try? decoder.decode(Head.self, from: payload), head.format == formatId else {
            return .failure(.unreadable)
        }
        guard head.version <= supportedVersion else { return .failure(.unsupportedVersion(head.version)) }
        guard let catalog = try? decoder.decode(Payload.self, from: payload) else { return .failure(.unreadable) }
        guard catalog.profileId == profileId else { return .failure(.otherCompany) }
        if let highWater, catalog.generation < highWater {
            return .failure(.replayed(generation: catalog.generation, highWater: highWater))
        }
        guard catalog.generation >= profileGeneration else {
            return .failure(.behindProfile(generation: catalog.generation, profileGeneration: profileGeneration))
        }
        return .success(screen(catalog))
    }

    /// The phone's own checks on every row, because a signed catalog is not a reason to trust a
    /// size: a row that fails is left out and named on its vault's row, and the rest is used.
    static func screen(_ catalog: Payload) -> Verified {
        var problems: [String: String] = [:]
        var vaults: [Vault] = []
        var seen = Set<String>(), seenPacks = Set<String>()
        for vault in catalog.vaults.prefix(CompanyVaultLimits.vaultsPerCatalog) {
            if let problem = problem(with: vault) {
                problems[vault.vaultId] = problems[vault.vaultId] ?? problem
                continue
            }
            guard seen.insert(vault.vaultId).inserted, seenPacks.insert(vault.id).inserted else { continue }
            vaults.append(vault)
        }
        var manuals: [Manual] = []
        var files = Set<String>()
        for manual in catalog.manuals.prefix(CompanyVaultLimits.manualsPerCatalog) where seen.contains(manual.vaultId) {
            if let problem = problem(with: manual) {
                problems[manual.vaultId] = problems[manual.vaultId] ?? problem
                continue
            }
            guard files.insert(manual.vaultId + "\u{0}" + manual.fileName.lowercased()).inserted else { continue }
            manuals.append(manual)
        }
        return Verified(profileId: catalog.profileId, generation: catalog.generation, issued: catalog.issued,
                        manualsOnAnyNetwork: catalog.manualsOnAnyNetwork, vaults: vaults, manuals: manuals,
                        problems: problems)
    }

    static func problem(with vault: Vault) -> String? {
        guard VaultPackManifest.isPackProductId(vault.id), vault.id.count > VaultPackManifest.productPrefix.count,
              safeIdentifier(vault.id), safeIdentifier(vault.vaultId), !vault.version.isEmpty, !vault.name.isEmpty,
              isDigest(vault.sha256), !vault.packSignature.isEmpty, downloadURL(vault.downloadURL) != nil else {
            return String(localized: "\(vault.name) can't be installed: its entry in the vault list is incomplete.")
        }
        guard (1...CompanyVaultLimits.vaultCoreBytes).contains(vault.sizeBytes) else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(CompanyVaultLimits.vaultCoreBytes), countStyle: .file)
            return String(localized: "\(vault.name) is larger than the \(limit) a vault may be.")
        }
        return nil
    }

    static func problem(with manual: Manual) -> String? {
        let ext = (manual.fileName as NSString).pathExtension.lowercased()
        guard safeFileName(manual.fileName), manual.kind.extensions.contains(ext), isDigest(manual.revision),
              isDigest(manual.sealedSha256), downloadURL(manual.downloadURL) != nil else {
            return String(localized: "A manual can't be downloaded: its entry in the vault list is incomplete.")
        }
        guard (1...manual.kind.maximumBytes).contains(manual.sizeBytes) else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(manual.kind.maximumBytes), countStyle: .file)
            return String(localized: "\(manual.title) is larger than the \(limit) this kind of manual may be.")
        }
        return nil
    }

    /// HTTPS, a host, no credentials and no fragment.
    static func downloadURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    /// 1–80 of `A-Z a-z 0-9 - _ .`, never `.` or `..` (`ProfileContract.isSafeIdentifier`).
    static func safeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    /// 1–160 UTF-8 bytes; no path separator, colon or control character, not hidden, no edge spaces.
    static func safeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 160, !name.hasPrefix("."), name != "..",
              name.trimmingCharacters(in: .whitespaces) == name else { return false }
        return name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !["/", "\\", ":"].contains(Character($0)) }
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Plan LR decision 2: the limits, the phone's own caps restated. `CompanyVaultContractTests`
/// holds them to the licence core's `CompanyVaultContract.Limits`.
enum CompanyVaultLimits {
    static let pdfBytes = CapturedManualContract.maximumPDFBytes
    static let wordBytes = ManualFileUpload.maximumWordBytes
    static let textBytes = ManualFileUpload.maximumTextBytes
    static let vaultCoreBytes = Config.vaultLinkMaxBytes
    static let vaultCoreFileBytes = VaultPackArchive.maxEntryBytes
    static let vaultsPerCatalog = 64
    static let manualsPerCatalog = 2_000
}

/// Plan LR — a company manual's sealed file, opened on the phone.
///
/// AES-GCM under HKDF-SHA256(company secret, info `openglasses.company-manual.v1`), in 1 MiB
/// chunks, each authenticating the company, the vault, the file name, the revision, the header,
/// its index and whether it is the last. The company secret reaches the phone only inside the
/// activation file, so a manual is useless to anyone without it. Mirrors
/// `CompanyVaultContract.ManualSeal`; pinned by `CompanyVaultContractTests`.
enum CompanyManualSeal {
    /// **Key-derivation and authentication domain, not a product name.** Never change it: every
    /// manual already sealed would stop opening.
    static let sealingDomain = "openglasses.company-manual.v1"
    static let chunkSize = 1_048_576
    static let headerLength = 9
    static let chunkOverhead = 12 + 16

    struct Context: Equatable, Sendable {
        let profileId: String
        let vaultId: String
        let fileName: String
        let revision: String

        init(profileId: String, vaultId: String, fileName: String, revision: String) {
            self.profileId = profileId
            self.vaultId = vaultId
            self.fileName = fileName
            self.revision = revision
        }

        init(profileId: String, manual: CompanyVaultCatalog.Manual) {
            self.init(profileId: profileId, vaultId: manual.vaultId, fileName: manual.fileName, revision: manual.revision)
        }
    }

    enum Failure: Error, Equatable {
        /// The phone has no company secret, or another company's.
        case noSecret
        /// Not a sealed manual of this format, or cut short.
        case malformed
        /// A chunk did not open: tampered, moved, or sealed for someone else.
        case tampered
        /// It opened, but is not the revision the catalog names.
        case wrongRevision
        case io
    }

    static var header: Data {
        var bytes = Data("OGCM".utf8)
        bytes.append(1)
        let size = UInt32(chunkSize)
        bytes.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        return bytes
    }

    /// The sealed file's exact length for `plaintextBytes` (at least 1).
    static func sealedLength(plaintextBytes: Int) -> Int {
        let chunks = (plaintextBytes + chunkSize - 1) / chunkSize
        return headerLength + plaintextBytes + chunks * chunkOverhead
    }

    private static func key(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data(sealingDomain.utf8), outputByteCount: 32)
    }

    private static func authenticated(_ context: Context, index: UInt64, isLast: Bool) -> Data {
        var bytes = Data((sealingDomain + "\n" + context.profileId + "\n" + context.vaultId + "\n" + context.fileName
                          + "\n" + context.revision + "\n").utf8)
        bytes.append(header)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((index >> UInt64(shift)) & 0xFF)) }
        bytes.append(isLast ? 1 : 0)
        return bytes
    }

    /// Open a sealed file chunk by chunk: `read` returns the bytes of a range of it and `sink`
    /// receives each opened chunk in order, only after its tag verified. Returns the plaintext's
    /// SHA-256, which the caller has already been told to expect (`context.revision`): a mismatch
    /// throws `wrongRevision`.
    @discardableResult
    static func open(length: Int, read: (Range<Int>) throws -> Data, context: Context, companySecret: Data,
                     sink: (Data) throws -> Void) throws -> Int {
        guard companySecret.count == OrgCredentialSeal.secretLength else { throw Failure.noSecret }
        guard length > headerLength + chunkOverhead, (try? read(0..<headerLength)) == header else { throw Failure.malformed }
        let body = length - headerLength
        let full = chunkSize + chunkOverhead
        let chunks = (body + full - 1) / full
        guard body - (chunks - 1) * full > chunkOverhead else { throw Failure.malformed }
        let key = key(companySecret)
        var hash = SHA256()
        var total = 0
        for index in 0..<chunks {
            let start = headerLength + index * full
            let end = index == chunks - 1 ? length : start + full
            let bytes: Data
            do { bytes = try read(start..<end) } catch { throw Failure.io }
            guard let box = try? AES.GCM.SealedBox(combined: bytes),
                  let plain = try? AES.GCM.open(box, using: key,
                                                authenticating: authenticated(context, index: UInt64(index), isLast: index == chunks - 1)) else {
                throw Failure.tampered
            }
            hash.update(data: plain)
            total += plain.count
            try sink(plain)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == context.revision else { throw Failure.wrongRevision }
        return total
    }

    /// Open bytes already in memory. Tests and fixtures.
    static func open(_ sealed: Data, context: Context, companySecret: Data) throws -> Data {
        var plain = Data()
        try open(length: sealed.count, read: { sealed.subdata(in: $0) }, context: context, companySecret: companySecret) {
            plain.append($0)
        }
        return plain
    }

    /// As the licence service seals one. Tests and fixtures only on the phone.
    static func seal(_ plaintext: Data, context: Context, companySecret: Data) throws -> Data {
        var output = header
        let key = key(companySecret)
        var index: UInt64 = 0
        var offset = plaintext.startIndex
        while offset < plaintext.endIndex {
            let end = plaintext.index(offset, offsetBy: chunkSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            guard let combined = try AES.GCM.seal(plaintext[offset..<end], using: key,
                                                  authenticating: authenticated(context, index: index, isLast: end == plaintext.endIndex)).combined else {
                throw Failure.malformed
            }
            output.append(combined)
            offset = end
            index += 1
        }
        return output
    }

    /// SHA-256 (lowercase hex) of a file, read a chunk at a time.
    static func fileDigest(_ url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.io }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
