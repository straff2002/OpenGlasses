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
    the 070"), or to record the model the technician says the unit in front of them is — including \
    one the manuals do not cover, which is still recorded as said. Pass 'serial' (and/or \
    'field_name' + 'field_value' for another nameplate field) when the technician reads one out, so \
    the record keeps it. Use 'clear_equipment' to forget the unit. Requires an active session.
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
            ],
            "serial": [
                "type": "string",
                "description": "The unit's serial number, exactly as the technician read it out."
            ],
            "field_name": [
                "type": "string",
                "description": "Another nameplate field the technician read out (e.g. 'firmware', 'refrigerant'). Pass with field_value."
            ],
            "field_value": [
                "type": "string",
                "description": "The value of field_name, exactly as read."
            ]
        ],
        "required": [] as [String]
    ]

    /// Files searched first, in priority order. Remaining vault files are searched after these.
    private static let priorityFiles = ["error_codes.md", "manufacturers.md"]

    private let cameraService: (any FilteredStillProviding)?
    private let ocr: OCRService
    /// Reference-tier fall-through: a code that lives only in an imported manual resolves here
    /// after the markdown core misses. Nil when no store was wired (headless contexts).
    private let documentStore: DocumentStore?
    /// Session to read the active vault from; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The guided job flow, when the app has one (Plan FO P1). Recognition goes through it so a
    /// machine that is not the one the job is on raises a question instead of silently re-scoping.
    private let flow: GuidedJobFlow?

    init(cameraService: (any FilteredStillProviding)? = nil, ocr: OCRService = OCRService(),
         documentStore: DocumentStore? = nil, sessionService: FieldSessionService? = nil,
         flow: GuidedJobFlow? = nil) {
        self.cameraService = cameraService
        self.ocr = ocr
        self.documentStore = documentStore
        self.injectedSession = sessionService
        self.flow = flow
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        // Plan GD2: an identification that attaches work already recorded says so, whichever of
        // this tool's routes made it (a spoken model, a nameplate read, a correction).
        let markerBefore = session.activeSession?.earlierWorkAttachedAt
        let reply = try await lookUp(args: args)
        return FieldSessionTool.withEarlierWorkNote(reply, markerBefore: markerBefore, service: session)
    }

    private func lookUp(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to search its vault."
        }

        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceCamera = (args["use_camera"] as? Bool) ?? false
        let restrictTo = args["file"] as? String

        // Nameplate fields the technician read out (Plan GB P2): written onto the unit before
        // anything else, because digits are where recognition fails quietly and a spoken serial is
        // the only thing that tells two identical machines apart.
        var recordedFields: [String] = []
        if let serial = (args["serial"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty, let field = session.recordIdentityField(name: "Serial", value: serial, source: .spoken) {
            session.recordSerialForActiveUnit(serial)
            recordedFields.append(field.summary)
        }
        if let name = args["field_name"] as? String, let value = args["field_value"] as? String,
           let field = session.recordIdentityField(name: name, value: value, source: .spoken) {
            recordedFields.append(field.summary)
        }
        let fieldsNote = recordedFields.isEmpty ? "" : "Recorded " + recordedFields.joined(separator: "; ") + ".\n\n"

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
            let answer = setEquipment(fragment: fragment)
            // The serial belongs to the unit as just stated, which may have only now been recorded.
            if let serial = args["serial"] as? String { session.recordSerialForActiveUnit(serial) }
            return fieldsNote + answer
        }
        if !recordedFields.isEmpty, query == nil || query?.isEmpty == true, !forceCamera {
            return String(fieldsNote.dropLast(2))
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
        if let sentence = session.equipmentScope(turn: query!).refusalSentence {
            // Naming a model is not the same as saying it is the machine in front of you. When it
            // is, the technician's statement is recorded as said (Plan GB P2).
            return sentence + " If this is the unit the technician is working on, record it with "
                + "set_equipment so the job keeps the model as they said it."
        }
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
        let identity = Self.identity(for: model, in: text, source: source, index: index,
                                     nameplateText: nameplateText)
        if session.activeEquipment?.heading == model.heading { return (nil, nil) }
        // Plan FO P1: this is the path where recognition *happens to* the session — a model number
        // said in passing, a nameplate the camera read. On a job that is already on a machine,
        // re-scoping silently leaves the previous job open and still billing, so the flow holds the
        // change and asks whether that job is finished. The correction path ("no, it's the 070")
        // and a tap on the phone's model list go straight to `setEquipment` below: those are the
        // technician saying which machine this is, and a question there would be arguing with them.
        if let flow {
            guard flow.proposeEquipment(.model(identity)) == nil else {
                // Held. The app puts the question itself at the end of the turn, so the model is
                // told what is happening rather than handed the question to relay.
                let current = session.activeEquipment?.modelToken ?? "the current unit"
                return ("\(identity.modelToken) is not \(current). The technician is being asked "
                        + "whether this job is finished or this is another unit on the same job; "
                        + "the session stays on \(current) until they answer. Do not ask or answer "
                        + "that question yourself.", nil)
            }
            return (Self.announcement(for: identity), nil)
        }
        session.setEquipment(identity)
        return (Self.announcement(for: identity), nil)
    }

    /// The identity to record for a model the text named (Plan GB P2). A spoken model keeps what
    /// was said beside the section it matched and how; a nameplate, a work order and a tap on the
    /// phone's list are the vault's own spelling, recorded as before.
    static func identity(for model: VaultModelIndex.Model, in text: String,
                         source: EquipmentIdentity.Source, index: VaultModelIndex,
                         nameplateText: String? = nil) -> EquipmentIdentity {
        guard source == .spoken,
              let stated = VaultModelIndex.modelLikeTokens(in: text)
                .filter({ index.resolve(token: $0).contains(model) })
                .max(by: { $0.count < $1.count }) else {
            return EquipmentIdentity(model: model, token: model.name, source: source,
                                     nameplateText: nameplateText)
        }
        let resolution = EquipmentRecognition.resolve(stated: stated, index: index)
        let kind = resolution.model == model ? (resolution.kind ?? .partial) : .partial
        return EquipmentIdentity(model: model, token: model.name, source: source,
                                 nameplateText: nameplateText, statedModel: stated,
                                 vaultMatch: .init(heading: model.heading, section: model.name, kind: kind))
    }

    /// What the tool says once it has recorded a unit. A near match is recorded as said and put to
    /// the technician as a question — the model asks it, once (Plan GB P2).
    static func announcement(for identity: EquipmentIdentity) -> String {
        guard identity.vaultMatch?.kind == .near, let section = identity.vaultSectionIfDifferent else {
            return identity.announcement
        }
        return "Recorded the unit as \(identity.stated), as the technician said it. The closest vault "
            + "section is \(section); answers use it. Ask the technician once: \"Did you mean \(section)?\" "
            + "If they confirm, call equipment_lookup with set_equipment '\(section)'; if not, leave it — "
            + "what they said is what the record keeps."
    }

    /// "No, it's the 070" — a fragment, matched as a substring of any spelling the vault lists — or
    /// "the model is SLP99UH090XV48C", a whole model number, resolved as stated (Plan GB P2). Either
    /// way it restates the unit the technician is on: same unit, same work, same "first
    /// recognised". A model the vault does not cover is recorded as said, not refused — the
    /// technician is the authority on what is in front of them.
    private func setEquipment(fragment: String) -> String {
        let index = session.modelIndex
        guard !index.isEmpty else {
            return "The \(session.activeVault?.manifest.name ?? "active") vault does not list models, so there is no equipment to set."
        }
        let wholeModel = EquipmentRecognition.normalised(fragment).count >= EquipmentRecognition.minimumNearLength
        let resolution = wholeModel ? EquipmentRecognition.resolve(stated: fragment, index: index) : .unmatched
        if resolution.model != nil {
            let identity = EquipmentRecognition.identity(stated: fragment, resolution: resolution, source: .spoken)
            let recorded = session.correctEquipment(identity)
            return Self.announcement(for: recorded)
                + "\n\n=== \(recorded.file) ===\n\(recorded.heading)"
        }
        let matches = index.match(fragment: fragment)
        if let model = matches.first, matches.count == 1 {
            let identity = EquipmentIdentity(
                model: model, token: model.name, source: .spoken,
                statedModel: wholeModel ? fragment : model.name,
                vaultMatch: .init(heading: model.heading, section: model.name, kind: .partial))
            let recorded = session.correctEquipment(identity)
            return recorded.announcement + "\n\n=== \(model.file) ===\n\(model.heading)"
        }
        if matches.count > 1 {
            return "'\(fragment)' matches \(matches.map(\.name).joined(separator: ", ")). Which one is it?"
        }
        guard VaultModelIndex.isModelLike(fragment) else { return index.scopeSentence(unknown: fragment) }
        let recorded = session.correctEquipment(
            EquipmentRecognition.identity(stated: fragment, resolution: .unmatched, source: .spoken))
        return recorded.announcement + " Recorded as the technician said it. Answers from these manuals "
            + "are for other models; say so when you use one."
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
        }, availability: VaultManualRemoval.availabilityCheck(forVault: store.manifest.id,
                                                              documentStore: documentStore),
        policy: session.retrievalPolicy, modelScope: session.retrievalModelScope)
        let outcome = retriever.retrieve(.init(turn: query, ocrText: ocrText, limit: 3))
        guard outcome.isSufficient else { return nil }
        return VaultRetriever.toolResult(outcome, query: query ?? "the label")
    }

    // MARK: - Camera path

    private func lookupViaCamera(store: VaultStore, restrictTo: String?) async -> String {
        guard let cameraService else {
            return "Camera not available. Ask the technician to read the code aloud."
        }
        // On-device OCR of the nameplate; the still never leaves (W04.1).
        let data = await cameraService.filteredStill(for: .onDeviceVision,
                                                    source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.9)
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
