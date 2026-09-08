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
        // A repeat is still one row — but it is no longer thrown away: the row now carries how
        // often the claim has been heard.
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme")
        XCTAssertEqual(store.stats.edges, 1)
        XCTAssertEqual(store.neighbors(of: "Alice").first?.observations, 2)
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

    // MARK: - Tiers, supersession and history

    /// Repetition is evidence, and the evidence has to be countable: a second sighting in a second
    /// conversation is the corroboration the distiller promotes on.
    func testRepeatInANewSessionCountsAsCorroboration() {
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-1")
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-1")
        XCTAssertEqual(store.neighbors(of: "Alice").first?.distinctSessions, 1,
                       "Saying it twice in one conversation is one claim")
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-2")
        let edge = store.neighbors(of: "Alice").first
        XCTAssertEqual(edge?.distinctSessions, 2)
        XCTAssertEqual(edge?.observations, 3)
    }

    /// A relation the graph never agreed to store is dropped, not written — and counted, so
    /// widening the vocabulary is a decision made on evidence.
    func testOffOntologyRelationIsDroppedAndCounted() {
        RelationOntology.resetDrops()
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "vibes_with",
                      dstKind: "person", dstName: "Bob")
        XCTAssertEqual(store.stats.edges, 0)
        XCTAssertEqual(RelationOntology.dropCount, 1)
        RelationOntology.resetDrops()
    }

    /// Where you live now and where you used to live are different facts, and only one of them is
    /// true. The incumbent is stamped, never deleted.
    func testFunctionalRelationSupersedesAndNeighborsPrefersTheCurrentOne() {
        let lastYear = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: lastYear)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Auckland")
        let summary = store.distill(sessionID: "thread-1")
        XCTAssertEqual(summary.superseded, 1)

        XCTAssertEqual(store.stats.edges, 2, "History is kept, not deleted")
        XCTAssertEqual(store.neighbors(of: "Maria").map(\.dstName), ["Auckland"],
                       "Only the current fact spends a slot in the answer")
        let withHistory = store.neighbors(of: "Maria", includeSuperseded: true)
        XCTAssertEqual(withHistory.map(\.dstName), ["Auckland", "Wellington"],
                       "Current first, history behind it")
        XCTAssertEqual(withHistory.last?.sentence, "Maria used to live in Wellington")
    }

    /// The same rule from the other direction: "who lives in Wellington?" must not answer with
    /// someone who moved out, unless it is asked for history on purpose.
    func testSourcesExcludesSupersededByDefaultAndIncludesItOnRequest() {
        let lastYear = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: lastYear)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Auckland")
        store.distill()

        XCTAssertTrue(store.sources(relation: "lives_in", dstName: "Wellington").isEmpty)
        XCTAssertEqual(store.sources(relation: "lives_in", dstName: "Wellington",
                                     includeSuperseded: true).count, 1)
        XCTAssertEqual(store.sources(relation: "lives_in", dstName: "Auckland").count, 1)
    }

    /// A guess is allowed into the graph, but never disguised as a fact: the model reads the
    /// marker, not just the sentence.
    func testProvisionalEdgeReadsAsUnconfirmed() {
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", confidence: 0.5, state: .provisional)
        let edge = store.neighbors(of: "Alice").first
        XCTAssertEqual(edge?.state, .provisional)
        XCTAssertEqual(edge?.sentence, "Alice works at Acme (unconfirmed)")
    }

    /// Corroboration across two conversations turns a guess into a fact, and the marker goes away
    /// with the doubt.
    func testCorroborationAcrossSessionsPromotesAProvisionalEdge() {
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-1",
                      confidence: 0.5, state: .provisional)
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-2",
                      confidence: 0.5, state: .provisional)
        XCTAssertEqual(store.distill(sessionID: "thread-2").promoted, 1)
        XCTAssertEqual(store.neighbors(of: "Alice").first?.state, .permanent)
        XCTAssertEqual(store.neighbors(of: "Alice").first?.sentence, "Alice works at Acme")
    }

    /// Said once, a fortnight ago, never again — the row goes. This is what keeps a wrong guess
    /// from costing anything permanent.
    func testUnrepeatedProvisionalExpiresAtTheNextPass() {
        let longAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", sessionID: "thread-1",
                      confidence: 0.5, state: .provisional, now: longAgo)
        XCTAssertEqual(store.distill().expired, 1)
        XCTAssertEqual(store.stats.edges, 0)
    }

    /// Forgetting someone takes their history with them — a superseded edge is still a fact about
    /// them, and "erased" has to mean erased.
    func testForgetRemovesSupersededHistoryToo() {
        let lastYear = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: lastYear)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Auckland")
        store.distill()
        XCTAssertEqual(store.stats.edges, 2)

        store.forget(entityName: "Maria")
        XCTAssertEqual(store.stats.edges, 0)
        XCTAssertTrue(store.neighbors(of: "Maria", includeSuperseded: true).isEmpty)
    }

    /// A fact can become true again. History is kept rather than deleted, so a wearer who moves
    /// back lands on the row supersession retired; a direct restatement has to revive it, or the
    /// graph would insist on Auckland forever.
    func testDirectRestatementRevivesARetiredFact() {
        let t0 = Date().addingTimeInterval(-300)
        let t1 = Date().addingTimeInterval(-200)
        let t2 = Date().addingTimeInterval(-100)

        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: t0)
        store.distill(now: t0)

        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Auckland", now: t1)
        store.distill(now: t1)
        XCTAssertEqual(store.neighbors(of: "Maria").map(\.sentence), ["Maria lives in Auckland"])

        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: t2)
        store.distill(now: t2)

        XCTAssertEqual(store.neighbors(of: "Maria").map(\.sentence), ["Maria lives in Wellington"])
        XCTAssertTrue(store.neighbors(of: "Maria", includeSuperseded: true)
            .map(\.sentence).contains("Maria used to live in Auckland"))
        XCTAssertEqual(store.stats.edges, 2, "Two rows the whole way: one current, one history")
    }

    /// A guess is not a correction. A provisional repeat on a retired row leaves it retired —
    /// otherwise a low-confidence extraction could quietly undo a decision the pass already made.
    func testProvisionalRepeatDoesNotReviveARetiredFact() {
        let t0 = Date().addingTimeInterval(-300)
        let t1 = Date().addingTimeInterval(-200)
        let t2 = Date().addingTimeInterval(-100)

        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", now: t0)
        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Auckland", now: t1)
        store.distill(now: t1)

        store.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", sessionID: "thread-9",
                      confidence: 0.5, state: .provisional, now: t2)
        store.distill(now: t2)

        XCTAssertEqual(store.neighbors(of: "Maria").map(\.sentence), ["Maria lives in Auckland"])
    }

    /// A long session should not have to end before the graph tidies itself, so the pass also runs
    /// on a turn budget.
    func testIngestBudgetTriggersAPassWithoutWaitingForTheSessionToEnd() {
        var policy = BrainDistiller.Policy.default
        policy.ingestsBetweenPasses = 2
        let directory = tempRoot.appendingPathComponent("budget", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = BrainStore(directory: directory, policy: policy)
        let longAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        store.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                      dstKind: "org", dstName: "Acme", confidence: 0.5,
                      state: .provisional, now: longAgo)
        store.ingest(text: "Dana lives in Dunedin")
        XCTAssertEqual(store.stats.edges, 2, "One ingest is under the budget — no pass yet")
        store.ingest(text: "Kim works at Weta")
        XCTAssertEqual(store.stats.edges, 2,
                       "The second ingest spends the budget: the stale guess is dropped, "
                       + "the new edge takes its place")
        XCTAssertTrue(store.neighbors(of: "Alice").isEmpty)
    }
}
