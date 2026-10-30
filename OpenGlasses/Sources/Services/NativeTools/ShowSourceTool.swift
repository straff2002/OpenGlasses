import Foundation
import PDFKit

/// Opens the page an answer cited, with the cited passage highlighted (Plan IN P2).
///
/// Resolves against the citations of the most recent answer, by document and page — never by
/// searching every manual for a page number, which is how "show me the page" used to open page 34
/// of the wrong book with two loaded (decision 2). A tool rather than turn classification, so it
/// works the same in Direct, Gemini Live and OpenAI Realtime.
@MainActor
final class ShowSourceTool: NativeTool {
    let name = "show_source"
    let description = """
    Open the manual or code-book page your last answer cited, on the technician's phone, with the \
    cited passage highlighted. Call it when the technician says "show me the page", "show me the \
    relevant pages", "show me clause 3.9.4", "show me the table", "show me the second one" or \
    "where does it say that". Pass 'which': "first" (the default), "second", "last", "all" for \
    every cited page as one paged sheet, a clause number as printed, "table" for the table the \
    answer cited (its row highlighted), or a table number such as "Table 99". Pass 'document' \
    when the technician names the book. It opens only what the last answer cited, so search with \
    manual_lookup or table_lookup and answer first. Only when the technician asks to see a page, \
    table or source — otherwise offer it, and it opens nothing. If it reports that the phone is locked, tell the technician "It's on your phone." and \
    do not say the page is showing. Uses your loaded manuals, or the active Field Assist session. In a personal library, name the manual when several are loaded; camera lookup requires Field Assist.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "which": [
                "type": "string",
                "description": "Which cited source: \"first\", \"second\", \"third\", \"last\", \"all\", a clause number such as \"3.9.4\", \"table\", or a table number such as \"Table 99\"."
            ],
            "document": [
                "type": "string",
                "description": "Optional: the manual or code book the technician named, by title or part of it."
            ]
        ],
        "required": [] as [String]
    ]

    private let documentStore: DocumentStore?
    private let injectedSession: FieldSessionService?
    /// The technician's words this turn: a page opens only when they asked to see one (Plan KD P0).
    private let currentUtterance: @MainActor () -> String?

    init(documentStore: DocumentStore?, sessionService: FieldSessionService? = nil,
         currentUtterance: @escaping @MainActor () -> String? = { TechnicianWords.current() }) {
        self.documentStore = documentStore
        self.injectedSession = sessionService
        self.currentUtterance = currentUtterance
    }

    /// What the model is told when the turn asked to see nothing (Plan KD P0).
    static let notAskedReply = "Not opened — the technician didn't ask to see a page; offer it."

    /// Whether the model's call may open anything: only on a turn whose words asked to see a page,
    /// a table or a source, typed or spoken (Plan KD P0). The retest had pages open before the
    /// answer, because results invited the call. A turn with no captured words (a live session)
    /// is not gated, as `TechnicianWords` documents. The app's own citation taps never come
    /// through this tool. Pure.
    static func mayOpen(said: String?) -> Bool {
        guard let said else { return true }
        return TechnicianRequest.asksToSee(said)
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Self.mayOpen(said: currentUtterance()) else { return Self.notAskedReply }
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.show(args, documentStore: documentStore)
        }
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to show a page from its manuals."
        }
        guard VaultRegistry.shared.isUnlocked(store.manifest) else { return MyManualsPaywallCopy.locked }
        let center = session.sourceCenter
        let which = args["which"] as? String
        let document = args["document"] as? String
        let sources: [ShowSourceResolver.Source]
        switch ShowSourceResolver.resolve(which: which, document: document, memory: center.memory) {
        case .problem(let sentence): return sentence
        case .sources(let found): sources = found
        }

        var pages: [FieldSessionService.StagedFigure] = []
        var checked: [Checked] = []
        var retrievedRowsOf: [String] = []
        var removed: [String] = []
        var notPages: [String] = []
        for source in sources {
            var resolved: FieldSessionService.StagedFigure
            switch session.resolveCitation(source.citation) {
            case .figure(let staged): resolved = staged
            case .removed: removed.append(source.citation.label); continue
            case .unknown: notPages.append(source.citation.label); continue
            }
            // Asked for by the technician: that is the only reason this tool runs.
            resolved.origin = .requested
            resolved.presentOnPhone = true
            resolved.citedPassages = center.citedPassages(for: source.citation, documentId: resolved.documentId,
                                                          store: documentStore, number: source.number)
            resolved.pictureAreas = center.pictureAreas(for: source.citation)
            // Plan JW P1a: rows of a table the answer read without a lookup — say so, and how to
            // mark one row.
            if center.memory.marking(source.citation).basis == .retrievedTableRows, let label = source.citation.figure,
               !resolved.citedPassages.isEmpty, !retrievedRowsOf.contains(label) {
                retrievedRowsOf.append(label)
            }
            let check = markState(of: resolved, session: session)
            // A passage that cannot be found on the page is not staged beside one that can: the sheet
            // would say "2 of the passages couldn't be marked" over a page whose marks are the
            // answer's. The reply still names what was not marked.
            resolved.citedPassages = check.kept
            session.logCitationOpened(source.citation, origin: .voice)
            pages.append(resolved)
            checked.append(check)
        }
        guard let first = pages.first else {
            return Self.nothingOpened(removed: removed, notPages: notPages)
        }

        let rows = checked.reduce(into: RowMarks()) { $0.marked += $1.rows.marked; $0.unmarked += $1.rows.unmarked }
        let onScreen = center.present(pages, notice: ShowSourceCenter.noticeText(for: first.asCitation))
        // Put on the phone (or waiting for it to unlock): "show that again" reopens it (Plan KD P3).
        session.noteShownOnPhone(first)
        return Self.reply(pages: pages, marks: checked.map(\.state), rows: rows, onScreen: onScreen,
                          removed: removed, notPages: notPages,
                          unmarkedPassages: checked.reduce(0) { $0 + $1.unmarkedText },
                          retrievedRowsOf: retrievedRowsOf)
    }

    /// What marking one staged page came to.
    struct Checked: Equatable {
        var state: MarkState
        var rows: RowMarks
        /// The cited passages to stage: all of them, unless some are found on the page and some are
        /// not, when only the found ones.
        var kept: [CitedPassage]
        /// Passages that are not a table's rows left unmarked beside marked ones on the page.
        var unmarkedText: Int = 0
    }

    /// The table rows the marks came to, by row heading (Plan JW P0), so the reply names exactly
    /// the rows on the page — the partner heard "both rows are highlighted" over a page that showed
    /// neither.
    struct RowMarks: Equatable {
        var marked: [String] = []
        var unmarked: [String] = []
        var isEmpty: Bool { marked.isEmpty && unmarked.isEmpty }
    }

    /// Whether the cited passages could be marked on a staged page, so the reply never claims a
    /// highlight the sheet will not draw.
    enum MarkState: Equatable {
        case marked
        case unmarked
        /// No passage to mark — the page opens plain, and the reply says nothing about marking.
        case noPassage
        /// A table read from a picture: the region it was read from is outlined (Plan JN P2).
        case outlined
    }

    private func markState(of staged: FieldSessionService.StagedFigure,
                           session: FieldSessionService) -> Checked {
        guard !staged.citedPassages.isEmpty else {
            return Checked(state: staged.pictureAreas.contains { $0.physical == staged.page } ? .outlined : .noPassage,
                           rows: RowMarks(), kept: [])
        }
        var pageText: String?
        if let url = session.sourcePDFURL(for: staged), let document = PDFDocument(url: url),
           staged.page >= 1, staged.page <= document.pageCount {
            pageText = document.page(at: staged.page - 1)?.string
        } else {
            pageText = documentStore?.pageTexts(documentId: staged.documentId)
                .first { $0.page == staged.page }?.text
        }
        return Self.check(staged.citedPassages, page: staged.page, pageText: pageText)
    }

    /// Marks the cited passages on one page's text and decides which to stage (Plan JW P1a). Pure.
    static func check(_ passages: [CitedPassage], page: Int, pageText: String?) -> Checked {
        let marks = PassageMarks(passages: passages, page: page, pageText: pageText)
        let rows = rowMarks(passages, page: page, pageText: pageText)
        guard !marks.located.isEmpty else { return Checked(state: .unmarked, rows: rows, kept: passages) }
        var kept: [CitedPassage] = []
        var unmarkedText = 0
        for passage in passages {
            guard passage.anchor.page == page,
                  PassageLocator.locate(passage.anchor, onPageText: pageText).ranges.isEmpty else {
                kept.append(passage)
                continue
            }
            if TableRowPassage.rowName(ofSentence: passage.anchor.text) == nil { unmarkedText += 1 }
        }
        return Checked(state: .marked, rows: rows, kept: kept, unmarkedText: unmarkedText)
    }

    /// Which of the cited table rows on `page` are found on its text, by heading; passages that are
    /// not a table's rows are left to the generic line. Pure.
    static func rowMarks(_ passages: [CitedPassage], page: Int, pageText: String?) -> RowMarks {
        var rows = RowMarks()
        for passage in passages where passage.anchor.page == page {
            guard let name = TableRowPassage.rowName(ofSentence: passage.anchor.text) else { continue }
            if PassageLocator.locate(passage.anchor, onPageText: pageText).ranges.isEmpty {
                if !rows.unmarked.contains(name) { rows.unmarked.append(name) }
            } else if !rows.marked.contains(name) {
                rows.marked.append(name)
            }
        }
        return rows
    }

    /// A citation that is not a page of a manual in this vault: the model's own wording of a source,
    /// or a core file. Nothing says a manual left the vault, and the model has to be told so: a
    /// tester was told a manual had been removed that was still loaded, and the turn stopped there
    /// (Plan KE).
    static func notAManualPage(_ labels: [String]) -> String {
        (labels.count == 1 ? "That source (\(labels[0])) is not a manual page"
            : "Those sources (\(labels.joined(separator: "; "))) are not manual pages")
            + " this vault can open. To find the page, search with manual_lookup."
    }

    /// The cited manual really has been taken out of the vault.
    static func removedFromVault(_ labels: [String]) -> String {
        "The cited manual is no longer in this vault (" + labels.joined(separator: "; ") + ")."
    }

    /// What the model is told when no cited source opened. Pure.
    static func nothingOpened(removed: [String], notPages: [String]) -> String {
        var lines: [String] = []
        if !removed.isEmpty { lines.append(removedFromVault(removed)) }
        if !notPages.isEmpty { lines.append(notAManualPage(notPages)) }
        lines.append("Nothing was opened.")
        return lines.joined(separator: " ")
    }

    /// What the model is told. Pure.
    static func reply(pages: [FieldSessionService.StagedFigure], marks: [MarkState], rows: RowMarks = RowMarks(),
                      onScreen: Bool, removed: [String], notPages: [String] = [], unmarkedPassages: Int = 0,
                      retrievedRowsOf: [String] = []) -> String {
        var lines: [String] = []
        let labels = pages.map(\.citation)
        if onScreen {
            lines.append(pages.count == 1
                ? "Showing \(labels[0]) on the technician's phone."
                : "Showing \(pages.count) pages on the technician's phone, in the order you cited them: "
                    + labels.joined(separator: "; ") + ".")
        } else {
            lines.append("The phone is locked or the app is in the background, so the page is not on screen yet. "
                + "A notification says where it is, and it opens when the technician unlocks the phone. "
                + "Tell the technician \"It's on your phone.\" Do not say the page is showing.")
        }
        if !rows.isEmpty {
            // Table rows are named, so nothing is claimed beyond what the page shows.
            if !rows.marked.isEmpty {
                lines.append("Marked on the page: " + rows.marked.map { "row \($0)" }.joined(separator: "; ") + ".")
            }
            if !rows.unmarked.isEmpty {
                lines.append("Could not be marked: " + rows.unmarked.map { "row \($0)" }.joined(separator: "; ")
                    + ". Do not say \(rows.unmarked.count == 1 ? "it is" : "they are") highlighted; read the value aloud if asked.")
            }
            if rows.marked.isEmpty {
                lines.append("No row is highlighted on the page.")
            } else {
                lines.append("Say only that \(rows.marked.count == 1 ? "this row is" : "these rows are") highlighted.")
            }
            if !retrievedRowsOf.isEmpty {
                // Plan JW P1a: the answer quoted a row passage, so these are the rows retrieved for
                // the table, not a row a lookup read.
                lines.append("These are the rows of " + retrievedRowsOf.joined(separator: " and ")
                    + " retrieved for the answer, not a row a lookup read. To mark one row, read the value with "
                    + "table_lookup (table, row, column).")
            }
        } else if marks.contains(.marked), unmarkedPassages > 0 {
            lines.append("Only the passages found on the page are highlighted; \(unmarkedPassages) other "
                + "\(unmarkedPassages == 1 ? "passage" : "passages") the answer drew on couldn't be marked, so read "
                + "\(unmarkedPassages == 1 ? "it" : "them") aloud if asked.")
        } else if marks.contains(.marked) {
            lines.append(marks.contains(.unmarked)
                ? "The cited passage is highlighted where it was found; on the other pages it couldn't be marked, so read the clause aloud if asked."
                : "The cited passage is highlighted on the page.")
        } else if marks.contains(.unmarked) {
            lines.append("The passage couldn't be marked on the page, so the page opens without a highlight.")
        }
        if marks.contains(.outlined) {
            lines.append("The table on that page was read from a picture, so the region it was read from is outlined "
                + "instead of a highlighted row: ask the technician to check the value against the page.")
        }
        if !removed.isEmpty {
            lines.append("Not opened, because the manual is no longer in this vault: " + removed.joined(separator: "; ") + ".")
        }
        if !notPages.isEmpty { lines.append("Not opened: " + notAManualPage(notPages)) }
        return lines.joined(separator: " ")
    }
}
