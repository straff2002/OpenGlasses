import Foundation
import CryptoKit

/// Plan BX P2 — the remote catalog: a signed static JSON index of installable packs.
///
/// Hosting (resolving the plan's open decision): repo-served static JSON on the existing GitHub
/// Pages deployment — the repo already ships `pages.yml`, so the catalog is a committed file and
/// publishing is a git push. The URL lives in `Config.skillPackCatalogURL` so an enterprise can
/// point at its own index.
///
/// # Envelope
///
/// ```json
/// { "payload": "<base64 of the index JSON>", "signature": "<base64 ed25519 over payload bytes>" }
/// ```
///
/// The signature covers the *exact payload bytes*, base64-wrapped so there is no JSON
/// canonicalization problem — re-serialization can't invalidate it. The same vendor key that signs
/// packs signs the index. An unsigned or badly signed catalog is refused outright (developer mode
/// loosens *pack* signing, never catalog signing — a poisoned index is a fleet-level attack, and a
/// developer testing a pack has the sideload path instead).
struct SkillPackCatalogEntry: Codable, Equatable, Identifiable {
    let id: String              // pack id (reverse-DNS)
    let version: String
    let name: String
    let summary: String
    let sizeBytes: Int?
    let hardware: [SkillPackManifest.HardwareRequirement]
    /// Where the pack zip lives.
    let downloadURL: String
    /// SHA256 (hex) of the zip — verified before extraction.
    let sha256: String
    /// The pack's own ed25519 signature (over manifest + payload hashes, per P1), carried in the
    /// index so install needs exactly one download.
    let packSignature: String

    init(id: String, version: String, name: String, summary: String, sizeBytes: Int? = nil,
         hardware: [SkillPackManifest.HardwareRequirement] = [], downloadURL: String,
         sha256: String, packSignature: String) {
        self.id = id
        self.version = version
        self.name = name
        self.summary = summary
        self.sizeBytes = sizeBytes
        self.hardware = hardware
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.packSignature = packSignature
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
        hardware = try c.decodeIfPresent([SkillPackManifest.HardwareRequirement].self, forKey: .hardware) ?? []
        downloadURL = try c.decode(String.self, forKey: .downloadURL)
        sha256 = try c.decode(String.self, forKey: .sha256)
        packSignature = try c.decode(String.self, forKey: .packSignature)
    }
}

enum SkillPackCatalog {

    struct Index: Codable, Equatable {
        let version: Int
        let packs: [SkillPackCatalogEntry]
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

    /// Highest index version this build understands. A newer index is a refusal with a clear
    /// error, not a partial parse — the index is small, and "update the app" beats mystery gaps.
    static let supportedIndexVersion = 1

    static func parse(
        envelopeData: Data,
        publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64
    ) -> Result<[SkillPackCatalogEntry], CatalogError> {
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

    /// Build a signed envelope. Vendor/test side — shares the exact byte contract with `parse`.
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

/// Plan BX P2 — availability of a pack against the hardware actually present.
enum SkillPackHardwareGate {

    enum Availability: Equatable {
        /// Everything the pack wants is present.
        case ready
        /// Installable and usable, with named optional capabilities absent — shown, not hidden.
        case degraded(missing: [String])
        /// A *required* capability is absent: install is refused with the reason, mirroring how
        /// `supportsDisplay()` gates HUD features.
        case blocked(missing: [String])
    }

    static func availability(
        requirements: [SkillPackManifest.HardwareRequirement],
        hasCamera: Bool,
        hasDisplay: Bool
    ) -> Availability {
        var requiredMissing: [String] = []
        var optionalMissing: [String] = []
        for requirement in requirements {
            let present: Bool
            switch requirement.type {
            case .camera: present = hasCamera
            case .display: present = hasDisplay
            }
            guard !present else { continue }
            switch requirement.level {
            case .required: requiredMissing.append(requirement.type.rawValue)
            case .optional: optionalMissing.append(requirement.type.rawValue)
            }
        }
        if !requiredMissing.isEmpty { return .blocked(missing: requiredMissing) }
        if !optionalMissing.isEmpty { return .degraded(missing: optionalMissing) }
        return .ready
    }
}

/// Plan BX P2 — pack zip → the `(manifestData, files)` shape `SkillPackStore.install` takes.
/// Pure over bytes; the reader is the Plan BT `ZipArchiveReader` (no new dependency).
///
/// Extraction is deliberately two-phase. `extractManifest` decides everything the central
/// directory can answer — count, path shape, entry type, declared and aggregate size, compression
/// ratio, nesting — and inflates exactly one entry, `skillpack.json`. Only after the caller has
/// decoded and validated that manifest does `materializeFiles` inflate payload bytes. A pack whose
/// manifest is refused therefore never has attacker-chosen entries expanded on its behalf.
enum SkillPackArchive {

    enum ArchiveError: Error, Equatable {
        case notAZip
        case missingManifest
        case archiveTooLarge
        case tooManyEntries
        case unsafeEntryPath
        case duplicateEntry
        case unsupportedEntry
        case entryTooLarge
        case totalUncompressedSizeTooLarge
        case suspiciousCompressionRatio
        case corruptEntry
        case missingDeclaredFile
    }

    static let maxArchiveBytes = 8 * 1024 * 1024
    static let maxEntryBytes = 4 * 1024 * 1024
    static let maxTotalUncompressedBytes = 32 * 1024 * 1024
    static let maxEntryCount = 128
    static let maxCompressionRatio = 100
    static let maxPathBytes = 180
    static let maxPathDepth = 8

    private static let nestedArchiveExtensions: Set<String> = [
        "7z", "bz2", "epub", "gz", "rar", "tar", "tgz", "xz", "zip",
    ]

    /// Counts entries actually inflated. Exists so "the manifest is validated before any payload
    /// byte is expanded" is an assertion over observed behaviour, not over source order.
    final class InflationCounter {
        private(set) var value = 0
        func record() { value += 1 }
    }

    /// A vetted archive: every entry has passed the metadata policy and the manifest bytes are
    /// inflated. No payload entry has been touched.
    struct StagedArchive {
        let manifestData: Data
        /// Normalized paths of the regular, non-manifest entries the policy admitted.
        let payloadPaths: [String]
        /// Entries inflated so far — one (the manifest) until `materializeFiles` runs.
        var inflatedEntryCount: Int { counter.value }

        fileprivate let reader: ZipArchiveReader
        fileprivate let sourceNames: [String: String]
        fileprivate let counter: InflationCounter
    }

    /// Phase 1: archive policy over central-directory metadata, then the manifest bytes alone.
    static func extractManifest(zipData: Data) -> Result<StagedArchive, ArchiveError> {
        guard zipData.count <= maxArchiveBytes else { return .failure(.archiveTooLarge) }
        guard let archive = ZipArchiveReader(data: zipData) else { return .failure(.notAZip) }
        guard archive.entryMetadata.count <= maxEntryCount else { return .failure(.tooManyEntries) }

        var normalizedNames: [String: String] = [:]
        var totalUncompressedBytes = 0
        for entry in archive.entryMetadata {
            guard let normalized = normalizedPath(entry.name) else { return .failure(.unsafeEntryPath) }
            guard normalizedNames[normalized] == nil else { return .failure(.duplicateEntry) }
            normalizedNames[normalized] = entry.name

            let unixMode = (entry.externalAttributes >> 16) & 0xF000
            let expectedUnixMode: UInt32 = entry.name.hasSuffix("/") ? 0x4000 : 0x8000
            // Zero means the producer omitted Unix type bits. Otherwise accept only regular files
            // and directories whose name agrees with the advertised type.
            let safeUnixType = unixMode == 0 || unixMode == expectedUnixMode
            let allowedFlags: UInt16 = 0x0008 | 0x0800 // data descriptor and UTF-8 names
            guard entry.generalPurposeBitFlag & ~allowedFlags == 0,
                  entry.compressionMethod == 0 || entry.compressionMethod == 8,
                  safeUnixType else { return .failure(.unsupportedEntry) }
            guard entry.uncompressedSize <= maxEntryBytes else { return .failure(.entryTooLarge) }
            let (nextTotal, overflow) = totalUncompressedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, nextTotal <= maxTotalUncompressedBytes else {
                return .failure(.totalUncompressedSizeTooLarge)
            }
            totalUncompressedBytes = nextTotal

            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0,
                      entry.uncompressedSize <= entry.compressedSize * maxCompressionRatio else {
                    return .failure(.suspiciousCompressionRatio)
                }
            }
            if !normalized.hasSuffix("/"),
               nestedArchiveExtensions.contains((normalized as NSString).pathExtension.lowercased()) {
                return .failure(.unsupportedEntry)
            }
        }

        guard let manifestSource = normalizedNames["skillpack.json"] else {
            return .failure(.missingManifest)
        }
        let counter = InflationCounter()
        guard let manifestData = archive.entryData(named: manifestSource,
                                                   maximumUncompressedSize: maxEntryBytes) else {
            return .failure(.corruptEntry)
        }
        counter.record()
        let payloadPaths = normalizedNames.keys
            .filter { $0 != "skillpack.json" && !$0.hasSuffix("/") }
            .sorted()
        return .success(StagedArchive(manifestData: manifestData,
                                      payloadPaths: payloadPaths,
                                      reader: archive,
                                      sourceNames: normalizedNames,
                                      counter: counter))
    }

    /// Phase 2: inflate payload files, for a manifest that has already been validated.
    ///
    /// A manifest that declares `files` gets exactly those — any other entry in the zip is ignored
    /// and never inflated, so an archive cannot smuggle content past the review the wearer saw.
    /// A manifest that declares nothing keeps the historical shape (every vetted payload entry),
    /// because packs signed before the declaration existed sign over exactly that set.
    static func materializeFiles(
        for staged: StagedArchive,
        declaredBy manifest: SkillPackManifest
    ) -> Result<[String: Data], ArchiveError> {
        let wanted: [String]
        if let declared = manifest.files {
            let normalized = declared.compactMap(normalizedPath)
            guard normalized.count == declared.count,
                  !normalized.contains(where: { $0.hasSuffix("/") }) else {
                return .failure(.unsafeEntryPath)
            }
            guard Set(normalized).isSubset(of: Set(staged.payloadPaths)) else {
                return .failure(.missingDeclaredFile)
            }
            wanted = Set(normalized).sorted()
        } else {
            wanted = staged.payloadPaths
        }

        var files: [String: Data] = [:]
        for path in wanted {
            guard let sourceName = staged.sourceNames[path],
                  let data = staged.reader.entryData(named: sourceName,
                                                     maximumUncompressedSize: maxEntryBytes) else {
                return .failure(.corruptEntry)
            }
            staged.counter.record()
            files[path] = data
        }
        return .success(files)
    }

    private static func normalizedPath(_ name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= maxPathBytes,
              !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        let stripped = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
        guard !stripped.isEmpty else { return nil }
        let isDirectory = stripped.hasSuffix("/")
        let components = stripped.split(separator: "/", omittingEmptySubsequences: false)
        let pathComponents = isDirectory ? components.dropLast() : components[...]
        guard !pathComponents.isEmpty, pathComponents.count <= maxPathDepth,
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let normalized = pathComponents.joined(separator: "/") + (isDirectory ? "/" : "")
        guard stripped == normalized else { return nil }
        return normalized
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
