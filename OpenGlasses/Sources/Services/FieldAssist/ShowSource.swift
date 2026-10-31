import Foundation
import UIKit
import UserNotifications

// "Show me the page", "show me the relevant pages" (Plan IN P2).
//
// The partner's electrician keeps the phone in a pocket: the spoken answer with its clause is
// usually enough, and when he wants to check he says "show me the page". Before this, the model
// could only reach a page through `manual_figure(page:)`, and a bare page number was looked up in
// every manual — with two code books loaded it opened the right page number in the wrong book.
// Here "show me" resolves against the citations of the answer he just heard, by document and page,
// and never searches for a page number at all (decision 2).

// MARK: - What the last answer cited

/// The sources the most recent answer cited, kept per session so "show me the second one" still
/// works after a follow-up that cited nothing.
///
/// Two inputs, because the modes differ. In Direct mode the answer's own text is parsed for its
/// `Source:` lines (`CitationLineParser`) and that is authoritative. The live modes (Gemini Live,
/// OpenAI Realtime) give the app no answer text with sources in it, so what `manual_lookup` returned
/// stands in for it — provisionally, until an answer that cites something replaces it. Pure.
struct AnswerSourceMemory: Equatable {

    /// A passage a retrieval returned this session, so a cited page can be marked with the passage
    /// that was actually given to the model.
    struct Retrieved: Equatable, Hashable {
        let documentId: String
        let documentName: String
        let chunkIndex: Int
        let page: Int?
        let section: String?
        let text: String
        /// The table or figure that names the passage (Plan JW P1a), so a table's citation marks
        /// that table's rows and nothing else on its page.
        var figure: String? = nil
        /// A row passage the app wrote from a table (`DocumentChunker.Kind.tableRow`).
        var isTableRow = false
        /// The pages a chunk packed across a page break sits on (Plan KE P2).
        var pageBreaks: [DocumentChunker.PageBreak] = []

        /// Whether any of the passage is on a page of `pages`. A passage cited at the page marked
        /// inside it is held by another page number than the chunk's.
        func isOn(_ pages: ClosedRange<Int>) -> Bool {
            pageBreaks.isEmpty ? (page.map(pages.contains) ?? false) : pageBreaks.contains { pages.contains($0.page) }
        }
    }

    /// Why the passages behind a citation were chosen (Plan JW P1a), so `show_source` says what it
    /// marked as plainly as it marked it.
    enum MarkBasis: Equatable {
        /// The rows a `table_lookup` read for this citation.
        case lookupRows
        /// A table's rows the turn retrieved that the answer's own words name (row and value).
        case answerRows
        /// Every row of the cited table the turn retrieved on the page: the answer read none
        /// through `table_lookup`, and its words do not single one out.
        case retrievedTableRows
        /// The passages the turn retrieved on a cited page that names no table.
        case page
    }

    private(set) var sessionId: String?
    private(set) var confirmed: [Citation] = []
    private(set) var provisional: [Citation]?
    private(set) var retrieved: [Retrieved] = []
    /// The rows a table lookup read (Plan JJ P1), by the citation it answered with, so "show me
    /// the table" marks the row the cell came from and not every row the turn retrieved. Kept
    /// after the answer, which repeats the same citation.
    private(set) var tableRows: [String: [Retrieved]] = [:]
    /// The regions a table read from a picture was recognised from (Plan JN P2), by the citation a
    /// lookup answered with: a picture has no text to mark, so the page outlines where it was read.
    private(set) var tableAreas: [String: [ManualTable.PictureArea]] = [:]
    /// The last Direct-mode answer that cited a manual, as said (Plan JW P1a): which of a table's
    /// retrieved rows it read from, when no lookup noted the row.
    private(set) var answerText: String?

    /// How many retrieved passages are kept. A few turns' worth: enough to mark what was cited a
    /// question or two ago, not a record of the job.
    static let retainedPassages = 32

    /// The last answer's manual citations, in the order it gave them.
    var citations: [Citation] { provisional ?? confirmed }

    /// A retrieval ran (the per-turn block or `manual_lookup`). Remembers its passages; says
    /// nothing about what was cited.
    mutating func noteRetrieved(_ passages: [Retrieved], sessionId: String?) {
        adopt(sessionId)
        guard !passages.isEmpty else { return }
        var seen = Set<Retrieved>()
        retrieved = Array((passages + retrieved).filter { seen.insert($0).inserted }.prefix(Self.retainedPassages))
    }

    /// `manual_lookup` answered: its sources stand for the answer until one that cites replaces
    /// them. An empty lookup changes nothing.
    mutating func noteLookup(_ passages: [Retrieved], sessionId: String?) {
        noteRetrieved(passages, sessionId: sessionId)
        let cited = Self.citations(from: passages)
        if !cited.isEmpty { provisional = cited }
    }

    /// A Direct-mode answer finished. One that cites manuals becomes the answer "show me" refers
    /// to; one that cites nothing leaves the previous answer's sources where they were.
    mutating func noteAnswer(_ citations: [Citation], text: String? = nil, sessionId: String?) {
        adopt(sessionId)
        let manual = Self.unique(citations.filter { $0.kind == .manual && ($0.page != nil || $0.printedPage != nil) })
        provisional = nil
        if !manual.isEmpty {
            confirmed = manual
            answerText = text
        }
    }

    /// `table_lookup` answered (Plan JJ P1): its citations stand for the answer until one that
    /// cites replaces them, and the rows it read are what each citation marks.
    mutating func noteTableLookup(rows: [Retrieved], citations: [Citation], pictureAreas: [ManualTable.PictureArea] = [],
                                  sessionId: String?) {
        adopt(sessionId)
        guard !citations.isEmpty else { return }
        provisional = Self.unique(citations)
        for citation in citations {
            tableRows[Self.tableKey(citation)] = rows.filter { $0.page == citation.page }
            var areas: [ManualTable.PictureArea] = []
            for area in pictureAreas where area.physical == citation.page && !areas.contains(area) { areas.append(area) }
            tableAreas[Self.tableKey(citation)] = areas
        }
    }

    /// The regions to outline for a table citation a lookup answered with, on its page (Plan JN P2).
    /// Empty for a table read from the text layer, and for any other citation.
    func pictureAreas(for citation: Citation) -> [ManualTable.PictureArea] {
        guard citation.figure != nil else { return [] }
        return tableAreas[Self.tableKey(citation)] ?? []
    }

    private static func tableKey(_ citation: Citation) -> String {
        "\(citation.title.lowercased())#\(citation.page ?? 0)#\((citation.figure ?? "").lowercased())"
    }

    /// The passages behind a citation: same manual, on a page the citation names. A table's
    /// citation that a lookup answered with marks the rows the lookup read.
    func retrieved(for citation: Citation) -> [Retrieved] {
        marking(citation).passages
    }

    /// The passages to mark for a citation, and why those (Plan JW P1a).
    ///
    /// A table's citation that no lookup answered — the partner's table question was answered from
    /// the row passages in the turn's retrieved context — used to mark every passage retrieved on
    /// the page: rows of the table, prose beside it, and rows whose printed line is not on the page
    /// once ("2 of the passages couldn't be marked"). Now it marks that table's own passages only:
    /// the rows the answer's words name (a row heading and a value from it), else every row of the
    /// table the turn retrieved on that page, else the passages named for the table. Never a passage
    /// of something else on the page.
    func marking(_ citation: Citation) -> (passages: [Retrieved], basis: MarkBasis) {
        if citation.figure != nil, let rows = tableRows[Self.tableKey(citation)] { return (rows, .lookupRows) }
        guard let page = citation.page else { return ([], .page) }
        let last = citation.throughPage ?? page
        let title = citation.title.lowercased()
        let onPages = retrieved.filter { $0.documentName.lowercased() == title && $0.isOn(page...last) }
        .sorted { ($0.page ?? 0, $0.chunkIndex) < ($1.page ?? 0, $1.chunkIndex) }
        guard let label = citation.figure, label.lowercased().hasPrefix("table") else { return (onPages, .page) }
        let named = onPages.filter { ($0.figure ?? "").caseInsensitiveCompare(label) == .orderedSame }
        let rows = named.filter(\.isTableRow)
        guard !rows.isEmpty else { return (named, .page) }
        if let said = answerText {
            let read = rows.filter { Self.answer(said, readsRow: $0.text) }
            if !read.isEmpty, read.count < rows.count { return (read, .answerRows) }
        }
        return (rows, .retrievedTableRows)
    }

    /// Whether an answer reads a row passage: every word of the row's heading is in the answer, and
    /// so is one of the row's values, as a whole word. Pure; a guess only in the sense that an answer
    /// naming two rows' headings and values reads both.
    static func answer(_ answer: String, readsRow sentence: String) -> Bool {
        guard let name = TableRowPassage.rowName(ofSentence: sentence) else { return false }
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        }
        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: \.isWhitespace).map { raw -> String in
                var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]\"'\u{201C}\u{201D}"))
                while token.hasSuffix(".") { token.removeLast() }
                return token
            })
        }
        let answerWords = words(answer)
        let nameWords = words(name)
        guard !nameWords.isEmpty, nameWords.isSubset(of: answerWords) else { return false }
        let answerTokens = tokens(answer)
        return TableRowPassage.values(ofSentence: sentence).contains { answerTokens.contains($0.lowercased()) }
    }

    static func citations(from passages: [Retrieved]) -> [Citation] {
        unique(passages.compactMap { passage in
            let pages = passage.pageBreaks.map(\.page)
            return passage.page.map {
                Citation(kind: .manual, title: passage.documentName, page: pages.min() ?? $0, throughPage: pages.max(),
                         section: passage.section)
            }
        })
    }

    /// One citation per manual page, first mention first.
    static func unique(_ citations: [Citation]) -> [Citation] {
        var seen = Set<String>()
        return citations.filter { seen.insert("\($0.title.lowercased())#\($0.page ?? 0)").inserted }
    }

    private mutating func adopt(_ id: String?) {
        guard id != sessionId else { return }
        self = AnswerSourceMemory()
        sessionId = id
    }
}

// MARK: - Which source "show me" means

/// Turns `which` and `document` into the cited sources to open. Pure.
enum ShowSourceResolver {

    struct Source: Equatable {
        /// The citation's place in the answer, 1-based — the number its mark carries.
        let number: Int
        let citation: Citation
    }

    enum Outcome: Equatable {
        case sources([Source])
        /// What to tell the model instead. Nothing opens.
        case problem(String)
    }

    /// The most pages "all" opens in one sheet.
    static let maximumPages = 6

    private static let ordinals: [String: Int] = [
        "first": 1, "one": 1, "1": 1, "1st": 1,
        "second": 2, "two": 2, "2": 2, "2nd": 2,
        "third": 3, "three": 3, "3": 3, "3rd": 3,
        "fourth": 4, "four": 4, "4": 4, "4th": 4,
        "fifth": 5, "five": 5, "5": 5, "5th": 5,
        "sixth": 6, "six": 6, "6": 6, "6th": 6,
    ]
    private static let allWords: Set<String> = ["all", "every", "relevant", "both", "them", "pages", "sources"]

    static func resolve(which rawWhich: String?, document: String?, memory: AnswerSourceMemory) -> Outcome {
        let all = memory.citations.enumerated().map { Source(number: $0.offset + 1, citation: $0.element) }
        guard !all.isEmpty else {
            return .problem("No answer in this job has cited a manual page yet, so there is no page to show. "
                + "Search with manual_lookup first. Nothing was opened.")
        }
        var pool = all
        if let document = document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            // A title that holds the words as written wins over a looser match: "book a" is in
            // "Code Book A", and every word but "a" is in "Code Book B" as well.
            let exact = all.filter { $0.citation.title.localizedCaseInsensitiveContains(document) }
            pool = exact.isEmpty ? all.filter { ManualDocumentChoice.matches($0.citation.title, requested: document) } : exact
            guard !pool.isEmpty else {
                return .problem("The last answer did not cite a manual called \"\(document)\". It cited "
                    + titles(all) + ". Nothing was opened.")
            }
        }
        let which = (rawWhich ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = which.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)

        // A table (Plan JJ P1): "the table" is the cited source that names a table, "Table 99"
        // the one that names that table, "the tables" every cited source that names one.
        if let label = TableReference.labels(in: which).first {
            let holding = pool.filter { ($0.citation.figure ?? "").caseInsensitiveCompare(label) == .orderedSame }
            guard !holding.isEmpty else {
                return .problem("The last answer did not cite \(label). It cited " + labels(pool) + ". Nothing was opened.")
            }
            return .sources(Array(holding.prefix(maximumPages)))
        }
        if words.contains("table") || words.contains("tables") {
            let tables = pool.filter { $0.citation.figure?.lowercased().hasPrefix("table") == true }
            guard let first = tables.first else {
                return .problem("The last answer did not cite a table. It cited " + labels(pool) + ". Nothing was opened.")
            }
            return .sources(words.contains("tables") ? Array(tables.prefix(maximumPages)) : [first])
        }
        // A clause number: the cited source that holds it.
        if let clause = ClauseReference.references(in: which).first {
            func holds(_ source: Source, reachingOnly: Bool) -> Bool {
                if let section = source.citation.section,
                   (ClauseReference.match(clause, in: section, section: section) ?? .cites) >= .startsSubclause {
                    return true
                }
                let pages = source.citation.page.map { $0...(source.citation.throughPage ?? $0) }
                return memory.retrieved(for: source.citation).contains { passage in
                    guard reachingOnly || (passage.page.flatMap { page in pages?.contains(page) } ?? false) else { return false }
                    return (ClauseReference.match(clause, in: passage.text, section: passage.section) ?? .cites) >= .continues
                }
            }
            // A chunk running onto the next page is on both (Plan KE P2), and the clause is on the
            // page the chunk is cited at. The next page has it only when nothing else cited does:
            // the model may have cited the mark inside the chunk.
            let cited = pool.filter { holds($0, reachingOnly: false) }
            let holding = cited.isEmpty ? pool.filter { holds($0, reachingOnly: true) } : cited
            guard !holding.isEmpty else {
                return .problem("The last answer did not cite clause \(clause). It cited "
                    + labels(pool) + ". Nothing was opened.")
            }
            return .sources(Array(holding.prefix(maximumPages)))
        }
        if words.contains(where: allWords.contains) {
            return .sources(Array(pool.prefix(maximumPages)))
        }
        if words.contains("last") || words.contains("latest") {
            return .sources([pool[pool.count - 1]])
        }
        if let ordinal = words.lazy.compactMap({ ordinals[$0] }).first {
            // With a manual named, "the second one" counts within that manual's sources.
            let numbered = pool
            guard ordinal <= numbered.count else {
                return .problem("The last answer cited \(numbered.count) source\(numbered.count == 1 ? "" : "s"): "
                    + labels(numbered) + ". Nothing was opened.")
            }
            return .sources([numbered[ordinal - 1]])
        }
        // "The page", "it", "that", or nothing: the first source the answer cited.
        return .sources([pool[0]])
    }

    private static func titles(_ sources: [Source]) -> String {
        var seen = Set<String>()
        return sources.map(\.citation.title).filter { seen.insert($0).inserted }.joined(separator: "; ")
    }

    private static func labels(_ sources: [Source]) -> String {
        sources.map { "\($0.number). \($0.citation.label)" }.joined(separator: "; ")
    }
}

// MARK: - Putting the pages on the phone

/// A set of cited pages for the sheet.
struct SourcePagesRequest: Equatable, Identifiable {
    let id = UUID()
    let pages: [FieldSessionService.StagedFigure]
    /// Which page the sheet opens on. Those before it are already on the phone (`TurnPageStack`).
    var opening = 0
}

/// The pages `manual_figure` put up in one turn (Plan KE P2). "Show me page 12 and the wiring
/// diagram" is two calls, and each staged one page, so the second took the place of the first. They
/// add up instead, oldest first, up to what one sheet holds; the newest is the one that opens. A
/// page asked for again moves to the end rather than stopping twice, and a new turn starts fresh.
/// Pure.
struct TurnPageStack: Equatable {
    private(set) var turn: String?
    private(set) var pages: [FieldSessionService.StagedFigure] = []

    /// Add a page for `turn`, and return the sheet's pages.
    mutating func adding(_ page: FieldSessionService.StagedFigure, turn: String) -> [FieldSessionService.StagedFigure] {
        if turn != self.turn {
            self.turn = turn
            pages = []
        }
        pages.removeAll { $0.documentId == page.documentId && $0.page == page.page }
        pages.append(page)
        pages = Array(pages.suffix(ShowSourceResolver.maximumPages))
        return pages
    }
}

/// Holds the answer's sources for the session and puts the pages `show_source` resolved in front of
/// the technician — now when the app is in front, or as soon as it is when the phone is locked or
/// the app is in the background, with a notification saying where the page is. Nothing here claims
/// a page is on screen when it is not.
@MainActor
final class ShowSourceCenter: ObservableObject {

    static let shared = ShowSourceCenter()

    private(set) var memory = AnswerSourceMemory()
    /// The request the app should present now.
    @Published private(set) var presented: SourcePagesRequest?
    /// A request made while the app could not show it.
    private(set) var waiting: SourcePagesRequest?

    /// Seams for the tests: whether the app is in front, and how a waiting page is announced.
    var isAppActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    var announce: (String) -> Void = ShowSourceCenter.postNotification

    private var activeObserver: NSObjectProtocol?

    init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    // MARK: Memory

    func clearForAccessLoss() {
        memory = AnswerSourceMemory()
        presented = nil
        waiting = nil
    }

    func noteRetrieved(_ passages: [VaultRetriever.Passage], sessionId: String?) {
        memory.noteRetrieved(passages.compactMap(Self.retrieved), sessionId: sessionId)
    }

    func noteLookup(_ passages: [VaultRetriever.Passage], sessionId: String?) {
        memory.noteLookup(passages.compactMap(Self.retrieved), sessionId: sessionId)
    }

    /// A table lookup answered (Plan JJ P1) with these citations, reading these row passages.
    func noteTableLookup(rows: [AnswerSourceMemory.Retrieved], citations: [Citation],
                         pictureAreas: [ManualTable.PictureArea] = [], sessionId: String?) {
        memory.noteTableLookup(rows: rows, citations: citations, pictureAreas: pictureAreas, sessionId: sessionId)
    }

    func noteAnswer(_ text: String, sessionId: String?) {
        memory.noteAnswer(CitationLineParser.parse(text), text: text, sessionId: sessionId)
    }

    /// The regions to outline for a table citation a lookup read from a picture (Plan JN P2).
    func pictureAreas(for citation: Citation) -> [ManualTable.PictureArea] {
        memory.pictureAreas(for: citation)
    }

    /// A cited page made ready to open: its passages to mark and, for a citation that names a range,
    /// the page of it holding them (Plan KE P2). A command and a tap both come through here, so
    /// neither can open what the other would not. `pageText` is asked only for a range.
    func placing(_ staged: FieldSessionService.StagedFigure, for citation: Citation, store: DocumentStore?,
                 number: Int? = nil, pageText: (Int) -> String?) -> FieldSessionService.StagedFigure {
        var placed = staged
        placed.citedPassages = citedPassages(for: citation, documentId: staged.documentId, store: store, number: number)
        placed.pictureAreas = pictureAreas(for: citation)
        if let first = citation.page, let last = citation.throughPage, !placed.citedPassages.isEmpty {
            let place = CitedPagePlacement.place(placed.citedPassages, among: first...last, pageText: pageText)
            placed.page = place.page
            placed.citedPassages = place.passages
        }
        return placed
    }

    /// The cited passages to mark for a citation opened in `documentId`, numbered as the answer
    /// numbered the citation (or 1 when it is not in the last answer — a chip on an older answer).
    func citedPassages(for citation: Citation, documentId: String, store: DocumentStore?,
                       number: Int? = nil) -> [CitedPassage] {
        guard let store else { return [] }
        let position = number ?? (memory.citations.firstIndex {
            $0.title.lowercased() == citation.title.lowercased() && $0.page == citation.page
        }.map { $0 + 1 } ?? 1)
        return memory.marking(citation).passages
            .filter { $0.documentId == documentId }
            .compactMap { store.anchor(documentId: $0.documentId, chunkIndex: $0.chunkIndex) }
            .map { CitedPassage(number: position, anchor: $0) }
    }

    // MARK: Presenting

    /// Put `pages` on the phone. Returns true when they are on screen now; false when they are
    /// waiting for the app to come to the front, in which case `notice` has been announced.
    @discardableResult
    func present(_ pages: [FieldSessionService.StagedFigure], notice: String, opening: Int = 0) -> Bool {
        guard !pages.isEmpty else { return false }
        let request = SourcePagesRequest(pages: pages, opening: opening)
        if isAppActive() {
            waiting = nil
            presented = request
            return true
        }
        waiting = request
        announce(notice)
        return false
    }

    /// The app came to the front — by the notification's tap or any other way. A waiting page opens.
    func appBecameActive() {
        guard let waiting else { return }
        self.waiting = nil
        presented = waiting
    }

    // MARK: Helpers

    private static func retrieved(_ passage: VaultRetriever.Passage) -> AnswerSourceMemory.Retrieved? {
        guard passage.source == .manual || passage.source == .capturedManual else { return nil }
        return .init(documentId: passage.documentId, documentName: passage.documentName,
                     chunkIndex: passage.chunkIndex, page: passage.page, section: passage.section,
                     text: passage.text, figure: passage.figure, isTableRow: passage.kind == .tableRow,
                     pageBreaks: passage.pageBreaks)
    }

    /// "AS/NZS 3000, page 112, §3.9.4.2 — tap to open". The citation is the vault's own label; no
    /// passage text goes on the lock screen.
    static func noticeText(for citation: Citation) -> String {
        "\(citation.label) — tap to open"
    }

    private static func postNotification(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Manual page ready"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "show-source-page", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
