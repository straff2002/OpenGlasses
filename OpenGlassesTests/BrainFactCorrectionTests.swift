import XCTest
@testable import OpenGlasses

/// Plan GG P1 — a correction replaces the wrong fact in the store that holds it and never leaves
/// the wrong one readable, not even as history.
@MainActor
final class BrainFactCorrectionTests: XCTestCase {

    private var dir: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainFactCorrection_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "BrainFactCorrectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testWrongEdgeIsUnreadableAfterCorrect() throws {
        let brain = BrainStore(directory: dir)
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", sourceRef: "memory-loop", origin: .inferred)
        let services = MemoryFactServices(stores: MemoryFactStores(brain: brain),
                                          coordinator: SubjectErasureCoordinator(stores: .init()))
        let wrong = try XCTUnwrap(services.repository.load().facts.first)
        XCTAssertEqual(wrong.correctableValue, "Wellington")

        let result = services.corrector.correct(wrong, to: "Nelson")
        XCTAssertTrue(result.verified)
        XCTAssertNotEqual(result.newID, wrong.id)

        let reopened = BrainStore(directory: dir)
        let all = reopened.neighbors(of: "Maria", includeSuperseded: true)
        XCTAssertEqual(all.map(\.dstName), ["Nelson"], "the wrong value is not kept as history")
        XCTAssertEqual(all.first?.origin, .toldMe, "a correction is the wearer's own word")
        XCTAssertNil(all.first?.sourceRef)
        XCTAssertNil(all.first?.supersededAt)

        // The memory loop hearing the wrong value again does not bring it back.
        reopened.ingest(text: "Maria lives in Wellington", sourceRef: "memory-loop",
                        sourceKind: "fact", origin: .inferred)
        XCTAssertEqual(reopened.neighbors(of: "Maria", includeSuperseded: true)
            .filter { $0.relation == "lives_in" }.map(\.dstName), ["Nelson"])
    }

    func testCorrectionKeepsTrueHistory() throws {
        let brain = BrainStore(directory: dir)
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Auckland", origin: .toldMe, now: Date().addingTimeInterval(-86_400 * 60))
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", origin: .toldMe)
        brain.distill()
        let services = MemoryFactServices(stores: MemoryFactStores(brain: brain),
                                          coordinator: SubjectErasureCoordinator(stores: .init()))
        let current = try XCTUnwrap(services.repository.load().facts.first)
        XCTAssertEqual(current.text, "Maria lives in Wellington", "only the current claim is listed")
        XCTAssertTrue(services.corrector.correct(current, to: "Nelson").verified)
        brain.distill()
        let names = Set(brain.neighbors(of: "Maria", includeSuperseded: true).map(\.dstName))
        XCTAssertEqual(names, ["Auckland", "Nelson"],
                       "an earlier, true move stays as history; the wrong claim does not")
        XCTAssertEqual(brain.neighbors(of: "Maria").map(\.dstName), ["Nelson"])
    }

    func testSemanticCorrectionReplacesValueAndMarksItToldMe() throws {
        let memory = SemanticMemoryStore(directory: dir)
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .inferred))
        let services = MemoryFactServices(stores: MemoryFactStores(semantic: memory),
                                          coordinator: SubjectErasureCoordinator(stores: .init()))
        let fact = try XCTUnwrap(services.repository.load().facts.first)
        XCTAssertTrue(services.corrector.correct(fact, to: "Nelson").verified)

        let reopened = SemanticMemoryStore(directory: dir)
        let entry = try XCTUnwrap(reopened.entry(id: fact.id.recordID))
        XCTAssertEqual(entry.value, "Nelson")
        XCTAssertEqual(entry.origin, .toldMe)
        XCTAssertFalse(reopened.semanticSearch(query: "Wellington", limit: 5).contains { $0.value == "Wellington" })
    }

    func testNoteNeedObjectAndPlaceCorrections() throws {
        let brain = BrainStore(directory: dir)
        let notes = AgentDocumentStore(directory: dir)
        let objects = ObjectMemoryStore(defaults: defaults)
        let places = SavedLocationStore(defaults: defaults)
        brain.addNeed(person: "Sam", text: "send the quote")
        notes.appendMemory("Drinks tea black")
        objects.save(ObjectMemoryEntry(id: "o1", objectName: "spare key", locationDescription: "blue bowl",
                                       latitude: nil, longitude: nil, savedAt: Date()))
        places.add(SavedLocationStore.SavedLocation(label: "hotel", latitude: 1, longitude: 2,
                                                    address: nil, timestamp: Date()))
        let services = MemoryFactServices(
            stores: MemoryFactStores(brain: brain, agentDocuments: notes, objects: objects, savedPlaces: places),
            coordinator: SubjectErasureCoordinator(stores: .init()))
        let facts = services.repository.load().facts
        let replacements: [MemoryFactStore: String] = [
            .brainNeed: "send the revised quote", .agentNote: "Drinks tea with milk",
            .object: "hook by the door", .savedPlace: "conference hotel",
        ]
        for (store, value) in replacements {
            let fact = try XCTUnwrap(facts.first { $0.id.store == store }, store.rawValue)
            XCTAssertTrue(services.corrector.correct(fact, to: value).verified, store.rawValue)
        }
        XCTAssertEqual(brain.needs(limit: 5).first?.text, "send the revised quote")
        XCTAssertTrue(notes.content(for: .memory).contains("Drinks tea with milk"))
        XCTAssertFalse(notes.content(for: .memory).contains("Drinks tea black"))
        XCTAssertEqual(objects.find("spare key")?.locationDescription, "hook by the door")
        XCTAssertEqual(places.all().map(\.label), ["conference hotel"])
    }

    func testEmptyCorrectionChangesNothing() throws {
        let memory = SemanticMemoryStore(directory: dir)
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        let services = MemoryFactServices(stores: MemoryFactStores(semantic: memory),
                                          coordinator: SubjectErasureCoordinator(stores: .init()))
        let fact = try XCTUnwrap(services.repository.load().facts.first)
        XCTAssertFalse(services.corrector.correct(fact, to: "   ").verified)
        XCTAssertEqual(memory.recall("tea"), "earl grey")
    }
}
