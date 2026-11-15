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
///
/// Plan LV: a published vault may carry a **company layer** between the two
/// (`Documents/Vaults/_baselines/{id}.company/`), read in the order publisher baseline → company
/// layer → technician overlay, as `VaultLayerMerge` resolves it. A vault without one reads exactly
/// as before.
final class VaultStore {
    let manifest: VaultManifest

    /// Plan LV: a company layer and how the merge resolved its files.
    struct CompanyLayer {
        let root: URL
        let merged: VaultLayerMerge.Merged

        init(root: URL, merged: VaultLayerMerge.Merged) {
            self.root = root
            self.merged = merged
            companyKeys = Set(merged.companyFiles.map(VaultPackRules.layerFileKey))
        }

        fileprivate let companyKeys: Set<String>

        func adds(_ filename: String) -> Bool { companyKeys.contains(VaultPackRules.layerFileKey(filename)) }
    }

    /// The company layer read between the baseline and the overlay, or nil (every vault but a
    /// published vault a company has added to).
    let companyLayer: CompanyLayer?

    /// Read-only baseline root — the app bundle (`<Bundle>/Vaults/{id}/`) for built-in vaults, or
    /// an imported baseline (`Documents/Vaults/_baselines/{id}/`) for admin-pushed vaults. Nil if
    /// neither exists.
    let bundleRoot: URL?
    /// Root in the user Documents directory (e.g. `Documents/Vaults/refrigeration/`).
    let overlayRoot: URL

    init(manifest: VaultManifest, bundleRoot: URL?, overlayRoot: URL, companyLayer: CompanyLayer? = nil) {
        self.manifest = manifest
        self.bundleRoot = bundleRoot
        self.overlayRoot = overlayRoot
        self.companyLayer = companyLayer
        ensureOverlayExists()
    }

    /// The read-only root a file comes from beneath the overlay: the company layer for a file it
    /// added, else the baseline.
    private func baseRoot(for filename: String) -> URL? {
        if let companyLayer, companyLayer.adds(filename) { return companyLayer.root }
        return bundleRoot
    }

    /// Plan LV: which layer `filename` is read from — the technician's overlay when it holds the
    /// file, else the company layer for a file it added, else the publisher's baseline.
    func layer(of filename: String) -> VaultLayerMerge.Layer {
        if FileManager.default.fileExists(atPath: overlayRoot.appendingPathComponent(filename).path) { return .technician }
        return baseLayer(of: filename)
    }

    /// Whose file `filename` is beneath any edit of the technician's: the company's or the publisher's.
    func baseLayer(of filename: String) -> VaultLayerMerge.Layer {
        companyLayer?.adds(filename) == true ? .company : .publisher
    }

    /// Read a file by name (e.g. "error_codes.md"). User-overlay version wins over bundled.
    /// Returns nil if neither location has the file.
    func read(_ filename: String) -> String? {
        let overlayURL = overlayRoot.appendingPathComponent(filename)
        if let contents = try? String(contentsOf: overlayURL, encoding: .utf8) {
            return contents
        }
        if let root = baseRoot(for: filename) {
            let bundleURL = root.appendingPathComponent(filename)
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
    /// Throws when an existing file can't be read (file protection, encoding) — rewriting the
    /// file from a failed read would replace the accumulated log with just this entry.
    @discardableResult
    func append(_ filename: String, entry: String, date: Date = Date()) throws -> URL {
        let existing = try readStrict(filename) ?? ""
        let iso = ISO8601DateFormatter().string(from: date)
        let separator = existing.isEmpty ? "" : "\n\n"
        let appended = "\(existing)\(separator)## \(iso)\n\n\(entry)"
        return try write(filename, contents: appended)
    }

    /// Like `read`, but distinguishes "file genuinely absent" (nil) from "file exists but the
    /// read failed" (throws).
    private func readStrict(_ filename: String) throws -> String? {
        let fm = FileManager.default
        let overlayURL = overlayRoot.appendingPathComponent(filename)
        if fm.fileExists(atPath: overlayURL.path) {
            return try String(contentsOf: overlayURL, encoding: .utf8)
        }
        if let root = baseRoot(for: filename) {
            let bundleURL = root.appendingPathComponent(filename)
            if fm.fileExists(atPath: bundleURL.path) {
                return try String(contentsOf: bundleURL, encoding: .utf8)
            }
        }
        return nil
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

    // MARK: - Site documents (Plan HV)

    /// The vault's site documents, in `sites` order. Read from the baseline only: site documents
    /// have no overlay and no phone editor. A file that no longer passes the validator's rules is
    /// left out rather than half-read — install validated every one, so this is a damaged baseline.
    /// Read once per store; empty for every vault without `sites`.
    func siteDocuments() -> [SiteSystemDocument] {
        if let cached = siteDocumentCache { return cached }
        let documents = Self.readSiteDocuments(manifest: manifest, root: bundleRoot)
        siteDocumentCache = documents
        return documents
    }

    /// The site document with this id, or nil.
    func siteDocument(id: String) -> SiteSystemDocument? {
        siteDocuments().first { $0.id == id }
    }

    private var siteDocumentCache: [SiteSystemDocument]?

    static func readSiteDocuments(manifest: VaultManifest, root: URL?) -> [SiteSystemDocument] {
        guard let root, !manifest.siteFiles.isEmpty else { return [] }
        let core = manifest.files.compactMap { file -> (filename: String, contents: String)? in
            (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).map { (file, $0) }
        }
        let covered = SiteSystemValidator.modelCovered(by: VaultModelIndex(vaultName: manifest.name, files: core))
        return manifest.siteFiles.prefix(SiteSystemValidator.maximumSiteDocuments).compactMap { path in
            guard SiteSystemValidator.isSitePath(path) else { return nil }
            let url = root.appendingPathComponent(path)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= SiteSystemValidator.maximumFileBytes,
                  let data = try? Data(contentsOf: url) else { return nil }
            return SiteSystemValidator.check(data, path: path, modelCovered: covered).document
        }
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
        return VaultStore(manifest: manifest, bundleRoot: baselineRoot, overlayRoot: overlay,
                          companyLayer: bundleResource == nil ? installedCompanyLayer(for: manifest.id) : nil)
    }

    /// Plan LV: the company layer installed over the imported vault `id`, merged against the
    /// publisher's manifest as installed. Nil when there is none or it no longer fits.
    static func installedCompanyLayer(for id: String) -> CompanyLayer? {
        guard let layer = VaultCompanyLayer.installed(baseId: id),
              let publisher = VaultImporter.installedManifest(id: id),
              case .success = VaultLayerMerge.manifest(publisher: publisher, company: layer.manifest),
              case .success(let merged) = VaultLayerMerge.merge(publisher: .init(publisher), company: .init(layer.manifest))
        else { return nil }
        return CompanyLayer(root: VaultCompanyLayer.directory(baseId: id), merged: merged)
    }
}
