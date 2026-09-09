import XCTest
@testable import OpenGlasses

/// W03.2 — the canary. One synthetic person is seeded into every store that can carry them, erased
/// through the coordinator, and then looked for again in each store's own read and search API,
/// in what prompt assembly would put in front of the model, and in what an export would carry.
///
/// The seeding matters as much as the erasing. The finding behind this work is that a forget
/// removed a person from the store the wearer was looking at and left them in the stores derived
/// from it, so a test that seeds only one store proves nothing. Every store here is a fresh
/// instance over a temporary directory or a throwaway preference domain: nothing touches the
/// wearer's own data, and nothing reaches a `.shared` service that would talk to the glasses SDK.
@MainActor
final class SubjectErasureTests: XCTestCase {

    /// A name shaped like a person's and shared by no other test. Single alphabetic word so FTS5
    /// and the document tokenizer both index it as one term.
    private let canary = "Zylkorath"

    private var workspace: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    private var conversations: ConversationStore!
    private var recallIndex: ConversationIndex!
    private var memory: SemanticMemoryStore!
    private var brain: BrainStore!
    private var documents: DocumentStore!
    private var faces: FaceRecognitionService!
    private var social: SocialContextStore!
    private var contextualNotes: ContextualNoteStore!
    private var objectMemory: ObjectMemoryStore!
    private var evolvedSkills: EvolvedSkillStore!
    private var agentDocuments: AgentDocumentStore!
    private var recordedSessions: RecordedSessionStore!
    private var queue: OfflineQueue!
    private var exports: StagedExportCoordinator!
    private var spotlight: RecordingSpotlightIndexer!

    private var queuePath: URL { workspace.appendingPathComponent("offline_queue.sqlite") }

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubjectErasure_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        suiteName = "SubjectErasureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)

        conversations = ConversationStore(directory: workspace)
        recallIndex = ConversationIndex(dbURL: workspace.appendingPathComponent("recall.sqlite"))
        memory = SemanticMemoryStore(directory: workspace)
        brain = BrainStore(directory: workspace)
        documents = DocumentStore(directory: workspace)
        faces = FaceRecognitionService(directory: workspace)
        social = SocialContextStore(defaults: defaults)
        contextualNotes = ContextualNoteStore(defaults: defaults)
        objectMemory = ObjectMemoryStore(defaults: defaults)
        evolvedSkills = EvolvedSkillStore(directory: workspace)
        agentDocuments = AgentDocumentStore(directory: workspace)
        recordedSessions = RecordedSessionStore(documentsDirectory: workspace)
        queue = OfflineQueue(path: queuePath)
        spotlight = RecordingSpotlightIndexer()
        exports = StagedExportCoordinator(
            channel: .agentExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(
                rootDirectoryName: "unused",
                root: workspace.appendingPathComponent("exports", isDirectory: true)))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeStores() -> SubjectErasureCoordinator.Stores {
        var stores = SubjectErasureCoordinator.Stores()
        stores.stagedExports = [exports]
        stores.spotlight = SpotlightIndexService(indexer: spotlight, defaults: defaults)
        stores.recallIndex = recallIndex
        stores.vaultDirectories = [workspace]
        stores.documents = documents
        stores.brain = brain
        stores.semanticMemory = memory
        stores.social = social
        stores.faces = faces
        stores.contextualNotes = contextualNotes
        stores.objectMemory = objectMemory
        stores.evolvedSkills = evolvedSkills
        stores.agentDocuments = agentDocuments
        stores.recordedSessions = recordedSessions
        stores.conversations = conversations
        stores.offlineQueue = queue
        return stores
    }

    /// Put the subject into every store the walk can reach.
    private func seed() async {
        // A face, written the way the service stores one — enrolling needs a camera.
        let known = [FaceRecognitionService.KnownFace(name: canary, faceprint: Array(repeating: 0.1, count: 128))]
        try? JSONEncoder().encode(known)
            .write(to: workspace.appendingPathComponent("known_faces.json"), options: .atomic)
        faces = FaceRecognitionService(directory: workspace)

        _ = brain.upsertEntity(kind: "person", name: canary)
        brain.addEdge(srcKind: "person", srcName: canary, relation: "works_at",
                      dstKind: "org", dstName: "Acme")

        _ = memory.remember("colleague", value: "\(canary) prefers morning meetings")
        social.addFact(person: canary, fact: "allergic to shellfish")
        contextualNotes.save(ContextualNote(id: UUID().uuidString,
                                            content: "met \(canary) at the depot",
                                            tags: [], latitude: nil, longitude: nil,
                                            locationName: nil, createdAt: Date()))
        objectMemory.save(ObjectMemoryEntry(id: UUID().uuidString, objectName: "spare key",
                                            locationDescription: "\(canary)'s desk drawer",
                                            latitude: nil, longitude: nil, savedAt: Date()))
        _ = evolvedSkills.enqueue(SkillDraft(name: "greet-colleague",
                                             trigger: "when greeting somebody",
                                             instruction: "\(canary) prefers to be greeted by surname"))
        agentDocuments.save(.memory, content: "# Memory\n- \(canary) is the depot supervisor")

        recordedSessions.add(RecordedSession(
            id: UUID(), title: "site walk", startedAt: Date(), duration: 30,
            audioFileName: "walk.m4a", transcript: "\(canary) showed me the roof plant",
            state: .done, failureReason: nil))

        _ = await documents.ingest(name: "handover", text: "The depot supervisor is \(canary).")

        let thread = conversations.startThread(mode: "test")
        conversations.appendMessage(role: "user", content: "what did \(canary) say about the plant")
        recallIndex.index(IndexedTurn(id: "turn-1", threadID: thread.id, role: "user",
                                      text: "what did \(canary) say about the plant", timestamp: Date()))

        queue.enqueue(QueuedOp.make(kind: .logEntry, sessionId: "s1",
                                    json: ["note": "spoke to \(canary)"]))
    }

    /// Everything a store will say about the subject after it is supposed to be gone.
    private func residue() -> [String: String] {
        var found: [String: String] = [:]
        func note(_ store: String, _ text: String?) {
            guard let text, text.localizedCaseInsensitiveContains(canary) else { return }
            found[store] = text
        }
        note("faces", faces.listKnownFaces())
        note("faces.knownFaces", faces.knownFaces.map(\.name).joined(separator: ","))
        note("brain.neighbors", brain.neighbors(of: canary).map(\.dstName).joined(separator: ","))
        note("brain.entityNames", brain.entityNames(mentionedIn: "did \(canary) call").joined(separator: ","))
        note("memory.values", memory.memories.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
        note("memory.prompt", memory.systemPromptContext(query: canary))
        note("social", social.facts(for: canary).joined(separator: ","))
        note("social.people", social.allPeople().joined(separator: ","))
        note("social.prompt", social.promptContext())
        note("contextualNotes", contextualNotes.all().map(\.content).joined(separator: ","))
        note("contextualNotes.search", contextualNotes.search(canary).map(\.content).joined(separator: ","))
        note("objectMemory", objectMemory.all().map { "\($0.objectName)@\($0.locationDescription)" }
            .joined(separator: ","))
        note("evolvedSkills", evolvedSkills.all().map(\.draft.instruction).joined(separator: ","))
        note("agentDocuments", agentDocuments.content(for: .memory))
        note("agentDocuments.prompt", agentDocuments.agentContext())
        note("recordedSessions", recordedSessions.sessions.map(\.transcript).joined(separator: ","))
        note("recallIndex", recallIndex.search(phrase: canary, limit: 50).map(\.text).joined(separator: ","))
        note("documents", documents.passages(containingToken: canary, limit: 50)
            .map(\.text).joined(separator: ","))
        note("documents.query", documents.query(canary, limit: 5).map(\.text).joined(separator: ","))
        // The erasure tombstone names the subject on purpose — a peer cannot delete a record it
        // has not been told to delete — so it is excluded here and asserted on directly instead.
        note("offlineQueue", queue.all().filter { $0.kind != .subjectErasure }
            .compactMap { String(data: $0.payload, encoding: .utf8) }.joined(separator: ","))
        return found
    }

    /// Rebuild every disk-backed store from its files, so what is asserted is what survived a
    /// restart rather than what happens to be in memory.
    private func reopenFromDisk() {
        conversations = ConversationStore(directory: workspace)
        memory = SemanticMemoryStore(directory: workspace)
        brain = BrainStore(directory: workspace)
        documents = DocumentStore(directory: workspace)
        faces = FaceRecognitionService(directory: workspace)
        evolvedSkills = EvolvedSkillStore(directory: workspace)
        agentDocuments = AgentDocumentStore(directory: workspace)
        recordedSessions = RecordedSessionStore(documentsDirectory: workspace)
        queue = OfflineQueue(path: queuePath)
        social = SocialContextStore(defaults: defaults)
        contextualNotes = ContextualNoteStore(defaults: defaults)
        objectMemory = ObjectMemoryStore(defaults: defaults)
    }

    // MARK: - The canary

    func testSubjectIsAbsentFromEveryStoreAfterErasure() async throws {
        await seed()
        XCTAssertFalse(residue().isEmpty, "sanity: the seed must actually reach the stores")

        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        XCTAssertFalse(receipts.isEmpty)

        reopenFromDisk()
        let survivors = residue()
        XCTAssertTrue(survivors.isEmpty,
                      "the subject survived in: \(survivors.keys.sorted().joined(separator: ", "))")

        // The one place the name may still appear, and why: the queued request a peer needs in
        // order to delete its own copy.
        let tombstones = queue.all().filter { $0.kind == .subjectErasure }
        XCTAssertEqual(tombstones.count, 1)
        XCTAssertTrue(String(data: try XCTUnwrap(tombstones.first).payload, encoding: .utf8)?
            .contains(canary) == true)
    }

    func testPromptAssemblyNoLongerCarriesTheSubject() async throws {
        await seed()
        // Sanity: before the erasure the subject really is in what a prompt would be built from.
        XCTAssertTrue([memory.systemPromptContext(query: canary),
                       agentDocuments.agentContext(),
                       social.promptContext()]
            .contains { $0?.localizedCaseInsensitiveContains(canary) == true })

        _ = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        reopenFromDisk()

        for fragment in [memory.systemPromptContext(query: canary),
                         agentDocuments.agentContext(),
                         social.promptContext()] {
            XCTAssertFalse(fragment?.localizedCaseInsensitiveContains(canary) == true,
                           "a prompt fragment still names the subject: \(fragment ?? "")")
        }
    }

    func testStagedExportOfTheSubjectDoesNotSurviveTheErasure() async throws {
        await seed()
        // An archive made before the erasure is a copy of several of these stores at once.
        let lease = try AgentDataExporter.exportAll(agentDocs: agentDocuments, memoryStore: memory,
                                                    conversationStore: conversations,
                                                    coordinator: exports)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))

        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))

        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.fileURL.path),
                       "an archive containing the subject must not outlive their erasure")
        let exportReceipt = try XCTUnwrap(receipts.first { $0.store == .stagedExports })
        XCTAssertTrue(exportReceipt.localComplete)
        XCTAssertEqual(exportReceipt.removed, 1)
    }

    // MARK: - Receipts

    func testEveryWalkedStoreProducesExactlyOneReceipt() async {
        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        XCTAssertEqual(receipts.map(\.store), SubjectErasureCoordinator.order)
    }

    func testUnsupportedStoresSayWhyAndAreNotReportedComplete() async {
        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        let blocked = receipts.filter { $0.unsupported != nil }
        XCTAssertFalse(blocked.isEmpty, "some stores genuinely cannot be erased by subject")
        for receipt in blocked {
            XCTAssertFalse(receipt.localComplete, "\(receipt.store.rawValue) claims completion it did not do")
            XCTAssertEqual(receipt.removed, 0)
            XCTAssertGreaterThan(receipt.unsupported?.count ?? 0, 20,
                                 "\(receipt.store.rawValue): a refusal needs a reason worth reading")
        }
        // The refusals a wearer must be told about, by name.
        for store in [SensitiveStore.recordings, .capturedPhotos, .clinicalTranscripts] {
            XCTAssertNotNil(receipts.first { $0.store == store }?.unsupported)
        }
    }

    func testAbsentStoreIsReportedUnsupportedRatherThanSkipped() async {
        // A coordinator wired to nothing must still account for every store.
        let receipts = await SubjectErasureCoordinator(stores: .init()).erase(.person(canary))
        XCTAssertEqual(receipts.count, SubjectErasureCoordinator.order.count)
        XCTAssertTrue(receipts.allSatisfy { !$0.localComplete || $0.removed == 0 })
        XCTAssertTrue(receipts.contains { $0.unsupported?.contains("no face service") == true })
    }

    func testSummaryIsContentFree() async {
        await seed()
        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        let summary = SubjectErasureCoordinator.summary(receipts)
        XCTAssertFalse(summary.localizedCaseInsensitiveContains(canary),
                       "the summary of an erasure must not name who was erased")
        XCTAssertTrue(summary.contains("queued for deletion"),
                      "a gateway copy is pending and the wearer has to be told: \(summary)")
    }

    func testCoordinatorWalksEveryStoreTheRegistrySaysCanCarryASubject() {
        let walked = Set(SubjectErasureCoordinator.order)
        for record in SensitiveStore.all {
            if record.deleteSubject.isAvailable {
                XCTAssertTrue(walked.contains(record.store),
                              "\(record.store.rawValue) has a subject delete but the erasure never calls it")
            }
            if record.subjectLinkage == .thirdPartySubject {
                XCTAssertTrue(walked.contains(record.store),
                              "\(record.store.rawValue) holds third-party data but the erasure "
                                  + "never accounts for it")
            }
        }
    }

    // MARK: - Offline queue and restart

    func testQueuedOpCarryingTheSubjectIsRemovedAndTheTombstoneSurvivesARestart() async throws {
        await seed()
        XCTAssertTrue(queue.all().contains { String(data: $0.payload, encoding: .utf8)?
            .contains(canary) == true }, "sanity: the queue holds a copy before the erasure")

        let receipts = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))
        let queueReceipt = try XCTUnwrap(receipts.first { $0.store == .offlineQueue })
        XCTAssertTrue(queueReceipt.remotePending, "a gateway copy exists and is not confirmed gone")
        XCTAssertEqual(queueReceipt.removed, 1, "the pending op carrying the subject must be dropped")

        // Restart: a brand new queue over the same database file.
        queue = OfflineQueue(path: queuePath)
        let survivors = queue.all()
        XCTAssertTrue(survivors.contains { $0.kind == .subjectErasure },
                      "the deletion request must survive a restart to reach the peer")
        XCTAssertFalse(survivors.contains { $0.kind == .logEntry },
                       "the op carrying the subject must not come back")
    }

    func testRetryingTheQueueAfterARestartDoesNotResurrectTheSubject() async throws {
        await seed()
        _ = await SubjectErasureCoordinator(stores: makeStores()).erase(.person(canary))

        queue = OfflineQueue(path: queuePath)
        // A retry re-arms every pending op. Nothing it would send may carry the subject: the
        // tombstone names them because a peer must be told what to delete, and that is the only
        // place the name may appear.
        for op in queue.pending() {
            queue.mark(op.id, state: .pending, attempts: op.attempts + 1)
        }
        reopenFromDisk()

        let payloads = queue.pending().filter { $0.kind != .subjectErasure }
            .compactMap { String(data: $0.payload, encoding: .utf8) }
        XCTAssertFalse(payloads.contains { $0.localizedCaseInsensitiveContains(canary) })

        let survivors = residue().filter { $0.key != "offlineQueue" }
        XCTAssertTrue(survivors.isEmpty,
                      "a retry resurrected the subject in: \(survivors.keys.sorted().joined(separator: ", "))")
    }

    // MARK: - Other subject kinds

    func testErasingAThreadRemovesItAndItsIndexRows() async throws {
        let thread = conversations.startThread(mode: "test")
        conversations.appendMessage(role: "user", content: "about the plant")
        recallIndex.index(IndexedTurn(id: "t1", threadID: thread.id, role: "user",
                                      text: "about the plant", timestamp: Date()))

        let receipts = await SubjectErasureCoordinator(stores: makeStores())
            .erase(.conversationThread(id: thread.id))

        XCTAssertTrue(try XCTUnwrap(receipts.first { $0.store == .conversationThreads }).localComplete)
        reopenFromDisk()
        XCTAssertFalse(conversations.threads.contains { $0.id == thread.id })
        XCTAssertTrue(recallIndex.search(phrase: "plant", limit: 10).isEmpty)
    }

    func testErasingADocumentRemovesItFromTheStoreAndTheVaultLedger() async throws {
        let ingested = await documents.ingest(name: "manual", text: "The unit is a \(canary).")
        let ref = try XCTUnwrap(ingested)
        var ledger = VaultDocumentLedger(entries: [
            .init(file: "manual.pdf", title: "manual", documentId: ref.id,
                  contentHash: "abc", chunkCount: 1),
        ])
        try ledger.save(to: workspace)

        let receipts = await SubjectErasureCoordinator(stores: makeStores())
            .erase(.document(id: ref.id))

        XCTAssertTrue(try XCTUnwrap(receipts.first { $0.store == .ragDocuments }).localComplete)
        XCTAssertEqual(try XCTUnwrap(receipts.first { $0.store == .vaultLedger }).removed, 1)

        reopenFromDisk()
        XCTAssertTrue(documents.passages(containingToken: canary, limit: 10).isEmpty)
        XCTAssertTrue(VaultDocumentLedger.load(from: workspace).entries.isEmpty)
    }
}

/// Records what the erasure asked Spotlight to do, without touching the device's own index.
private final class RecordingSpotlightIndexer: SpotlightIndexing, @unchecked Sendable {
    private(set) var deletedAll = false
    private(set) var deletedIDs: [String] = []

    func upsert(_ entities: [GlassesContentEntity]) async throws {}
    func delete(ids: [String]) async throws { deletedIDs.append(contentsOf: ids) }
    func deleteAll() async throws { deletedAll = true }
}
