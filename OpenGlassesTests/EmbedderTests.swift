import XCTest
@testable import OpenGlasses

final class EmbedderTests: XCTestCase {

    func testCosineSimilarityBasics() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let c: [Float] = [0, 1, 0]
        XCTAssertEqual(Embedder.cosineSimilarity(a, b), 1, accuracy: 1e-5)
        XCTAssertEqual(Embedder.cosineSimilarity(a, c), 0, accuracy: 1e-5)
        // Mismatched dimensions and empties are defined as 0, not a crash.
        XCTAssertEqual(Embedder.cosineSimilarity([1, 2], [1, 2, 3]), 0)
        XCTAssertEqual(Embedder.cosineSimilarity([], []), 0)
    }

    func testEmptyTextEmbedsToNil() {
        let embedder = Embedder()
        XCTAssertNil(embedder.embed(""))
        XCTAssertNil(embedder.embed("   \n  "))
    }

    func testDeterministicAndConsistentDimension() throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "No NLEmbedding model available in this environment")

        guard let v1 = embedder.embed("the cat sat on the mat"),
              let v2 = embedder.embed("the cat sat on the mat") else {
            return XCTFail("Expected embeddings for normal English text")
        }
        XCTAssertEqual(v1, v2, "Embedding must be deterministic")
        XCTAssertEqual(v1.count, embedder.dimension)
        XCTAssertGreaterThan(embedder.dimension, 0)
    }

    func testRelatedTextScoresHigherThanUnrelated() throws {
        let embedder = Embedder()
        try XCTSkipUnless(embedder.isAvailable, "No NLEmbedding model available in this environment")

        guard let query = embedder.embed("how do I reset the device"),
              let related = embedder.embed("steps to restart and reset the unit"),
              let unrelated = embedder.embed("the weather is sunny and warm today") else {
            return XCTFail("Expected embeddings for all sample texts")
        }
        let relatedScore = Embedder.cosineSimilarity(query, related)
        let unrelatedScore = Embedder.cosineSimilarity(query, unrelated)
        XCTAssertGreaterThan(relatedScore, unrelatedScore,
                             "Related text (\(relatedScore)) should outrank unrelated (\(unrelatedScore))")
    }
}
