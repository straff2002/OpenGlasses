import Foundation

/// The bundled GGUF catalog that PR1 deferred, and the validation that decides what it is allowed
/// to claim (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Catalog policy").
///
/// ### Why this one is JSON when the MLX catalog is Swift
/// A JSON entry earns its format by carrying the size/digest/revision triple. The MLX entries have
/// none — they are hub snapshots fetched whole — so PR1 kept them in Swift and said so. Every
/// entry here has an exact revision, exact files, exact byte counts and real SHA-256 digests, which
/// is precisely the data a hand-authored Swift literal is a bad home for.
///
/// ### What an entry is allowed to claim
/// Loading refuses an entry that:
///
///  - fails `installationFaults()` — unpinned revision, missing digest, non-positive size, a path
///    that escapes the model root, no `.text` capability;
///  - declares a runtime other than `llamaCpp`; or
///  - claims `.vision` or `.toolFriendly` without device evidence.
///
/// That last rule is the plan's, made structural: "Do not add a model based only on a successful
/// load; it must complete the conversation, long-prompt, cancellation, tool-call, and
/// device-memory fixtures relevant to its capability badges." An entry whose evidence is
/// `fileMetadataOnly` can therefore be shipped honestly — it is a text model with verified bytes —
/// but it cannot wear a badge nobody demonstrated.
///
/// ### `minimumHeadroomBytes` in this catalog
/// It is an **additional** reserve on top of the weights and the runtime working set, because that
/// is how the GGUF load path consumes it (`LlamaCppLocalInferenceBackend` passes it to
/// `LocalModelBudget.admit` as `safetyReserveBytes`). It is not "weights + working set" the way the
/// MLX entries compute it; writing that here would double-count and refuse loads that fit.
struct LocalModelCatalogDocument: Equatable, Sendable {

    /// Bumped when the document's *shape* changes.
    static let currentVersion = 1
    static let resourceName = "LocalModelCatalog"

    let version: Int
    let entries: [LocalModelCatalog.GGUFEntry]

    /// Decode and validate. A malformed or over-claiming entry is dropped, not fatal: one bad row
    /// must not cost the user the rest of the catalog. `loadStrict` reports what was dropped, which
    /// is what the bundled-catalog test asserts is empty.
    static func load(from data: Data) throws -> LocalModelCatalogDocument {
        try loadStrict(from: data).document
    }

    static func loadStrict(from data: Data) throws -> (document: LocalModelCatalogDocument,
                                                       rejected: [String]) {
        let raw = try JSONDecoder().decode(RawDocument.self, from: data)
        var entries: [LocalModelCatalog.GGUFEntry] = []
        var rejected: [String] = []
        var seen = Set<String>()

        for candidate in raw.models {
            let entry = candidate.entry
            if let reason = LocalModelCatalog.validationError(for: entry) {
                rejected.append("\(entry.descriptor.id.rawValue): \(reason)")
            } else if !seen.insert(entry.descriptor.id.rawValue).inserted {
                rejected.append("\(entry.descriptor.id.rawValue): duplicate id")
            } else {
                entries.append(entry)
            }
        }
        return (LocalModelCatalogDocument(version: raw.version, entries: entries), rejected)
    }

    /// Tolerates one malformed element rather than failing the whole decode — the same shape the
    /// bundled MCP catalogue already uses.
    private struct RawDocument: Decodable {
        let version: Int
        let models: [LocalModelCatalog.RawGGUFEntry]

        enum CodingKeys: String, CodingKey { case version, models }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            var list = try container.nestedUnkeyedContainer(forKey: .models)
            var parsed: [LocalModelCatalog.RawGGUFEntry] = []
            while !list.isAtEnd {
                let element = try list.decode(FailableDecodable<LocalModelCatalog.RawGGUFEntry>.self)
                if let value = element.value { parsed.append(value) }
            }
            models = parsed
        }
    }
}

extension LocalModelCatalog {

    /// Evidence behind an entry's claims.
    enum Evidence: String, Codable, Sendable, Equatable {
        /// The entry's fixtures have been run on a physical device: it loads, holds a conversation,
        /// survives a long prompt, cancels cleanly, and — where badged — produces tool calls.
        case deviceVerified
        /// The bytes are pinned and verified, and the file's own GGUF metadata was read at that
        /// revision, but nothing has run it on hardware. Such an entry ships as a text model with
        /// no capability badges beyond `.text`.
        case fileMetadataOnly
    }

    /// A curated GGUF model.
    struct GGUFEntry: Equatable, Sendable, Identifiable {
        let descriptor: LocalModelDescriptor
        /// Picker copy.
        let notes: String
        /// Minimum device RAM (GB) to offer this model. 0 = no restriction.
        let minimumRAMGB: Double
        /// `general.architecture` as read from the file at the pinned revision. A fact about the
        /// bytes, not a guess from the name — and never a substitute for what the runtime reads at
        /// load time.
        let architecture: String?
        /// `<arch>.context_length` from the same read. Recorded so the difference between what the
        /// model was trained for and what this app is willing to allocate is visible.
        let trainedContextTokens: Int?
        let evidence: Evidence

        var id: LocalModelID { descriptor.id }
    }

    /// Why an entry may not ship. Nil means it may.
    static func validationError(for entry: GGUFEntry) -> String? {
        let descriptor = entry.descriptor
        guard descriptor.runtime == .llamaCpp else { return "runtime is not llamaCpp" }
        let faults = descriptor.installationFaults()
        guard faults.isEmpty else {
            return "not installable: " + faults.map { String(describing: $0) }.joined(separator: ", ")
        }
        guard descriptor.contextLength > 0 else { return "context length must be positive" }
        guard descriptor.estimatedWeightsBytes > 0 else { return "weights size must be positive" }
        if entry.evidence != .deviceVerified {
            // The plan's rule, enforced by construction rather than by review discipline.
            let badged = descriptor.capabilities.subtracting([.text])
            guard badged.isEmpty else {
                return "claims \(badged.map(\.rawValue).sorted().joined(separator: ", "))"
                    + " without device evidence"
            }
        }
        if descriptor.license.requiresAcceptance && descriptor.license.revision == nil {
            return "licence requires acceptance but names no revision to accept"
        }
        return nil
    }

    /// The catalog shipped in the app bundle. Empty when the resource is absent or unreadable —
    /// callers fall back to the import path, exactly as the MCP catalogue does.
    static func bundledGGUFDocument(_ bundle: Bundle = .main) -> LocalModelCatalogDocument? {
        guard let url = bundle.url(forResource: LocalModelCatalogDocument.resourceName,
                                   withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? LocalModelCatalogDocument.load(from: data)
    }

    static func bundledGGUFEntries(_ bundle: Bundle = .main) -> [GGUFEntry] {
        bundledGGUFDocument(bundle)?.entries ?? []
    }

    /// JSON shape, kept separate from the domain type so the file format can gain a field without
    /// the runtime type gaining an optional.
    struct RawGGUFEntry: Decodable {
        let id: String
        let displayName: String
        let repositoryID: String
        let revision: String
        let quantization: String?
        let capabilities: [String]?
        let contextLength: Int
        let estimatedWeightsBytes: Int64?
        let estimatedWorkingBytes: Int64?
        let minimumHeadroomBytes: Int64?
        let files: [RawFile]
        let license: RawLicense?
        let notes: String?
        let minimumRAMGB: Double?
        let architecture: String?
        let trainedContextTokens: Int?
        let evidence: String?

        struct RawFile: Decodable {
            let relativePath: String
            let byteCount: Int64
            let sha256: String
            let role: String?
        }

        struct RawLicense: Decodable {
            let displayName: String
            let summary: String
            let requiresAcceptance: Bool?
            let revision: String?
        }

        var entry: GGUFEntry {
            let files = self.files.map {
                LocalModelFile(relativePath: $0.relativePath,
                               byteCount: $0.byteCount,
                               sha256: $0.sha256.lowercased(),
                               role: LocalModelFile.Role(rawValue: $0.role ?? "weights") ?? .weights)
            }
            // Unknown capability strings are dropped rather than kept: a badge this build cannot
            // honour must not survive into a descriptor.
            let declared = Set((capabilities ?? ["text"]).compactMap(LocalModelCapability.init(rawValue:)))
            let weights = estimatedWeightsBytes ?? files.filter { $0.role == .weights }
                .reduce(Int64(0)) { $0 + $1.byteCount }
            let license = self.license.map {
                LocalModelLicenseSummary(displayName: $0.displayName,
                                         summary: $0.summary,
                                         requiresAcceptance: $0.requiresAcceptance ?? false,
                                         revision: $0.revision)
            } ?? .unverified
            let descriptor = LocalModelDescriptor(
                id: LocalModelID(id),
                displayName: displayName,
                runtime: .llamaCpp,
                repositoryID: repositoryID,
                revision: revision,
                files: files,
                quantization: quantization,
                capabilities: declared.isEmpty ? [.text] : declared,
                contextLength: contextLength,
                estimatedWeightsBytes: weights,
                estimatedWorkingBytes: estimatedWorkingBytes
                    ?? LocalModelBudget.workingSetBytes(for: .llamaCpp),
                minimumHeadroomBytes: minimumHeadroomBytes ?? 0,
                license: license)
            return GGUFEntry(descriptor: descriptor,
                             notes: notes ?? "",
                             minimumRAMGB: minimumRAMGB ?? 0,
                             architecture: architecture,
                             trainedContextTokens: trainedContextTokens,
                             evidence: Evidence(rawValue: evidence ?? "") ?? .fileMetadataOnly)
        }
    }
}
