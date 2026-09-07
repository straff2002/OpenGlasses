import Foundation

/// Retrieval-quality measurement for choosing an embedding model from evidence rather than vibes.
///
/// The scoring (`recallAtK`, `meanReciprocalRank`) is pure and model-agnostic — feed it any retriever's
/// ranked output. `selfTest` runs a tiny built-in labelled corpus through a given [[Embedder]], so the
/// same number can be read on the `NLEmbedding` baseline (headless) and on `NLContextualEmbedding`
/// on-device once its asset is present.
enum EmbeddingBenchmark {

    struct LabeledQuery: Equatable { let query: String; let relevantId: String }

    /// Fraction of queries whose relevant id appears in the top-`k` ranked results.
    static func recallAtK(_ k: Int,
                          results: [(query: String, rankedIds: [String])],
                          labels: [String: String]) -> Double {
        guard !results.isEmpty, k > 0 else { return 0 }
        let hits = results.reduce(0) { acc, r in
            guard let want = labels[r.query] else { return acc }
            return r.rankedIds.prefix(k).contains(want) ? acc + 1 : acc
        }
        return Double(hits) / Double(results.count)
    }

    /// Mean reciprocal rank: average of 1/rank of the relevant id (0 when it isn't retrieved at all).
    static func meanReciprocalRank(results: [(query: String, rankedIds: [String])],
                                   labels: [String: String]) -> Double {
        guard !results.isEmpty else { return 0 }
        let total = results.reduce(0.0) { acc, r in
            guard let want = labels[r.query], let idx = r.rankedIds.firstIndex(of: want) else { return acc }
            return acc + 1.0 / Double(idx + 1)
        }
        return total / Double(results.count)
    }

    // MARK: - Built-in smoke corpus

    struct Sample { let id: String; let text: String }

    static let corpus: [Sample] = [
        Sample(id: "thermostat", text: "Hold the power button for ten seconds to reset the thermostat to factory defaults."),
        Sample(id: "wifi", text: "Open the companion app and choose Add Device to connect to your Wi-Fi network."),
        Sample(id: "battery", text: "Replacing the battery needs a Phillips screwdriver and two AA cells."),
        Sample(id: "warranty", text: "The warranty covers parts and labour for two years from purchase."),
        Sample(id: "recipe", text: "Whisk the eggs with sugar, then fold in the flour to make the sponge cake batter."),
        Sample(id: "weather", text: "A cold front brings rain and gusty winds across the coast tomorrow afternoon."),
    ]

    static let queries: [LabeledQuery] = [
        LabeledQuery(query: "how do I factory reset the thermostat", relevantId: "thermostat"),
        LabeledQuery(query: "connect the device to wireless internet", relevantId: "wifi"),
        LabeledQuery(query: "what tools to change the batteries", relevantId: "battery"),
        LabeledQuery(query: "how long is the guarantee", relevantId: "warranty"),
    ]

    /// Questions the corpus above has no passage for. Recall alone cannot see the failure that
    /// matters in the field — an assistant answering confidently from whatever the embedder ranked
    /// first — so a retrieval measurement needs negatives as well as labels.
    static let negatives: [String] = [
        "what is the torque setting for the compressor mounting bolts",
        "how do I calibrate the refrigerant charge on a heat pump",
        "which fuse protects the outdoor condenser fan",
        "what is the wiring colour code for the defrost board",
    ]

    /// Fraction of `results` (one entry per negative question, each with the ranked passages the
    /// retriever produced for it) that `policy` refuses to answer from.
    ///
    /// The complement of a false-confidence rate: 1.0 means every out-of-scope question produced the
    /// insufficiency sentence. Pure — it runs the shipped gate, including its lexical criterion, so
    /// the number is the gate's behaviour and not a re-implementation of it.
    static func insufficiencyRecall(policy: RetrievalEvidencePolicy,
                                    results: [(query: String, ranked: [VaultRetriever.Passage])],
                                    limit: Int = 4) -> Double {
        guard !results.isEmpty else { return 0 }
        let refused = results.reduce(0) { acc, r in
            let terms = LexicalSupport.contentTerms(r.query)
            return policy.decide(r.ranked, limit: limit, queryTerms: terms).isSufficient ? acc : acc + 1
        }
        return Double(refused) / Double(results.count)
    }

    /// The smoke corpus ranked for one query, shaped as retriever passages so the gate can be run
    /// over it. Semantic only — the built-in corpus carries no code-like tokens.
    static func rankedPassages(for query: String, using embedder: Embedder, limit: Int = 4) -> [VaultRetriever.Passage] {
        guard let qv = embedder.embed(query) else { return [] }
        return corpus.compactMap { sample -> VaultRetriever.Passage? in
            guard let v = embedder.embed(sample.text) else { return nil }
            let sim = Embedder.cosineSimilarity(qv, v)
            return VaultRetriever.Passage(documentId: sample.id, documentName: sample.id, chunkIndex: 0,
                                          text: sample.text, page: nil, section: nil,
                                          similarity: sim, score: sim, matchedTokens: [])
        }
        .sorted { $0.similarity > $1.similarity }
        .prefix(limit)
        .map { $0 }
    }

    /// Insufficiency recall over the built-in negatives, using `embedder` to rank the smoke corpus.
    /// Nil when the embedder can't produce vectors.
    static func insufficiencySelfTest(using embedder: Embedder,
                                      policy: RetrievalEvidencePolicy,
                                      limit: Int = 4) -> Double? {
        guard embedder.isAvailable else { return nil }
        let results = negatives.map { (query: $0, ranked: rankedPassages(for: $0, using: embedder, limit: limit)) }
        guard results.contains(where: { !$0.ranked.isEmpty }) else { return nil }
        return insufficiencyRecall(policy: policy, results: results, limit: limit)
    }

    /// Embed the corpus with `embedder`, rank each query by cosine, return recall@k over the built-in
    /// labels. Nil when the embedder can't produce vectors (no model available). Side-effect-free
    /// aside from the embedder itself.
    static func selfTest(using embedder: Embedder, k: Int = 1) -> Double? {
        guard embedder.isAvailable else { return nil }
        let vectors = corpus.compactMap { sample in embedder.embed(sample.text).map { (sample.id, $0) } }
        guard !vectors.isEmpty else { return nil }

        let results: [(query: String, rankedIds: [String])] = queries.compactMap { q in
            guard let qv = embedder.embed(q.query) else { return nil }
            let ranked = vectors
                .map { (id: $0.0, sim: Embedder.cosineSimilarity(qv, $0.1)) }
                .sorted { $0.sim > $1.sim }
                .map { $0.id }
            return (q.query, ranked)
        }
        let labels = Dictionary(uniqueKeysWithValues: queries.map { ($0.query, $0.relevantId) })
        return recallAtK(k, results: results, labels: labels)
    }
}
