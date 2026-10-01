import XCTest
@testable import OpenGlasses

/// Plan GG P0 — the merge is stable, and a source that cannot be read shows a status, never rows.
@MainActor
final class MemoryFactRepositoryTests: XCTestCase {

    private struct FakeSource: MemoryFactSource {
        let sourceID: String
        let result: MemorySourcePage
        func page() -> MemorySourcePage { result }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fact(_ store: MemoryFactStore, _ id: String, at offset: TimeInterval,
                      text: String? = nil) -> MemoryFact {
        MemoryFact(id: MemoryFactID(store: store, recordID: id), text: text ?? id,
                   kind: .semantic(topic: "general"), origin: .toldMe,
                   createdAt: t0.addingTimeInterval(offset))
    }

    func testMergeIsNewestFirstWithIdentityTieBreakAcrossSources() {
        let a = MemorySourcePage.available("a", [fact(.semantic, "b", at: 0), fact(.semantic, "z", at: 10)])
        let b = MemorySourcePage.available("b", [fact(.brainEdge, "a", at: 0), fact(.agentNote, "m", at: 5)])
        let forward = MemoryFactRepository.merge([a, b]).facts.map(\.id.rendered)
        let reverse = MemoryFactRepository.merge([b, a]).facts.map(\.id.rendered)
        XCTAssertEqual(forward, ["semantic:z", "agentNote:m", "brainEdge:a", "semantic:b"])
        XCTAssertEqual(forward, reverse, "source order must not change the merged order")
    }

    func testIdenticalTextInTwoStoresStaysTwoFacts() {
        let listing = MemoryFactRepository.merge([
            .available("a", [fact(.semantic, "1", at: 0, text: "likes tea")]),
            .available("b", [fact(.agentNote, "1", at: 0, text: "likes tea")]),
        ])
        XCTAssertEqual(listing.facts.count, 2)
    }

    func testLockedSourceShowsStatusAndNoRowsEvenIfItHandsSomeBack() {
        let stale = MemorySourcePage(sourceID: "brain", status: .locked,
                                     facts: [fact(.brainEdge, "stale", at: 0)])
        let listing = MemoryFactRepository.merge([
            .available("semantic", [fact(.semantic, "fresh", at: 0)]), stale,
        ])
        XCTAssertEqual(listing.facts.map(\.id.recordID), ["fresh"])
        XCTAssertEqual(listing.unavailableSources, [MemorySourceIssue(sourceID: "brain", status: .locked)])
        XCTAssertFalse(listing.isComplete, "a partial list never reads as everything")
    }

    func testProtectedDataUnavailableLocksEverySourceWithoutReadingIt() {
        let repository = MemoryFactRepository(
            sources: [FakeSource(sourceID: "semantic", result: .available("semantic", [fact(.semantic, "x", at: 0)]))],
            protectedDataAvailable: { false })
        let listing = repository.load()
        XCTAssertTrue(listing.facts.isEmpty)
        XCTAssertEqual(listing.unavailableSources.first?.status, .locked)
    }

    func testSearchMatchesEveryWordIgnoringCaseAndAccents() {
        let facts = [fact(.semantic, "1", at: 0, text: "sister city: Wellington"),
                     fact(.semantic, "2", at: 0, text: "café order: flat white")]
        XCTAssertEqual(MemoryFactRepository.search(facts, query: "SISTER wellington").map(\.id.recordID), ["1"])
        XCTAssertEqual(MemoryFactRepository.search(facts, query: "cafe").map(\.id.recordID), ["2"])
        XCTAssertEqual(MemoryFactRepository.search(facts, query: "  ").count, 2)
    }

    func testRealStoresProduceFactsFromEverySource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MFR_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "MemoryFactRepositoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = SemanticMemoryStore(directory: dir)
        let brain = BrainStore(directory: dir)
        let notes = AgentDocumentStore(directory: dir)
        let objects = ObjectMemoryStore(defaults: defaults)
        let places = SavedLocationStore(defaults: defaults)

        XCTAssertTrue(memory.rememberGlobal("favourite tea", value: "earl grey"))
        memory.writeDiary("Seems to prefer short answers in the morning")
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in",
                      dstKind: "place", dstName: "Wellington", origin: .toldMe)
        brain.addNeed(person: "Sam", text: "send the quote")
        notes.appendMemory("Prefers metric units")
        objects.save(ObjectMemoryEntry(id: "o1", objectName: "spare key", locationDescription: "blue bowl",
                                       latitude: nil, longitude: nil, savedAt: Date()))
        places.add(SavedLocationStore.SavedLocation(label: "hotel", latitude: 1, longitude: 2,
                                                    address: "12 Queen St", timestamp: Date()))

        let services = MemoryFactServices(
            stores: MemoryFactStores(semantic: memory, brain: brain, agentDocuments: notes,
                                     objects: objects, savedPlaces: places),
            coordinator: SubjectErasureCoordinator(stores: .init()))
        let listing = services.repository.load()
        XCTAssertTrue(listing.isComplete)
        let stores = Set(listing.facts.map(\.id.store))
        XCTAssertEqual(stores, [.semantic, .diary, .brainEdge, .brainNeed, .agentNote, .object, .savedPlace])
        XCTAssertEqual(listing.facts.first { $0.id.store == .brainEdge }?.text, "Maria lives in Wellington")
        XCTAssertEqual(listing.facts.first { $0.id.store == .diary }?.origin, .inferred)
        XCTAssertEqual(listing.facts.first { $0.id.store == .agentNote }?.text, "Prefers metric units")
    }
}
