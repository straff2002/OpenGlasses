import XCTest
@testable import OpenGlasses

/// Headless tests for the embedding benchmark: pure recall@k / MRR scoring (deterministic) plus a
/// smoke run of `selfTest` on whatever model the host has (skipped if none).
final class EmbeddingBenchmarkTests: XCTestCase {

    private let labels = ["q1": "a", "q2": "b", "q3": "c"]

    // MARK: - recall@k

    func testRecallAtKCountsTopKHits() {
        let results = [
            (query: "q1", rankedIds: ["a", "x", "y"]),   // hit at rank 1
            (query: "q2", rankedIds: ["x", "b", "y"]),   // hit at rank 2
            (query: "q3", rankedIds: ["x", "y", "z"]),   // miss
        ]
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(1, results: results, labels: labels), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(2, results: results, labels: labels), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(3, results: results, labels: labels), 2.0 / 3.0, accuracy: 1e-9)
    }

    func testRecallAtKEdgeCases() {
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(1, results: [], labels: labels), 0)
        let r = [(query: "q1", rankedIds: ["a"])]
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(0, results: r, labels: labels), 0)   // k=0 → 0
        XCTAssertEqual(EmbeddingBenchmark.recallAtK(1, results: r, labels: [:]), 0)       // no label → miss
    }

    // MARK: - MRR

    func testMeanReciprocalRank() {
        let results = [
            (query: "q1", rankedIds: ["a", "x"]),        // 1/1
            (query: "q2", rankedIds: ["x", "y", "b"]),   // 1/3
            (query: "q3", rankedIds: ["x", "y"]),        // 0
        ]
        XCTAssertEqual(EmbeddingBenchmark.meanReciprocalRank(results: results, labels: labels),
                       (1.0 + 1.0 / 3.0 + 0) / 3.0, accuracy: 1e-9)
    }

    // MARK: - Insufficiency recall

    private func passage(_ text: String, _ similarity: Float) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: "d", documentName: "M", chunkIndex: 0, text: text, page: nil,
                               section: nil, similarity: similarity, score: similarity, matchedTokens: [])
    }

    func testInsufficiencyRecallIsTheFractionOfNegativesRefused() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.3)
        let results = [
            (query: "n1", ranked: [passage("anything", 0.5)]),    // answered → not refused
            (query: "n2", ranked: [passage("anything", 0.1)]),    // below the floor → refused
            (query: "n3", ranked: [VaultRetriever.Passage]()),    // nothing retrieved → refused
        ]
        XCTAssertEqual(EmbeddingBenchmark.insufficiencyRecall(policy: policy, results: results),
                       2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingBenchmark.insufficiencyRecall(policy: policy, results: []), 0)
    }

    func testInsufficiencyRecallRunsTheLexicalCriterion() {
        // The score is the shipped gate, criteria and all: the same passage is evidence for a
        // question that shares its words and not for one that doesn't.
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.3, minSharedTerms: 2)
        let ranked = [passage("Measure the manifold pressure at the gas valve.", 0.9)]
        XCTAssertEqual(EmbeddingBenchmark.insufficiencyRecall(
            policy: policy, results: [(query: "what is the manifold pressure", ranked: ranked)]), 0)
        XCTAssertEqual(EmbeddingBenchmark.insufficiencyRecall(
            policy: policy, results: [(query: "what is the weather forecast tomorrow", ranked: ranked)]), 1)
    }

    func testBuiltInNegativesHaveNoLabelInTheSmokeCorpus() {
        let labelled = Set(EmbeddingBenchmark.queries.map(\.query))
        for negative in EmbeddingBenchmark.negatives {
            XCTAssertFalse(labelled.contains(negative), negative)
        }
        XCTAssertFalse(EmbeddingBenchmark.negatives.isEmpty)
    }

    func testInsufficiencySelfTestScoresTheBuiltInNegatives() throws {
        try XCTSkipUnless(Embedder().isAvailable, "No on-device embedding model on this host")
        // A floor no cosine can clear refuses everything; a floor below -1 refuses nothing. The number
        // between those two is what a real backend earns, and is printed rather than asserted.
        XCTAssertEqual(EmbeddingBenchmark.insufficiencySelfTest(using: Embedder(),
                                                                policy: RetrievalEvidencePolicy(similarityFloor: 1.01)), 1)
        XCTAssertEqual(EmbeddingBenchmark.insufficiencySelfTest(using: Embedder(),
                                                                policy: RetrievalEvidencePolicy(similarityFloor: -1)), 0)
        let shipped = try XCTUnwrap(EmbeddingBenchmark.insufficiencySelfTest(using: Embedder(),
                                                                             policy: RetrievalEvidencePolicy()))
        print("[GATE] smoke-corpus insufficiency recall on \(Embedder().modelId): \(shipped)")
    }

    // MARK: - selfTest smoke

    func testSelfTestRetrievesEverythingWithinFullK() throws {
        try XCTSkipUnless(Embedder().isAvailable, "No on-device embedding model on this host")
        // With k = corpus size, every relevant id is necessarily within the top-k → perfect recall.
        let recall = EmbeddingBenchmark.selfTest(using: Embedder(), k: EmbeddingBenchmark.corpus.count)
        XCTAssertEqual(recall, 1.0)
    }

    func testSelfTestRecallIsAFraction() throws {
        try XCTSkipUnless(Embedder().isAvailable, "No on-device embedding model on this host")
        let recall = try XCTUnwrap(EmbeddingBenchmark.selfTest(using: Embedder(), k: 1))
        XCTAssertGreaterThanOrEqual(recall, 0)
        XCTAssertLessThanOrEqual(recall, 1)
    }
}
