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
        return policy.decide(ranked, limit: request.limit)
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

/// The evidence gate. A passage counts as evidence when its embedding similarity clears the floor
/// **or** it contains a code-like token from the request verbatim — an exact fault-code hit is
/// strong evidence even at a low cosine. Nothing counts → the fixed insufficient sentence, which
/// the vault's prompt rules already tell the model to relay rather than improve on.
struct RetrievalEvidencePolicy: Equatable {
    var similarityFloor: Float = 0.30
    var tokenBoost: Float = 0.25
    var maxBoost: Float = 0.5

    static let insufficientSentence =
        "The loaded manuals do not cover this. Ask the technician for the model number, or recommend escalation rather than guessing."

    init(similarityFloor: Float = 0.30, tokenBoost: Float = 0.25, maxBoost: Float = 0.5) {
        self.similarityFloor = similarityFloor
        self.tokenBoost = tokenBoost
        self.maxBoost = maxBoost
    }

    func isEvidence(_ passage: VaultRetriever.Passage) -> Bool {
        passage.similarity >= similarityFloor || !passage.matchedTokens.isEmpty
    }

    func decide(_ ranked: [VaultRetriever.Passage], limit: Int) -> RetrievalOutcome {
        let evidence = ranked.filter(isEvidence)
        guard !evidence.isEmpty else { return .insufficient(reason: Self.insufficientSentence) }
        return .sufficient(Array(evidence.prefix(max(limit, 1))))
    }
}
