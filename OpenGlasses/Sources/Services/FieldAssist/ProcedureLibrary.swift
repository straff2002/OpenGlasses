import Foundation

/// Loads `Procedure` definitions from a vault's procedures directory.
///
/// Procedures live in `{vaultRoot}/{proceduresDir}/*.json`. Like vault markdown, they merge two
/// sources with the user overlay winning over the bundled baseline:
///   - Bundled:  `<Bundle>/Vaults/{id}/procedures/*.json`
///   - Overlay:  `Documents/Vaults/{id}/procedures/*.json`
///
/// A procedure file present in the overlay shadows the bundled file of the same name.
struct ProcedureLibrary {
    let vaultId: String
    private let procedures: [Procedure]

    /// Build a library for a vault store. Returns an empty library if the vault declares no
    /// procedures directory or none can be decoded.
    init(store: VaultStore) {
        vaultId = store.manifest.id
        guard let dir = store.manifest.proceduresDir else {
            procedures = []
            return
        }
        procedures = Self.load(proceduresDir: dir, bundleRoot: store.bundleRoot, overlayRoot: store.overlayRoot)
    }

    /// Test/explicit init.
    init(vaultId: String, procedures: [Procedure]) {
        self.vaultId = vaultId
        self.procedures = procedures
    }

    var all: [Procedure] { procedures }

    var isEmpty: Bool { procedures.isEmpty }

    func procedure(id: String) -> Procedure? {
        procedures.first { $0.id == id }
    }

    /// Short listing for prompts / `list` actions: "id — title".
    func summaries() -> [String] {
        procedures.map { "\($0.id) — \($0.title)" }
    }

    // MARK: - Loading

    private static func load(proceduresDir: String, bundleRoot: URL?, overlayRoot: URL) -> [Procedure] {
        resolve(candidates(proceduresDir: proceduresDir, bundleRoot: bundleRoot, overlayRoot: overlayRoot))
    }

    /// Every procedure file that decodes, one per file name, with the overlay's file in place of the
    /// bundle's of the same name.
    private static func candidates(proceduresDir: String, bundleRoot: URL?, overlayRoot: URL) -> [Candidate] {
        // Overlay wins: collect overlay filenames first, then fill gaps from the bundle.
        var byFilename: [String: (url: URL, fromOverlay: Bool)] = [:]
        if let bundleRoot {
            for url in jsonFiles(in: bundleRoot.appendingPathComponent(proceduresDir, isDirectory: true)) {
                byFilename[url.lastPathComponent] = (url, false)
            }
        }
        for url in jsonFiles(in: overlayRoot.appendingPathComponent(proceduresDir, isDirectory: true)) {
            byFilename[url.lastPathComponent] = (url, true)
        }

        let decoder = JSONDecoder()
        return byFilename.compactMap { file, source -> Candidate? in
            guard let data = try? Data(contentsOf: source.url),
                  let procedure = try? decoder.decode(Procedure.self, from: data) else { return nil }
            return Candidate(file: file, fromOverlay: source.fromOverlay, procedure: procedure)
        }
    }

    /// The vault's procedures with the file each is read from (Plan MN P3: the authoring screen
    /// writes an edited procedure back over the same file name, in the overlay). The same choice
    /// `all` makes — one per id, the overlay's file first — in id order.
    static func entries(store: VaultStore) -> [Candidate] {
        guard let dir = store.manifest.proceduresDir else { return [] }
        let found = candidates(proceduresDir: dir, bundleRoot: store.bundleRoot, overlayRoot: store.overlayRoot)
        let chosen = resolve(found)
        return chosen.compactMap { procedure in
            found.filter { $0.procedure.id == procedure.id }
                .sorted { lhs, rhs in lhs.fromOverlay != rhs.fromOverlay ? lhs.fromOverlay : lhs.file < rhs.file }
                .first
        }
    }

    /// One decoded procedure file, as `resolve` weighs it.
    struct Candidate {
        let file: String
        let fromOverlay: Bool
        let procedure: Procedure
    }

    /// One procedure per id, in id order — the same list on every load. Two files declaring the
    /// same id would otherwise both be listed, in whatever order the directory scan produced, and a
    /// SwiftUI `List` keyed by id cannot survive that order changing between redraws (it asserts in
    /// `UICollectionView`'s batch-update validation). The overlay's file wins over the bundle's;
    /// between two files from the same place, the first file name does.
    static func resolve(_ candidates: [Candidate]) -> [Procedure] {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.procedure.id != rhs.procedure.id { return lhs.procedure.id < rhs.procedure.id }
            if lhs.fromOverlay != rhs.fromOverlay { return lhs.fromOverlay }
            return lhs.file < rhs.file
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.procedure.id).inserted }.map(\.procedure)
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "json" }
    }
}
