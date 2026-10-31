import XCTest
@testable import OpenGlasses

/// Plan KG P4: the unit's assigned documents are searched as well as the whole vault. Candidates only:
/// the gate, the ranking and the other documents stay. On invented models and manuals.
final class ScopedSearchRouteTests: XCTestCase {

    private let gate = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.6)
    private let scope = VaultRetriever.ModelScope(activeTokens: ["QX100"], otherTokens: ["QX200"], assignedDocumentIds: ["own"])

    private func stored(_ document: String, _ index: Int, _ text: String, sim: Float = 0.8) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: document, documentName: document, chunkIndex: index, text: text,
                              similarity: sim, page: index + 1, section: nil)
    }

    /// A retriever whose whole-vault search finds `elsewhere` and whose search with the assigned
    /// documents finds `own` beside it, counting who was asked.
    private final class Calls { var plain = 0, assigned = 0, within: [Set<String>] = [] }

    private func retriever(elsewhere: [DocumentStore.Passage], own: [DocumentStore.Passage],
                           scope: VaultRetriever.ModelScope?, wired: Bool = true, calls: Calls = Calls()) -> VaultRetriever {
        let search = VaultRetriever.AssignedSearch(query: { _, _, within in
            calls.assigned += 1
            calls.within.append(within)
            return elsewhere + own
        }, terms: { _, _, within in
            calls.assigned += 1
            calls.within.append(within)
            return elsewhere + own
        })
        return VaultRetriever(query: { _, _ in calls.plain += 1; return elsewhere },
                              termSearch: { _, _ in calls.plain += 1; return elsewhere },
                              policy: gate, modelScope: scope, assignedSearch: wired ? search : nil)
    }

    private let turn = "reseal the radiator loop"
    private let answer = "Reseal the radiator loop after draining it."

    func testTheUnitsDocumentsReachThePool() {
        let outcome = retriever(elsewhere: [stored("other", 0, answer)], own: [stored("own", 0, answer)], scope: scope)
            .retrieve(.init(turn: turn))
        XCTAssertEqual(outcome.passages.map(\.documentId), ["own", "other"], "and the other document stays, ranked down")
    }

    func testEachRouteRunsOnceAndTheWholeVaultIsNotSearchedTwice() {
        let calls = Calls()
        _ = retriever(elsewhere: [], own: [stored("own", 0, answer)], scope: scope, calls: calls).retrieve(.init(turn: turn))
        XCTAssertEqual(calls.assigned, 2, "by meaning and by words")
        XCTAssertEqual(calls.plain, 0, "the search with the documents is the search")
        XCTAssertEqual(calls.within, [["own"], ["own"]])
    }

    func testNoUnitNoDocumentsOrNoWiringChangesNothing() {
        let own = [stored("own", 0, answer)]
        for (scope, wired): (VaultRetriever.ModelScope?, Bool) in [
            (nil, true),
            (.init(activeTokens: ["QX100"], otherTokens: ["QX200"]), true),
            (self.scope, false),   // the personal library builds its own retriever, with no such search
        ] {
            let calls = Calls()
            let outcome = retriever(elsewhere: [stored("other", 0, answer)], own: own, scope: scope, wired: wired, calls: calls)
                .retrieve(.init(turn: turn))
            XCTAssertEqual(calls.assigned, 0)
            XCTAssertEqual(outcome.passages.map(\.documentId), ["other"])
        }
    }

    func testATurnNamingAnotherModelDoesNotPullInTheUnitsDocuments() {
        let calls = Calls()
        let outcome = retriever(elsewhere: [stored("other", 0, answer + " QX200")], own: [stored("own", 0, answer)],
                                scope: scope, calls: calls).retrieve(.init(turn: "on the QX200 " + turn))
        XCTAssertEqual(calls.assigned, 0)
        XCTAssertEqual(outcome.passages.map(\.documentId), ["other"])
    }

    func testTheGateJudgesAScopedCandidateAsAnyOther() {
        let weak = "A passage from the right document about something else entirely."
        XCTAssertFalse(retriever(elsewhere: [], own: [stored("own", 0, weak)], scope: scope).retrieve(.init(turn: turn)).answers,
                       "being assigned is not evidence")
    }

    func testAModelNumberIsNotEvidenceForAScopedCandidateEither() {
        let listing = "Wiring diagram for models QX100 and QX200."
        let plain = retriever(elsewhere: [], own: [stored("own", 0, listing)], scope: scope)
        XCTAssertFalse(plain.retrieve(.init(turn: "QX100 bleed a hydronic radiator loop")).answers)
    }

    func testTwoRoutesReachingOneChunkGiveOnePassage() {
        let same = stored("own", 3, answer)
        let outcome = retriever(elsewhere: [same], own: [same], scope: scope).retrieve(.init(turn: turn))
        XCTAssertEqual(outcome.passages.count, 1)
    }

    func testAnUnavailableDocumentStaysOutOfThePool() {
        var removed = retriever(elsewhere: [stored("other", 0, answer)], own: [stored("own", 0, answer)], scope: scope)
        removed.availability = { $0 != "own" }
        XCTAssertEqual(removed.retrieve(.init(turn: turn)).passages.map(\.documentId), ["other"])
    }

    func testTheCorpusStatisticsComeFromTheCorpusNotThePool() {
        var asked = 0
        var plain = retriever(elsewhere: [], own: [stored("own", 0, answer)], scope: scope)
        plain.termStatistics = { asked += 1; return nil }
        _ = plain.retrieve(.init(turn: turn))
        XCTAssertEqual(asked, 1, "read once, by a route that takes no candidates")
    }

    // MARK: - The best and the best within

    func testTheBestAndTheBestWithinAreInRankOrderEachOnce() {
        let ranked = ["a", "own", "b", "c", "own2", "d", "own3", "own4"]
        let within: Set<String> = ["own", "own2", "own3", "own4"]
        XCTAssertEqual(DocumentStore.bestAndBestWithin(ranked, limit: 3, within: within) { $0 }, ["a", "own", "b", "own2", "own3"])
        XCTAssertEqual(DocumentStore.bestAndBestWithin(ranked, limit: 3, within: []) { $0 }, ["a", "own", "b"])
        XCTAssertEqual(DocumentStore.bestAndBestWithin(ranked, limit: 8, within: within) { $0 }, ranked)
    }
}

/// The store's side: one pass, one embedding, and a search that cannot be widened.
@MainActor
final class ScopedSearchStoreTests: XCTestCase {

    private final class CountingModel: EmbeddingBackend {
        var calls = 0
        let modelId = "nl-word.test-counting"
        let dimension = 3
        func embed(_ text: String) -> [Float]? {
            calls += 1
            return [Float(text.count % 7 + 1), 1, Float(text.count % 3 + 1)]
        }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScopedSearch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store(_ model: CountingModel) async throws -> (store: DocumentStore, own: String, other: String) {
        let store = DocumentStore(directory: directory, chunker: DocumentChunker(targetChars: 120, maxChars: 200, overlapChars: 0),
                                  embedder: Embedder(backend: model))
        let lines = (1...12).map { "The blower relay harness plug number \($0) sits behind the panel." }.joined(separator: "\n\n")
        let other = try await XCTUnwrapAsync(await store.ingest(name: "Other", text: lines, namespace: "vault:x"))
        let own = try await XCTUnwrapAsync(await store.ingest(name: "Own", text: "The harness plug sits behind the door.", namespace: "vault:x"))
        return (store, own.id, other.id)
    }

    func testTheSearchesEmbedTheQuestionOnceEachWithTheDocumentsOrWithout() async throws {
        let model = CountingModel()
        let (store, own, _) = try await store(model)
        model.calls = 0
        _ = store.query("blower relay harness plug", limit: 2, namespace: "vault:x")
        let plain = model.calls
        model.calls = 0
        _ = store.query("blower relay harness plug", limit: 2, namespace: "vault:x", alsoWithin: [own])
        XCTAssertEqual(model.calls, plain)
    }

    func testBothSearchesFindTheUnitsDocumentBelowTheirDepth() async throws {
        let (store, own, other) = try await store(CountingModel())
        let words = "blower relay harness plug"
        XCTAssertFalse(store.passages(sharingTermsWith: words, limit: 2, namespace: "vault:x").contains { $0.documentId == own })
        let found = store.passages(sharingTermsWith: words, limit: 2, namespace: "vault:x", alsoWithin: [own])
        XCTAssertEqual(found.map(\.documentId), [other, other, own])
        let meaning = store.query(words, limit: 1, namespace: "vault:x", alsoWithin: [own])
        XCTAssertTrue(meaning.contains { $0.documentId == own })
        XCTAssertEqual(Set(meaning.map { "\($0.documentId)#\($0.chunkIndex)" }).count, meaning.count, "each once")
    }

    func testAFilteredSearchIsNotWidenedByTheDocuments() async throws {
        // An edition, a language group or a named manual: what the search may read does not change.
        let (store, own, other) = try await store(CountingModel())
        let found = store.query("harness plug", limit: 2, namespace: "vault:x", documentIds: [other], alsoWithin: [own])
        XCTAssertFalse(found.contains { $0.documentId == own })
        let words = store.passages(sharingTermsWith: "harness plug", limit: 2, namespace: "vault:x", documentIds: [other], alsoWithin: [own])
        XCTAssertFalse(words.contains { $0.documentId == own })
    }

    func testAskingWithTheDocumentsLeavesTheStatisticsAlone() async throws {
        let (store, own, _) = try await store(CountingModel())
        let before = store.termStatistics(namespaces: ["vault:x"])
        _ = store.passages(sharingTermsWith: "harness plug", limit: 2, namespace: "vault:x", alsoWithin: [own])
        XCTAssertEqual(store.termStatistics(namespaces: ["vault:x"]), before)
    }
}

/// The session's side, on an invented vault of two families and an install guide that fills the
/// search's depth with near-identical pages.
@MainActor
final class ScopedSearchSessionTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private static let models = """
    # Models

    ## QX100 (rooftop)
    S:A02

    ## QX200 (rooftop)
    S:A03
    """

    private static let filler = (1...40).map {
        "Route blower relay harness plug clip number \($0) along the upper rail before fitting the cover plate."
    }.joined(separator: "\n\n")

    private static let manuals: [(file: String, title: String, text: String)] = [
        ("a02.txt", "A02 Acme Service Manual", "The harness plug sits behind the door panel on this unit."),
        ("a03.txt", "A03 Acme Service Manual", "The harness plug sits under the base tray on this unit."),
        ("a09.txt", "A09 Acme Install Guide", filler),
    ]

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScopedSearchSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: "kg_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func start(vaultOnly: Bool? = nil) async throws -> (service: FieldSessionService, store: DocumentStore) {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let documentsDir = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: "kg_test", name: "Acme Refrigeration", version: "1.0.0",
                                     files: ["models.md"], proceduresDir: nil, documentsDir: "documents",
                                     documents: Self.manuals.map { VaultDocument(file: $0.file, title: $0.title, kind: "service_manual") },
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."], vaultOnly: vaultOnly)
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try Self.models.write(to: dir.appendingPathComponent("models.md"), atomically: true, encoding: .utf8)
        for manual in Self.manuals {
            try manual.text.write(to: documentsDir.appendingPathComponent(manual.file), atomically: true, encoding: .utf8)
        }
        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let storeDirectory = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDirectory)
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try service.startSession(vaultId: installed.id, assetId: nil)
        return (service, store)
    }

    private func onUnit(_ model: String, _ service: FieldSessionService) -> VaultRetriever {
        service.technicianWords = { model }
        _ = service.promptContext(turn: model)
        return service.makeRetriever(store: service.activeVault!, documentStore: service.documentStore)
    }

    private let asked = "where is the blower relay harness plug"

    func testTheUnitsManualIsFoundBelowADepthOfAnotherDocument() async throws {
        let (service, store) = try await start()
        let own = try XCTUnwrap(store.list(namespace: DocumentStore.vaultNamespace("kg_test")).first { $0.name.hasPrefix("A02") })
        XCTAssertFalse(store.passages(sharingTermsWith: asked, limit: 8, namespace: DocumentStore.vaultNamespace("kg_test"))
            .contains { $0.documentId == own.id }, "the fixture fills the depth of the search by words")
        let outcome = onUnit("QX100", service).retrieve(.init(turn: asked, limit: 8))
        XCTAssertEqual(outcome.passages.first?.documentName, "A02 Acme Service Manual")
        XCTAssertTrue(outcome.passages.contains { $0.documentName.hasPrefix("A09") }, "other documents stay")
    }

    func testNoUnitOnTheJobMeansNoNewSearch() async throws {
        let (service, store) = try await start()
        let retriever = service.makeRetriever(store: try XCTUnwrap(service.activeVault), documentStore: store)
        XCTAssertNil(retriever.modelScope, "so the route has nothing to search within")
    }

    func testAUnitChangedMidJobSearchesItsOwnDocuments() async throws {
        let (service, _) = try await start()
        XCTAssertEqual(onUnit("QX100", service).retrieve(.init(turn: asked)).passages.first?.documentName, "A02 Acme Service Manual")
        let tool = EquipmentLookupTool(sessionService: service)
        _ = try await tool.execute(args: ["set_equipment": "QX200"])
        let retriever = service.makeRetriever(store: try XCTUnwrap(service.activeVault), documentStore: service.documentStore)
        XCTAssertEqual(retriever.retrieve(.init(turn: asked)).passages.first?.documentName, "A03 Acme Service Manual")
    }

    func testARemovedManualIsNotSearched() async throws {
        let (service, store) = try await start()
        let retriever = onUnit("QX100", service)
        _ = try await VaultManualRemoval.remove(file: "a02.txt", fromVault: "kg_test", documentStore: store)
        XCTAssertFalse(retriever.retrieve(.init(turn: asked)).passages.contains { $0.documentName.hasPrefix("A02") })
    }

    func testAVaultOnlyJobSearchesAlike() async throws {
        let (service, _) = try await start(vaultOnly: true)
        XCTAssertEqual(onUnit("QX100", service).retrieve(.init(turn: asked)).passages.first?.documentName, "A02 Acme Service Manual")
    }

    func testManualLookupFindsThem() async throws {
        let (service, store) = try await start()
        _ = onUnit("QX100", service)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)
        let reply = try await tool.execute(args: ["query": asked])
        XCTAssertTrue(reply.contains("Source: A02"), reply)
        let rewritten = try await tool.execute(args: ["query": asked, "queries": [["language": "en", "query": asked]]])
        XCTAssertTrue(rewritten.contains("Source: A02"), rewritten)
    }

    func testEquipmentLookupsFallThroughFindsThem() async throws {
        let (service, store) = try await start()
        _ = onUnit("QX100", service)
        let tool = EquipmentLookupTool(documentStore: store, sessionService: service)
        let reply = try await tool.execute(args: ["query": asked])
        XCTAssertTrue(reply.contains("A02"), reply)
    }
}

private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                               line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
