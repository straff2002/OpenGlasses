import XCTest
@testable import OpenGlasses

/// Plan KQ P1: a question is embedded as a question, a passage as a passage, and the search-trained
/// backend's pure helpers. The Core ML model itself is never loaded here.
@MainActor
final class SearchModelRoleTests: XCTestCase {

    /// Records which entry each text came through.
    private final class RoleModel: EmbeddingBackend {
        var documents: [String] = []
        var queries: [String] = []
        let modelId = "role-test.3"
        let dimension = 3
        func embed(_ text: String) -> [Float]? {
            documents.append(text)
            return [1, Float(text.count % 5 + 1), 1]
        }
        func embedQuery(_ text: String) -> [Float]? {
            queries.append(text)
            return [1, Float(text.count % 5 + 1), 1]
        }
    }

    /// A backend with only `embed`: the protocol's default reads a question the same way.
    private final class PlainModel: EmbeddingBackend {
        let modelId = "plain-test.2"
        let dimension = 2
        func embed(_ text: String) -> [Float]? { [Float(text.count), 1] }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchModelRole-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAModelWithoutAQueryEntryReadsAQuestionAsAnyText() {
        let embedder = Embedder(backend: PlainModel())
        XCTAssertEqual(embedder.embedQuery("  four  "), embedder.embed("four"))
        XCTAssertNil(embedder.embedQuery("   "))
    }

    func testPassagesAreEmbeddedAsPassagesAndTheQuestionAsAQuestion() async throws {
        for namespace in ["documents", "vault:x"] {
            let model = RoleModel()
            let folder = directory.appendingPathComponent(namespace.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = DocumentStore(directory: folder,
                                      chunker: DocumentChunker(targetChars: 120, maxChars: 200, overlapChars: 0),
                                      embedder: Embedder(backend: model))
            let text = (1...6).map { "The drain pump on unit \($0) sits behind the lower panel." }.joined(separator: "\n\n")
            _ = await store.ingest(name: "Manual", text: text, namespace: namespace)
            XCTAssertFalse(model.documents.isEmpty, namespace)
            XCTAssertTrue(model.queries.isEmpty, namespace)
            let passages = model.documents.count

            _ = store.query("where is the drain pump", limit: 2, namespace: namespace)
            XCTAssertEqual(model.queries, ["where is the drain pump"], namespace)
            XCTAssertEqual(model.documents.count, passages, "a search embeds no passage: \(namespace)")
        }
    }

    func testTruncationKeepsTheLeadingValuesAndRenormalises() throws {
        let cut = try XCTUnwrap(CoreMLEmbeddingBackend.truncated([3, 4, 12], to: 2))
        XCTAssertEqual(cut[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(cut[1], 0.8, accuracy: 1e-6)
        XCTAssertNil(CoreMLEmbeddingBackend.truncated([0, 0, 1], to: 2))
        XCTAssertNil(CoreMLEmbeddingBackend.truncated([.nan, 1], to: 2))
    }

    func testASplitTextsHalvesAreWeighedByTheirTokens() throws {
        let pooled = try XCTUnwrap(CoreMLEmbeddingBackend.pooled([(vector: [1, 0], tokens: 3), (vector: [0, 1], tokens: 1)]))
        XCTAssertEqual(pooled[0] / pooled[1], 3, accuracy: 1e-5)
        XCTAssertEqual(pooled[0] * pooled[0] + pooled[1] * pooled[1], 1, accuracy: 1e-5)
        XCTAssertNil(CoreMLEmbeddingBackend.pooled([]))
    }

    func testTheSearchModelsGateIsTheMeasuredOneAndOnlyForItsMeasuredDimension() {
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: "eg2-text.768"),
                       RetrievalEvidencePolicy(similarityFloor: 0.69, minSharedTerms: 3, sharedFraction: 0.5))
        XCTAssertEqual(RetrievalEvidencePolicy.default(for: "eg2-text.256"), RetrievalEvidencePolicy(),
                       "an unmeasured dimension has no measured gate")
    }

    func testTheModelIdNamesTheDimensionSoAChangeReindexes() {
        XCTAssertEqual(CoreMLEmbeddingBackend.modelId(dimension: 256), "eg2-text.256")
        XCTAssertNotEqual(EmbeddingVersion(modelId: CoreMLEmbeddingBackend.modelId(dimension: 256), dim: 256).tag,
                          EmbeddingVersion(modelId: CoreMLEmbeddingBackend.modelId(dimension: 768), dim: 768).tag)
    }
}
