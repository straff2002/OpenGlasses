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
    /// Whether the folder this manifest describes actually contains the files `documents` lists.
    ///
    /// False only in an **export**: manuals never leave the phone through the app (Plan FS), so an
    /// exported vault still declares the manuals it needs — they are part of what the vault *is* —
    /// while the files stay behind. Absent means true, so every manifest authored before the rule
    /// existed reads exactly as it did. An import normalises it back to true once the files are
    /// there, which is the only state an installed vault can be in.
    let documentsIncluded: Bool
    /// Gating that controls whether this vault is unlocked for the current user.
    let gating: Gating
    /// Rules prepended to the system prompt when this vault is active.
    let promptRules: [String]
    /// Required source-citation suffix template (uses `{files}` placeholder).
    /// When nil, source attribution is encouraged but not required.
    let sourceAttributionFormat: String?
    /// When true, the prompt explicitly instructs the model to refuse answering without a citation.
    let sourceAttributionRequired: Bool
    /// The trades this vault is for (`refrigeration_hvac`, `electrical`), as the author wrote them.
    /// Optional: absent means the vault says nothing, and the technician's or the organisation's
    /// choice decides which trade tiles Field Assist shows. Kept as written, so an export carries a
    /// value this build does not know; `FieldTrade.known(_:)` reads it and ignores what it does not
    /// recognise rather than refusing the manifest.
    let trades: [String]?
    /// Site documents (Plan HV): JSON files under `sites/`, one per site, each describing how the
    /// units at one site are connected and controlled. Not core and not reference: never loaded
    /// into every turn and never retrieved by similarity — the job picks the one site it is at.
    /// Nil, and absent from the JSON, on every vault without them, so such a manifest encodes
    /// exactly as it did; an older build ignores the key and installs the rest unchanged.
    let sites: [String]?
    /// Plan KE: `"vault_only": true` seals a job on this vault to the vault's own content
    /// (`VaultOnlyPolicy`): no web search, no MCP server, no gateway. It is the vault's rule, so it
    /// travels with the vault and survives an export. Nil, and absent from the JSON, on every vault
    /// that does not set it, so such a manifest encodes exactly as it did. An older build ignores
    /// the key, which is why a sealed vault states the build it needs.
    let vaultOnly: Bool?

    struct Gating: Codable, Equatable {
        /// IAP product identifier required to unlock this vault. Nil = free.
        let iap: String?
    }

    /// Whether this vault declares a reference tier at all.
    var hasDocuments: Bool { !documents.isEmpty }

    /// This manifest as an export states it: the manuals stay listed, because the vault still
    /// requires them, but the folder does not carry the files. A manifest with no manuals is
    /// returned unchanged — there is nothing to leave out.
    func markingDocumentsNotIncluded() -> VaultManifest {
        hasDocuments ? copy(documentsIncluded: false) : self
    }

    /// This manifest as an installed vault states it: the files are present. Called after
    /// validation has confirmed exactly that.
    func markingDocumentsIncluded() -> VaultManifest {
        documentsIncluded ? self : copy(documentsIncluded: true)
    }

    private func copy(documentsIncluded: Bool) -> VaultManifest {
        VaultManifest(id: id, name: name, version: version, files: files,
                      proceduresDir: proceduresDir, documentsDir: documentsDir,
                      documents: documents, documentsIncluded: documentsIncluded,
                      gating: gating, promptRules: promptRules,
                      sourceAttributionFormat: sourceAttributionFormat,
                      sourceAttributionRequired: sourceAttributionRequired, trades: trades,
                      sites: sites, vaultOnly: vaultOnly)
    }

    /// Location of a document relative to the vault root.
    func documentRelativePath(_ document: VaultDocument) -> String {
        if let dir = documentsDir, !dir.isEmpty { return "\(dir)/\(document.file)" }
        return document.file
    }

    /// Location of a document's bundled original relative to the vault root, or nil when it has none.
    func documentSourceRelativePath(_ document: VaultDocument) -> String? {
        guard let source = document.source, !source.isEmpty else { return nil }
        if let dir = documentsDir, !dir.isEmpty { return "\(dir)/\(source)" }
        return source
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, files, documents
        case documentsIncluded = "documents_included"
        case proceduresDir = "procedures_dir"
        case documentsDir = "documents_dir"
        case gating
        case promptRules = "prompt_rules"
        case sourceAttributionFormat = "source_attribution_format"
        case sourceAttributionRequired = "source_attribution_required"
        case trades
        case sites
        case vaultOnly = "vault_only"
    }

    init(
        id: String,
        name: String,
        version: String,
        files: [String],
        proceduresDir: String? = nil,
        documentsDir: String? = nil,
        documents: [VaultDocument] = [],
        documentsIncluded: Bool = true,
        gating: Gating = Gating(iap: nil),
        promptRules: [String] = [],
        sourceAttributionFormat: String? = "Source: {files}",
        sourceAttributionRequired: Bool = true,
        trades: [String]? = nil,
        sites: [String]? = nil,
        vaultOnly: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.files = files
        self.proceduresDir = proceduresDir
        self.documentsDir = documentsDir
        self.documents = documents
        self.documentsIncluded = documentsIncluded
        self.gating = gating
        self.promptRules = promptRules
        self.sourceAttributionFormat = sourceAttributionFormat
        self.sourceAttributionRequired = sourceAttributionRequired
        self.trades = trades
        self.sites = sites
        self.vaultOnly = vaultOnly
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
        documentsIncluded = try c.decodeIfPresent(Bool.self, forKey: .documentsIncluded) ?? true
        gating = try c.decodeIfPresent(Gating.self, forKey: .gating) ?? Gating(iap: nil)
        promptRules = try c.decodeIfPresent([String].self, forKey: .promptRules) ?? []
        sourceAttributionFormat = try c.decodeIfPresent(String.self, forKey: .sourceAttributionFormat)
        sourceAttributionRequired = try c.decodeIfPresent(Bool.self, forKey: .sourceAttributionRequired) ?? true
        // A malformed `trades` (not a list of strings) is ignored like an unknown value, never a
        // refused manifest: it only chooses tiles.
        trades = (try? c.decodeIfPresent([String].self, forKey: .trades)) ?? nil
        // Unlike `trades`, a malformed `sites` refuses the manifest: it names files to install.
        sites = try c.decodeIfPresent([String].self, forKey: .sites)
        // A malformed `vault_only` refuses the manifest too: read as false, a seal the author asked
        // for would silently not be there.
        vaultOnly = try c.decodeIfPresent(Bool.self, forKey: .vaultOnly)
    }

    /// The site documents this vault lists; empty for every vault without them.
    var siteFiles: [String] { sites ?? [] }

    /// Whether a job on this vault is sealed to it (Plan KE). Absent and false read the same.
    var isVaultOnly: Bool { vaultOnly == true }

    var isPersonalLibrary: Bool { gating.iap == "my_manuals" || id == "my-manuals" }

    /// Document bytes and page mapping only; never professional manifest behaviour.
    var personalProjection: VaultManifest {
        VaultManifest(id: id.hasPrefix("personal-") ? id : "personal-" + id, name: name, version: version, files: [], documentsDir: documentsDir,
            documents: documents.map { VaultDocument(file: $0.file, title: $0.title, source: $0.source, personalReadingCopy: $0.personalReadingCopy) },
            gating: .init(iap: "my_manuals"))
    }
}

/// One reference-tier document declared by a vault manifest.
struct VaultDocument: Codable, Equatable {
    /// App-written provenance for a personal-library scan; never a job/Office capture claim.
    let personalCapture: Bool?
    /// Source is an app-generated text reading PDF; file retains the uploaded original.
    let personalReadingCopy: Bool?
    /// File name inside `documents_dir` (or the vault root). PDF, EPUB, Markdown, or plain text.
    let file: String
    /// The name the technician hears in a citation ("RTU-500 Service Manual").
    let title: String
    /// Free-text classification ("service_manual", "wiring", "install_guide"); informational.
    let kind: String?
    /// The manufacturer's own PDF, beside the extracted text this document was made from — a file
    /// name inside the same `documents_dir` (Plan EK P3).
    ///
    /// It is copied at install and hashed in the ledger but **never indexed**: the text is what is
    /// searched, so an author's corrections to it still count. What the original buys is the page
    /// itself — a technician following a manufacturer's SOP has to be able to see the page the
    /// answer came from, in the manufacturer's document, not only a transcription of it.
    let source: String?
    /// Where the manufacturer publishes this manual. Opened outside the app, so it is a link and
    /// never a substitute for the bundled original.
    let sourceUrl: String?
    let capturedManual: CapturedManualReview?
    /// Which edition or revision of its work this document is ("2024", "Rev C", "3rd edition"),
    /// when the vault holds more than one (Plan IV P2; the field Plan IN P3 names). The newest
    /// edition answers by default and an older one only when asked for — see `DocumentEditions`.
    /// Optional: two documents whose titles differ only by a year are recognised without it.
    let edition: String?

    init(file: String, title: String, kind: String? = nil,
         source: String? = nil, sourceUrl: String? = nil, capturedManual: CapturedManualReview? = nil,
         edition: String? = nil, personalCapture: Bool? = nil, personalReadingCopy: Bool? = nil) {
        self.personalCapture = personalCapture
        self.personalReadingCopy = personalReadingCopy
        self.file = file
        self.title = title
        self.kind = kind
        self.source = source
        self.sourceUrl = sourceUrl
        self.capturedManual = capturedManual
        self.edition = edition
    }

    enum CodingKeys: String, CodingKey {
        case file, title, kind, source, edition, personalCapture, personalReadingCopy
        case sourceUrl = "source_url"
        case capturedManual = "captured_manual"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        personalCapture = try c.decodeIfPresent(Bool.self, forKey: .personalCapture)
        personalReadingCopy = try c.decodeIfPresent(Bool.self, forKey: .personalReadingCopy)
        file = try c.decode(String.self,forKey:.file);title = try c.decode(String.self,forKey:.title)
        kind = try c.decodeIfPresent(String.self,forKey:.kind);source = try c.decodeIfPresent(String.self,forKey:.source)
        sourceUrl = try c.decodeIfPresent(String.self,forKey:.sourceUrl)
        edition = try c.decodeIfPresent(String.self, forKey: .edition)
        capturedManual = c.contains(.capturedManual) ? try c.decode(CapturedManualReview.self,forKey:.capturedManual) : nil
        if let review = capturedManual, !review.valid {
            throw DecodingError.dataCorruptedError(forKey:.capturedManual,in:c,debugDescription:"Invalid photographed-manual review metadata")
        }
    }

    /// Persisted only after the signed archive and Office assignment have both verified. Binds
    /// approval/origins to this document's exact text and physical PDF, including title changes.
    func capturedBinding(text: Data, pdf: Data) throws -> String {
        guard let review = capturedManual,review.valid,
              text.count <= CapturedManualContract.maximumTextBytes,pdf.count <= CapturedManualContract.maximumPDFBytes,
              source?.lowercased().hasSuffix(".pdf") == true,!isPDF else {throw CapturedManualStore.Failure.invalidRequest}
        _ = try review.pageTexts(text)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return CapturedManualContract.digest(try encoder.encode(self) + Data(CapturedManualContract.digest(text).utf8) + Data(CapturedManualContract.digest(pdf).utf8))
    }

    /// Whether this document is itself the manufacturer's PDF (rather than text extracted from one).
    var isPDF: Bool { file.lowercased().hasSuffix(".pdf") }
}
