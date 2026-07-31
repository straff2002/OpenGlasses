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
enum SkillPackArchive {

    enum ArchiveError: Error, Equatable {
        case notAZip
        case missingManifest
    }

    /// Zip entries larger than this are refused before inflation — a zip-bomb guard, not a
    /// realistic content limit.
    static let maxEntryBytes = 5 * 1024 * 1024

    static func extract(zipData: Data) -> Result<(manifestData: Data, files: [String: Data]), ArchiveError> {
        guard let archive = ZipArchiveReader(data: zipData) else { return .failure(.notAZip) }
        guard let manifestData = archive.entryData(named: "skillpack.json") else {
            return .failure(.missingManifest)
        }
        var files: [String: Data] = [:]
        for name in archive.entryNames {
            let normalized = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            guard normalized != "skillpack.json", !normalized.hasSuffix("/") else { continue }
            guard let data = archive.entryData(named: name), data.count <= maxEntryBytes else { continue }
            files[normalized] = data
        }
        return .success((manifestData, files))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
