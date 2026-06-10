import XCTest
@testable import OpenGlasses

/// Tests for the on-device knowledge graph: entity/edge/encounter storage, the zero-LLM
/// relation extractor, and free-text ingestion.
@MainActor
final class BrainStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BrainStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = BrainStore(directory: tempRoot)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Entities & edges

    func testUpsertEntityIsIdempotent() {
        let first = store.upsertEntity(kind: "person", name: "Alice")
        let second = store.upsertEntity(kind: "person", name: "alice")
        XCTAssertEqual(first, second, "Same name (case-insensitive) within a kind must not duplicate")
        XCTAssertEqual(store.stats.entities, 1)
    }

    func testAddEdgeAndNeighbors() {
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sourceRef: "meeting notes")
        let edges = store.neighbors(of: "Alice")
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.relation, "works_at")
        XCTAssertEqual(edges.first?.dstName, "Acme")
        // Reverse direction also resolves
        XCTAssertEqual(store.neighbors(of: "acme").count, 1)
        // Duplicate edges are ignored
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme")
        XCTAssertEqual(store.stats.edges, 1)
    }

    func testForgetRemovesEntityEdgesAndEncounters() {
        store.addEdge(srcKind: "person", srcName: "Bob", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington")
        store.logEncounter(person: "Bob")
        store.forget(entityName: "Bob")
        XCTAssertTrue(store.neighbors(of: "Bob").isEmpty)
        XCTAssertTrue(store.encounters(for: "Bob").isEmpty)
        XCTAssertEqual(store.stats.encounters, 0)
    }

    // MARK: - Encounters

    func testEncounterLogOrderAndFilter() {
        store.logEncounter(person: "Alice", locationName: "Office", latitude: -41.3, longitude: 174.8)
        store.logEncounter(person: "Bob")
        let all = store.encounters()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.person, "Bob", "Newest first")
        let alice = store.encounters(for: "alice")
        XCTAssertEqual(alice.count, 1)
        XCTAssertEqual(alice.first?.locationName, "Office")
    }

    // MARK: - Relation extraction

    func testExtractsTypedRelations() {
        let relations = BrainRelationExtractor.extract(
            from: "John Smith works at Stripe. Maria lives in Auckland. Maria is married to Carlos.")
        XCTAssertTrue(relations.contains(.init(srcKind: "person", src: "John Smith",
                                               relation: "works_at", dstKind: "org", dst: "Stripe")))
        XCTAssertTrue(relations.contains(.init(srcKind: "person", src: "Maria",
                                               relation: "lives_in", dstKind: "place", dst: "Auckland")))
        XCTAssertTrue(relations.contains(.init(srcKind: "person", src: "Maria",
                                               relation: "married_to", dstKind: "person", dst: "Carlos")))
    }

    func testExtractionSkipsSentenceStartPronouns() {
        XCTAssertTrue(BrainRelationExtractor.extract(from: "She works at Stripe").isEmpty)
        XCTAssertTrue(BrainRelationExtractor.extract(from: "The team moved to Berlin").isEmpty)
    }

    func testExtractionDoesNotCrossSentenceBoundaries() {
        let relations = BrainRelationExtractor.extract(from: "He likes Stripe. Maria lives in Auckland.")
        XCTAssertEqual(relations, [.init(srcKind: "person", src: "Maria",
                                         relation: "lives_in", dstKind: "place", dst: "Auckland")],
                       "A name must not absorb the previous sentence's trailing proper noun")
    }

    // MARK: - Ingestion

    func testIngestFallsBackToSubjectForBareFacts() {
        store.ingest(text: "works at Stripe", subject: "Dana")
        let edges = store.neighbors(of: "Dana")
        XCTAssertEqual(edges.first?.relation, "works_at")
        XCTAssertEqual(edges.first?.dstName, "Stripe")
    }

    func testIngestLinksMentionedPeopleToSource() {
        store.upsertEntity(kind: "person", name: "Alice")
        store.ingest(text: "Alice presented the Q3 roadmap.",
                     sourceRef: "Meeting 2026-06-10", sourceKind: "meeting")
        let edges = store.neighbors(of: "Alice")
        XCTAssertTrue(edges.contains { $0.relation == "mentioned_in" && $0.dstName == "Meeting 2026-06-10" })
    }
}
