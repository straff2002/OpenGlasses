import Foundation

/// Describes a single knowledge vault that grounds the LLM with domain-specific markdown content.
///
/// Vaults are the foundation of the Field Assist feature (refrigeration, IT, electrical, automotive)
/// and the Personal Health Vault. Each vault ships as a directory of markdown files + this manifest.
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

    enum CodingKeys: String, CodingKey {
        case id, name, version, files
        case proceduresDir = "procedures_dir"
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
        self.gating = gating
        self.promptRules = promptRules
        self.sourceAttributionFormat = sourceAttributionFormat
        self.sourceAttributionRequired = sourceAttributionRequired
    }
}
