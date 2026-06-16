import Foundation

/// Loads `CaptureFlow` definitions from a vault's `flows/` directory (Plan U) — mirroring how
/// `ProcedureLibrary` loads `procedures/`. Merges the bundled baseline with the user overlay, the
/// overlay winning, so authored/edited flows shadow the shipped ones.
struct CaptureFlowLibrary {
    let vaultId: String
    private let flows: [CaptureFlow]

    /// Build from a vault store. Returns an empty library if the vault has no `flows/` content.
    init(store: VaultStore) {
        vaultId = store.manifest.id
        flows = Self.load(bundleDir: store.bundleRoot?.appendingPathComponent("flows", isDirectory: true),
                          overlayDir: store.overlayRoot.appendingPathComponent("flows", isDirectory: true))
    }

    /// Test / explicit init.
    init(vaultId: String, flows: [CaptureFlow]) {
        self.vaultId = vaultId
        self.flows = flows
    }

    var all: [CaptureFlow] { flows }
    var isEmpty: Bool { flows.isEmpty }

    func flow(id: String) -> CaptureFlow? { flows.first { $0.id == id } }

    /// "id — title" summaries for prompts / `list` actions.
    func summaries() -> [String] { flows.map { "\($0.id) — \($0.title)" } }

    // MARK: - Loading

    /// Decode a single flow from JSON data (nil on malformed input).
    static func decode(_ data: Data) -> CaptureFlow? {
        try? JSONDecoder().decode(CaptureFlow.self, from: data)
    }

    /// Load every `*.json` flow from a directory (overlay wins over bundle by filename).
    static func load(bundleDir: URL?, overlayDir: URL?) -> [CaptureFlow] {
        var byFilename: [String: URL] = [:]
        if let bundleDir {
            for url in jsonFiles(in: bundleDir) { byFilename[url.lastPathComponent] = url }
        }
        if let overlayDir {
            for url in jsonFiles(in: overlayDir) { byFilename[url.lastPathComponent] = url }
        }
        let loaded = byFilename.values.compactMap { url -> CaptureFlow? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
        return loaded.sorted { $0.id < $1.id }
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "json" }
    }
}
