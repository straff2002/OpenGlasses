import Foundation

/// Searches the OEM manuals imported into the active Field Assist vault (the reference tier) and
/// returns the relevant passages with machine-attached page citations — or the vault's fixed
/// insufficient-information sentence when nothing clears the evidence gate.
///
/// The per-turn prompt already carries passages for what the technician just said; this tool is
/// for follow-ups ("what does the manual say about the pressure switch?"), for widening a search
/// the model wants to run itself, and for reading a nameplate straight into a manual search.
@MainActor
final class ManualLookupTool: NativeTool {
    let name = "manual_lookup"
    let description = """
    Search the OEM manuals and code books loaded on this phone for a fault \
    code, model, component, procedure, or a clause or rule number (pass it as printed, e.g. \
    "clause 3.9.4.2", "rule 26-700", "section 110.26"). Pass 'query' with what to look for, or omit it (or set 'use_camera') \
    to read a nameplate / fault display through the camera (\(GlassesSupportPolicy.toolCameraSource)) and search on what it says. \
    Returns the matching manual passages, each with a Source line naming the manual and page — \
    cite those lines. If it reports that the manuals do not cover the question, or that they are \
    not for the machine the question names, say so verbatim rather than answering from general \
    knowledge. Write the query in the manual's own words — the part, procedure, table or rule as \
    the book would name it — rather than repeating the technician's phrasing; when a result offers \
    the book's index references or its nearest section headings, those are the words to search \
    with. Uses your loaded manuals, or the active Field Assist session. In a personal library, searches the manuals selected for this chat together. Omit document to search that set; name a manual to narrow it. If none are selected and the request is ambiguous, ask which manuals. Cite each book separately and explain any conflicting values. Camera lookup requires Field Assist. \
    Manuals may be in other languages, named in the manual list and the results. If a manual's \
    language differs from the question's, write query in that language; if the manuals searched \
    span more than one language, also pass queries with the question rewritten for each of them. \
    Answer in the wearer's language, citing the original page.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "What to look up in the manuals (a fault code, model number, component, clause number, or question)."
            ],
            "document": [
                "type": "string",
                "description": "Optional: restrict the search to one manual by title (substring match)."
            ],
            "use_camera": [
                "type": "boolean",
                "description": "Read the nameplate or fault display via the camera and search on it."
            ],
            "queries": [
                "type": "array",
                "description": "Optional: the question rewritten for manuals in other languages, one item per manual language.",
                "items": [
                    "type": "object",
                    "properties": [
                        "language": [
                            "type": "string",
                            "description": "The manual's language code as listed, e.g. zh-Hans, uk, ja."
                        ],
                        "query": [
                            "type": "string",
                            "description": "The question written in that language."
                        ]
                    ],
                    "required": ["language", "query"]
                ]
            ]
        ],
        "required": [] as [String]
    ]

    private let documentStore: DocumentStore?
    private let cameraService: (any FilteredStillProviding)?
    private let ocr: OCRService
    /// Session to read the active vault from; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The technician's words this turn. "What did the 2021 code say" asks for an older edition
    /// even when the model's query leaves the year out (Plan IV P2).
    private let currentUtterance: @MainActor () -> String?

    init(documentStore: DocumentStore?, cameraService: (any FilteredStillProviding)? = nil,
         ocr: OCRService = OCRService(),
         sessionService: FieldSessionService? = nil,
         currentUtterance: @escaping @MainActor () -> String? = { TechnicianWords.current() }) {
        self.documentStore = documentStore
        self.cameraService = cameraService
        self.ocr = ocr
        self.injectedSession = sessionService
        self.currentUtterance = currentUtterance
    }

    func execute(args: [String: Any]) async throws -> String {
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.lookup(args, documentStore: documentStore)
        }
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to search its manuals."
        }
        guard VaultRegistry.shared.isUnlocked(store.manifest) else { return MyManualsPaywallCopy.locked }
        // Published team learnings are searched beside the manuals (Plan FP P2), so a vault with
        // learnings and no manuals is still searchable; the messages below are for one with neither.
        let corpus = session.retrievableCorpus(store: store, documentStore: documentStore)
        guard store.manifest.hasDocuments || corpus.any else {
            return "The \(store.manifest.name) vault has no manuals. Its reference material is the vault core, which is already in context."
        }
        guard let documentStore else {
            return "Manual search is unavailable in this context."
        }
        guard corpus.any else {
            // Listed but not searchable: still being indexed, or never indexed — not "never
            // imported", which sent the model round five rephrasings of the same search.
            return ManualIndexAvailability.unsearchableSentence(for: store.manifest)
        }

        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceCamera = (args["use_camera"] as? Bool) ?? false
        let documentFilter = (args["document"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var ocrText: String?
        if forceCamera || query == nil || query?.isEmpty == true {
            guard let cameraService else {
                return "Specify what to look up in the manuals (a fault code, model, or component)."
            }
            // On-device OCR of a nameplate or fault code; the still never leaves (W04.1).
            let data = await cameraService.filteredStill(for: .onDeviceVision,
                                                        source: .cachedFrameThenPhoto)
                .jpegData(compressionQuality: 0.9)
            guard let data else { return "Could not capture an image. Ask the technician to read the code aloud." }
            let text = await ocr.recognizeText(in: data).text
            guard !text.isEmpty else {
                return "I couldn't read any text on the label. Try moving closer or improving the lighting, or read the code aloud."
            }
            ocrText = text
        }

        let documentIds = documentFilter.flatMap { filter -> [String]? in
            let needle = filter.lowercased()
            guard !needle.isEmpty else { return nil }
            let spaces = session.retrievalNamespaces(vaultId: store.manifest.id).filter { $0.source.isReference }
            let ids = spaces.flatMap { documentStore.list(namespace: $0.namespace) }
                .filter { $0.name.lowercased().contains(needle) }
                .map(\.id)
            return ids.isEmpty ? nil : ids
        }
        if let documentFilter, !documentFilter.isEmpty, documentIds == nil {
            let titles = session.retrievalNamespaces(vaultId: store.manifest.id).filter { $0.source.isReference }
                .flatMap { documentStore.list(namespace: $0.namespace) }.map { "\"\($0.name)\"" }.joined(separator: ", ")
            return "No manual titled like '\(documentFilter)'. Loaded manuals: \(titles)."
        }

        // A question about another manufacturer's machine cannot be answered from these manuals at
        // any similarity, so it is refused before the search rather than after it (Plan EL §3).
        if let sentence = session.equipmentScope(turn: query, nameplateText: ocrText).refusalSentence {
            return ocrText.map { "Read from the label: \($0.replacingOccurrences(of: "\n", with: " "))\n\n" + sentence }
                ?? sentence
        }

        // The shared factory: manuals and the vault's published team learnings, each tagged.
        // The newest edition unless the query or the technician's words reach past it. A
        // `document` the model passed is its own choice and is searched as named.
        let editionRequest = EditionRequest.parse([query, currentUtterance()].compactMap { $0 }.joined(separator: " "),
                                                  editions: session.documentEditions(of: store))
        let retriever = session.makeRetriever(store: store, documentStore: documentStore, documentIds: documentIds,
                                              editionRequest: editionRequest)
        // Manuals in more than one language: once per language, each with the model's rewrite for
        // it (Plan JY P2). One language: today's search, with its rewrite when one was passed.
        let rewrites = ManualLanguageSearch.Rewrites(args["queries"])
        let search = session.retrieveByLanguage(.init(turn: query, ocrText: ocrText, procedureStep: nil),
                                                with: retriever, store: store, documentIds: documentIds,
                                                editionRequest: editionRequest, rewrites: rewrites)
        let outcome = search.outcome
        let disclosure = session.noteRetrieval(outcome)
        // What "show me the page" opens next, until an answer that cites replaces it (Plan IN P2).
        if outcome.answers {
            session.sourceCenter.noteLookup(outcome.passages, sessionId: session.activeSession?.id)
        }
        let label = query.flatMap { $0.isEmpty ? nil : $0 } ?? "what the label says"
        var result = VaultRetriever.toolResult(outcome, query: label, leadIn: disclosure?.leadIn)
        // The book's way in (Plan IV P5): what its own index names for these words, when a manual
        // has one and the passages don't already carry it; and on a first miss, the headings of
        // the nearest sections, so the one retry #763 allows is in the book's terms.
        // The rewrites for the languages searched are the book's words too (Plan JY P2).
        let rewritten = search.groups.compactMap { rewrites.query(for: $0.language) }
        let lookupWords = ([query, ocrText].compactMap { $0 } + rewritten).joined(separator: " ")
        let references = session.indexReferences(for: lookupWords, store: store, documentIds: documentIds)
            .filter { ref in !outcome.passages.contains { ClauseReference.match(ref, in: $0.text) != nil || $0.figure == ref } }
        if !references.isEmpty {
            result += "\n\n" + Self.indexHint(references)
        }
        // A manual in another script that found nothing for want of its language's words (Plan JY
        // P2): the one retry is worth spending in that language.
        let languageHint = ManualLanguageSearch.missHint(ManualLanguageSearch.missedForLanguage(search, query: query))
        if !outcome.answers {
            let misses = session.noteManualLookupMiss()
            if misses == 1, let languageHint {
                result += "\n\n" + languageHint
            } else {
                result += "\n\n" + Self.missGuidance(misses: misses)
            }
            let sections = misses > 1 ? [] : session.closestSections(for: lookupWords, store: store,
                                                                     documentIds: documentIds, editionRequest: editionRequest,
                                                                     asked: [query, ocrText].compactMap { $0 }.joined(separator: " "),
                                                                     rewrites: rewrites)
            if !sections.isEmpty { result += "\n\n" + Self.sectionsHint(sections) }
        }
        if outcome.answers, let languageHint {
            result += "\n\n" + languageHint
        }
        if documentIds == nil, let note = session.editionNote(for: editionRequest, store: store) {
            result += "\n\n" + note
        }
        if let languages = ManualLanguageSearch.languagesLine(search) {
            result = languages + "\n\n" + result
        }
        if let ocrText {
            result = "Read from the label: \(ocrText.replacingOccurrences(of: "\n", with: " "))\n\n" + result
        }
        return result
    }

    /// The book's own index pointing elsewhere than the passages.
    static func indexHint(_ references: [String]) -> String {
        "The manual's own index lists these for those words: "
            + references.map { $0.hasPrefix("Table") ? $0 : "rule \($0)" }.joined(separator: ", ")
            + ". If the passages above don't answer, look them up by number."
    }

    /// The nearest sections, offered after a first miss.
    static func sectionsHint(_ sections: [String]) -> String {
        "The nearest sections in the manuals are headed: " + sections.joined(separator: "; ")
            + ". If one of them is what was asked about, one more lookup in those words is worth it."
    }

    /// What the model is told after a search that found nothing it may answer from. Field report:
    /// on a code-book vault one question about a cord's capacity ran this tool five times in a
    /// turn, each a rephrasing, each refused with the same sentence, and the technician got no
    /// answer at all. A different wording reaches the same pages; the second miss in a turn says
    /// to stop and answer.
    static func missGuidance(misses: Int) -> String {
        guard misses > 1 else {
            return "Nothing in the loaded manuals answers this. Do not run manual_lookup again with a "
                + "rephrasing of the same question: other wordings reach the same pages. Tell the "
                + "technician the manuals do not cover it, or ask for the one detail that would change "
                + "the search (a model number, a table, clause or page number)."
        }
        return "That is \(misses) searches this turn that found nothing. Stop searching and answer the "
            + "technician now: say the loaded manuals do not cover it, and give what you do have from "
            + "the passages and the vault already in front of you."
    }
}
