import Foundation

/// Equipment lookup for Field Assist: finds an error code, fault, or model number in the active
/// vault (error codes, manufacturer specs) and returns the matching reference section with its
/// source file, grounding the AI's diagnosis in the vault instead of free recall.
///
/// Two input paths:
///   - **Voice-first** (default): the technician reads the code/model aloud → `query`.
///   - **OCR** (when a camera is available and no `query` is given, or `use_camera` is set): the
///     nameplate/error display is read on-device via `OCRService`; candidate code/model tokens are
///     extracted and searched. Images never leave the device.
@MainActor
final class EquipmentLookupTool: NativeTool {
    let name = "equipment_lookup"
    let description = """
    Look up an equipment error code, fault, or model number in the active Field Assist vault. The \
    technician can read the code/model aloud (pass 'query'), or point the glasses at the nameplate / \
    error display and omit 'query' (or set 'use_camera') to read it via on-device OCR. Returns the \
    matching reference section with its source file. Use before diagnosing so the answer is grounded. \
    When a lookup or a nameplate read names exactly one model the vault covers, that model becomes \
    the session's active equipment and every later answer is scoped to it — say so to the \
    technician. Pass 'set_equipment' with a model or part of one to correct a wrong read ("no, it's \
    the 070"), or 'clear_equipment' to forget it. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "The error code, fault, or model to look up (e.g. 'E5', 'Carrier 30RB'). Omit to read it from the camera."
            ],
            "use_camera": [
                "type": "boolean",
                "description": "Force reading the code/model from the glasses camera via OCR even if a query is given."
            ],
            "file": [
                "type": "string",
                "description": "Optional: restrict the search to a single vault file (e.g. 'error_codes.md')."
            ],
            "set_equipment": [
                "type": "string",
                "description": "Set the session's active equipment to this model (a full model number or part of one, e.g. '070'). Use when the technician corrects a nameplate read."
            ],
            "clear_equipment": [
                "type": "boolean",
                "description": "Forget the session's active equipment."
            ]
        ],
        "required": [] as [String]
    ]

    /// Files searched first, in priority order. Remaining vault files are searched after these.
    private static let priorityFiles = ["error_codes.md", "manufacturers.md"]

    private let cameraService: CameraService?
    private let ocr: OCRService
    /// Reference-tier fall-through: a code that lives only in an imported manual resolves here
    /// after the markdown core misses. Nil when no store was wired (headless contexts).
    private let documentStore: DocumentStore?
    /// Session to read the active vault from; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?

    init(cameraService: CameraService? = nil, ocr: OCRService = OCRService(),
         documentStore: DocumentStore? = nil, sessionService: FieldSessionService? = nil) {
        self.cameraService = cameraService
        self.ocr = ocr
        self.documentStore = documentStore
        self.injectedSession = sessionService
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to search its vault."
        }

        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceCamera = (args["use_camera"] as? Bool) ?? false
        let restrictTo = args["file"] as? String

        // Corrections first: they are what the technician says when the last read was wrong, and
        // they must not be treated as a question about a machine.
        if (args["clear_equipment"] as? Bool) == true {
            let previous = session.activeEquipment?.modelToken
            session.clearEquipment()
            return previous.map { "Cleared the active equipment (was \($0))." }
                ?? "No active equipment was set."
        }
        if let fragment = (args["set_equipment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fragment.isEmpty {
            return setEquipment(fragment: fragment)
        }

        // Camera/OCR path when requested, or when no spoken query was provided.
        if (forceCamera || query == nil || query?.isEmpty == true) {
            guard cameraService != nil else {
                return "Specify what to look up (an error code, fault, or model number)."
            }
            return await lookupViaCamera(store: store, restrictTo: restrictTo)
        }

        let recognised = recogniseEquipment(in: query!, source: .spoken)
        if let ambiguous = recognised.ambiguity { return ambiguous }
        let prefix = recognised.announcement.map { $0 + "\n\n" } ?? ""

        if let hit = search(query: query!, store: store, restrictTo: restrictTo) { return prefix + hit }
        if let manual = manualFallback(query: query!, ocrText: nil, store: store) { return prefix + manual }
        if let sentence = session.equipmentScope(turn: query!).refusalSentence { return sentence }
        return "No vault entry found for '\(query!)' in the \(store.manifest.name). Ask the technician for more detail, or recommend escalation rather than guessing."
    }

    // MARK: - Equipment identity (Plan EL)

    /// Recognition with memory: a query or a nameplate read that names exactly one of the vault's
    /// models sets the session's active equipment. Several models is not an identification — the
    /// technician is asked which, because guessing here poisons every answer that follows.
    private func recogniseEquipment(in text: String, source: EquipmentIdentity.Source,
                                    nameplateText: String? = nil) -> (announcement: String?, ambiguity: String?) {
        let index = session.modelIndex
        guard !index.isEmpty else { return (nil, nil) }
        let matches = index.match(text: text)
        guard !matches.isEmpty else { return (nil, nil) }
        guard matches.count == 1 else {
            let names = matches.map(\.name).joined(separator: ", ")
            return (nil, "That reads as more than one model: \(names). Which one is it?")
        }
        let model = matches[0]
        if session.activeEquipment?.heading == model.heading { return (nil, nil) }
        let identity = EquipmentIdentity(model: model, token: model.name, source: source,
                                         nameplateText: nameplateText)
        session.setEquipment(identity)
        return (identity.announcement, nil)
    }

    /// "No, it's the 070" — a fragment, matched as a substring of any spelling the vault lists.
    private func setEquipment(fragment: String) -> String {
        let index = session.modelIndex
        guard !index.isEmpty else {
            return "The \(session.activeVault?.manifest.name ?? "active") vault does not list models, so there is no equipment to set."
        }
        let matches = index.match(fragment: fragment)
        guard let model = matches.first, matches.count == 1 else {
            if matches.isEmpty {
                return index.scopeSentence(unknown: fragment)
            }
            return "'\(fragment)' matches \(matches.map(\.name).joined(separator: ", ")). Which one is it?"
        }
        let identity = EquipmentIdentity(model: model, token: model.name, source: .spoken)
        session.setEquipment(identity)
        return identity.announcement + "\n\n=== \(model.file) ===\n\(model.heading)"
    }

    // MARK: - Reference-tier fall-through

    /// Search the vault's imported manuals when the markdown core has nothing. Returns nil when the
    /// vault has no reference tier, nothing is ingested, or the evidence gate says insufficient —
    /// the caller's own miss message is the right answer then.
    private func manualFallback(query: String?, ocrText: String?, store: VaultStore) -> String? {
        guard store.manifest.hasDocuments, let documentStore else { return nil }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else { return nil }
        let retriever = VaultRetriever(query: { q, limit in
            documentStore.query(q, limit: limit, namespace: namespace)
        }, tokenSearch: { token, limit in
            documentStore.passages(containingToken: token, namespace: namespace, limit: limit)
        }, provenance: { documentId in
            documentStore.list(namespace: namespace).first { $0.id == documentId }?.sourceType == VaultImporter.recognisedSourceType
        }, policy: session.retrievalPolicy, modelScope: session.retrievalModelScope)
        let outcome = retriever.retrieve(.init(turn: query, ocrText: ocrText, limit: 3))
        guard outcome.isSufficient else { return nil }
        return VaultRetriever.toolResult(outcome, query: query ?? "the label")
    }

    // MARK: - Camera path

    private func lookupViaCamera(store: VaultStore, restrictTo: String?) async -> String {
        guard let cameraService else {
            return "Camera not available. Ask the technician to read the code aloud."
        }
        let data: Data?
        if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.9) {
            data = jpeg
        } else {
            data = try? await cameraService.capturePhoto()
        }
        guard let data else {
            return "Could not capture an image. Ask the technician to read the code aloud."
        }
        let ocrText = await ocr.recognizeText(in: data).text
        guard !ocrText.isEmpty else {
            return "I couldn't read any text on the label. Try moving closer or improving the lighting, or read the code aloud."
        }

        let label = "Read from the label: \(ocrText.replacingOccurrences(of: "\n", with: " "))\n\n"

        // The nameplate is the strongest identification there is, so this is where the session
        // learns what it is standing in front of.
        let recognised = recogniseEquipment(in: ocrText, source: .nameplate, nameplateText: ocrText)
        if let ambiguous = recognised.ambiguity { return label + ambiguous }

        // Search each plausible code/model token from the OCR text, the recognised model first —
        // a nameplate's model number is longer than the generic token screen allows for.
        var matches: [(file: String, section: String)] = []
        var tokens = candidateTokens(from: ocrText)
        if let active = session.activeEquipment { tokens.insert(active.modelToken, at: 0) }
        for token in tokens {
            if let result = searchMatches(query: token, store: store, restrictTo: restrictTo) {
                matches.append(contentsOf: result)
                if matches.count >= 3 { break }
            }
        }

        if matches.isEmpty {
            if let manual = manualFallback(query: nil, ocrText: ocrText, store: store) {
                return label + manual
            }
            if let sentence = session.equipmentScope(turn: nil, nameplateText: ocrText).refusalSentence {
                return label + sentence
            }
            return "Read this from the label via camera:\n\(ocrText)\n\n[No exact vault match. Identify the code/model from the text above and look it up, or ask the technician to confirm.]"
        }
        return render(Array(matches.prefix(3)), prefix: label + (recognised.announcement.map { $0 + "\n\n" } ?? ""))
    }

    /// Plausible code/model tokens from OCR text — shared with manual retrieval via `CodeTokenizer`
    /// so both agree on what a code looks like. Kept as an instance method for existing callers.
    func candidateTokens(from text: String) -> [String] {
        CodeTokenizer.candidateTokens(from: text)
    }

    // MARK: - Search

    private func search(query: String, store: VaultStore, restrictTo: String?) -> String? {
        guard let matches = searchMatches(query: query, store: store, restrictTo: restrictTo) else { return nil }
        return render(matches, prefix: "")
    }

    /// At most three `##` sections, in vault file priority order. For a code-like query the
    /// section *titled* with the code comes first: a model number is usually also mentioned in an
    /// introduction or a summary table, and in plain file order those mentions push the model's own
    /// section past the cap.
    private func searchMatches(query: String, store: VaultStore, restrictTo: String?) -> [(file: String, section: String)]? {
        let orderedFiles = orderedSearchFiles(manifestFiles: store.manifest.files, restrictTo: restrictTo)
        let preferTitled = CodeTokenizer.isCodeLike(query)
        var titled: [(file: String, section: String)] = []
        var mentions: [(file: String, section: String)] = []
        for filename in orderedFiles {
            guard let contents = store.read(filename) else { continue }
            for match in matchingSections(in: contents, query: query) {
                if preferTitled && match.inHeading {
                    titled.append((filename, match.section))
                } else {
                    mentions.append((filename, match.section))
                }
            }
            if titled.count >= 3 || (!preferTitled && mentions.count >= 3) { break }
        }
        // With a machine identified, its own section leads: the same spelling appears in a summary
        // table and in half a dozen other models' rows, and the cap is three.
        var ordered = titled + mentions
        if let active = session.activeEquipment {
            let activeFirst = ordered.filter { $0.section.contains(active.heading) }
            ordered = activeFirst + ordered.filter { !$0.section.contains(active.heading) }
        }
        let matches = Array(ordered.prefix(3))
        return matches.isEmpty ? nil : matches
    }

    private func render(_ matches: [(file: String, section: String)], prefix: String) -> String {
        let rendered = matches.map { "=== \($0.file) ===\n\($0.section)" }.joined(separator: "\n\n")
        let citation = Set(matches.map { $0.file }).sorted().joined(separator: ", ")
        return "\(prefix)\(rendered)\n\n(Source: \(citation))"
    }

    private func orderedSearchFiles(manifestFiles: [String], restrictTo: String?) -> [String] {
        if let restrictTo { return [restrictTo] }
        let priority = Self.priorityFiles.filter { manifestFiles.contains($0) }
        let rest = manifestFiles.filter { !priority.contains($0) }
        return priority + rest
    }

    /// Split markdown into sections by `##`/`###` headings and return sections whose heading or body
    /// contains the query (case-insensitive), each flagged with whether the match was in the
    /// section's own heading line. Matching is token-aware so "E5" doesn't match "E50".
    private func matchingSections(in markdown: String, query: String) -> [(section: String, inHeading: Bool)] {
        let lowerQuery = query.lowercased()
        var sections: [String] = []
        var current: [String] = []

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { sections.append(joined) }
            current = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
            }
            current.append(String(line))
        }
        flush()

        return sections.compactMap { section in
            guard sectionMatches(section.lowercased(), query: lowerQuery) else { return nil }
            let heading = section.prefix { $0 != "\n" }
            let inHeading = (heading.hasPrefix("## ") || heading.hasPrefix("### "))
                && sectionMatches(heading.lowercased(), query: lowerQuery)
            return (section, inHeading)
        }
    }

    /// Contains check that rejects a match glued to a trailing alphanumeric, so a short code like
    /// "E5" doesn't match "E50". Checks every occurrence, not just the first.
    private func sectionMatches(_ haystack: String, query: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: query, range: searchStart..<haystack.endIndex) {
            let trailingOK: Bool
            if range.upperBound == haystack.endIndex {
                trailingOK = true
            } else {
                let after = haystack[range.upperBound]
                trailingOK = !(after.isLetter || after.isNumber)
            }
            if trailingOK { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
