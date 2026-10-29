import Foundation

/// Puts a numbered drawing from the vault's manuals in front of the technician, and on the next
/// turn's image slot for the model (Plan EK P2).
///
/// The automatic path already stages the drawing a turn's own evidence points at. This tool is the
/// asked-for path — "show me figure 65", "what's on page 44", "show that figure again" — which is
/// how a technician gets a diagram they know the number of without phrasing a question that
/// happens to retrieve it.
@MainActor
final class ManualFigureTool: NativeTool {
    let name = "manual_figure"
    let description = """
    Show a numbered figure, table or page from the manuals loaded on this phone, or re-open the source a previous answer cited. Pass 'figure' ("Figure 58", or just \
    "58"), or 'printed_page' with the page number printed on the page ("printed page 57"), or \
    'page' with the PDF's own page number (the viewer's count, which may differ from the printed \
    one), or 'again' to bring back the last figure or page shown ("show me that source", "show that figure again"). The page opens on the technician's phone and is \
    attached to your next turn as an image when one is available, so you can read the drawing \
    yourself. Use it when the technician names a figure or asks to see a wiring diagram, and after \
    citing one. Say the page it reports it opened, PDF and printed, never the one you asked for. A manual imported as extracted text has no page to show — the tool says so, and \
    the citation is still correct. Uses your loaded manuals, or the active Field Assist session. In a personal library, name the manual when several are loaded; camera lookup requires Field Assist.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "figure": [
                "type": "string",
                "description": "The figure or table to show, e.g. \"Figure 58\", \"Table 16\", or just \"58\"."
            ],
            "page": [
                "type": "integer",
                "description": "The PDF page number (the viewer's count from the first page of the file, not the number printed on the page) for an imported manual, or the photographed page index for a captured manual."
            ],
            "printed_page": [
                "type": "string",
                "description": "The page number as printed on the page (\"57\", \"iv\", \"A-3\") when the technician says one. Opened through the manual's printed page numbers; refused, never guessed, when no page carries it."
            ],
            "document": [
                "type": "string",
                "description": "Which manual, when the technician names one: its title or part of it (\"service manual\", \"installation instructions\"), or a photographed manual's capture id. A page number alone is ambiguous when several manuals are loaded."
            ],
            "again": [
                "type": "boolean",
                "description": "Show the last figure again (\"show that figure again\")."
            ]
        ],
        "required": [] as [String]
    ]

    private let documentStore: DocumentStore?
    /// Session to stage on; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The technician's words this turn: "page 34 of the service manual" names the book even when
    /// the call leaves `document` out, and "printed page 57" is a printed page even when the call
    /// passes `page` (Plan KD P0).
    private let currentUtterance: @MainActor () -> String?

    init(documentStore: DocumentStore?, sessionService: FieldSessionService? = nil,
         currentUtterance: @escaping @MainActor () -> String? = { TechnicianWords.current() }) {
        self.documentStore = documentStore
        self.injectedSession = sessionService
        self.currentUtterance = currentUtterance
    }

    func execute(args: [String: Any]) async throws -> String {
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.figure(args, documentStore: documentStore)
        }
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to show a figure from its manuals."
        }

        guard VaultRegistry.shared.isUnlocked(store.manifest) else { return MyManualsPaywallCopy.locked }
        if (args["again"] as? Bool) == true {
            guard let staged = session.restageLastFigure(
                origin: session.turnAskedForPage ? .requested : .automatic) else {
                return "No figure has been shown yet in this session. Name a figure or a page number."
            }
            return show(staged, session: session, opening: "Back to")
        }

        let chosen = (args["document"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines)
        let captures = session.capturedManuals.eligible(for:session.activeSession,vaultID:store.manifest.id)
            .filter { m in chosen == nil || chosen?.isEmpty == true || m.captureID == chosen
                || m.title.localizedCaseInsensitiveContains(chosen!) }
        if chosen?.isEmpty == false || !store.manifest.hasDocuments {
            if captures.count > 1 {
                return "Choose a photographed manual by its title or capture id before opening a page: "
                    + captures.map { "\($0.title) (\($0.captureID))" }.joined(separator:"; ")
            }
            if let m = captures.first {
                if printedPage(args) != nil {
                    return "A photographed manual has no printed page numbers to open by: name the photographed page, from 1 to \(m.pageCount). Nothing was opened."
                }
                var page = Self.integer(args["page"])
                if page == nil, let figure = args["figure"] as? String, let documentStore {
                    page = Self.candidateLabels(for:figure).lazy.compactMap { label in
                        documentStore.passages(figure:label,namespace:m.documentID,limit:1).first?.page
                    }.first
                }
                guard let page, (1...m.pageCount).contains(page) else {
                    return "Name a photographed page from 1 to \(m.pageCount). Printed page numbers are supplementary labels."
                }
                var staged = FieldSessionService.StagedFigure(documentId:m.documentID,
                    documentTitle:CapturedManualCatalog.citationName(m),page:page,sourceFile:"pages.pdf")
                staged.origin = session.turnAskedForPage ? .requested : .automatic
                session.stageFigure(staged)
                return show(staged,session:session,opening:"Photographed manual:")
            }
            // A name that is no photograph may still be an imported manual's title.
            if chosen?.isEmpty == false, !store.manifest.hasDocuments {
                return "No eligible photographed manual matches that title or capture id."
            }
        }

        guard store.manifest.hasDocuments, let documentStore else {
            return "The \(store.manifest.name) vault has no manuals to show figures from."
        }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else {
            return ManualIndexAvailability.unsearchableSentence(for: store.manifest)
        }

        let requestedFigure = (args["figure"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPage = Self.integer(args["page"])
        let requestedPrinted = printedPage(args)

        // This tool asks the index by caption and by page rather than by similarity, so it never
        // builds a retriever and would not otherwise get the retriever's availability check. A
        // caption is exactly the kind of thing a technician asks for again after the manual it was
        // printed in has been taken out of the vault.
        let isAvailable = VaultManualRemoval.availabilityCheck(forVault: store.manifest.id,
                                                               documentStore: documentStore, capturedCatalog:session.capturedManuals)
        // Every manual's copy of the page or caption, then the one the technician meant. The store
        // orders by document name, so "page 34" alone always opened the Installation Instructions
        // — twice, for a technician who had said "page 34 of the service manual" both times.
        var passage: VaultRetriever.Passage?
        if let requestedPrinted {
            // A printed page (Plan KD P0): through each manual's printed page numbers, never as the
            // PDF page of the same number — "printed page 57" opened PDF page 57 on the retest.
            let documents = documentStore.list(namespace: namespace).filter { isAvailable($0.id) }
            var hits: [DocumentStore.Passage] = []
            var repeated: [String] = []
            for document in documents {
                let pages = documentStore.pageLabels(documentId: document.id).physicalPages(forPrinted: requestedPrinted)
                if pages.count > 1 { repeated.append(document.name); continue }
                guard let physical = pages.first else { continue }
                hits += documentStore.passages(onPage: physical, documentIds: [document.id], limit: 1)
            }
            guard !hits.isEmpty else {
                return Self.printedPageRefusal(requestedPrinted, repeatedIn: repeated)
            }
            switch ManualDocumentChoice.pick(hits, document: chosen, said: currentUtterance(),
                                             editions: session.documentEditions(of: store)) {
            case .found(let hit): passage = Self.retrieved(hit)
            case .problem(let sentence):
                return sentence.replacingOccurrences(of: "{what}", with: "Printed page \(requestedPrinted)")
            }
        } else if let requestedFigure, !requestedFigure.isEmpty {
            var lastProblem: String?
            for label in Self.candidateLabels(for: requestedFigure) {
                let hits = documentStore.passages(figure: label, namespace: namespace, limit: 40)
                    .filter { isAvailable($0.documentId) }
                guard !hits.isEmpty else { continue }
                switch ManualDocumentChoice.pick(hits, document: chosen, said: currentUtterance(),
                                                 editions: session.documentEditions(of: store)) {
                case .found(let hit): passage = Self.retrieved(hit)
                case .problem(let sentence): lastProblem = sentence.replacingOccurrences(of: "{what}", with: label)
                }
                if passage != nil { break }
            }
            if passage == nil, let lastProblem { return lastProblem }
            guard passage != nil else {
                return "No \(requestedFigure) in the manuals loaded for this vault. Ask for it by page number, or search the manuals with manual_lookup."
            }
        } else if let requestedPage {
            let hits = documentStore.passages(onPage: requestedPage, namespace: namespace, limit: 40)
                .filter { isAvailable($0.documentId) }
            guard !hits.isEmpty else {
                return "Nothing is stored for page \(requestedPage) of the loaded manuals."
            }
            switch ManualDocumentChoice.pick(hits, document: chosen, said: currentUtterance(),
                                             editions: session.documentEditions(of: store)) {
            case .found(let hit): passage = Self.retrieved(hit)
            case .problem(let sentence):
                return sentence.replacingOccurrences(of: "{what}", with: "Page \(requestedPage)")
            }
        } else {
            return "Name the figure to show (\"Figure 58\"), a page number, or ask for the last one again."
        }

        guard var staged = session.makeStagedFigure(for: passage, vaultId: store.manifest.id) else {
            return "That passage has no page number, so there is no page to show."
        }
        // A voice-originated open cannot tell the technician's request from the model's own
        // initiative, so the turn decides: a turn that asked for a page makes it the technician's;
        // anything else is the app putting a page up (Plan GB P1).
        staged.origin = session.turnAskedForPage ? .requested : .automatic
        session.stageFigure(staged)
        // A page asked for by number says which page opened, both ways (Plan KD P0): the retest's
        // reply never said, so the model claimed the printed page it had asked for.
        let opened = requestedPrinted != nil || (requestedFigure?.isEmpty != false && requestedPage != nil)
            ? Self.openedPageLine(physical: staged.page,
                                  printed: documentStore.pageLabels(documentId: staged.documentId)
                                      .printed(forPhysical: staged.page),
                                  documentTitle: staged.documentTitle)
            : nil
        return show(staged, session: session, opening: "Showing", openedLine: opened)
    }

    /// The printed page the call or the technician's words ask for: `printed_page`, else "printed
    /// page 57" in the words this turn.
    private func printedPage(_ args: [String: Any]) -> String? {
        if let value = args["printed_page"] {
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return currentUtterance().flatMap(Self.printedPage(in:))
    }

    /// "printed page 57", "printed page number iv", "page 57 printed" → the label. Pure.
    static func printedPage(in said: String) -> String? {
        for pattern in [#"(?i)\bprinted\s+page\s+(?:number\s+|no\.?\s*)?([A-Za-z0-9][A-Za-z0-9-]*)"#,
                        #"(?i)\bpage\s+([A-Za-z0-9][A-Za-z0-9-]*)\s+(?:as\s+)?printed\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)),
                  let range = Range(match.range(at: 1), in: said) else { continue }
            return String(said[range])
        }
        return nil
    }

    /// Why a printed page was not opened. Pure.
    static func printedPageRefusal(_ label: String, repeatedIn documents: [String]) -> String {
        if !documents.isEmpty {
            return "Printed page \(label) is printed on more than one page of " + documents.joined(separator: "; ")
                + " (front matter and body, most likely), so nothing was opened. Ask the technician for the PDF page, "
                + "or a figure or table number."
        }
        return "No loaded manual has a page printed \"\(label)\" that the app could read, so nothing was opened — "
            + "not PDF page \(label) either, which is a different page. Ask the technician for the PDF page, or a "
            + "figure or table number."
    }

    /// "Opened PDF page 63 (printed page 57) of Book." — what actually opened. Pure.
    static func openedPageLine(physical: Int, printed: String?, documentTitle: String) -> String {
        let label = printed.map { " (printed page \($0))" } ?? " (the app knows no printed page number for it)"
        return "Opened PDF page \(physical)\(label) of \(documentTitle). Say this page, not the one you asked for."
    }

    // MARK: - Staging → phone, lens, and the answer

    /// Staging is what shows the figure: the app subscribes to the session and opens the sheet,
    /// flashes the lens cue and writes the audit line. All this does is say what happened, so a
    /// headless caller gets the same answer without an app around it.
    private func show(_ staged: FieldSessionService.StagedFigure,
                      session: FieldSessionService, opening: String, openedLine: String? = nil) -> String {
        let presenter = ManualFigurePresenter(figure: staged, sourceURL: session.sourcePDFURL(for: staged))
        // Asked for out loud rather than tapped: the audit records which it was, because a
        // technician reading a page and a technician asking to be shown one are different evidence.
        // A page the model put up without being asked is not an open at all (Plan GB P1).
        if staged.origin == .requested {
            session.logCitationOpened(staged.asCitation, origin: .voice)
        }
        var lines = ["\(opening) \(staged.name) on the technician's phone. Source: \(staged.citation)."]
        if let openedLine { lines.append(openedLine) }
        if presenter.hasPicture {
            lines.append("The page is attached to your next turn as an image, so read the drawing there rather than describing it from the labels.")
        } else {
            lines.append("The figure is cited but this document was imported as text, so there is no page to show; import the PDF to see it.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Parsing

    /// The captions a spoken request could mean. "58" is the common case — a technician reads the
    /// number off the page and says it — and a drawing is far likelier than a table, so the figure
    /// is tried first.
    static func candidateLabels(for request: String) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = trimmed.range(of: #"\d+"#, options: .regularExpression).map({ String(trimmed[$0]) }) else {
            return []
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("table") { return ["Table \(number)"] }
        if lowered.hasPrefix("figure") || lowered.hasPrefix("fig") { return ["Figure \(number)"] }
        return ["Figure \(number)", "Table \(number)"]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A store passage as the retriever's passage type, so staging has one input shape whether it
    /// came from a ranked turn or from an exact lookup.
    private static func retrieved(_ p: DocumentStore.Passage) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: p.documentId, documentName: p.documentName,
                               chunkIndex: p.chunkIndex, text: p.text, page: p.page, section: p.section,
                               similarity: p.similarity, score: p.similarity, matchedTokens: [],
                               kind: p.kind, figure: p.figure, termRule: p.termRule, vectorPending: p.vectorPending)
    }
}

/// Which loaded manual a request means (a tester's job 1028).
///
/// Two manuals both have a page 34. Asked for "page 34 of the service manual", the tool opened the
/// Installation Instructions' page 34 twice, because it never chose: it took the first copy the
/// store returned. The book is chosen from the call's `document`, else from the technician's own
/// words, and when neither names one and the page is in several books the question goes back.
///
/// Pure over passages and strings.
enum ManualDocumentChoice {

    enum Outcome: Equatable {
        case found(DocumentStore.Passage)
        /// What to say instead. `{what}` stands for the page or caption asked for.
        case problem(String)
    }

    static func pick(_ hits: [DocumentStore.Passage], document: String?, said: String?,
                     editions: DocumentEditions = .none) -> Outcome {
        let names = orderedNames(hits)
        guard let first = hits.first else { return .problem("Nothing is stored for {what} of the loaded manuals.") }
        if let document = document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            guard let hit = hits.first(where: { matches($0.documentName, requested: document) }) else {
                return .problem("{what} is not in a manual called \"\(document)\". It is in "
                                + names.joined(separator: "; ") + ".")
            }
            return .found(hit)
        }
        guard names.count > 1 else { return .found(first) }
        if let said, let named = named(in: said, among: names),
           let hit = hits.first(where: { $0.documentName == named }) {
            return .found(hit)
        }
        // Editions of one work (Plan IV P2): the page or caption opens in the newest unless the
        // technician asked for an older one. A request to compare still asks which.
        if let allowed = editions.searchableTitles(for: EditionRequest.parse(said, editions: editions), among: names) {
            let chosen = names.filter(allowed.contains)
            if chosen.count == 1, let hit = hits.first(where: { $0.documentName == chosen[0] }) { return .found(hit) }
        }
        return .problem("{what} is in more than one manual: " + names.joined(separator: "; ")
                        + ". Ask the technician which, then call again with 'document'. Nothing was opened.")
    }

    /// Whether `requested` names the manual called `documentName`: part of its title ("service
    /// manual"), every word of the request in the title, or its initials as the vault writes them
    /// ("SM", "II").
    static func matches(_ documentName: String, requested: String) -> Bool {
        let title = documentName.lowercased(), wanted = requested.lowercased()
        if title.contains(wanted) { return true }
        let titleWords = Set(words(title))
        let wantedWords = words(wanted).filter { $0.count >= 3 && !filler.contains($0) }
        if !wantedWords.isEmpty, wantedWords.allSatisfy({ titleWords.contains($0) }) { return true }
        return initials(documentName) == requested.uppercased().filter(\.isLetter)
    }

    /// The one manual the technician's sentence names by a word that tells the manuals apart —
    /// "service", "installation" — or nil when it names none, or several.
    static func named(in said: String, among names: [String]) -> String? {
        let spoken = Set(words(said.lowercased()))
        let wordsByName = names.map { ($0, Set(words($0.lowercased()))) }
        let shared = wordsByName.map(\.1).reduce(wordsByName.first?.1 ?? []) { $0.intersection($1) }
        let named = wordsByName.filter { _, titleWords in
            !titleWords.subtracting(shared).subtracting(generic).filter { $0.count >= 3 }
                .isDisjoint(with: spoken)
        }
        return named.count == 1 ? named[0].0 : nil
    }

    private static let filler: Set<String> = ["the", "of", "and", "page", "manual's"]
    /// Words that do not tell one book from another in speech: "the manual" is any of them.
    private static let generic: Set<String> = ["manual", "manuals", "guide", "book", "the", "and", "for"]

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    /// "SLP99UHVK Service Manual" → "SM": the title's words, the model-like ones left out.
    private static func initials(_ title: String) -> String {
        String(words(title).filter { !$0.contains(where: \.isNumber) }.compactMap(\.first)).uppercased()
    }

    private static func orderedNames(_ hits: [DocumentStore.Passage]) -> [String] {
        var seen = Set<String>()
        return hits.map(\.documentName).filter { seen.insert($0).inserted }
    }
}
