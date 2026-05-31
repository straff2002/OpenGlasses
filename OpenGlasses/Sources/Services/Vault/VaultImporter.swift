import Foundation

/// Installs a customer-supplied vault (Plan H) as a **read-only baseline** so it loads through the
/// normal `VaultStore`/`VaultRegistry` path. Validates first via `VaultValidator`; only a clean pack
/// is installed. Source is a directory (already-unzipped) containing manifest.json + markdown +
/// optional procedures/.
///
/// An admin's pushed content lands in `Documents/Vaults/_baselines/{id}/` and is never mutated by
/// in-app editing — technician edits go to the `Documents/Vaults/{id}/` overlay, which `VaultStore`
/// merges *over* the baseline. So an admin can re-push a new vault version (updating the baseline)
/// without clobbering technician overlay edits.
enum VaultImporter {

    enum ImportError: LocalizedError {
        case invalid([String])
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let issues): return "Vault failed validation:\n• " + issues.joined(separator: "\n• ")
            case .ioError(let message): return "Install failed: \(message)"
            }
        }
    }

    /// `Documents/Vaults/_registry/` — where user vault manifests live for registry discovery.
    static var registryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/_registry", isDirectory: true)
    }

    /// Overlay directory for a vault id (`Documents/Vaults/{id}/`) — where technician edits live.
    static func overlayDirectory(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/\(id)", isDirectory: true)
    }

    /// Read-only baseline directory for an imported vault (`Documents/Vaults/_baselines/{id}/`) —
    /// where the admin's pushed content lives. `VaultStore` treats this as its baseline root and
    /// merges the overlay over it.
    static func baselineDirectory(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/_baselines/\(id)", isDirectory: true)
    }

    /// Validate and install. Returns the installed manifest on success; throws with the issues otherwise.
    @discardableResult
    static func install(from sourceDir: URL) throws -> VaultManifest {
        let result = VaultValidator.validate(directory: sourceDir)
        guard result.isValid, let manifest = result.manifest else {
            throw ImportError.invalid(result.issues)
        }

        let fm = FileManager.default
        let baseline = baselineDirectory(for: manifest.id)
        let overlay = overlayDirectory(for: manifest.id)
        // Whether this is the first time we're laying down a baseline for this id. Under the
        // baseline model a technician's overlay only ever holds genuine edits *after* a baseline
        // exists, so a pre-existing overlay here is legacy full-content from the old importer and
        // must be cleared so the new baseline is visible. Re-pushes (baseline already present)
        // never reach that branch, preserving overlay edits.
        let isFirstBaseline = !fm.fileExists(atPath: baseline.path)

        // Install into a temp dir first, then atomically swap — so a half-copy never goes live.
        let staging = baseline.appendingPathExtension("staging-\(UUID().uuidString.prefix(8))")
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // Copy listed markdown files.
            for file in manifest.files {
                try fm.copyItem(at: sourceDir.appendingPathComponent(file), to: staging.appendingPathComponent(file))
            }
            // Copy procedures dir if present.
            if let dir = manifest.proceduresDir {
                let src = sourceDir.appendingPathComponent(dir, isDirectory: true)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: staging.appendingPathComponent(dir, isDirectory: true))
                }
            }
            // Swap staging → baseline (the read-only authoritative copy).
            try? fm.removeItem(at: baseline)
            try fm.createDirectory(at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: baseline)

            // Migrate legacy installs: clear a pre-existing overlay only on first baseline creation.
            if isFirstBaseline {
                try? fm.removeItem(at: overlay)
            }

            // Record the manifest for registry discovery.
            try fm.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: registryDirectory.appendingPathComponent("\(manifest.id).json"), options: .atomic)
        } catch let error as ImportError {
            try? fm.removeItem(at: staging)
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.ioError(error.localizedDescription)
        }
        return manifest
    }

    /// Fully remove an installed user vault: baseline + overlay edits + registry entry.
    static func uninstall(id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: baselineDirectory(for: id))
        try? fm.removeItem(at: overlayDirectory(for: id))
        try? fm.removeItem(at: registryDirectory.appendingPathComponent("\(id).json"))
    }

    /// Load all user-installed manifests from the registry directory.
    static func installedManifests() -> [VaultManifest] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: registryDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(VaultManifest.self, from: $0) }
        }
    }
}
