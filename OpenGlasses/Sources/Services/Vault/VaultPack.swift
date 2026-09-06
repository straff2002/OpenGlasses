import CryptoKit
import Foundation

/// Plan EG — an authored vault as sellable, signed, downloadable content.
///
/// A pack is a vault folder (manifest.json, core markdown, procedures) plus this `pack.json`,
/// zipped and signed. It **never contains OEM manuals**; a customer loads their own into the
/// pack's documents tier on their own phone. The pack id doubles as its App Store product id, so
/// a pack can have a price; the licence `packs` claim names its `licensePack` key, so an
/// organisation's code can include it for everyone.
struct VaultPackManifest: Codable, Equatable {
    /// Reverse-DNS pack id; also the StoreKit product id (`com.openglasses.vault.<vaultId>`).
    let id: String
    /// The vault this pack installs (must equal the inner manifest's `id`).
    let vaultId: String
    let version: String
    let name: String
    let summary: String?
    /// Rendered in Settings and in the session audit log's vault line.
    let author: String?
    let minAppBuild: Int?
    /// The key a licence code's `packs` claim uses to include this pack. Defaults to `vaultId`.
    let licensePack: String?
    /// Where a pack redistributes extracted manual text, the written permission it rests on.
    let redistributionNote: String?

    static let filename = "pack.json"
    static let productPrefix = "com.openglasses.vault."

    init(id: String, vaultId: String, version: String, name: String, summary: String? = nil,
         author: String? = nil, minAppBuild: Int? = nil, licensePack: String? = nil,
         redistributionNote: String? = nil) {
        self.id = id
        self.vaultId = vaultId
        self.version = version
        self.name = name
        self.summary = summary
        self.author = author
        self.minAppBuild = minAppBuild
        self.licensePack = licensePack
        self.redistributionNote = redistributionNote
    }

    var effectiveLicensePack: String { licensePack ?? vaultId }
    var productId: String { id }

    static func isPackProductId(_ id: String) -> Bool { id.hasPrefix(productPrefix) }
}

/// Pack zip → `pack.json` bytes plus every other file by relative path (manifest.json included).
/// Pure over bytes; the reader is the Reading Companion's `ZipArchiveReader`.
enum VaultPackArchive {
    enum ArchiveError: Error, Equatable {
        case notAZip
        case missingPackManifest
        case missingVaultManifest
    }

    static let maxEntryBytes = 20 * 1024 * 1024

    static func extract(zipData: Data) -> Result<(packManifestData: Data, files: [String: Data]), ArchiveError> {
        guard let archive = ZipArchiveReader(data: zipData) else { return .failure(.notAZip) }
        guard let packData = archive.entryData(named: VaultPackManifest.filename,
                                               maximumUncompressedSize: maxEntryBytes) else {
            return .failure(.missingPackManifest)
        }
        var files: [String: Data] = [:]
        for name in archive.entryNames {
            let normalized = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            guard normalized != VaultPackManifest.filename, !normalized.hasSuffix("/"),
                  !normalized.hasPrefix("__MACOSX"), !normalized.contains("..") else { continue }
            guard let data = archive.entryData(named: name,
                                               maximumUncompressedSize: maxEntryBytes) else { continue }
            files[normalized] = data
        }
        guard files["manifest.json"] != nil else { return .failure(.missingVaultManifest) }
        return .success((packData, files))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Signature over `pack.json` plus a sorted digest of every other file — the skill-pack message,
/// verified with the same vendor key. One private key, already off-repo, signs both catalogs.
enum VaultPackSignature {
    static func verify(signatureBase64: String, packManifestData: Data, files: [String: Data],
                       publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64) -> Bool {
        SkillPackSignature.verify(signatureBase64: signatureBase64, manifestData: packManifestData,
                                  payloadFiles: files, publicKeyBase64: publicKeyBase64)
    }

    static func sign(packManifestData: Data, files: [String: Data], privateKeyBase64: String) throws -> String {
        try SkillPackSignature.sign(manifestData: packManifestData, payloadFiles: files, privateKeyBase64: privateKeyBase64)
    }
}

/// One row of the signed vault-pack catalog.
struct VaultPackCatalogEntry: Codable, Equatable, Identifiable {
    let id: String
    let vaultId: String
    let version: String
    let name: String
    let summary: String
    let author: String?
    let minAppBuild: Int?
    let sizeBytes: Int?
    let downloadURL: String
    let sha256: String
    let packSignature: String

    init(id: String, vaultId: String, version: String, name: String, summary: String = "",
         author: String? = nil, minAppBuild: Int? = nil, sizeBytes: Int? = nil,
         downloadURL: String, sha256: String, packSignature: String) {
        self.id = id
        self.vaultId = vaultId
        self.version = version
        self.name = name
        self.summary = summary
        self.author = author
        self.minAppBuild = minAppBuild
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.packSignature = packSignature
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        version = try c.decode(String.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author)
        minAppBuild = try c.decodeIfPresent(Int.self, forKey: .minAppBuild)
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
        downloadURL = try c.decode(String.self, forKey: .downloadURL)
        sha256 = try c.decode(String.self, forKey: .sha256)
        packSignature = try c.decode(String.self, forKey: .packSignature)
    }
}

/// The signed index: same envelope as the skill-pack catalog (signature over the exact base64-
/// wrapped payload bytes), a second index file, one key.
enum VaultPackCatalog {
    struct Index: Codable, Equatable {
        let version: Int
        let packs: [VaultPackCatalogEntry]
    }

    private struct Envelope: Codable {
        let payload: String
        let signature: String
    }

    enum CatalogError: Error, Equatable {
        case notAnEnvelope
        case badSignature
        case unreadableIndex
        case unsupportedVersion(Int)
    }

    static let supportedIndexVersion = 1

    static func parse(envelopeData: Data,
                      publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64) -> Result<[VaultPackCatalogEntry], CatalogError> {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              let payloadData = Data(base64Encoded: envelope.payload) else {
            return .failure(.notAnEnvelope)
        }
        guard let signature = Data(base64Encoded: envelope.signature),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              publicKey.isValidSignature(signature, for: payloadData) else {
            return .failure(.badSignature)
        }
        guard let index = try? JSONDecoder().decode(Index.self, from: payloadData) else {
            return .failure(.unreadableIndex)
        }
        guard index.version <= supportedIndexVersion else {
            return .failure(.unsupportedVersion(index.version))
        }
        return .success(index.packs)
    }

    static func makeEnvelope(index: Index, privateKeyBase64: String) throws -> Data {
        let payloadData = try JSONEncoder().encode(index)
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw SkillPackSignature.SigningError.badKey
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let signature = try key.signature(for: payloadData)
        let envelope = Envelope(payload: payloadData.base64EncodedString(),
                                signature: signature.base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }
}

/// Who may open a pack. Pure: the registry feeds it what the evidence says.
enum VaultPackAccess {
    /// A pack is unlocked by a verified store purchase of its product, by a licence code whose
    /// `packs` claim names its licence key, or by an enterprise licence (which includes every pack).
    static func isUnlocked(productId: String, licensePack: String,
                           purchasedProducts: Set<String>, licensedPacks: Set<String>,
                           tier: FieldAssistTier?) -> Bool {
        if tier == .enterprise { return true }
        if purchasedProducts.contains(productId) { return true }
        return licensedPacks.contains(licensePack)
    }
}

/// What the Packs list shows for one catalog entry. Pure over the facts the service gathers.
enum VaultPackRowState: Equatable {
    /// The running build is older than the pack requires.
    case needsNewerApp(minBuild: Int)
    /// No Field Assist entitlement at all; a pack is nothing without the feature.
    case needsFieldAssist
    /// Solo device that has not bought this pack.
    case buy(productId: String)
    /// Entitled (bought, licensed, or enterprise) and not yet installed.
    case install
    /// Installed at an older version than the catalog lists.
    case update(installed: String)
    /// Installed at the catalog's version.
    case installed

    static func resolve(entry: VaultPackCatalogEntry, installedVersion: String?, unlocked: Bool,
                        fieldAssistGranted: Bool, currentBuild: Int) -> VaultPackRowState {
        if let min = entry.minAppBuild, min > currentBuild { return .needsNewerApp(minBuild: min) }
        guard fieldAssistGranted else { return .needsFieldAssist }
        guard unlocked else { return .buy(productId: entry.id) }
        guard let installedVersion else { return .install }
        return isNewer(entry.version, than: installedVersion) ? .update(installed: installedVersion) : .installed
    }

    /// Dotted-numeric comparison; a non-numeric component compares as zero.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
