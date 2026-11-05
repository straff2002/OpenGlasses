import Foundation
#if canImport(OpenGlasses)
@testable import OpenGlasses
#endif

/// The local retrieval eval: an answer key run through the shipped retriever, scored as hit@1 and
/// hit@4, with every miss put in the class that explains it.
///
/// Shared by two runners so both measure the same thing:
/// - `LocalManualEvalTests` in the simulator, through the session's own retriever factory, on the
///   simulator's embedder (`nl-word`);
/// - `Scripts/retrieval-eval` on a Mac, which compiles this file with the app's real
///   `DocumentStore` and `VaultRetriever`, on the device's embedding model (`nl-sentence`, or the
///   contextual model when asked).
///
/// **Nothing here prints a question, a passage or a document title.** The answer key and the
/// manuals behind it are often licensed to one person — a code book, a training workbook — so a
/// run's output is aggregate counts only, safe to paste into a plan or a PR. The answer key format
/// and how to write one from your own material are in `Scripts/retrieval-eval/README.md`.
enum RetrievalEval {

    // MARK: - The answer key

    /// One line of an answer key (JSON lines). A question is scored against what it expects:
    /// clause or rule numbers and table labels a passage must print (`rules`, `tables`), or pages
    /// of a named document a passage must come from (`pages`). `outOfScope` marks a question the
    /// manuals do not answer, which the gate should refuse.
    struct Question: Decodable, Equatable {
        let q: String
        var rules: [String]?
        var tables: [String]?
        /// Document title → the pages that answer it.
        var pages: [String: [Int]]?
        var outOfScope: Bool?
        /// Needs several rules or a calculation: one-passage hit@k is the wrong test for it.
        var multi: Bool?
        /// The expected answer itself is in doubt (a hard-to-read key, a corrected answer).
        var doubt: Bool?
        var note: String?

        var expectsLabels: [String] { (rules ?? []) + (tables ?? []) }
        var isScorable: Bool { !expectsLabels.isEmpty || !(pages ?? [:]).isEmpty }
    }

    /// Reads JSON lines. Blank lines and lines starting with `//` are skipped, as is any object
    /// without a question.
    static func loadAnswerKey(_ text: String) -> [Question] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }
            return try? JSONDecoder().decode(Question.self, from: Data(trimmed.utf8))
        }
    }

    /// The chunker a runner indexes with: the shipped one, or an earlier behaviour to measure a
    /// chunking change against (`RETRIEVAL_EVAL_CHUNKER`): "spaces" joins every sentence with a
    /// space and never splits at clause headings (before Plan IV P3), "linebreaks" keeps line
    /// breaks but doesn't split. Index each variant into its own work folder.
    static func chunker(named name: String?) -> DocumentChunker {
        switch name {
        case "spaces": return DocumentChunker(keepsLineBreaks: false, chunksAtClauseHeadings: false)
        case "linebreaks": return DocumentChunker(keepsLineBreaks: true, chunksAtClauseHeadings: false)
        default: return DocumentChunker()
        }
    }

    // MARK: - The retriever under test

    /// Which routes a table's row passages are searched by (Plan JJ P1), to measure what they do
    /// to a book's numbers: `all` as shipped (every route, and the table route), `none` as before
    /// P0 (no route, no table route), `tokenAndTable` with them out of the semantic and lexical
    /// defaults but still reached by an exact token and by a table the question names, and
    /// `tableOnly` reached only by a table the question names.
    /// `RETRIEVAL_EVAL_TABLE_ROWS` = `1`, `0`, `token` or `table` on the Mac runner.
    enum TableRows: String { case all = "1", none = "0", tokenAndTable = "token", tableOnly = "table" }
    nonisolated(unsafe) static var tableRows: TableRows = .all

    /// The shipped retrieval routes over one store, with the given gate — the routes
    /// `FieldSessionService.makeRetriever` builds, without the session's namespaces, availability
    /// check or model scope. For a runner that has no session (the Mac script, the calibration
    /// test). `LocalManualEvalTests` checks it ranks exactly as the session's factory does.
    @MainActor
    static func retriever(over store: DocumentStore, policy: RetrievalEvidencePolicy) -> VaultRetriever {
        retriever(over: store, policy: policy, documentIds: nil)
    }

    @MainActor
    private static func retriever(over store: DocumentStore, policy: RetrievalEvidencePolicy,
                                  documentIds ids: [String]?) -> VaultRetriever {
        let rows = tableRows
        let searched: Set<DocumentChunker.Kind> = rows == .all ? DocumentStore.searchedKinds : [.prose]
        let tokenKinds = Set(DocumentChunker.Kind.allCases)
            .subtracting(rows == .none || rows == .tableOnly ? [.tableRow] : [])
        return VaultRetriever(
            query: { query, limit in store.query(query, limit: limit, documentIds: ids, kinds: searched) },
            tokenSearch: { token, limit in store.passages(containingToken: token, documentIds: ids, limit: limit, kinds: tokenKinds) },
            clauseSearch: { clause, limit in store.passages(clause: clause, documentIds: ids, limit: limit) },
            termSearch: { query, limit in store.passages(sharingTermsWith: query, limit: limit, documentIds: ids, kinds: searched) },
            tableSearch: rows == .none ? nil : { label in store.passages(table: label, namespace: nil, documentIds: ids) },
            tableCatalogue: { store.storedTables(namespace: nil, documentIds: ids).map {
                TableReference.Entry(label: $0.table.label, title: $0.table.title)
            } },
            termStatistics: { store.termStatistics(namespaces: nil) },
            policy: policy)
    }

    /// The same routes, searching only what the newest-edition default (or the question's own
    /// reach past it) allows — the filter `makeRetriever` applies (Plan IV P2), for a runner with
    /// no session.
    @MainActor
    static func retriever(over store: DocumentStore, policy: RetrievalEvidencePolicy,
                          editions: DocumentEditions, turn: String) -> VaultRetriever {
        guard let titles = editions.searchableTitles(for: EditionRequest.parse(turn, editions: editions),
                                                     among: store.documents.map(\.name)) else {
            return retriever(over: store, policy: policy)
        }
        let ids = store.documents.filter { titles.contains($0.name) }.map(\.id)
        return retriever(over: store, policy: policy, documentIds: ids)
    }

    /// What a model would retry with after a miss, simulated deterministically (Plan IV P5): the
    /// clause numbers a document's index gives for the question, or the headings of the passages
    /// nearest it. The real retry is the model's; this measures how often the hint holds the way.
    enum Retry: String { case index, headings }
    nonisolated(unsafe) static var retry: Retry?

    @MainActor
    private static func retried(_ q: Question, kind: Retry, gated: VaultRetriever, open: VaultRetriever,
                                store: DocumentStore) -> Bool {
        let turn: String
        switch kind {
        case .index:
            let refs = store.documents.compactMap { store.backOfBookIndex(documentId: $0.id) }
                .flatMap { $0.references(for: q.q, limit: 3) }
            guard !refs.isEmpty else { return false }
            turn = refs.map { $0.hasPrefix("Table") ? $0 : "rule " + $0 }.joined(separator: " ")
        case .headings:
            let headings = open.retrieve(.init(turn: q.q, limit: 3)).passages.compactMap(\.section)
            guard !headings.isEmpty else { return false }
            turn = Array(NSOrderedSet(array: headings)).compactMap { $0 as? String }.joined(separator: "; ")
        }
        return gated.retrieve(.init(turn: turn, limit: 4)).passages.prefix(4).contains { holds($0, q) }
    }

    // MARK: - Scoring

    /// Why a question missed hit@4, first class that fits, in this order.
    enum MissClass: String, CaseIterable {
        /// The expected rule or table is never printed as its own heading in the documents
        /// searched — another edition's number, or a doubtful key.
        case notInDocuments = "expected label not printed in these documents"
        /// The rule's continuation (the chunk after its heading) is in the top 4 without its number.
        case chunkBoundary = "chunk boundary"
        /// Near-identical passages from different documents take slots; removing them would hit.
        case duplicates = "duplicates across documents"
        /// The expected passage is in the top 30 candidates, outranked.
        case ranking = "ranking (in the top 30)"
        /// The expected passage is not in the top 30 candidates at all.
        case recall = "recall (not in the top 30)"
    }

    struct Report: Equatable {
        var scored = 0
        var hit1 = 0
        var hit4 = 0
        var outOfScope = 0
        var refused = 0
        /// Scored (in-scope) questions the gate turned away with "the manuals do not cover this".
        var inScopeRefused = 0
        var misses: [MissClass: Int] = [:]
        var multiQuestions = 0, multiMisses = 0
        /// Distinct expected rule numbers the documents print as a heading, and how many of those
        /// no chunk is graded as starting (`ClauseReference` `.starts`) — the measure of whether
        /// a rule's own text can be found by its number.
        var rulesPrinted = 0, rulesNeverStarting = 0
        /// Missed questions a guided retry would have found (`retry`), as an estimate of the model
        /// taking the hint a lookup gives it.
        var retryHits = 0
        /// The passages as the app sends them (Plan IV P6: six when the best passage is from a
        /// clause-numbered document, four otherwise), when the run was given the limit: questions
        /// answered somewhere in what was sent, how many passages and characters went, refusals.
        var sentMeasured = false
        var hitSent = 0, passagesSent = 0, charactersSent = 0, inScopeRefusedSent = 0, refusedSent = 0
        var doubtQuestions = 0, doubtMisses = 0
        /// Scored questions that name a table (Plan JJ P1) by number or by title words, how many of
        /// them expect a table label, and their hit@4.
        var tableNamed = 0, tableNamedByTitle = 0, tableNamedExpectingTable = 0, tableNamedHit4 = 0

        var missCount: Int { scored - hit4 }

        /// Aggregate lines only — never a question or a passage.
        func lines(label: String, embedder: String) -> [String] {
            func rate(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.2f", Double(n) / Double(d)) }
            var out = ["[EVAL] \(label) embedder=\(embedder) scored=\(scored) hit@1 \(hit1) (\(rate(hit1, scored))) "
                       + "hit@4 \(hit4) (\(rate(hit4, scored)))"
                       + " | in-scope refused \(inScopeRefused)"
                       + (outOfScope > 0 ? " | out-of-scope refused \(refused) of \(outOfScope)" : "")]
            if missCount > 0 {
                let parts = MissClass.allCases.compactMap { c -> String? in
                    guard let n = misses[c], n > 0 else { return nil }
                    return "\(c.rawValue) \(n) (\(Int((100 * Double(n) / Double(missCount)).rounded()))%)"
                }
                out.append("[EVAL]   misses \(missCount): " + parts.joined(separator: " · "))
            }
            if rulesPrinted > 0 {
                out.append("[EVAL]   rules printed as a heading \(rulesPrinted), never graded as starting \(rulesNeverStarting)")
            }
            if sentMeasured, scored > 0 {
                out.append("[EVAL]   as sent: hit \(hitSent) (\(rate(hitSent, scored))) · passages \(String(format: "%.1f", Double(passagesSent) / Double(scored)))"
                           + " · characters \(charactersSent / scored) per question · in-scope refused \(inScopeRefusedSent)"
                           + (outOfScope > 0 ? " · out-of-scope refused \(refusedSent) of \(outOfScope)" : ""))
            }
            if let retry = RetrievalEval.retry {
                out.append("[EVAL]   estimate, one guided retry (\(retry.rawValue)): \(retryHits) of \(missCount) misses found")
            }
            if tableNamed > 0 {
                out.append("[EVAL]   naming a table: \(tableNamed) (\(tableNamedByTitle) by title words), "
                           + "\(tableNamedExpectingTable) expecting a table, hit@4 \(tableNamedHit4)")
            }
            if multiQuestions + doubtQuestions > 0 {
                out.append("[EVAL]   overlays: multi-rule or calculation \(multiQuestions) (\(multiMisses) missed) · "
                           + "answer in doubt \(doubtQuestions) (\(doubtMisses) missed)")
            }
            return out
        }
    }

    /// What a passage is to a question: it holds the answer (prints an expected label, or sits on
    /// an expected page), or not.
    static func holds(_ p: VaultRetriever.Passage, _ q: Question) -> Bool {
        if let pages = q.pages, let page = p.page, pages[p.documentName]?.contains(page) == true { return true }
        return q.expectsLabels.contains { label in
            ClauseReference.match(label, in: p.text, section: p.section) != nil
                || (p.figure ?? "").caseInsensitiveCompare(label) == .orderedSame
                || CodeTokenizer.contains(p.text, token: label) && !looksLikeClause(label)
        }
    }

    /// A clause or rule number ("99-200", "3.9.4.2"); a table label ("Table 99") is not one.
    private static func looksLikeClause(_ label: String) -> Bool {
        label.range(of: #"^\d+([.\-]\d+)+$"#, options: .regularExpression) != nil
    }

    /// Run every question. `gated` is the retriever as shipped (its gate decides); `open` is the
    /// same routes with no gate, read to 30 deep to tell a ranking miss from a recall miss.
    /// `classifyMisses: false` counts hits and refusals only, for a sweep over many gates.
    @MainActor
    static func run(_ questions: [Question], gated: VaultRetriever, open: VaultRetriever,
                    store: DocumentStore, classifyMisses: Bool = true, passageLimit: ManualPassageLimit? = nil) -> Report {
        run(questions, gatedFor: { _ in gated }, openFor: { _ in open }, store: store, classifyMisses: classifyMisses,
            passageLimit: passageLimit)
    }

    /// The same, with a retriever per question: the session's factory reads the question to
    /// choose an edition (Plan IV P2), so the runner hands it each one.
    @MainActor
    static func run(_ questions: [Question], gatedFor: (String) -> VaultRetriever, openFor: (String) -> VaultRetriever,
                    store: DocumentStore, classifyMisses: Bool = true, passageLimit: ManualPassageLimit? = nil) -> Report {
        var report = Report()
        report.sentMeasured = passageLimit != nil
        let searchesClauseNumbered = store.documents.contains { store.usesClausePassageBudget(documentId: $0.id) }
        let searchesTableRows = tableRows != .none && store.hasTableRows(documentIds: store.documents.map(\.id))
        func sent(_ gated: VaultRetriever, _ q: Question) -> RetrievalOutcome? {
            passageLimit?.retrieve(.init(turn: q.q), with: gated, searchesClauseNumbered: searchesClauseNumbered,
                                   searchesTableRows: searchesTableRows,
                                   isClauseNumbered: { store.usesClausePassageBudget(documentId: $0) })
        }
        for q in questions {
            let gated = gatedFor(q.q), open = openFor(q.q)
            if q.outOfScope == true {
                report.outOfScope += 1
                if !gated.retrieve(.init(turn: q.q, limit: 4)).isSufficient { report.refused += 1 }
                if let sent = sent(gated, q), !sent.isSufficient { report.refusedSent += 1 }
                continue
            }
            guard q.isScorable else { continue }
            report.scored += 1
            if q.multi == true { report.multiQuestions += 1 }
            if q.doubt == true { report.doubtQuestions += 1 }

            let outcome = gated.retrieve(.init(turn: q.q, limit: 4))
            if !outcome.isSufficient { report.inScopeRefused += 1 }
            if let sent = sent(gated, q) {
                if !sent.isSufficient { report.inScopeRefusedSent += 1 }
                if sent.passages.contains(where: { holds($0, q) }) { report.hitSent += 1 }
                report.passagesSent += sent.passages.count
                report.charactersSent += sent.passages.reduce(0) { $0 + $1.text.count }
            }
            let top4 = Array(outcome.passages.prefix(4))
            let catalogue = store.storedTables(namespace: nil).map { TableReference.Entry(label: $0.table.label, title: $0.table.title) }
            if !TableReference.references(in: q.q, catalogue: catalogue).isEmpty {
                report.tableNamed += 1
                if TableReference.labels(in: q.q).isEmpty { report.tableNamedByTitle += 1 }
                if !(q.tables ?? []).isEmpty { report.tableNamedExpectingTable += 1 }
                if top4.contains(where: { holds($0, q) }) { report.tableNamedHit4 += 1 }
            }
            if top4.first.map({ holds($0, q) }) == true { report.hit1 += 1 }
            if top4.contains(where: { holds($0, q) }) { report.hit4 += 1; continue }

            if q.multi == true { report.multiMisses += 1 }
            if q.doubt == true { report.doubtMisses += 1 }
            if let retry = RetrievalEval.retry, retried(q, kind: retry, gated: gated, open: open, store: store) { report.retryHits += 1 }
            guard classifyMisses else { continue }
            report.misses[classify(q, top4: top4, gated: gated, open: open, store: store), default: 0] += 1
        }
        if classifyMisses {
            let rules = Set(questions.filter { $0.outOfScope != true }.flatMap { $0.rules ?? [] }).filter(looksLikeClause)
            for rule in rules where !ownPassages(Question(q: "", rules: [rule]), store: store).isEmpty {
                report.rulesPrinted += 1
                let starts = store.passages(containingToken: rule, limit: Int.max).contains {
                    ClauseReference.match(rule, in: $0.text, section: $0.section) == .starts
                }
                if !starts { report.rulesNeverStarting += 1 }
            }
        }
        return report
    }

    @MainActor
    private static func classify(_ q: Question, top4: [VaultRetriever.Passage], gated: VaultRetriever,
                                 open: VaultRetriever, store: DocumentStore) -> MissClass {
        let own = ownPassages(q, store: store)
        if own.isEmpty, !q.expectsLabels.isEmpty, (q.pages ?? [:]).isEmpty { return .notInDocuments }
        // A page expectation has no "rest of the rule": the chunk after a page's last one is
        // simply the next page. Only a label's heading has a continuation.
        let labelled = q.expectsLabels.isEmpty ? [] : ownPassages(Question(q: q.q, rules: q.rules, tables: q.tables), store: store)
        let continuation = Set(labelled.map { Key(documentId: $0.documentId, chunkIndex: $0.chunkIndex + 1) })
            .subtracting(own)
        if top4.contains(where: { continuation.contains(Key($0)) }) { return .chunkBoundary }

        var deduped: [VaultRetriever.Passage] = []
        for p in gated.retrieve(.init(turn: q.q, limit: 12)).passages
        where !deduped.contains(where: { nearDuplicate($0, p) }) {
            deduped.append(p)
        }
        if deduped.prefix(4).contains(where: { holds($0, q) }) { return .duplicates }

        let ranked = open.retrieve(.init(turn: q.q, limit: 30)).passages
        if ranked.contains(where: { own.contains(Key($0)) || holds($0, q) }) { return .ranking }
        return .recall
    }

    struct Key: Hashable {
        let documentId: String
        let chunkIndex: Int
        init(documentId: String, chunkIndex: Int) { self.documentId = documentId; self.chunkIndex = chunkIndex }
        init(_ p: VaultRetriever.Passage) { self.init(documentId: p.documentId, chunkIndex: p.chunkIndex) }
        init(_ p: DocumentStore.Passage) { self.init(documentId: p.documentId, chunkIndex: p.chunkIndex) }
    }

    /// Where the expected answer's own text is: a chunk on an expected page, or a chunk that prints
    /// an expected label as a heading — the number then a capitalised title — rather than citing it
    /// ("Rule 99-200 2)", "see Table 99").
    @MainActor
    static func ownPassages(_ q: Question, store: DocumentStore) -> Set<Key> {
        var own = Set<Key>()
        for (title, pages) in q.pages ?? [:] {
            guard let doc = store.document(named: title) else { continue }
            for page in pages {
                store.passages(onPage: page, documentIds: [doc.id], limit: 1_000).forEach { own.insert(Key($0)) }
            }
        }
        for label in q.expectsLabels {
            for p in store.passages(containingToken: label, limit: Int.max)
            where printsAsHeading(label, in: p.text, section: p.section) {
                own.insert(Key(p))
            }
        }
        return own
    }

    private static let notHeadingBefore: Set<String> = [
        "rule", "rules", "and", "to", "or", "with", "see", "of", "in", "under", "per", "table", "tables",
        "clause", "clauses", "section", "sections",
    ]

    static func printsAsHeading(_ label: String, in text: String, section: String?) -> Bool {
        if (ClauseReference.match(label, in: text, section: section) ?? .cites) >= .continues { return true }
        let pattern = #"(\S+)?\s*(?<![\p{L}\p{N}.\-])"# + NSRegularExpression.escapedPattern(for: label)
            + #"\s+\p{Lu}\p{Ll}"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = m.range(at: 1).location == NSNotFound ? ""
                : ns.substring(with: m.range(at: 1)).lowercased().trimmingCharacters(in: .punctuationCharacters)
            if !notHeadingBefore.contains(before) { return true }
        }
        return false
    }

    // MARK: - Ranking features (Plan KN P1)

    /// One candidate of one question, as the runner writes it to `RETRIEVAL_EVAL_FEATURES`: numbers
    /// and flags, and the embedder's model id. **No string from the vault or the answer key**: the
    /// question is its line number in the key, the document its place in the manifest.
    struct FeatureLine: Encodable, Equatable {
        /// The keys a line carries besides the features. `embedder` is the only string.
        static let fixedKeys = ["q", "rank", "label", "oos", "family", "embedder", "schema", "doc", "chunk"]

        /// The question's 1-based line number among the key's questions.
        let q: Int
        /// The candidate's 0-based place in today's order.
        let rank: Int
        /// 1 when the passage holds the answer (`holds`), else 0; nil (written null) out of scope.
        let label: Int?
        let oos: Bool
        /// The manual family's number (`RETRIEVAL_EVAL_FAMILY`), 0 when not given.
        let family: Int
        /// The embedder's model id, from the app (`Embedder.modelId`), never the vault.
        let embedder: String
        let schema: Int
        /// The passage's document's 1-based place in the vault manifest, 0 when not found there.
        let doc: Int
        let chunk: Int
        let features: RankingFeatures

        private enum Key: String, CodingKey { case q, rank, label, oos, family, embedder, schema, doc, chunk }

        /// The fixed keys and the features in one flat object.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(q, forKey: .q)
            try c.encode(rank, forKey: .rank)
            if let label { try c.encode(label, forKey: .label) } else { try c.encodeNil(forKey: .label) }
            try c.encode(oos, forKey: .oos)
            try c.encode(family, forKey: .family)
            try c.encode(embedder, forKey: .embedder)
            try c.encode(schema, forKey: .schema)
            try c.encode(doc, forKey: .doc)
            try c.encode(chunk, forKey: .chunk)
            try features.encode(to: encoder)
        }

        /// One JSON line, keys sorted.
        func encoded() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    /// Every candidate of every scored and out-of-scope question, from the ungated retriever read
    /// 30 deep — the candidates `classify` reads — each with its features and its label.
    /// `documentIndex` maps a document id to its 1-based place in the manifest.
    @MainActor
    static func featureLines(_ questions: [Question], openFor: (String) -> VaultRetriever, family: Int,
                             embedder: String, documentIndex: (String) -> Int?) -> [FeatureLine] {
        var lines: [FeatureLine] = []
        for (index, q) in questions.enumerated() {
            let oos = q.outOfScope == true
            guard oos || q.isScorable else { continue }
            let (outcome, candidates) = openFor(q.q).retrieveWithFeatures(.init(turn: q.q, limit: 30))
            let features = Dictionary(candidates.map { (Key($0.passage), $0.features) }, uniquingKeysWith: { first, _ in first })
            for (rank, passage) in outcome.passages.prefix(30).enumerated() {
                guard let f = features[Key(passage)] else { continue }
                lines.append(FeatureLine(q: index + 1, rank: rank, label: oos ? nil : (holds(passage, q) ? 1 : 0),
                                         oos: oos, family: family, embedder: embedder,
                                         schema: RankingFeatures.schemaVersion,
                                         doc: documentIndex(passage.documentId) ?? 0, chunk: passage.chunkIndex,
                                         features: f))
            }
        }
        return lines
    }

    /// Two passages from different documents sharing most of their words — the same table printed
    /// in two manuals, the same rule in two editions.
    static func nearDuplicate(_ a: VaultRetriever.Passage, _ b: VaultRetriever.Passage) -> Bool {
        guard a.documentId != b.documentId else { return false }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let x = words(a.text), y = words(b.text)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }
}
