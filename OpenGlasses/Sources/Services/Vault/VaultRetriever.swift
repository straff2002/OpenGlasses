import Foundation

/// Which corpus a retrieved passage came from (Plan FP §5). Set by the caller from the namespace it
/// queried — the retriever never infers it from text — so a team learning cannot be mistaken for
/// OEM evidence anywhere downstream. Not `provenance`: that name is the recognised-from-scan
/// closure.
enum RetrievalSource: String, Equatable, Codable, Sendable {
    /// A page of a manual imported into the vault (`vault:<id>`).
    case manual
    /// An approved team learning published for the vault (`learning:<id>`).
    case teamLearning
    case capturedManual

    var isReference: Bool { self != .teamLearning }
}

/// Retrieves reference-tier passages for a Field Assist turn and decides, deterministically,
/// whether they are evidence enough to answer from.
///
/// Pure over an injected query function, so the ranking and the evidence gate are tested without
/// SQLite or an embedding model. Hybrid scoring: the store's embedding similarity, plus an exact
/// whole-token boost for code-like tokens ("E5", "30RB") found verbatim in a passage — embeddings
/// handle "the unit short-cycles on a call for cooling" and handle "E5" badly, and the fault-code
/// case is the whole point of the workflow.
struct VaultRetriever {

    /// One retrieval request. Each non-empty part becomes its own query and the results merge.
    struct Request: Equatable {
        var turn: String?
        /// Raw OCR text from a nameplate or fault display; its code-like tokens are boosted.
        var ocrText: String?
        /// Title of the active procedure step, when one is running.
        var procedureStep: String?
        var limit: Int = 4
        /// What the job is about, for a follow-up that does not say (`JobSearchContext`, Plan KE
        /// P1). Searched and compared like the step's title, and deliberately never a boost token:
        /// the model's own number is on half the vault's pages and would vouch for all of them.
        var jobContext: String?

        init(turn: String? = nil, ocrText: String? = nil, procedureStep: String? = nil, limit: Int = 4,
             jobContext: String? = nil) {
            self.turn = turn
            self.ocrText = ocrText
            self.procedureStep = procedureStep
            self.limit = limit
            self.jobContext = jobContext
        }
    }

    struct Passage: Equatable {
        let documentId: String
        let documentName: String
        let chunkIndex: Int
        let text: String
        let page: Int?
        let section: String?
        /// Embedding similarity as reported by the store.
        let similarity: Float
        /// Similarity plus the token boost — the ranking key.
        let score: Float
        /// Code-like tokens — and clause numbers — from the request found verbatim in this passage.
        var matchedTokens: [String]
        /// Those of `matchedTokens` that only name a model of the vault (Plan KG P0). They rank and
        /// propose the passage as any token does, but no longer carry it past the gate: the page
        /// listing the model prints the number whatever was asked. Empty for a turn that asks for
        /// nothing but the model.
        var matchedModels: [String] = []
        /// A code the turn named is in the passage: a fault code, a part number, a clause or a table.
        /// A model number is not one of these.
        var hasEvidenceToken: Bool { matchedTokens.contains { !matchedModels.contains($0) } }
        /// Subtracted from `score` when this passage names a model the session is not working on
        /// (Plan EL §4). Kept beside `score` rather than folded into it so a passage's own strength
        /// stays readable in a log or a test while the ranking reflects the machine in the room.
        var modelPenalty: Float = 0
        /// The passage's document was read, at least in part, by recognition rather than a text
        /// layer. Numbers are where recognition fails quietly, so the reader is told.
        var recognisedFromScan: Bool = false
        /// What kind of page the passage came off (Plan EK).
        var kind: DocumentChunker.Kind = .prose
        /// The figure or table that names the passage's place ("Figure 58"), when it has one.
        var figure: String?
        /// The manual, or an approved team learning (Plan FP P2). A learning's `documentName` is
        /// its contract §7.1 citation name, so `citation` renders it unchanged.
        var source: RetrievalSource = .manual
        var printedPage: Int?
        /// The passage's edition, when the turn asked for an older edition or to compare (Plan IV
        /// P2). The model is told it before the text, and the `Source:` line stays the document's
        /// own title, so a citation still opens its page.
        var editionLabel: String?
        /// How the passage relates to a clause number the request named (Plan IN P3a), when it
        /// does. Ranks the clause's own text ahead of passages that only cite it.
        var clauseMatch: ClauseReference.Match?
        /// The passage belongs to a table the request named (Plan JJ P1): one of its rows, or a
        /// passage of the page it is printed on. Ranks ahead of everything else, the clause's own
        /// text included.
        var tableMatch = false
        /// The rule the passage's document is read with (Plan JY P0); the question is compared
        /// with it under the same rule. A passage built without one is read with today's.
        var termRule: TermRule = .english
        /// The passage has no vector because its document's script model is not on the phone
        /// yet (Plan JY P1): the gate judges it by its words, under the stricter rule.
        var vectorPending = false
        /// The pages a chunk packed across a page break sits on (Plan KE P2). `text` carries no
        /// mark of them, so the gate, token matching and the highlight read what the page printed;
        /// `markedText` is what the model reads.
        var pageBreaks: [DocumentChunker.PageBreak] = []
        /// What is printed on those pages, by physical page, where the manual's labels say.
        var printedLabels: [Int: String] = [:]

        typealias Source = RetrievalSource

        /// How a team-learning passage is labelled to the model, before its text.
        static let teamLearningLabel = "TEAM LEARNING (not the manual)"

        /// The sentence appended to a recognised passage's citation.
        static let provenanceNote = "(text recognised from a scan; verify figures against the printed page)"

        /// Machine-attached citation: title, page, and the name of the place — the figure on a
        /// drawing, the section in prose. Never something the model recalled.
        ///
        /// **The kind decides which name is used, not which one is present.** A figure names a
        /// drawing; a section names prose. A prose paragraph printed under a caption is still
        /// prose, and citing it as "page 12, Figure 16" sends the reader to a picture that does not
        /// contain the sentence they were given — so prose cites its section even when it carries a
        /// figure. A drawing with no caption still says it is one, because "page 44" of a wiring
        /// diagram and "page 44" of a procedure are read very differently. A table's row passage
        /// (Plan JJ P0) names its table: the row is in it, by construction.
        ///
        /// A passage across a page break gives the range (Plan KE P2): one number would be wrong for
        /// some of its words, and the marks in `markedText` say which.
        var citation: String {
            var parts = [documentName]
            if let span = pageSpan {
                parts.append("pages \(span.first)\u{2013}\(span.last)")
            } else if let page {
                parts.append("page \(page)" + (printedPage.map { " (printed \($0))" } ?? ""))
            }
            if kind == .tableRow, let figure, !figure.isEmpty {
                parts.append(figure)
            } else if kind == .diagram {
                guard let figure, !figure.isEmpty else {
                    return parts.joined(separator: ", ") + " (diagram)"
                }
                parts.append(figure)
            } else if let section, !section.isEmpty {
                parts.append("§\(section)")
            }
            return parts.joined(separator: ", ")
        }

        /// The first and last page of a passage across a page break, nil on one page.
        var pageSpan: (first: Int, last: Int)? {
            let pages = pageBreaks.map(\.page)
            guard let first = pages.min(), let last = pages.max(), first != last else { return nil }
            return (first, last)
        }

        /// How one page reads in a mark: "[page 12 (printed 3-4)]".
        func pageMark(_ page: Int) -> String {
            "[page \(page)" + (printedLabels[page].map { " (printed \($0))" } ?? "") + "]"
        }

        /// The text the model reads: a mark where each page starts (Plan KE P2), so a step at the
        /// head of a page is cited at that page rather than at the chunk's. A chunk on one page
        /// reads as it always did.
        var markedText: String {
            guard !pageBreaks.isEmpty else { return text }
            let characters = Array(text)
            var marked = ""
            var from = 0
            for pageBreak in pageBreaks where pageBreak.offset >= from && pageBreak.offset <= characters.count {
                marked += String(characters[from..<pageBreak.offset]) + pageMark(pageBreak.page) + " "
                from = pageBreak.offset
            }
            return marked + String(characters[from...])
        }

        /// The key the ranked list is sorted by: the passage's own score, less any model-mismatch
        /// penalty.
        var rankScore: Float { score - modelPenalty }

        /// How a drawing is announced to the model before its text, so a bag of terminal labels is
        /// read as labels on a picture rather than as prose. Nil for an ordinary passage.
        var kindLabel: String? {
            if kind == .tableRow {
                // A sentence the app wrote from one row of an extracted table, not the page's own
                // words: the model is told so, and which table and page it came from.
                var parts = ["table row"]
                if let figure, !figure.isEmpty { parts.append(figure) }
                if let page { parts.append("page \(page)") }
                return "(" + parts.joined(separator: ", ") + ")"
            }
            guard kind == .diagram else { return nil }
            // A table page meets the same test as a drawing and is accepted there (its rows stay
            // token-searchable); calling it a wiring diagram would be a lie to the model.
            var parts = [figure?.hasPrefix("Table") == true ? "table" : "wiring diagram"]
            if let figure, !figure.isEmpty { parts.append(figure) }
            if let page { parts.append("page \(page)") }
            return "(" + parts.joined(separator: ", ") + ")"
        }
    }

    typealias QueryFunction = (_ query: String, _ limit: Int) -> [DocumentStore.Passage]
    /// Exact whole-token search, for the code-like tokens the embedder cannot represent — a bare
    /// "ZX9" has no word vector, so without this a fault-code query would retrieve nothing.
    typealias TokenSearch = (_ token: String, _ limit: Int) -> [DocumentStore.Passage]
    /// Search by clause number (Plan IN P3a), the clause's own text first — see
    /// `DocumentStore.passages(clause:)`.
    typealias ClauseSearch = (_ clause: String, _ limit: Int) -> [DocumentStore.Passage]
    /// Search by the question's content words ([[LexicalSupport]]), most shared first — see
    /// `DocumentStore.passages(sharingTermsWith:)`. The lexical route beside the embedding one.
    typealias TermSearch = (_ query: String, _ limit: Int) -> [DocumentStore.Passage]
    /// Every passage of one table by its label (Plan JJ P1) — its row passages, or its page's —
    /// see `DocumentStore.passages(table:)`. The retriever keeps the ones sharing the most of the
    /// question's words.
    typealias TableSearch = (_ label: String) -> [DocumentStore.Passage]
    /// The tables the searched manuals hold, by label and title, for recognising a table a
    /// question names by its title words.
    typealias TableCatalogue = () -> [TableReference.Entry]

    /// The searched corpus's term statistics (Plan IV P7), asked for once per retrieval — see
    /// `DocumentStore.termStatistics(namespaces:)`. Nil ranks by shared-word count, as before.
    typealias TermStatisticsSource = () -> LexicalSupport.TermStatistics?

    /// Whether a document (by id) was read by recognition. Nil means "unknown", treated as no.
    typealias Provenance = (_ documentId: String) -> Bool

    /// Whether a document may still be published, asked once per candidate immediately before the
    /// evidence gate runs.
    ///
    /// Retrieval and removal overlap by construction: a query is issued, the store is read, the
    /// passages are ranked — and a manual removal can complete anywhere in there, because both
    /// yield. Without this last check the turn would quote a manual the vault no longer has, which
    /// is precisely the guarantee removal exists to make. Nil means every candidate is available,
    /// which is the behaviour of every caller that has nothing to withhold.
    typealias Availability = (_ documentId: String) -> Bool
    /// Whether a token spells one of the vault's models (`VaultModelIndex.namesModel`, Plan KG P0).
    /// Beside `ModelScope` because the rule holds with no unit on the job.
    typealias ModelNames = (_ token: String) -> Bool
    /// The search by meaning and the search by words, each giving its usual best and the best of
    /// the unit's assigned documents from the one pass (Plan KG P4, `DocumentStore.bestAndBestWithin`).
    struct AssignedSearch {
        var query: (_ query: String, _ limit: Int, _ within: Set<String>) -> [DocumentStore.Passage]
        var terms: (_ query: String, _ limit: Int, _ within: Set<String>) -> [DocumentStore.Passage]
    }

    /// The machine the session is working on, and the other machines the vault covers (Plan EL).
    ///
    /// A manual for a family of units prints rows for all of them; the row for a *different* model
    /// is worse than useless in front of a technician holding the one in `activeTokens`. This ranks
    /// such a row down rather than dropping it — the model may still want it to say "that figure is
    /// for the 090" — and it does so inside each of the two ranking groups, so Plan EJ's invariant
    /// (an exact token hit outranks anything without one) is untouched.
    struct ModelScope: Equatable {
        /// Every spelling of the active model, uppercased.
        var activeTokens: Set<String>
        /// Every spelling of every *other* model the vault names, uppercased.
        var otherTokens: Set<String>
        var penalty: Float = 0.5
        /// The documents the vault's section for the active model names (Plan KE P1). A generic
        /// page of another family's manual names no model, so `penalty(for:)` cannot see it; the
        /// vault's own list can. Empty means the section names none, and nothing is scored by it.
        var assignedDocumentIds: Set<String> = []

        init(activeTokens: Set<String>, otherTokens: Set<String>, penalty: Float = 0.5,
             assignedDocumentIds: Set<String> = []) {
            self.activeTokens = activeTokens
            self.otherTokens = otherTokens.subtracting(activeTokens)
            self.penalty = penalty
            self.assignedDocumentIds = assignedDocumentIds
        }

        /// The penalty for one passage: it names another model and does not name this one.
        func penalty(for text: String) -> Float {
            guard !activeTokens.isEmpty, !otherTokens.isEmpty else { return 0 }
            let index = CodeTokenizer.TokenIndex(text)
            guard !activeTokens.contains(where: index.contains) else { return 0 }
            return otherTokens.contains(where: index.contains) ? penalty : 0
        }

        /// The penalty for a page of a vault manual: the one `penalty(for:)` gives, else the same
        /// amount for a document the active model is not assigned. Ranks down, never out, as Plan EL
        /// chose, and never twice.
        func penalty(for text: String, documentId: String) -> Float {
            let named = penalty(for: text)
            guard named == 0, !assignedDocumentIds.isEmpty, !assignedDocumentIds.contains(documentId) else { return named }
            return penalty
        }

        /// The penalty for a team learning, by **identity** (contract §7.2): its `modelToken`,
        /// trimmed and case-folded, is one of the active model's spellings or it is penalised. Its
        /// prose is never scanned. A practice entry (no model) is never penalised — it is scoped
        /// by topic, not by machine.
        func penalty(forSubjectToken token: String?) -> Float {
            guard let token = Self.identity(token), !activeTokens.isEmpty else { return 0 }
            return activeTokens.contains(token) ? 0 : penalty
        }

        /// A model token as identity compares it: trimmed and case-folded. Nil when empty.
        static func identity(_ token: String?) -> String? {
            guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).uppercased()
        }
    }

    var query: QueryFunction
    var tokenSearch: TokenSearch?
    var clauseSearch: ClauseSearch?
    var termSearch: TermSearch?
    var tableSearch: TableSearch?
    var tableCatalogue: TableCatalogue?
    var termStatistics: TermStatisticsSource?
    var provenance: Provenance?
    var availability: Availability?
    var policy = RetrievalEvidencePolicy()
    var modelScope: ModelScope?
    var modelNames: ModelNames?
    var assignedSearch: AssignedSearch?

    init(query: @escaping QueryFunction, tokenSearch: TokenSearch? = nil,
         clauseSearch: ClauseSearch? = nil, termSearch: TermSearch? = nil,
         tableSearch: TableSearch? = nil, tableCatalogue: TableCatalogue? = nil,
         termStatistics: TermStatisticsSource? = nil,
         provenance: Provenance? = nil, availability: Availability? = nil,
         policy: RetrievalEvidencePolicy = RetrievalEvidencePolicy(),
         modelScope: ModelScope? = nil, modelNames: ModelNames? = nil, assignedSearch: AssignedSearch? = nil) {
        self.query = query
        self.tokenSearch = tokenSearch
        self.clauseSearch = clauseSearch
        self.termSearch = termSearch
        self.tableSearch = tableSearch
        self.tableCatalogue = tableCatalogue
        self.termStatistics = termStatistics
        self.provenance = provenance
        self.availability = availability
        self.policy = policy
        self.modelScope = modelScope
        self.modelNames = modelNames
        self.assignedSearch = assignedSearch
    }

    /// Whether `token` is a model: the vault's list, else a spelling the scope carries.
    private func namesModel(_ token: String) -> Bool {
        if modelNames?(token) == true { return true }
        guard let modelScope else { return false }
        let key = ModelMention.key(token)
        return modelScope.activeTokens.contains { ModelMention.key($0) == key }
            || modelScope.otherTokens.contains { ModelMention.key($0) == key }
    }

    func retrieve(_ request: Request) -> RetrievalOutcome {
        let parts = [request.turn, request.ocrText, request.procedureStep, request.jobContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence) }

        // Clause numbers the technician named ("clause 3.9.4.2", "rule 26-700") are matched whole
        // (Plan IN P3a); their pieces are kept out of the per-token boost, or "26-700" would boost
        // every passage that prints a 26.
        let clauses = ClauseReference.references(in: request.turn ?? "")
        // A table the technician named ("table 99", "the conductor ratings table") is found whole by its
        // label (Plan JJ P1), ahead of the clause route, and its number is kept out of the boost
        // as a clause's pieces are.
        let tables = tableSearch == nil ? []
            : TableReference.references(in: request.turn ?? "", catalogue: tableCatalogue?() ?? [])
        // Boost tokens: anything code-like the technician said or the camera read, and any word
        // they said in capitals ("QXRT"). A page they named is where to look, not something to
        // look for, so its number is not one of them.
        let spokenTurn = PageReference.removingReferences(from: TableReference.removingReferences(
            from: ClauseReference.removingReferences(from: request.turn ?? "")))
        // A row key printed as a range ("7-9") is a designation too: kept whole, and counted only
        // when the manuals print it (Plan JJ P1).
        let designations = Set(CodeTokenizer.capitalisedDesignations(from: spokenTurn)
            + CodeTokenizer.rangeKeys(from: spokenTurn))
        let spokenTokens = Array(Set(
            CodeTokenizer.codeTokens(from: spokenTurn) + designations
                + CodeTokenizer.codeTokens(from: request.ocrText ?? "")
        )).sorted()

        // The lexical criterion compares a passage against everything that was searched, not just
        // the spoken turn: a nameplate's words and the running procedure step are as much a part of
        // what was asked as the sentence is. The question is cut into terms under every rule, and
        // each passage compared under its own document's (Plan JY P0).
        let question = LexicalSupport.QueryTerms(parts.joined(separator: " "))

        // The exact-token search runs first, because what it finds decides which tokens count.
        // Its hits come back in document order, so for a token printed in more passages than the
        // search returns, which of them came back was decided by the manual's page order, not by
        // the token. A bare number is the usual case and is dropped from the boost: "34", "99",
        // "090" are table cells on page after page, and in the field (build 497) the first
        // vent-length tables of the installation instructions took every slot, for a page number
        // and for a fragment of a spoken model number alike; in a code book "14" (a wire gauge)
        // is on hundreds of pages and the first four pages of the book took them. It neither ranks
        // a passage first nor carries one past the gate. A number that names few passages ("what
        // does the 120 VAC output feed" on a drawing) is kept. A code or a designation is kept
        // however often it is printed — a cord type recurs in every table that lists it, and
        // again in each edition of a book — but when it overflows the search, the passages kept for it are the ones
        // that share the most of the question's words, not the first in page order. A word in
        // capitals counts only when the search finds it at all.
        let searchLimit = max(request.limit * 2, 4)
        var tokenHits: [String: [DocumentStore.Passage]] = [:]
        if let tokenSearch {
            for token in spokenTokens {
                var hits = tokenSearch(token, searchLimit + 1)
                if hits.count > searchLimit {
                    if CodeTokenizer.isNumber(token) { continue }
                    hits = Self.sharingMostWords(tokenSearch(token, Int.max), question: question,
                                                 limit: searchLimit)
                }
                tokenHits[token] = hits
            }
        }
        let boostTokens = spokenTokens.filter { token in
            // Without a token search nothing can vouch for a word in capitals, and every number
            // is kept as it always was.
            guard tokenSearch != nil else { return !designations.contains(token) }
            if designations.contains(token) { return !(tokenHits[token] ?? []).isEmpty }
            // A number that overflowed has no entry.
            return !CodeTokenizer.isNumber(token) || tokenHits[token] != nil
        }

        // A model number is not evidence (Plan KG P0). It still ranks and proposes passages, but the
        // page listing the model prints it whatever was asked, so the gate does not take it for an
        // answer and does not count it among the question's words: only that page can supply it.
        // `question` stays as it was for ranking, so BM25F scores what was asked and moves nothing.
        // A nameplate's model counts like a spoken one; a job's context is searched, never a token,
        // so its model only comes out of the words. Asked for alone, the page is the answer.
        let knowsModels = modelNames != nil || modelScope != nil
        let isModel: ModelNames = { namesModel($0) }
        let namedModels = knowsModels
            ? [request.turn, request.ocrText].compactMap { $0 }.reduce(into: Set<String>()) {
                $0.formUnion(ModelMention.words(in: $1, names: isModel))
            } : []
        let modelTokens = Set(boostTokens.filter { namedModels.contains($0.uppercased()) })
        let asksForTheModelAlone: Bool = {
            guard !modelTokens.isEmpty, clauses.isEmpty, tables.isEmpty else { return false }
            let rest = ModelMention.removing(from: spokenTurn, names: isModel)
            return LexicalSupport.contentTerms(rest).isEmpty && CodeTokenizer.codeTokens(from: rest).isEmpty
        }()
        let notEvidence = asksForTheModelAlone ? [] : modelTokens
        let gateQuestion = knowsModels
            ? LexicalSupport.QueryTerms(parts.map { ModelMention.removing(from: $0, names: isModel) }.joined(separator: " "))
            : question

        // The unit's assigned documents are searched too (Plan KG P4): in a vault of many families
        // other machines' near-identical pages fill the search's depth, and the document rule below
        // can only reorder what was found. Candidates only: the gate and the ranking judge them as
        // anything else, and other documents stay. Not for a turn naming another model, which is
        // asking about that machine and not the unit's.
        let namesAnotherModel = modelScope.map { scope in
            namedModels.contains { word in
                let key = ModelMention.key(word)
                return scope.otherTokens.contains { ModelMention.key($0) == key }
            }
        } ?? false
        let assigned = namesAnotherModel ? [] : modelScope?.assignedDocumentIds ?? []
        func searchByMeaning(_ text: String) -> [DocumentStore.Passage] {
            guard let assignedSearch, !assigned.isEmpty else { return query(text, searchLimit) }
            return assignedSearch.query(text, searchLimit, assigned)
        }
        func searchByWords(_ text: String, _ words: TermSearch) -> [DocumentStore.Passage] {
            guard let assignedSearch, !assigned.isEmpty else { return words(text, searchLimit) }
            return assignedSearch.terms(text, searchLimit, assigned)
        }

        // Query each part; the OCR part is queried as its tokens joined so a whole nameplate
        // dump does not drown the embedding in boilerplate.
        var queries = parts
        if let ocr = request.ocrText, !ocr.isEmpty {
            let tokens = CodeTokenizer.candidateTokens(from: ocr)
            if let index = queries.firstIndex(of: ocr.trimmingCharacters(in: .whitespacesAndNewlines)) {
                queries[index] = tokens.isEmpty ? ocr : tokens.joined(separator: " ")
            }
        }

        var merged: [String: Passage] = [:]
        func consider(_ raw: DocumentStore.Passage, foundForClause searched: String? = nil,
                      foundForTable table: String? = nil) {
            let key = "\(raw.documentId)#\(raw.chunkIndex)"
            var matched = boostTokens.filter { CodeTokenizer.contains(raw.text, token: $0) }
            var clauseMatch = raw.clauseMatch
            for clause in clauses {
                // A continuation chunk need not print the number; the clause search vouches for it.
                let match = ClauseReference.match(clause, in: raw.text, section: raw.section)
                    ?? (clause == searched ? raw.clauseMatch : nil)
                guard let match else { continue }
                matched.append(clause)
                clauseMatch = max(clauseMatch ?? match, match)
            }
            // A passage of a named table: one its caption names, whatever route found it, or one
            // the table route found on the page of a table whose grid was not read and that prints
            // the table's label — the page's other passages are about something else, and ranked
            // above the clauses they would take the first place from the passage that answers
            // (Plan JJ P5, measured on the code book's key).
            var tableMatch = false
            for label in tables
            where (label == table && (raw.kind == .tableRow || Self.prints(label, in: raw.text)))
                || (raw.figure ?? "").caseInsensitiveCompare(label) == .orderedSame {
                matched.append(label)
                tableMatch = true
            }
            var candidate = scored(raw, matched: matched)
            candidate.clauseMatch = clauseMatch
            candidate.tableMatch = tableMatch
            candidate.matchedModels = matched.filter(notEvidence.contains)
            if let existing = merged[key] {
                // Two routes reached the same chunk: keep the better score, and everything either
                // route knew about why it matched.
                var kept = existing.rankScore >= candidate.rankScore ? existing : candidate
                kept.matchedTokens = Array(Set(existing.matchedTokens + candidate.matchedTokens)).sorted()
                kept.matchedModels = Array(Set(existing.matchedModels + candidate.matchedModels)).sorted()
                kept.clauseMatch = [existing.clauseMatch, candidate.clauseMatch].compactMap { $0 }.max()
                kept.tableMatch = existing.tableMatch || candidate.tableMatch
                // The chunk's own state, whichever route reported it.
                kept.vectorPending = existing.vectorPending || candidate.vectorPending
                merged[key] = kept
                return
            }
            merged[key] = candidate
        }
        for q in queries {
            searchByMeaning(q).forEach { consider($0) }
        }
        for token in boostTokens {
            tokenHits[token]?.prefix(searchLimit).forEach { consider($0) }
        }
        if let clauseSearch {
            for clause in clauses {
                clauseSearch(clause, searchLimit).forEach { consider($0, foundForClause: clause) }
            }
        }
        // The table route (Plan JJ P1): the named table's passages, the rows sharing the most of
        // the question's words kept — "table 99, QXRT three conductors" keeps that row whichever
        // page of a long table it is on.
        if let tableSearch {
            for label in tables {
                Self.sharingMostWords(tableSearch(label), question: question, limit: searchLimit)
                    .forEach { consider($0, foundForTable: label) }
            }
        }
        // The lexical route (field report, build 497). "How to test the flame sensor readings or
        // signal" shares every content word but one with the Service Manual's flame-sensor
        // section — the one that says to read the signal in Field Test Mode — and the device's
        // sentence embedder ranked that passage 159th of 708, below a page of diagnostic-code
        // table rows that merely mention a flame. An embedder that cannot see a passage leaves it
        // unreachable unless something else proposes it; the question's own words do.
        if let termSearch, !question.isEmpty {
            for q in queries {
                searchByWords(q, termSearch).forEach { consider($0) }
            }
        }

        // Exact-token hits rank ahead of everything else, then words and score within each group. An
        // embedder scores a whole manual's prose alike (0.87–0.91 on the word-average backend), so
        // an additive boost cannot lift the row that actually names the code above prose that
        // merely sounds like it. Filling rather than replacing: token hits take the first slots,
        // the best semantic passages take whatever `limit` leaves — a spoken sentence carrying a
        // code gets the code's row *and* its context.
        func precedes(_ a: Passage, _ b: Passage) -> Bool {
            a.rankScore != b.rankScore ? a.rankScore > b.rankScore
                : (a.documentName, a.chunkIndex) < (b.documentName, b.chunkIndex)
        }
        // The availability check runs here, after everything has been gathered and before anything
        // is decided: this is the last moment at which the answer can still be "that manual is
        // gone" rather than a quotation from it.
        let candidates = availability.map { check in Array(merged.values).filter { check($0.documentId) } }
            ?? Array(merged.values)
        //
        // A clause number ranks above both (Plan IN P3a), by how the passage holds the clause: the
        // passage that starts it, then its subclauses, then the text that carries it on, then the
        // passages that only cite it. Without a clause in the request every passage is in group 0
        // or 1, which is the ordering above unchanged.
        // A table the request named ranks above all of them (Plan JJ P1), the way a clause does
        // above the token groups.
        func group(_ p: Passage) -> Int {
            (p.tableMatch ? 100 : 0) + (p.clauseMatch?.rawValue ?? 0) * 2 + (p.matchedTokens.isEmpty ? 0 : 1)
        }
        // Inside a group, the passage that shares more of the question's content words leads, and
        // the score decides between passages that share as many (field report, build 497). On the
        // device the sentence embedder ranked the flame-sensor section — four of the question's
        // five words, and the answer — below diagnostic-code rows sharing none, and the score alone
        // handed the model those rows. On the word-average backend the score is flat (every
        // passage 0.84–0.92), so the words were already the only real signal. Measured on the
        // Lennox pair with the lexical route beside it (`RetrievalGateCalibrationTests`): recall@4
        // under the nl-word gate 0.77 → 0.88 with the out-of-scope refusals unchanged at 0.78, and
        // under the sentence model's gate 0.12 → 0.53. Neither half does it alone: without the
        // route the passage is never a candidate, and without this order it is one, ranked last.
        // Without content terms (a bare "E223") every passage
        // shares none and the order is the score order, as before. Two rules stay ahead of the
        // words: a passage matching more of the spoken codes leads a token group, and a row for
        // another model sorts below this one's (Plan EL) whatever it shares.
        //
        // With the corpus's term statistics the words are weighed rather than counted (Plan IV
        // P7): BM25F, a section or clause heading's words counting three times a body word's. A
        // count treats a word printed on most of a book's pages like the rare word that names the
        // subject asked about, and cannot tell the passage whose heading names the subject
        // from one that mentions it in passing. Measured at the shipped candidate depth with the
        // device models: the answering passage first 0.35 → 0.39 of a code book's local answer key
        // (contextual model) and 0.67 → 0.83 of the field manual pair's, with no question lost.
        let statistics = candidates.isEmpty || question.isEmpty ? nil : termStatistics?()
        let lexical = Dictionary(candidates.map { passage in
            (Self.key(passage), statistics.map {
                $0.score(queryTerms: question.terms(for: passage.termRule), text: passage.text,
                         heading: passage.section, rule: passage.termRule)
            } ?? Double(LexicalSupport.sharedTermCount(text: passage.text, question: question, rule: passage.termRule)))
        }, uniquingKeysWith: max)
        let ranked = candidates.sorted { a, b in
            if group(a) != group(b) { return group(a) > group(b) }
            // Inside a named table, its rows before its page: a row is the data the question asks
            // for, the page the picture it is printed in.
            if a.tableMatch, b.tableMatch, (a.kind == .tableRow) != (b.kind == .tableRow) { return a.kind == .tableRow }
            if !clauses.isEmpty, a.clauseMatch != nil, b.clauseMatch != nil {
                let offsets = (ClauseReference.offset(of: clauses, in: a.text),
                               ClauseReference.offset(of: clauses, in: b.text))
                if offsets.0 != offsets.1 { return offsets.0 < offsets.1 }
            }
            if (a.modelPenalty > 0) != (b.modelPenalty > 0) { return b.modelPenalty > 0 }
            if a.matchedTokens.count != b.matchedTokens.count { return a.matchedTokens.count > b.matchedTokens.count }
            let words = (lexical[Self.key(a)] ?? 0, lexical[Self.key(b)] ?? 0)
            return words.0 != words.1 ? words.0 > words.1 : precedes(a, b)
        }
        let outcome = policy.decide(ranked, limit: request.limit, question: gateQuestion)
        if case .insufficient = outcome, ranked.contains(where: { !$0.matchedModels.isEmpty && $0.source.isReference }) {
            return .insufficient(reason: RetrievalEvidencePolicy.modelPageOnlySentence)
        }
        return outcome
    }

    private static func key(_ p: Passage) -> String { "\(p.documentId)#\(p.chunkIndex)" }

    /// The text prints the table's label as a whole ("Table 92", any case, any spacing; not
    /// "Table 921" or "Table 92A").
    static func prints(_ label: String, in text: String) -> Bool {
        let parts = label.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return false }
        let pattern = #"(?<![\p{L}\p{N}])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The `limit` passages sharing the most of the question's content terms, ties in the order
    /// given (document order, from the token search). `queryTerms` are compared under today's
    /// English rule whatever the passages' documents are; `sharingMostWords(_:question:limit:)`
    /// compares each passage under its own.
    static func sharingMostWords(_ passages: [DocumentStore.Passage], queryTerms: Set<String>,
                                 limit: Int) -> [DocumentStore.Passage] {
        sharingMostWords(passages, limit: limit) {
            LexicalSupport.sharedTermCount(text: $0.text, queryTerms: queryTerms)
        }
    }

    /// The `limit` passages sharing the most of the question's content terms, each passage
    /// compared under its own document's rule (Plan JY P0).
    static func sharingMostWords(_ passages: [DocumentStore.Passage], question: LexicalSupport.QueryTerms,
                                 limit: Int) -> [DocumentStore.Passage] {
        sharingMostWords(passages, limit: limit) {
            LexicalSupport.sharedTermCount(text: $0.text, question: question, rule: $0.termRule)
        }
    }

    private static func sharingMostWords(_ passages: [DocumentStore.Passage], limit: Int,
                                         shared count: (DocumentStore.Passage) -> Int) -> [DocumentStore.Passage] {
        // Typed step by step: as one chain this took seconds to type-check (Plan JW P1a).
        let counted: [(offset: Int, passage: DocumentStore.Passage, shared: Int)] = passages.enumerated().map { item in
            (offset: item.offset, passage: item.element, shared: count(item.element))
        }
        let ranked = counted.sorted { (a, b) -> Bool in a.shared != b.shared ? a.shared > b.shared : a.offset < b.offset }
        return ranked.prefix(limit).map { $0.passage }
    }

    private func scored(_ raw: DocumentStore.Passage, matched: [String]) -> Passage {
        let boost = min(policy.maxBoost, policy.tokenBoost * Float(matched.count))
        // A manual page is scoped by the models its text names and the documents the vault assigns
        // the model (Plan KE P1); a photographed manual is the job's own, in no vault's list; a team
        // learning by the model its entry is filed against, never by its prose (Plan FP §5,
        // contract §7.2).
        let penalty: Float
        switch raw.source {
        case .teamLearning: penalty = modelScope?.penalty(forSubjectToken: raw.subjectModelToken) ?? 0
        case .manual: penalty = modelScope?.penalty(for: raw.text, documentId: raw.documentId) ?? 0
        case .capturedManual: penalty = modelScope?.penalty(for: raw.text) ?? 0
        }
        return Passage(documentId: raw.documentId, documentName: raw.documentName, chunkIndex: raw.chunkIndex,
                       text: raw.text, page: raw.page, section: raw.section,
                       similarity: raw.similarity, score: raw.similarity + boost, matchedTokens: matched,
                       modelPenalty: penalty,
                       recognisedFromScan: raw.source.isReference && (provenance?(raw.documentId) ?? false),
                       kind: raw.kind, figure: raw.figure, source: raw.source, printedPage:raw.printedPage,
                       editionLabel: raw.editionLabel, termRule: raw.termRule, vectorPending: raw.vectorPending,
                       pageBreaks: raw.pageBreaks, printedLabels: raw.printedLabels)
    }

    // MARK: - Rendering

    /// The block appended to the system prompt for a turn. States insufficiency explicitly so the
    /// model does not fall back to general knowledge silently.
    ///
    /// `leadIn` is the deterministic sentence a learning-only answer opens with
    /// (`TeamLearningDisclosure.leadIn`); the caller composes it because the entry's job count is
    /// not the retriever's to know.
    static func promptBlock(_ outcome: RetrievalOutcome, characterLimit: Int = 12_000,
                            leadIn: String? = nil) -> String {
        let bounded = boundedOutcome(outcome, characterLimit: characterLimit)
        return unboundedPromptBlock(bounded.outcome, leadIn: leadIn) + bounded.notice
    }

    /// Select complete ranked passages, retaining citations, table headers and units together.
    /// Oversized evidence is explicitly unavailable; a partial warning must not look complete.
    static func boundedOutcome(_ outcome: RetrievalOutcome, characterLimit: Int) -> (outcome: RetrievalOutcome, notice: String) {
        let passages: [Passage]
        switch outcome {
        case .sufficient(let found), .teamLearningOnly(let found): passages = found
        case .insufficient: return (outcome, "")
        }
        var selected: [Passage] = []
        var remaining = max(0, characterLimit)
        var seen = Set<String>()
        for passage in passages {
            let key = "\(passage.documentId):\(passage.chunkIndex)"
            guard seen.insert(key).inserted else { continue }
            let cost = passage.text.utf8.count + passage.citation.utf8.count + 256
            guard cost <= remaining else { continue }
            selected.append(passage)
            remaining -= cost
        }
        let omitted = passages.count - selected.count
        guard omitted > 0 else { return (outcome, "") }
        let notice = "\n\n\(omitted) manual passages omitted by the context budget. Do not assume omitted warnings or evidence are absent; narrow the lookup or open the cited manual before relying on incomplete coverage."
        guard !selected.isEmpty else {
            return (.insufficient(reason: "Retrieved evidence could not fit as complete passages. Narrow the lookup; do not diagnose from missing evidence."), notice)
        }
        if case .teamLearningOnly = outcome { return (.teamLearningOnly(selected), notice) }
        // A bounded `.sufficient` keeps its promise: a learning is never sufficient alone, so a
        // budget that kept only learnings demotes the outcome rather than relabelling it.
        guard selected.contains(where: { $0.source.isReference }) else { return (.teamLearningOnly(selected), notice) }
        return (.sufficient(selected), notice)
    }

    /// One numbered passage as the model reads it: a team learning is labelled as one before its
    /// text, so it is never read as the manual's words.
    static func passageLine(_ index: Int, _ p: Passage) -> String {
        let label = p.source == .teamLearning ? Passage.teamLearningLabel + " "
            : (p.source == .capturedManual ? "PHOTOGRAPHED MANUAL (unreviewed; original job/date in citation) " : "")
                + (p.kindLabel.map { $0 + " " } ?? "")
                + (p.editionLabel.map { "(edition: \($0)) " } ?? "")
        return "[\(index + 1)] \(label)\(p.markedText)\nSource: \(p.citation)"
            + (p.recognisedFromScan ? " " + Passage.provenanceNote : "")
    }

    /// The standing instruction beside any team-learning passage (Plan FP §5).
    static let teamLearningRule = "Passages marked \(Passage.teamLearningLabel) are your organisation's crew's approved findings, not the manufacturer's manual: when you use one, say it is your crew's finding and repeat its Source line, and never let it override a safety note."

    /// The standing instruction beside any table-row passage (Plan JW P1a). The partner's table
    /// question was answered with no tool call, its value quoted from a row passage in this block —
    /// which may be a neighbouring row or column, and which `show_source` cannot then mark as the
    /// row the answer read. The value goes through `table_lookup`, which reads the cell and notes its
    /// row for "show me".
    static let tableRowRule = "Passages marked (table row …) are sentences the app wrote from a table's rows: "
        + "before you say a value from a table, read it with table_lookup (table, row, column) — never quote it from these."

    /// The standing instruction beside any passage that crosses a page (Plan KE P2). The citation
    /// rule itself is the block's; this says which page of the range a claim belongs to.
    static let pageMarkRule = "A mark such as [page 12] or [page 12 (printed 3-4)] inside a passage says the words after it, "
        + "up to the next mark, are on that page. For a claim from those words, cite that page, not the range on the "
        + "passage's Source line: repeat the line with \"page 12\" in place of its pages."

    /// The rules a set of passages calls for, each on its own paragraph after them.
    private static func rules(for passages: [Passage]) -> String {
        var rules: [String] = []
        if passages.contains(where: { !$0.pageBreaks.isEmpty }) { rules.append(pageMarkRule) }
        if passages.contains(where: { $0.source == .teamLearning }) { rules.append(teamLearningRule) }
        if passages.contains(where: { $0.kind == .tableRow }) { rules.append(tableRowRule) }
        return rules.map { "\n\n" + $0 }.joined()
    }

    /// What a learning-only answer is told: the manual is silent, open with the fixed sentence,
    /// then the finding named as the crew's.
    static func teamLearningOnlyInstruction(leadIn: String?) -> String {
        let opening = leadIn.map { "Open your answer with exactly this sentence: \"\($0.trimmingCharacters(in: .whitespaces))\" — then give the finding. " }
            ?? "Open your answer by saying the manual does not cover this and that what follows is your crew's own finding. "
        return "No passage in the loaded manuals answers this closely enough. What was retrieved instead is \(Passage.teamLearningLabel): "
            + opening
            + "Name it as your crew's finding, not the manufacturer's instruction — circumstances differ — repeat its Source line, "
            + "and never let it override a safety note."
    }

    private static func unboundedPromptBlock(_ outcome: RetrievalOutcome, leadIn: String?) -> String {
        switch outcome {
        case .sufficient(let passages):
            let body = passages.enumerated().map { passageLine($0, $1) }.joined(separator: "\n\n")
            let rule = rules(for: passages)
            return """
            MANUAL PASSAGES (retrieved for this turn — the only reference material available beyond the vault core; \
            answer from these and repeat each passage's Source line for any claim drawn from it):

            \(body)
            """ + rule
        case .teamLearningOnly(let passages):
            let body = passages.enumerated().map { passageLine($0, $1) }.joined(separator: "\n\n")
            return "MANUAL PASSAGES: none retrieved for this turn. " + teamLearningOnlyInstruction(leadIn: leadIn)
                + "\n\n" + body
        case .insufficient(let reason):
            return "MANUAL PASSAGES: none retrieved for this turn. \(reason)"
        }
    }

    /// Tool-result rendering: same passages, numbered, with an instruction the model can act on.
    static func toolResult(_ outcome: RetrievalOutcome, query: String, leadIn: String? = nil) -> String {
        let bounded = boundedOutcome(outcome, characterLimit: 12_000)
        return unboundedToolResult(bounded.outcome, query: query, leadIn: leadIn) + bounded.notice
    }

    private static func unboundedToolResult(_ outcome: RetrievalOutcome, query: String, leadIn: String?) -> String {
        switch outcome {
        case .sufficient(let passages):
            let body = passages.enumerated().map { passageLine($0, $1) }.joined(separator: "\n\n")
            let rule = rules(for: passages)
            return "Manual passages for '\(query)' — answer using only these and cite each Source line you rely on:\n\n\(body)" + rule
        case .teamLearningOnly(let passages):
            let body = passages.enumerated().map { passageLine($0, $1) }.joined(separator: "\n\n")
            return "No manual passage for '\(query)'. " + teamLearningOnlyInstruction(leadIn: leadIn) + "\n\n" + body
        case .insufficient(let reason):
            return reason
        }
    }
}

enum RetrievalOutcome: Equatable {
    /// A manual passage cleared the gate — possibly with team learnings beside it, each labelled.
    case sufficient([VaultRetriever.Passage])
    /// Only approved team learnings cleared the gate (Plan FP §5). Never a quiet pass and never a
    /// refusal: the answer opens by saying the manual does not cover this and that what follows is
    /// the crew's own finding.
    case teamLearningOnly([VaultRetriever.Passage])
    case insufficient(reason: String)

    var passages: [VaultRetriever.Passage] {
        switch self {
        case .sufficient(let p), .teamLearningOnly(let p): return p
        case .insufficient: return []
        }
    }
    /// The manual covers this. False on a learning-only outcome, by design: EJ's gate keeps
    /// meaning "the manual covers this".
    var isSufficient: Bool {
        if case .sufficient = self { return true }
        return false
    }
    var isTeamLearningOnly: Bool {
        if case .teamLearningOnly = self { return true }
        return false
    }
    /// Something may be answered from — the manual, or a learning disclosed as one.
    var answers: Bool { isSufficient || isTeamLearningOnly }
    /// The team-learning passages in the outcome, in rank order.
    var teamLearningPassages: [VaultRetriever.Passage] { passages.filter { $0.source == .teamLearning } }
}

/// How a piece of text names models, for the gate (Plan KG P0). A spelling the vault prints with
/// hyphens reaches the tokenizer in pieces, and each piece is as much the model as the whole. Pure.
enum ModelMention {

    /// A spelling as compared: uppercased, without its hyphens (`VaultModelIndex.key`).
    static func key(_ spelling: String) -> String {
        spelling.uppercased().replacingOccurrences(of: "-", with: "")
    }

    private static let run = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*"#)

    private static func runs(in text: String) -> [NSRange] {
        run.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    private static func isModel(_ word: String, names: (String) -> Bool) -> Bool {
        names(word) || (word.contains("-") && word.split(separator: "-").contains { names(String($0)) })
    }

    /// The words of `text` that are a model, uppercased: each spelling, and the pieces of a
    /// hyphenated one.
    static func words(in text: String, names: (String) -> Bool) -> Set<String> {
        let text = CodeTokenizer.foldedForms(text)
        let ns = text as NSString
        var found = Set<String>()
        for range in runs(in: text) {
            let word = ns.substring(with: range)
            guard isModel(word, names: names) else { continue }
            found.insert(word.uppercased())
            found.formUnion(word.split(separator: "-").map { $0.uppercased() })
        }
        return found
    }

    /// `text` with its models taken out.
    static func removing(from text: String, names: (String) -> Bool) -> String {
        let text = CodeTokenizer.foldedForms(text)
        let out = NSMutableString(string: text)
        for range in runs(in: text).reversed() where isModel(out.substring(with: range), names: names) {
            out.replaceCharacters(in: range, with: " ")
        }
        return out as String
    }
}

/// The evidence gate. A passage counts as evidence when it contains a code-like token from the
/// request verbatim — an exact fault-code hit is strong evidence even at a low cosine — or when it
/// clears every similarity-side criterion below. Nothing counts → the fixed insufficient sentence,
/// which the vault's prompt rules already tell the model to relay rather than improve on.
///
/// Three criteria, each independently switchable so a backend can use only what its scores support:
/// - `similarityFloor` — an absolute cosine floor.
/// - `margin` — a *relative* criterion: within `margin` of the best passage in the ranked list.
///   Note what this can and cannot do: the best passage always satisfies it, so a margin trims a
///   weak tail but can never on its own make a query insufficient.
/// - `minSharedTerms` — [[LexicalSupport]] content-word overlap with the question.
///
/// **Measured, not assumed** (2026-09-07, simulator, `nl-word.en`, the Lennox SLP99 manual pair,
/// 685 chunks, 12 in-scope and 12 out-of-scope questions):
/// similarity was flat and the two sides overlapped completely — positives min 0.838 / median 0.888
/// / max 0.917, negatives min 0.846 / median 0.876 / max 0.897 — so neither the floor nor the margin
/// can separate them at any setting, and the shipped 0.30 floor refused nothing at all. Only the
/// lexical criterion moves insufficiency recall off zero. See `RetrievalGateCalibrationTests`
/// for the instrument and `docs/plans/EJ-manual-retrieval-fidelity.md` §2 for the table.
struct RetrievalEvidencePolicy: Equatable {
    var similarityFloor: Float = 0.30
    /// Maximum shortfall from the best passage's similarity. `.infinity` disables the criterion.
    var margin: Float = .infinity
    /// Content terms a non-token passage must share with the question. 0 disables the criterion.
    var minSharedTerms: Int = 0
    /// Share of the question's *own* content terms that must be shared, when that is fewer than
    /// `minSharedTerms`. 0 disables the scaling and `minSharedTerms` applies as a flat count.
    ///
    /// A flat count is unreachable by construction for a question shorter than the count: "pre-purge
    /// time" has two content terms ([[LexicalSupport]] drops words under four letters), so a
    /// three-term rule refuses it whatever the manual says. Scaling asks a short question for
    /// proportionally less — 0.6 wants 2 terms of a 2- or 3-term question and 3 of a 5-term one —
    /// while never asking a long question for more than `minSharedTerms`.
    var sharedFraction: Double = 0
    var tokenBoost: Float = 0.25
    var maxBoost: Float = 0.5

    /// One language group's lexical criterion (Plan JY P3): the count and the share of the
    /// question's own terms a passage of that group must share, read like `minSharedTerms` and
    /// `sharedFraction`.
    struct LexicalCriterion: Equatable, Sendable {
        var minSharedTerms: Int
        var sharedFraction: Double
    }

    /// The criterion for each language group measured apart from English (Plan JY P3), the
    /// measured ones unless a caller sets others. A group with no entry — English always — uses
    /// `minSharedTerms` and `sharedFraction` above; with `minSharedTerms` 0 no group has one.
    var groupCriteria: [TermRule.Group: LexicalCriterion] = RetrievalEvidencePolicy.measuredGroupCriteria
    /// How much stricter the criterion is for a passage awaiting its script model, per group
    /// (Plan JY P3); a group with no entry uses `pendingVectorFractionIncrease`.
    var pendingIncrease: [TermRule.Group: Double] = [:]

    /// What a turn the gate turned away is told. It says the search came up short, not that the
    /// manuals are silent: measured on a field manual pair, the device gate (Plan IV P1) refuses a
    /// third of the in-scope questions it cannot place, and "the manuals do not cover this" told a
    /// technician something false about a book that does cover it.
    static let insufficientSentence =
        "No passage in the loaded manuals answers this closely enough to rely on. Say you couldn't find it "
        + "in the manuals — not that they don't cover it — and ask the technician for the model number or "
        + "different words. If it stays unanswered, name what is missing and offer an expert if one would help; "
        + "do not guess."

    /// What a turn is told when the only thing found prints the model it named (Plan KG P0): the
    /// manuals know the machine, and nothing on what was asked. A machine the vault covers is not
    /// refused, and as with `insufficientSentence`, a miss is not a reason to escalate.
    static let modelPageOnlySentence =
        "The manuals list this model, but no passage answers what was asked. Say you found the model's page and "
        + "nothing on this question, not that the manuals don't cover it, and ask the technician for different "
        + "words or the name of the part. If it stays unanswered, name what is missing and offer an expert if one "
        + "would help; do not guess."

    init(similarityFloor: Float = 0.30, margin: Float = .infinity, minSharedTerms: Int = 0,
         sharedFraction: Double = 0, tokenBoost: Float = 0.25, maxBoost: Float = 0.5) {
        self.similarityFloor = similarityFloor
        self.margin = margin
        self.minSharedTerms = minSharedTerms
        self.sharedFraction = sharedFraction
        self.tokenBoost = tokenBoost
        self.maxBoost = maxBoost
    }

    /// The shared-term count a question of `queryTermCount` terms actually has to meet: the flat
    /// `minSharedTerms`, lowered (never raised) to `ceil(sharedFraction × queryTermCount)` when the
    /// fraction is switched on, and never below 1.
    func requiredSharedTerms(queryTermCount: Int) -> Int {
        guard minSharedTerms > 0 else { return 0 }
        guard sharedFraction > 0, queryTermCount > 0 else { return minSharedTerms }
        return min(minSharedTerms, max(1, Int(ceil(sharedFraction * Double(queryTermCount)))))
    }

    /// The shared-term count a question of `queryTermCount` terms under `rule` has to meet (Plan
    /// JY P0), the terms counted under that rule.
    ///
    /// `.english` is `requiredSharedTerms(queryTermCount:)`, with the measured counts and
    /// per-backend fractions below. **The other rules are provisional:** they use the same
    /// formula and the same numbers until Plan JY P3 measures each language group. The numbers
    /// already fit their terms in the cases P0 pins: a prefix-stemmed Ukrainian question of four
    /// terms needs three, and a Chinese question cut into twelve bigrams needs the full three —
    /// the question-word pieces are dropped, but the pieces across word boundaries ("用了",
    /// "法来") are not, so a fraction of the bigram count would ask too much and the flat
    /// `minSharedTerms` is what binds.
    func requiredSharedTerms(queryTermCount: Int, rule: TermRule) -> Int {
        guard let criterion = groupCriteria[rule.group] else { return requiredSharedTerms(queryTermCount: queryTermCount) }
        guard minSharedTerms > 0 else { return 0 }
        return Self.required(queryTermCount: queryTermCount, minSharedTerms: criterion.minSharedTerms,
                             fraction: criterion.sharedFraction)
    }

    /// The formula every count shares: `minimum`, lowered to `ceil(fraction × terms)` when a
    /// fraction is set, never below 1.
    private static func required(queryTermCount: Int, minSharedTerms: Int, fraction: Double) -> Int {
        guard minSharedTerms > 0 else { return 0 }
        guard fraction > 0, queryTermCount > 0 else { return minSharedTerms }
        return min(minSharedTerms, max(1, Int(ceil(fraction * Double(queryTermCount)))))
    }

    /// How much stricter the lexical criterion is for a passage with no vector yet (Plan JY P1,
    /// owner decision 6): its share of the question's terms is raised by this much, capped at 1.
    /// **Provisional** — Plan JY P3 calibrates it per language group.
    static let pendingVectorFractionIncrease = 0.15

    /// The shared-term count a passage whose script model is pending (`vectorPending`) has to
    /// meet: the same formula with `sharedFraction` raised by `pendingVectorFractionIncrease`
    /// (capped at 1), still never more than `minSharedTerms` and never fewer than 1. A policy with
    /// no fraction asks the flat `minSharedTerms`, already its strictest. 0 when the lexical
    /// criterion is off.
    ///
    /// Such a passage has no similarity to clear the floor with, so it is judged on its words
    /// alone; asking a little more of them stands in for the missing second criterion. With the
    /// shipped fractions it binds for a three-term question under the contextual rule (2 → 3
    /// terms), and for a one- or two-term question nothing is looser than today.
    func requiredSharedTermsWithoutVector(queryTermCount: Int, rule: TermRule) -> Int {
        guard minSharedTerms > 0 else { return 0 }
        let criterion = groupCriteria[rule.group] ?? LexicalCriterion(minSharedTerms: minSharedTerms, sharedFraction: sharedFraction)
        guard criterion.sharedFraction > 0, queryTermCount > 0 else { return criterion.minSharedTerms }
        let increase = pendingIncrease[rule.group] ?? Self.pendingVectorFractionIncrease
        return Self.required(queryTermCount: queryTermCount, minSharedTerms: criterion.minSharedTerms,
                             fraction: min(1, criterion.sharedFraction + increase))
    }

    /// The defaults measured for an embedding backend, chosen by [[Embedder]] `modelId` prefix.
    ///
    /// - `nl-word` — **measured** on the Lennox pair (see the type's doc comment). The floor stays
    ///   at 0.30 because nothing in that backend's range is near it, the margin stays off because a
    ///   relative criterion cannot reject a query, and `minSharedTerms` is 3 — the measured knee:
    ///   1 shared term refuses 1 out-of-scope question in 5, 3 refuses 3 in 4 while *raising*
    ///   recall@4 (off-topic passages stop crowding the top four), and 4 refuses all of them but
    ///   also a third of the in-scope ones and drops recall@4 from 0.77 to 0.41.
    /// - `sharedFraction` is 0.75, measured on the same corpus after the question set was widened
    ///   with the short questions a technician mid-job actually asks. A flat count of 3 refuses a
    ///   two-term question ("pre-purge time") whatever the manual says; scaling it asks that
    ///   question for 2 terms and every question of four terms or more for the full 3. It refuses
    ///   fewer in-scope questions (2 of 17 rather than 3), raises recall@4 from 0.765 to 0.824, and
    ///   costs nothing on the out-of-scope side — insufficiency recall stays at 0.750, because the
    ///   short *out-of-scope* questions are asked for proportionally less too and still share
    ///   nothing. Fractions of 0.5 and 0.6 refuse no in-scope question at all but drop insufficiency
    ///   recall to 0.562 and 0.688, which is the wrong trade: a technician who has to rephrase is
    ///   recoverable, a confident answer from the wrong manual is not.
    /// - `nl-sentence` — **measured** (2026-10-17, the device's model run on a Mac through the
    ///   same retriever, `Scripts/retrieval-eval`): the same rule as `nl-word`. The bare 0.30 floor
    ///   refused none of the 18 out-of-scope Lennox questions, because this model's cosines sit
    ///   between 0.2 and 0.6 for everything and no floor separates an answer from a near miss. With
    ///   the lexical criterion it refuses 15 of 18, and recall@4 and hit@1 are unchanged on the
    ///   Lennox set and on a code book's 68-question local answer key. The cost is in-scope
    ///   refusals, 0 → 6 of 18 on Lennox and 0 → 2 of 68 on the code book, every one of them a
    ///   question whose four passages held no answering page anyway: it now hears "the manuals do
    ///   not cover this" instead of an answer built from the wrong pages. Gentler settings were
    ///   measured and buy back refusals only by answering out-of-scope questions again (one shared
    ///   term: 1 in-scope and 6 of 18 out-of-scope refused; 3 terms at 0.6: 4 and 14). The two
    ///   backends share one rule because the criterion reads words, not cosines.
    /// - `nl-contextual` — **measured** (Plan IV P4, the device's framework model run on a Mac):
    ///   three shared terms, scaled 0.6. The bare floor refused none of the 18 out-of-scope Lennox
    ///   questions. Swept on both sets, 0.6 refuses 12 of them with no in-scope question refused
    ///   and recall unchanged (Lennox 0.94, code book hit@4 0.53); 0.75, the other models' rule,
    ///   refuses 14 but turns away one in-scope question and drops Lennox recall to 0.89. Looser
    ///   settings refuse 2–7. This model ranks the answering passage high enough that the stricter
    ///   rule only costs answers.
    static func `default`(for modelId: String) -> RetrievalEvidencePolicy {
        if modelId.hasPrefix("nl-word") || modelId.hasPrefix("nl-sentence") {
            return RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.75)
        }
        if modelId.hasPrefix("nl-contextual") {
            return RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.6)
        }
        return RetrievalEvidencePolicy()
    }

    /// The language groups whose criterion Plan JY P3 measured apart from the backend's own
    /// (the parallel baseline and technical sets on each group's script model, Mac runner;
    /// the plan's P3 tables). Every other group keeps the backend's values, which P3 measured as
    /// the best of those tried for it. A group's documents are searched with their own script's
    /// model whatever the Latin backend is, so the value does not depend on it.
    static let measuredGroupCriteria: [TermRule.Group: LexicalCriterion] = [
        // Measured on the baseline: 0.5 over 0.6 — hit@4 15 → 18, in-scope refusals 20 → 15, one more
        // out-of-scope answer of 15.
        .arabic: LexicalCriterion(minSharedTerms: 3, sharedFraction: 0.5),
        // Measured on the baseline and a regulation in de, hu, pl: 0.75 over 0.6 — seven more
        // out-of-scope refusals of 90 for three hit@4 and four in-scope refusals of 173.
        .latinHeavy: LexicalCriterion(minSharedTerms: 3, sharedFraction: 0.75),
    ]

    /// Whether a passage is evidence. `bestSimilarity` and `queryTerms` are what the relative and
    /// lexical criteria need; omitting either switches that criterion off, so the two-argument form
    /// is exactly the original floor-or-token gate.
    ///
    /// `queryTerms` are compared under today's English rule, whatever the passage's document is;
    /// `isEvidence(_:bestSimilarity:question:)` compares under the passage's own rule.
    func isEvidence(_ passage: VaultRetriever.Passage,
                    bestSimilarity: Float? = nil,
                    queryTerms: Set<String>? = nil) -> Bool {
        if passage.hasEvidenceToken { return true }
        // No vector yet (Plan JY P1): its words decide, under the stricter count.
        if passage.vectorPending, minSharedTerms > 0, let queryTerms {
            let required = requiredSharedTermsWithoutVector(queryTermCount: queryTerms.count, rule: .english)
            return LexicalSupport.sharedTermCount(text: passage.text, queryTerms: queryTerms) >= required
        }
        // Reached by a model's number alone, it may never have been compared (Plan KG P0): its words decide.
        let byItsWords = !passage.matchedModels.isEmpty && minSharedTerms > 0
        guard byItsWords || passage.similarity >= similarityFloor else { return false }
        if !byItsWords, let bestSimilarity, margin.isFinite, passage.similarity < bestSimilarity - margin { return false }
        if minSharedTerms > 0, let queryTerms {
            let required = requiredSharedTerms(queryTermCount: queryTerms.count)
            guard LexicalSupport.sharedTermCount(text: passage.text, queryTerms: queryTerms) >= required else {
                return false
            }
        }
        return true
    }

    /// Whether a passage is evidence, its lexical criterion read under the passage's own rule
    /// (Plan JY P0): the question's terms under that rule, counted against the passage cut the
    /// same way, and the count required of a question of that many such terms. For a passage of
    /// an English document this is `isEvidence(_:bestSimilarity:queryTerms:)` with the question's
    /// English terms.
    func isEvidence(_ passage: VaultRetriever.Passage, bestSimilarity: Float? = nil,
                    question: LexicalSupport.QueryTerms) -> Bool {
        if passage.hasEvidenceToken { return true }
        // A passage whose script model is pending has no similarity to clear the floor or the
        // margin with (Plan JY P1, decision 6): its words decide, under the stricter count.
        if passage.vectorPending, minSharedTerms > 0 {
            let terms = question.terms(for: passage.termRule)
            let required = requiredSharedTermsWithoutVector(queryTermCount: terms.count, rule: passage.termRule)
            return LexicalSupport.sharedTermCount(text: passage.text, queryTerms: terms, rule: passage.termRule) >= required
        }
        let byItsWords = !passage.matchedModels.isEmpty && minSharedTerms > 0
        guard byItsWords || passage.similarity >= similarityFloor else { return false }
        if !byItsWords, let bestSimilarity, margin.isFinite, passage.similarity < bestSimilarity - margin { return false }
        if minSharedTerms > 0 {
            let terms = question.terms(for: passage.termRule)
            let required = requiredSharedTerms(queryTermCount: terms.count, rule: passage.termRule)
            guard LexicalSupport.sharedTermCount(text: passage.text, queryTerms: terms, rule: passage.termRule) >= required
            else { return false }
        }
        return true
    }

    /// The gate. **A team learning is never sufficient alone** (Plan FP §5): `.sufficient` needs a
    /// manual passage among the evidence, and then learnings that also cleared ride beside it;
    /// when only learnings clear, the outcome is the named `.teamLearningOnly`.
    func decide(_ ranked: [VaultRetriever.Passage], limit: Int, queryTerms: Set<String>? = nil) -> RetrievalOutcome {
        let best = ranked.map(\.similarity).max()
        return decide(limit: limit, evidence: ranked.filter { isEvidence($0, bestSimilarity: best, queryTerms: queryTerms) })
    }

    /// The gate with each passage's lexical criterion read under its own document's rule (Plan JY
    /// P0) — what retrieval runs.
    func decide(_ ranked: [VaultRetriever.Passage], limit: Int, question: LexicalSupport.QueryTerms) -> RetrievalOutcome {
        let best = ranked.map(\.similarity).max()
        return decide(limit: limit, evidence: ranked.filter { isEvidence($0, bestSimilarity: best, question: question) })
    }

    private func decide(limit: Int, evidence: [VaultRetriever.Passage]) -> RetrievalOutcome {
        guard !evidence.isEmpty else { return .insufficient(reason: Self.insufficientSentence) }
        let take = max(limit, 1)
        guard let bestManual = evidence.first(where: { $0.source.isReference }) else {
            return .teamLearningOnly(Array(evidence.prefix(take)))
        }
        var chosen = Array(evidence.prefix(take))
        // The limit must not cut the one passage that makes this sufficient: if learnings filled
        // every slot, the last of them gives way to the best manual passage.
        if !chosen.contains(where: { $0.source.isReference }) { chosen[chosen.count - 1] = bestManual }
        return .sufficient(chosen)
    }
}
