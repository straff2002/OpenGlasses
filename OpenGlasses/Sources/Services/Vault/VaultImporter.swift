import Foundation

/// Installs a customer-supplied vault (Plan H) into the user overlay so it loads through the normal
/// `VaultStore`/`VaultRegistry` path. Validates first via `VaultValidator`; only a clean pack is
/// installed. Source is a directory (already-unzipped) containing manifest.json + markdown +
/// optional procedures/.
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

    /// Overlay directory for a vault id (`Documents/Vaults/{id}/`).
    static func overlayDirectory(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/\(id)", isDirectory: true)
    }

    /// Validate and install. Returns the installed manifest on success; throws with the issues otherwise.
    @discardableResult
    static func install(from sourceDir: URL) throws -> VaultManifest {
        let result = VaultValidator.validate(directory: sourceDir)
        guard result.isValid, let manifest = result.manifest else {
            throw ImportError.invalid(result.issues)
        }

        let fm = FileManager.default
        let overlay = overlayDirectory(for: manifest.id)
        // Install into a temp dir first, then atomically swap — so a half-copy never goes live.
        let staging = overlay.appendingPathExtension("staging-\(UUID().uuidString.prefix(8))")
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
            // Swap staging → overlay.
            try? fm.removeItem(at: overlay)
            try fm.createDirectory(at: overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: overlay)

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

    /// Remove an installed user vault (overlay + registry entry).
    static func uninstall(id: String) {
        let fm = FileManager.default
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
