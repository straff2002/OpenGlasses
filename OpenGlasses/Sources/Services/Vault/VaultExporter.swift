import Foundation

/// Inverse of `VaultImporter`: packages a vault's *effective* content into a folder laid out exactly
/// like an import source — `manifest.json` + the listed markdown files + an optional `procedures/`
/// directory. The output round-trips straight back through `VaultImporter.install`.
///
/// Files are read through `VaultStore`, which merges the user overlay over any bundled baseline, so
/// the export captures the technician's edits rather than just the shipped files.
///
/// **Licensing:** exporting the baseline of a *paid bundled* vault (refrigeration, IT, health) would
/// bypass the per-pack IAP gate. Export is therefore restricted to user-imported/authored vaults and
/// free vaults — see `isExportable`. (Aligns with the agent-mode / gateway gating convention.)
@MainActor
enum VaultExporter {

    enum ExportError: LocalizedError {
        case unknownVault(String)
        case notExportable(String)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .unknownVault(let id): return "No vault found with id \(id)."
            case .notExportable(let name): return "“\(name)” is a paid bundled vault and can't be exported."
            case .ioError(let message): return "Export failed: \(message)"
            }
        }
    }

    /// A vault may be exported when it's user-imported (lives in the import registry) or free
    /// (no IAP gate). Paid bundled baselines are deliberately excluded for licensing.
    static func isExportable(_ manifest: VaultManifest) -> Bool {
        let isUserImported = VaultImporter.installedManifests().contains { $0.id == manifest.id }
        let isFree = manifest.gating.iap == nil
        return isUserImported || isFree
    }

    /// Build an export folder in a temp directory and return its URL. Hand the URL to a share sheet
    /// (`ShareSheet`) or `fileExporter`; the format equals the import format so the importer consumes
    /// it directly.
    @discardableResult
    static func export(id: String) throws -> URL {
        guard let manifest = VaultRegistry.shared.manifest(id: id) else {
            throw ExportError.unknownVault(id)
        }
        guard isExportable(manifest) else {
            throw ExportError.notExportable(manifest.name)
        }

        let store = VaultRegistry.shared.store(for: manifest)
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("VaultExport-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("\(manifest.id)-vault", isDirectory: true)

        do {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            // manifest.json — same shape the importer/validator expects.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)

            // Markdown files — merged overlay-over-bundle so a tech's edits are captured.
            for filename in manifest.files {
                let contents = store.read(filename) ?? ""
                try contents.write(to: root.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            }

            // procedures/ — copy whatever is present (overlay wins, else bundle).
            if let dir = manifest.proceduresDir {
                let dest = root.appendingPathComponent(dir, isDirectory: true)
                let overlaySrc = store.overlayRoot.appendingPathComponent(dir, isDirectory: true)
                let bundleSrc = store.bundleRoot?.appendingPathComponent(dir, isDirectory: true)
                if fm.fileExists(atPath: overlaySrc.path) {
                    try fm.copyItem(at: overlaySrc, to: dest)
                } else if let bundleSrc, fm.fileExists(atPath: bundleSrc.path) {
                    try fm.copyItem(at: bundleSrc, to: dest)
                }
            }
        } catch {
            try? fm.removeItem(at: root.deletingLastPathComponent())
            throw ExportError.ioError(error.localizedDescription)
        }
        return root
    }
}
