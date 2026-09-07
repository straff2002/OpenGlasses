import Foundation

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

        init(turn: String? = nil, ocrText: String? = nil, procedureStep: String? = nil, limit: Int = 4) {
            self.turn = turn
            self.ocrText = ocrText
            self.procedureStep = procedureStep
            self.limit = limit
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
        /// Code-like tokens from the request found verbatim in this passage.
        let matchedTokens: [String]
        /// The passage's document was read, at least in part, by recognition rather than a text
        /// layer. Numbers are where recognition fails quietly, so the reader is told.
        var recognisedFromScan: Bool = false

        /// The sentence appended to a recognised passage's citation.
        static let provenanceNote = "(text recognised from a scan; verify figures against the printed page)"

        /// Machine-attached citation: title, page, section. Never something the model recalled.
        var citation: String {
            var parts = [documentName]
            if let page { parts.append("page \(page)") }
            if let section, !section.isEmpty { parts.append("§\(section)") }
            return parts.joined(separator: ", ")
        }
    }

    typealias QueryFunction = (_ query: String, _ limit: Int) -> [DocumentStore.Passage]
    /// Exact whole-token search, for the code-like tokens the embedder cannot represent — a bare
    /// "ZX9" has no word vector, so without this a fault-code query would retrieve nothing.
    typealias TokenSearch = (_ token: String, _ limit: Int) -> [DocumentStore.Passage]

    /// Whether a document (by id) was read by recognition. Nil means "unknown", treated as no.
    typealias Provenance = (_ documentId: String) -> Bool

    var query: QueryFunction
    var tokenSearch: TokenSearch?
    var provenance: Provenance?
    var policy = RetrievalEvidencePolicy()

    init(query: @escaping QueryFunction, tokenSearch: TokenSearch? = nil,
         provenance: Provenance? = nil,
         policy: RetrievalEvidencePolicy = RetrievalEvidencePolicy()) {
        self.query = query
        self.tokenSearch = tokenSearch
        self.provenance = provenance
        self.policy = policy
    }

    func retrieve(_ request: Request) -> RetrievalOutcome {
        let parts = [request.turn, request.ocrText, request.procedureStep]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence) }

        // Boost tokens: anything code-like the technician said or the camera read.
        let boostTokens = Array(Set(
            CodeTokenizer.codeTokens(from: request.turn ?? "") + CodeTokenizer.codeTokens(from: request.ocrText ?? "")
        )).sorted()

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
        func consider(_ raw: DocumentStore.Passage) {
            let key = "\(raw.documentId)#\(raw.chunkIndex)"
            let matched = boostTokens.filter { CodeTokenizer.contains(raw.text, token: $0) }
            let candidate = scored(raw, matched: matched)
            if let existing = merged[key], existing.score >= candidate.score { return }
            merged[key] = candidate
        }
        for q in queries {
            query(q, max(request.limit * 2, 4)).forEach(consider)
        }
        if let tokenSearch {
            for token in boostTokens {
                tokenSearch(token, max(request.limit * 2, 4)).forEach(consider)
            }
        }

        // Exact-token hits rank ahead of everything else, then score within each group. An
        // embedder scores a whole manual's prose alike (0.87–0.91 on the word-average backend), so
        // an additive boost cannot lift the row that actually names the code above prose that
        // merely sounds like it. Filling rather than replacing: token hits take the first slots,
        // the best semantic passages take whatever `limit` leaves — a spoken sentence carrying a
        // code gets the code's row *and* its context.
        func precedes(_ a: Passage, _ b: Passage) -> Bool {
            a.score != b.score ? a.score > b.score
                : (a.documentName, a.chunkIndex) < (b.documentName, b.chunkIndex)
        }
        let candidates = Array(merged.values)
        let ranked = candidates.filter { !$0.matchedTokens.isEmpty }.sorted(by: precedes)
            + candidates.filter { $0.matchedTokens.isEmpty }.sorted(by: precedes)
        // The lexical criterion compares a passage against everything that was searched, not just
        // the spoken turn: a nameplate's words and the running procedure step are as much a part of
        // what was asked as the sentence is.
        return policy.decide(ranked, limit: request.limit,
                             queryTerms: LexicalSupport.contentTerms(parts.joined(separator: " ")))
    }

    private func scored(_ raw: DocumentStore.Passage, matched: [String]) -> Passage {
        let boost = min(policy.maxBoost, policy.tokenBoost * Float(matched.count))
        return Passage(documentId: raw.documentId, documentName: raw.documentName, chunkIndex: raw.chunkIndex,
                       text: raw.text, page: raw.page, section: raw.section,
                       similarity: raw.similarity, score: raw.similarity + boost, matchedTokens: matched,
                       recognisedFromScan: provenance?(raw.documentId) ?? false)
    }

    // MARK: - Rendering

    /// The block appended to the system prompt for a turn. States insufficiency explicitly so the
    /// model does not fall back to general knowledge silently.
    static func promptBlock(_ outcome: RetrievalOutcome) -> String {
        switch outcome {
        case .sufficient(let passages):
            let body = passages.enumerated().map { i, p in
                "[\(i + 1)] \(p.text)\nSource: \(p.citation)\(p.recognisedFromScan ? " " + Passage.provenanceNote : "")"
            }.joined(separator: "\n\n")
            return """
            MANUAL PASSAGES (retrieved for this turn — the only reference material available beyond the vault core; \
            answer from these and repeat each passage's Source line for any claim drawn from it):

            \(body)
            """
        case .insufficient(let reason):
            return "MANUAL PASSAGES: none retrieved for this turn. \(reason)"
        }
    }

    /// Tool-result rendering: same passages, numbered, with an instruction the model can act on.
    static func toolResult(_ outcome: RetrievalOutcome, query: String) -> String {
        switch outcome {
        case .sufficient(let passages):
            let body = passages.enumerated().map { i, p in
                "[\(i + 1)] \(p.text)\nSource: \(p.citation)\(p.recognisedFromScan ? " " + Passage.provenanceNote : "")"
            }.joined(separator: "\n\n")
            return "Manual passages for '\(query)' — answer using only these and cite each Source line you rely on:\n\n\(body)"
        case .insufficient(let reason):
            return reason
        }
    }
}

enum RetrievalOutcome: Equatable {
    case sufficient([VaultRetriever.Passage])
    case insufficient(reason: String)

    var passages: [VaultRetriever.Passage] {
        if case .sufficient(let p) = self { return p }
        return []
    }
    var isSufficient: Bool {
        if case .sufficient = self { return true }
        return false
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

    static let insufficientSentence =
        "The loaded manuals do not cover this. Ask the technician for the model number, or recommend escalation rather than guessing."

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
    /// - `nl-sentence`, `nl-contextual` — **unmeasured — device run pending.** Left at today's
    ///   values (floor 0.30, no margin, no lexical criterion) rather than guessed: their cosines
    ///   span a different range and the lexical rule may be unnecessary once similarity separates.
    static func `default`(for modelId: String) -> RetrievalEvidencePolicy {
        if modelId.hasPrefix("nl-word") {
            return RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.75)
        }
        return RetrievalEvidencePolicy()
    }

    /// Whether a passage is evidence. `bestSimilarity` and `queryTerms` are what the relative and
    /// lexical criteria need; omitting either switches that criterion off, so the two-argument form
    /// is exactly the original floor-or-token gate.
    func isEvidence(_ passage: VaultRetriever.Passage,
                    bestSimilarity: Float? = nil,
                    queryTerms: Set<String>? = nil) -> Bool {
        if !passage.matchedTokens.isEmpty { return true }
        guard passage.similarity >= similarityFloor else { return false }
        if let bestSimilarity, margin.isFinite, passage.similarity < bestSimilarity - margin { return false }
        if minSharedTerms > 0, let queryTerms {
            let required = requiredSharedTerms(queryTermCount: queryTerms.count)
            guard LexicalSupport.sharedTermCount(text: passage.text, queryTerms: queryTerms) >= required else {
                return false
            }
        }
        return true
    }

    func decide(_ ranked: [VaultRetriever.Passage], limit: Int, queryTerms: Set<String>? = nil) -> RetrievalOutcome {
        let best = ranked.map(\.similarity).max()
        let evidence = ranked.filter { isEvidence($0, bestSimilarity: best, queryTerms: queryTerms) }
        guard !evidence.isEmpty else { return .insufficient(reason: Self.insufficientSentence) }
        return .sufficient(Array(evidence.prefix(max(limit, 1))))
    }
}
