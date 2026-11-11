import Foundation

/// Loads `CaptureFlow` definitions from a vault's `flows/` directory (Plan U) — mirroring how
/// `ProcedureLibrary` loads `procedures/`. Merges the bundled baseline with the user overlay, the
/// overlay winning, so authored/edited flows shadow the shipped ones.
struct CaptureFlowLibrary {
    let vaultId: String
    private let flows: [CaptureFlow]
    /// "filename: reason" for each flow file that failed to load (BM P2) — surfaced by the
    /// `capture_flow` tool's `list` action so a typo'd overlay never silently vanishes.
    let rejected: [String]

    /// Build from a vault store. Returns an empty library if the vault has no `flows/` content.
    init(store: VaultStore) {
        vaultId = store.manifest.id
        (flows, rejected) = Self.loadStrict(
            bundleDir: store.bundleRoot?.appendingPathComponent("flows", isDirectory: true),
            overlayDir: store.overlayRoot.appendingPathComponent("flows", isDirectory: true))
    }

    /// Test / explicit init.
    init(vaultId: String, flows: [CaptureFlow]) {
        self.vaultId = vaultId
        self.flows = flows
        self.rejected = []
    }

    var all: [CaptureFlow] { flows }
    var isEmpty: Bool { flows.isEmpty }

    func flow(id: String) -> CaptureFlow? { flows.first { $0.id == id } }

    /// "id — title" summaries for prompts / `list` actions.
    func summaries() -> [String] { flows.map { "\($0.id) — \($0.title)" } }

    // MARK: - Loading

    /// Decode a single flow from JSON data (nil on malformed input).
    static func decode(_ data: Data) -> CaptureFlow? {
        decodeReporting(data).flow
    }

    /// Decode a single flow, returning a human-readable rejection reason on failure — the
    /// `MCPCatalog.loadStrict` pattern (BM P2). A file declaring a `schema_version` newer than
    /// `CaptureFlow.currentSchemaVersion` is rejected without attempting a full decode, so a
    /// v2 flow reads as "too new", not as a pile of decoding errors.
    static func decodeReporting(_ data: Data) -> (flow: CaptureFlow?, rejection: String?) {
        let decoder = JSONDecoder()
        if let probe = try? decoder.decode(VersionProbe.self, from: data),
           let version = probe.schemaVersion, version > CaptureFlow.currentSchemaVersion {
            return (nil, "schema_version \(version) is newer than this app supports (\(CaptureFlow.currentSchemaVersion))")
        }
        do {
            return (try decoder.decode(CaptureFlow.self, from: data), nil)
        } catch {
            return (nil, rejectionReason(from: error))
        }
    }

    /// Load every `*.json` flow from a directory (overlay wins over bundle by filename).
    static func load(bundleDir: URL?, overlayDir: URL?) -> [CaptureFlow] {
        loadStrict(bundleDir: bundleDir, overlayDir: overlayDir).flows
    }

    /// As `load`, additionally reporting every file that failed ("filename: reason") instead of
    /// silently dropping it.
    static func loadStrict(bundleDir: URL?, overlayDir: URL?) -> (flows: [CaptureFlow], rejected: [String]) {
        var byFilename: [String: (url: URL, fromOverlay: Bool)] = [:]
        if let bundleDir {
            for url in jsonFiles(in: bundleDir) { byFilename[url.lastPathComponent] = (url, false) }
        }
        if let overlayDir {
            for url in jsonFiles(in: overlayDir) { byFilename[url.lastPathComponent] = (url, true) }
        }
        var candidates: [Candidate] = []
        var rejected: [String] = []
        for (filename, source) in byFilename.sorted(by: { $0.key < $1.key }) {
            guard let data = try? Data(contentsOf: source.url) else {
                rejected.append("\(filename): unreadable")
                continue
            }
            let (flow, rejection) = decodeReporting(data)
            if let flow {
                candidates.append(Candidate(file: filename, fromOverlay: source.fromOverlay, flow: flow))
            } else {
                rejected.append("\(filename): \(rejection ?? "not valid flow JSON")")
            }
        }
        let (flows, duplicates) = resolve(candidates)
        return (flows, rejected + duplicates)
    }

    /// One decoded flow file, as `resolve` weighs it.
    struct Candidate {
        let file: String
        let fromOverlay: Bool
        let flow: CaptureFlow
    }

    /// One flow per id, in id order — `ProcedureLibrary.resolve`'s rule. Two files declaring the
    /// same id would otherwise both be listed, and the flows are rows in a `List` keyed by id
    /// (Siri & Shortcuts), which asserts in `UICollectionView`'s batch-update validation on a
    /// repeated id. The overlay's file wins over the bundle's; between two files from the same
    /// place, the first file name does. Each file left out is reported, not silently dropped.
    static func resolve(_ candidates: [Candidate]) -> (flows: [CaptureFlow], duplicates: [String]) {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.flow.id != rhs.flow.id { return lhs.flow.id < rhs.flow.id }
            if lhs.fromOverlay != rhs.fromOverlay { return lhs.fromOverlay }
            return lhs.file < rhs.file
        }
        var seen = Set<String>()
        var flows: [CaptureFlow] = []
        var duplicates: [String] = []
        for candidate in ordered {
            if seen.insert(candidate.flow.id).inserted {
                flows.append(candidate.flow)
            } else {
                duplicates.append("\(candidate.file): repeats flow id \"\(candidate.flow.id)\"")
            }
        }
        return (flows, duplicates)
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int?
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
    }

    private static func rejectionReason(from error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let ctx),
             DecodingError.typeMismatch(_, let ctx),
             DecodingError.valueNotFound(_, let ctx):
            return readable(ctx)
        case DecodingError.keyNotFound(let key, let ctx):
            let path = pathString(ctx.codingPath)
            return "missing required field '\(key.stringValue)'\(path.isEmpty ? "" : " at \(path)")"
        default:
            return "not valid flow JSON"
        }
    }

    private static func readable(_ ctx: DecodingError.Context) -> String {
        let path = pathString(ctx.codingPath)
        return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
    }

    private static func pathString(_ codingPath: [CodingKey]) -> String {
        codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "json" }
    }
}
