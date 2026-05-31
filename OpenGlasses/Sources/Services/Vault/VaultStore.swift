import Foundation

/// File-backed store for a single knowledge vault.
///
/// A vault merges two locations:
///   1. **Baseline** (read-only): either app resources at `<Bundle>/Vaults/{id}/` (built-in vaults)
///      or an admin-pushed import at `Documents/Vaults/_baselines/{id}/` (Plan H). Never mutated.
///   2. **User-overlay**: `Documents/Vaults/{id}/` — technician edits that override baseline files.
///
/// Reads transparently merge the two — overlay files take precedence, falling back to the baseline.
/// Writes go to the overlay only; the baseline is never mutated, so an admin can re-push a new
/// baseline version without clobbering overlay edits.
final class VaultStore {
    let manifest: VaultManifest

    /// Read-only baseline root — the app bundle (`<Bundle>/Vaults/{id}/`) for built-in vaults, or
    /// an imported baseline (`Documents/Vaults/_baselines/{id}/`) for admin-pushed vaults. Nil if
    /// neither exists.
    let bundleRoot: URL?
    /// Root in the user Documents directory (e.g. `Documents/Vaults/refrigeration/`).
    let overlayRoot: URL

    init(manifest: VaultManifest, bundleRoot: URL?, overlayRoot: URL) {
        self.manifest = manifest
        self.bundleRoot = bundleRoot
        self.overlayRoot = overlayRoot
        ensureOverlayExists()
    }

    /// Read a file by name (e.g. "error_codes.md"). User-overlay version wins over bundled.
    /// Returns nil if neither location has the file.
    func read(_ filename: String) -> String? {
        let overlayURL = overlayRoot.appendingPathComponent(filename)
        if let contents = try? String(contentsOf: overlayURL, encoding: .utf8) {
            return contents
        }
        if let bundleRoot {
            let bundleURL = bundleRoot.appendingPathComponent(filename)
            if let contents = try? String(contentsOf: bundleURL, encoding: .utf8) {
                return contents
            }
        }
        return nil
    }

    /// Write a file to the user overlay, creating parent dirs if needed.
    @discardableResult
    func write(_ filename: String, contents: String) throws -> URL {
        let url = overlayRoot.appendingPathComponent(filename)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Append a timestamped entry to a vault file. Creates the file if missing.
    /// Format: trailing blank line + ISO date heading + entry text.
    @discardableResult
    func append(_ filename: String, entry: String, date: Date = Date()) throws -> URL {
        let existing = read(filename) ?? ""
        let iso = ISO8601DateFormatter().string(from: date)
        let separator = existing.isEmpty ? "" : "\n\n"
        let appended = "\(existing)\(separator)## \(iso)\n\n\(entry)"
        return try write(filename, contents: appended)
    }

    /// Read all manifest files, returning [filename: contents]. Missing files are skipped.
    func readAll() -> [(filename: String, contents: String)] {
        var out: [(String, String)] = []
        for filename in manifest.files {
            if let contents = read(filename), !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append((filename, contents))
            }
        }
        return out
    }

    /// True when at least one manifest file has content (bundle or overlay).
    var hasContent: Bool {
        manifest.files.contains { (read($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    // MARK: - Helpers

    private func ensureOverlayExists() {
        try? FileManager.default.createDirectory(at: overlayRoot, withIntermediateDirectories: true)
    }

    /// Convenience: build a store with the read-only baseline (bundled resources, else an imported
    /// baseline) and the standard `Documents/Vaults/{id}/` overlay.
    static func standard(manifest: VaultManifest, bundle: Bundle = .main) -> VaultStore {
        let fm = FileManager.default
        // Prefer bundled resources; fall back to an admin-pushed import baseline if present.
        let bundleResource = bundle.url(forResource: "Vaults/\(manifest.id)", withExtension: nil)
        let importedBaseline = VaultImporter.baselineDirectory(for: manifest.id)
        let baselineRoot = bundleResource
            ?? (fm.fileExists(atPath: importedBaseline.path) ? importedBaseline : nil)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let overlay = docs.appendingPathComponent("Vaults/\(manifest.id)", isDirectory: true)
        return VaultStore(manifest: manifest, bundleRoot: baselineRoot, overlayRoot: overlay)
    }
}
