import XCTest
@testable import OpenGlasses

/// Plan GG P1 — forgetting one fact removes it from every store that holds it, reports success
/// only after a re-read, and says honestly where a copy may remain.
@MainActor
final class MemoryFactForgetterTests: XCTestCase {

    private var dir: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    private var memory: SemanticMemoryStore!
    private var brain: BrainStore!
    private var notes: AgentDocumentStore!
    private var objects: ObjectMemoryStore!
    private var places: SavedLocationStore!
    private var conversations: ConversationStore!
    private var queue: OfflineQueue!
    private var exports: StagedExportCoordinator!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryFactForgetter_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "MemoryFactForgetterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reopen()
        exports = StagedExportCoordinator(
            channel: .agentExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused",
                                            root: dir.appendingPathComponent("exports", isDirectory: true)))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        // XCTest keeps the case alive until the run ends, so the SQLite-backed stores have to be
        // released here — closing their connections — before their files are unlinked.
        memory = nil
        brain = nil
        queue = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Every store rebuilt from disk, so assertions are about what survived, not what is cached.
    private func reopen() {
        memory = SemanticMemoryStore(directory: dir)
        brain = BrainStore(directory: dir)
        notes = AgentDocumentStore(directory: dir)
        objects = ObjectMemoryStore(defaults: defaults)
        places = SavedLocationStore(defaults: defaults)
        conversations = ConversationStore(directory: dir)
        queue = OfflineQueue(path: dir.appendingPathComponent("offline_queue.sqlite"))
    }

    private func services() -> MemoryFactServices {
        let stores = MemoryFactStores(semantic: memory, brain: brain, agentDocuments: notes,
                                      objects: objects, savedPlaces: places,
                                      conversations: conversations)
        var erasure = SubjectErasureCoordinator.Stores()
        erasure.stagedExports = [exports]
        erasure.brain = brain
        erasure.semanticMemory = memory
        erasure.objectMemory = objects
        erasure.agentDocuments = notes
        erasure.conversations = conversations
        erasure.offlineQueue = queue
        return MemoryFactServices(stores: stores, coordinator: SubjectErasureCoordinator(stores: erasure))
    }

    private func fact(_ store: MemoryFactStore, in services: MemoryFactServices) throws -> MemoryFact {
        try XCTUnwrap(services.repository.load().facts.first { $0.id.store == store })
    }

    // MARK: - Semantic

    func testSemanticForgetRemovesRowAndEmbeddingAndQueuesGatewayDeletion() async throws {
        let thread = conversations.startThread(mode: "test")
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe,
                                            sourceRef: thread.id))
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        let s = services()
        let target = try XCTUnwrap(s.repository.load().facts.first { $0.text.contains("Wellington") })

        let plan = s.forgetter.plan(for: target)
        XCTAssertTrue(plan.gatewayCopyPossible)
        XCTAssertEqual(plan.conversationThreadID, thread.id, "the originating conversation is offered")

        let result = await s.forgetter.forget(plan, removeNoteLines: true)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.remotePending, "the gateway copy cannot be confirmed gone")
        XCTAssertEqual(result.conversationThreadID, thread.id)
        XCTAssertTrue(result.summary.contains("still in the conversation"))
        XCTAssertTrue(queue.all().contains { $0.kind == .subjectErasure },
                      "a deletion request for the gateway copy is queued")
        XCTAssertTrue(conversations.threads.contains { $0.id == thread.id },
                      "the conversation is never deleted automatically (decision 3)")

        reopen()
        XCTAssertNil(memory.entry(id: target.id.recordID))
        XCTAssertEqual(memory.recall("tea"), "earl grey", "an unrelated fact is untouched")
        XCTAssertFalse(memory.semanticSearch(query: "Wellington", limit: 10)
            .contains { $0.value == "Wellington" }, "no search path finds the forgotten fact")
        XCTAssertFalse(memory.systemPromptContext(query: "sister")?.contains("Wellington") == true)
    }

    func testForgettingOffersAndDeletesTheConversationOnlyWhenAsked() async throws {
        let thread = conversations.startThread(mode: "test")
        conversations.appendMessage(role: "user", content: "remember my sister lives in Wellington")
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe,
                                            sourceRef: thread.id))
        let s = services()
        let model = s.makeScreenModel()
        model.reload()
        model.requestForget(try XCTUnwrap(model.listing.facts.first))
        let confirmed = await model.confirmForget()
        let result = try XCTUnwrap(confirmed)
        XCTAssertEqual(result.conversationThreadID, thread.id)
        XCTAssertTrue(conversations.threads.contains { $0.id == thread.id })

        let deleted = await model.deleteOriginatingConversation()
        XCTAssertTrue(deleted)
        XCTAssertFalse(conversations.threads.contains { $0.id == thread.id })
    }

    func testForgetDropsTheGatewayEchoFromThePrompt() async throws {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        memory.gatewayMemories = ["sister city: Wellington", "tea: earl grey"]
        let s = services()
        let target = try fact(.semantic, in: s)
        _ = await s.forgetter.forget(s.forgetter.plan(for: target), removeNoteLines: false)
        XCTAssertEqual(memory.gatewayMemories, ["tea: earl grey"])
    }

    func testTombstoneStopsInferredRelearningButToldMeWins() async throws {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        let s = services()
        _ = await s.forgetter.forget(s.forgetter.plan(for: try fact(.semantic, in: s)),
                                     removeNoteLines: false)

        // The next conversation's memory review re-infers it: dropped, and not reported as a failure.
        let reply = memory.parseAndExecuteCommands(in: "Ok. [REMEMBER: sister_city = wellington]",
                                                   userUtterance: "my sister is in Wellington",
                                                   threadID: nil)
        XCTAssertEqual(reply, "Ok.", "a dropped re-inference is silent, not a failed save")
        XCTAssertNil(memory.recall("sister city"))
        XCTAssertNil(memory.recall("sister_city"))

        // The wearer asks for it again: kept.
        _ = memory.parseAndExecuteCommands(in: "Saved. [REMEMBER: sister city = Wellington]",
                                           userUtterance: "Remember that my sister lives in Wellington",
                                           threadID: nil)
        XCTAssertEqual(memory.recall("sister city"), "Wellington")
    }

    func testStagedExportMadeBeforeTheForgetIsRevokedAndTheExportSourceLacksTheFact() async throws {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        let lease = try AgentDataExporter.exportAll(agentDocs: notes, memoryStore: memory,
                                                    conversationStore: conversations,
                                                    coordinator: exports)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))

        let s = services()
        let result = await s.forgetter.forget(s.forgetter.plan(for: try fact(.semantic, in: s)),
                                              removeNoteLines: false)
        XCTAssertEqual(result.receipts.first { $0.store == .stagedExports }?.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.fileURL.path))

        // The archive is written from the store's key/value cache, so that is what a later export
        // would carry.
        XCTAssertFalse(memory.memories.values.contains("Wellington"),
                       "an export made after the forget lacks the fact")
    }

    // MARK: - Diary

    func testDiaryObservationForgetIsLocalOnly() async throws {
        memory.writeDiary("Seems tired on Mondays")
        let s = services()
        let diary = try fact(.diary, in: s)
        XCTAssertEqual(diary.origin, .inferred)
        let result = await s.forgetter.forget(s.forgetter.plan(for: diary), removeNoteLines: false)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.remotePending, "diary entries never go to a gateway")
        reopen()
        XCTAssertTrue(memory.readDiary(limit: 10).isEmpty)
    }

    // MARK: - Brain

    func testBrainForgetRemovesTheEdgeAndItsRetiredHistory() async throws {
        let earlier = Date().addingTimeInterval(-86_400 * 30)
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Auckland", origin: .toldMe, now: earlier)
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", origin: .toldMe)
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "works_at", dstKind: "org",
                      dstName: "Acme", origin: .toldMe)
        brain.distill()
        XCTAssertEqual(brain.neighbors(of: "Maria", includeSuperseded: true).count, 3)

        let s = services()
        let target = try XCTUnwrap(s.repository.load().facts.first { $0.text == "Maria lives in Wellington" })
        XCTAssertFalse(s.forgetter.plan(for: target).gatewayCopyPossible, "the graph is never synced")
        let result = await s.forgetter.forget(s.forgetter.plan(for: target), removeNoteLines: false)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.receipts.first { $0.store == .brainGraph }?.removed, 2,
                       "the current claim and the retired one it replaced")

        reopen()
        let left = brain.neighbors(of: "Maria", includeSuperseded: true)
        XCTAssertEqual(left.map(\.dstName), ["Acme"], "no lives_in claim survives as history")
    }

    func testBrainTombstoneStopsInferredRelearning() async throws {
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", origin: .toldMe)
        let s = services()
        _ = await s.forgetter.forget(s.forgetter.plan(for: try fact(.brainEdge, in: s)),
                                     removeNoteLines: false)
        brain.ingest(text: "Maria lives in Wellington", sourceRef: "memory-loop", sourceKind: "fact",
                     origin: .inferred)
        // (The ingest still links Maria to its source with a `mentioned_in` edge; that is
        // bookkeeping, not the claim.)
        let claims = { self.brain.neighbors(of: "Maria").filter { $0.relation == "lives_in" } }
        XCTAssertTrue(claims().isEmpty, "the memory loop must not re-learn it")
        brain.addEdge(srcKind: "person", srcName: "Maria", relation: "lives_in", dstKind: "place",
                      dstName: "Wellington", origin: .toldMe)
        XCTAssertEqual(claims().count, 1, "told again, it is kept")
    }

    func testNeedAndProjectNoteForget() async throws {
        brain.addNeed(person: "Sam", text: "send the quote")
        brain.addProjectMemory(projectTag: "job-1", text: "valve on level 2 still leaking")
        let s = services()
        for store in [MemoryFactStore.brainNeed, .projectNote] {
            let f = try fact(store, in: s)
            let result = await s.forgetter.forget(s.forgetter.plan(for: f), removeNoteLines: false)
            XCTAssertTrue(result.verified, store.rawValue)
        }
        reopen()
        XCTAssertTrue(brain.needs(limit: 10).isEmpty)
        XCTAssertTrue(brain.allProjectMemories(limit: 10).isEmpty)
    }

    // MARK: - Agent notes

    func testMatchingNoteLinesAreShownFirstAndRemovedOnlyWhenChosen() async throws {
        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        notes.appendMemory("Their sister moved to Wellington last year")
        notes.appendMemory("Prefers metric units")
        let s = services()
        let target = try fact(.semantic, in: s)
        let plan = s.forgetter.plan(for: target)
        XCTAssertEqual(plan.noteLines.count, 1)
        XCTAssertTrue(plan.noteLines[0].contains("Wellington"))

        let kept = await s.forgetter.forget(plan, removeNoteLines: false)
        XCTAssertEqual(kept.removedNoteLines, 0)
        XCTAssertTrue(notes.content(for: .memory).contains("Wellington"), "not chosen, not removed")

        XCTAssertTrue(memory.rememberGlobal("sister city", value: "Wellington", origin: .toldMe))
        let again = try fact(.semantic, in: s)
        let removed = await s.forgetter.forget(s.forgetter.plan(for: again), removeNoteLines: true)
        XCTAssertEqual(removed.removedNoteLines, 1)
        reopen()
        XCTAssertFalse(notes.content(for: .memory).contains("Wellington"))
        XCTAssertTrue(notes.content(for: .memory).contains("metric units"))
    }

    func testAgentNoteLineForgetsItself() async throws {
        notes.appendMemory("Allergic to cats")
        notes.appendMemory("Prefers metric units")
        let s = services()
        let line = try XCTUnwrap(s.repository.load().facts.first { $0.text == "Allergic to cats" })
        let result = await s.forgetter.forget(s.forgetter.plan(for: line), removeNoteLines: false)
        XCTAssertTrue(result.verified)
        reopen()
        XCTAssertFalse(notes.content(for: .memory).contains("cats"))
        XCTAssertTrue(notes.content(for: .memory).contains("metric"))
    }

    // MARK: - Places

    func testObjectAndSavedPlaceForget() async throws {
        objects.save(ObjectMemoryEntry(id: "o1", objectName: "spare key", locationDescription: "blue bowl",
                                       latitude: nil, longitude: nil, savedAt: Date()))
        places.add(SavedLocationStore.SavedLocation(label: "hotel", latitude: 1, longitude: 2,
                                                    address: nil, timestamp: Date()))
        let s = services()
        for store in [MemoryFactStore.object, .savedPlace] {
            let f = try fact(store, in: s)
            let result = await s.forgetter.forget(s.forgetter.plan(for: f), removeNoteLines: false)
            XCTAssertTrue(result.verified, store.rawValue)
        }
        reopen()
        XCTAssertTrue(objects.all().isEmpty)
        XCTAssertTrue(places.all().isEmpty)
        let receipts = await s.forgetter.forget(
            s.forgetter.plan(for: MemoryFact(id: MemoryFactID(store: .savedPlace, recordID: "gone"),
                                             text: "x", kind: .savedPlace, origin: .toldMe,
                                             createdAt: Date())), removeNoteLines: false).receipts
        XCTAssertEqual(receipts.first { $0.store == .savedLocations }?.removed, 0)
    }

    // MARK: - Receipts

    func testReceiptsCoverTheWalkAndNeverClaimTheTranscript() async throws {
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        let s = services()
        let result = await s.forgetter.forget(s.forgetter.plan(for: try fact(.semantic, in: s)),
                                              removeNoteLines: false)
        XCTAssertEqual(result.receipts.map(\.store), SubjectErasureCoordinator.order)
        let threads = try XCTUnwrap(result.receipts.first { $0.store == .conversationThreads })
        XCTAssertFalse(threads.localComplete, "a transcript is not memory and is not claimed erased")
        XCTAssertNotNil(threads.unsupported)
    }

    func testFailedForgetIsNotReportedAsSuccess() async throws {
        let s = MemoryFactServices(stores: MemoryFactStores(semantic: memory),
                                   coordinator: SubjectErasureCoordinator(stores: .init()))
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        let target = try fact(.semantic, in: s)
        // The walk has no semantic store wired, so nothing can be deleted.
        let result = await s.forgetter.forget(s.forgetter.plan(for: target), removeNoteLines: false)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.summary.contains("couldn't"))
        XCTAssertEqual(memory.recall("tea"), "earl grey")
    }

    func testForgetIsNotRecordedInTheErasureLedger() async throws {
        let ledger = ErasureLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        var erasure = SubjectErasureCoordinator.Stores()
        erasure.semanticMemory = memory
        let s = MemoryFactServices(stores: MemoryFactStores(semantic: memory),
                                   coordinator: SubjectErasureCoordinator(stores: erasure, ledger: ledger))
        XCTAssertTrue(memory.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
        _ = await s.forgetter.forget(s.forgetter.plan(for: try fact(.semantic, in: s)),
                                     removeNoteLines: false)
        XCTAssertTrue(ledger.entries.isEmpty,
                      "a replay would delete the fact again after the wearer re-told it")
    }
}
