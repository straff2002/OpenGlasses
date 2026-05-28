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
        // Overlay wins: collect overlay filenames first, then fill gaps from the bundle.
        var byFilename: [String: URL] = [:]
        if let bundleRoot {
            for url in jsonFiles(in: bundleRoot.appendingPathComponent(proceduresDir, isDirectory: true)) {
                byFilename[url.lastPathComponent] = url
            }
        }
        for url in jsonFiles(in: overlayRoot.appendingPathComponent(proceduresDir, isDirectory: true)) {
            byFilename[url.lastPathComponent] = url
        }

        let decoder = JSONDecoder()
        var loaded: [Procedure] = []
        for url in byFilename.values {
            guard let data = try? Data(contentsOf: url),
                  let procedure = try? decoder.decode(Procedure.self, from: data) else { continue }
            loaded.append(procedure)
        }
        return loaded.sorted { $0.id < $1.id }
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "json" }
    }
}
