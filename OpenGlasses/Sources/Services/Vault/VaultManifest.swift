import Foundation

/// Describes a single knowledge vault that grounds the LLM with domain-specific markdown content.
///
/// Vaults are the foundation of the Field Assist feature (refrigeration, IT, electrical, automotive)
/// and the Personal Health Vault. Each vault ships as a directory of markdown files + this manifest.
///
/// Two tiers of content:
/// - **Core** (`files`): curated markdown loaded whole into the system prompt on every turn.
/// - **Reference** (`documents`): whole documents (OEM manuals, wiring guides) that are chunked and
///   embedded on-device at import and *retrieved* per turn, so a 300-page manual costs nothing until
///   a passage from it is relevant. See `VaultRetriever`.
struct VaultManifest: Codable, Equatable {
    /// Stable identifier ("refrigeration", "health", "it_network").
    let id: String
    /// User-facing name ("Refrigeration Service").
    let name: String
    /// Semantic version of this vault content.
    let version: String
    /// Markdown files that make up the vault content. Order matters — used in prompt assembly.
    let files: [String]
    /// Optional folder (relative to vault root) containing procedure JSON definitions.
    let proceduresDir: String?
    /// Optional folder (relative to vault root) containing the reference documents. When nil,
    /// document files are resolved against the vault root.
    let documentsDir: String?
    /// Reference-tier documents, retrieved per turn rather than loaded whole. Empty for a
    /// markdown-only vault (every vault before this field existed).
    let documents: [VaultDocument]
    /// Gating that controls whether this vault is unlocked for the current user.
    let gating: Gating
    /// Rules prepended to the system prompt when this vault is active.
    let promptRules: [String]
    /// Required source-citation suffix template (uses `{files}` placeholder).
    /// When nil, source attribution is encouraged but not required.
    let sourceAttributionFormat: String?
    /// When true, the prompt explicitly instructs the model to refuse answering without a citation.
    let sourceAttributionRequired: Bool

    struct Gating: Codable, Equatable {
        /// IAP product identifier required to unlock this vault. Nil = free.
        let iap: String?
    }

    /// Whether this vault declares a reference tier at all.
    var hasDocuments: Bool { !documents.isEmpty }

    /// Location of a document relative to the vault root.
    func documentRelativePath(_ document: VaultDocument) -> String {
        if let dir = documentsDir, !dir.isEmpty { return "\(dir)/\(document.file)" }
        return document.file
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, files, documents
        case proceduresDir = "procedures_dir"
        case documentsDir = "documents_dir"
        case gating
        case promptRules = "prompt_rules"
        case sourceAttributionFormat = "source_attribution_format"
        case sourceAttributionRequired = "source_attribution_required"
    }

    init(
        id: String,
        name: String,
        version: String,
        files: [String],
        proceduresDir: String? = nil,
        documentsDir: String? = nil,
        documents: [VaultDocument] = [],
        gating: Gating = Gating(iap: nil),
        promptRules: [String] = [],
        sourceAttributionFormat: String? = "Source: {files}",
        sourceAttributionRequired: Bool = true
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.files = files
        self.proceduresDir = proceduresDir
        self.documentsDir = documentsDir
        self.documents = documents
        self.gating = gating
        self.promptRules = promptRules
        self.sourceAttributionFormat = sourceAttributionFormat
        self.sourceAttributionRequired = sourceAttributionRequired
    }

    /// Hand-written so every manifest authored before the reference tier existed — and every
    /// hand-authored manifest that omits an optional key — still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        proceduresDir = try c.decodeIfPresent(String.self, forKey: .proceduresDir)
        documentsDir = try c.decodeIfPresent(String.self, forKey: .documentsDir)
        documents = try c.decodeIfPresent([VaultDocument].self, forKey: .documents) ?? []
        gating = try c.decodeIfPresent(Gating.self, forKey: .gating) ?? Gating(iap: nil)
        promptRules = try c.decodeIfPresent([String].self, forKey: .promptRules) ?? []
        sourceAttributionFormat = try c.decodeIfPresent(String.self, forKey: .sourceAttributionFormat)
        sourceAttributionRequired = try c.decodeIfPresent(Bool.self, forKey: .sourceAttributionRequired) ?? true
    }
}

/// One reference-tier document declared by a vault manifest.
struct VaultDocument: Codable, Equatable {
    /// File name inside `documents_dir` (or the vault root). PDF, EPUB, Markdown, or plain text.
    let file: String
    /// The name the technician hears in a citation ("RTU-500 Service Manual").
    let title: String
    /// Free-text classification ("service_manual", "wiring", "install_guide"); informational.
    let kind: String?

    init(file: String, title: String, kind: String? = nil) {
        self.file = file
        self.title = title
        self.kind = kind
    }
}
