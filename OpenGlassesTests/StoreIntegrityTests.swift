import XCTest
@testable import OpenGlasses

/// Plan BB (docs/plans/BB-store-integrity.md): the shared `JSONStore` helper plus the store-level
/// invariant it exists to enforce — **no code path may write over data whose last load failed
/// without first preserving the original.**
@MainActor
final class StoreIntegrityTests: XCTestCase {

    private var tempDir: URL!
    private var backupDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        backupDir = tempDir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        SharedTeleprompterInbox.testContainerURL = nil
        super.tearDown()
    }

    private func backupCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path))?.count ?? 0
    }

    // MARK: - JSONStore core

    func testDecodeArrayAbsentWhenNoData() {
        if case .absent = JSONStore.decodeArray(SavedScript.self, from: nil, name: "t",
                                                backupDirectory: backupDir) {} else {
            XCTFail("nil data should be .absent")
        }
        XCTAssertEqual(backupCount(), 0)
    }

    func testDecodeArrayLoadsIntactBlob() throws {
        let scripts = [SavedScript(title: "A", text: "aaa"), SavedScript(title: "B", text: "bbb")]
        let data = try JSONEncoder().encode(scripts)
        guard case .loaded(let decoded) = JSONStore.decodeArray(SavedScript.self, from: data, name: "t",
                                                                backupDirectory: backupDir) else {
            return XCTFail("intact blob should be .loaded")
        }
        XCTAssertEqual(decoded, scripts)
        XCTAssertEqual(backupCount(), 0)
    }

    func testDecodeArraySalvagesGoodElementsAndBacksUp() throws {
        let good = SavedScript(title: "Keep", text: "kept")
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let blob = "[\(goodJSON), {\"bogus\": true}]".data(using: .utf8)!
        guard case .recovered(let decoded, let backup) =
                JSONStore.decodeArray(SavedScript.self, from: blob, name: "t", backupDirectory: backupDir) else {
            return XCTFail("partially-bad blob should be .recovered")
        }
        XCTAssertEqual(decoded, [good])
        XCTAssertNotNil(backup)
        XCTAssertEqual(try Data(contentsOf: backup!), blob, "backup must be the original bytes")
    }

    func testDecodeArrayCorruptBacksUpOriginal() {
        let blob = Data("not json at all".utf8)
        guard case .corrupt(let backup) =
                JSONStore.decodeArray(SavedScript.self, from: blob, name: "t", backupDirectory: backupDir) else {
            return XCTFail("garbage should be .corrupt")
        }
        XCTAssertNotNil(backup)
        XCTAssertEqual(try? Data(contentsOf: backup!), blob)
    }

    func testDecodeDictionarySalvagesGoodValues() {
        let blob = """
        {"good": {"cardID": "c1", "box": 2, "dueAt": 100, "lastReviewed": 50},
         "bad": {"box": "nope"}}
        """.data(using: .utf8)!
        guard case .recovered(let decoded, _) =
                JSONStore.decodeDictionary(ReviewRecord.self, from: blob, name: "t", backupDirectory: backupDir) else {
            return XCTFail("partially-bad dictionary should be .recovered")
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded["good"]?.box, 2)
    }

    func testLoadArrayFileAbsent() {
        let url = tempDir.appendingPathComponent("missing.json")
        if case .absent = JSONStore.loadArray(SavedScript.self, at: url, name: "t",
                                              backupDirectory: backupDir) {} else {
            XCTFail("missing file should be .absent")
        }
    }

    func testLoadArrayFileUnreadableBlocksSaving() throws {
        // A directory at the file's path: exists, but Data(contentsOf:) throws.
        let url = tempDir.appendingPathComponent("store.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let result = JSONStore.loadArray(SavedScript.self, at: url, name: "t", backupDirectory: backupDir)
        guard case .unreadable = result else {
            return XCTFail("unreadable file should be .unreadable")
        }
        XCTAssertFalse(result.allowsSaving)
        XCTAssertEqual(backupCount(), 0, "an unreadable file must not be 'backed up' (we never saw its bytes)")
    }

    // MARK: - PlaybookStore: corrupt blob must never be overwritten by factory defaults

    func testPlaybookStoreDoesNotOverwriteCorruptBlobWithDefaults() {
        defer {
            UserDefaults.standard.removeObject(forKey: "playbooks")
            UserDefaults.standard.removeObject(forKey: "playbookSession")
        }
        let corrupt = Data("{\"definitely\": \"not a playbook array\"}".utf8)
        UserDefaults.standard.set(corrupt, forKey: "playbooks")

        let store = PlaybookStore()

        XCTAssertFalse(store.playbooks.isEmpty, "defaults should be served in-memory")
        XCTAssertEqual(UserDefaults.standard.data(forKey: "playbooks"), corrupt,
                       "the stored blob must be left for recovery, not overwritten by defaults")
    }

    func testPlaybookStoreSeedsDefaultsOnGenuineFirstRun() {
        defer {
            UserDefaults.standard.removeObject(forKey: "playbooks")
            UserDefaults.standard.removeObject(forKey: "playbookSession")
        }
        UserDefaults.standard.removeObject(forKey: "playbooks")

        let store = PlaybookStore()

        XCTAssertFalse(store.playbooks.isEmpty)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "playbooks"),
                        "a true first run should persist the seed")
    }

    // MARK: - AgentDocumentStore: transient read failure must not clobber documents

    func testAgentDocumentStoreLoadsExistingContent() throws {
        try "my accumulated facts".write(to: tempDir.appendingPathComponent("memory.md"),
                                         atomically: true, encoding: .utf8)
        let store = AgentDocumentStore(directory: tempDir)
        XCTAssertEqual(store.memory, "my accumulated facts")
    }

    func testAgentDocumentStoreTreatsEmptyFileAsValid() throws {
        let url = tempDir.appendingPathComponent("memory.md")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let store = AgentDocumentStore(directory: tempDir)
        XCTAssertEqual(store.memory, "", "an emptied document is intentional, not first-run")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "",
                       "the file must not be re-seeded with defaults")
    }

    func testAgentDocumentStoreDoesNotClobberUnreadableFile() throws {
        // Invalid UTF-8 makes String(contentsOf:encoding:) throw while the file clearly exists —
        // the same shape as a file-protection read failure on a locked device.
        let url = tempDir.appendingPathComponent("memory.md")
        let bytes = Data([0xFF, 0xFE, 0xFD, 0x00, 0x81])
        try bytes.write(to: url)

        let store = AgentDocumentStore(directory: tempDir)

        XCTAssertEqual(store.memory, AgentDocumentStore.defaultMemory,
                       "defaults are served in-memory")
        XCTAssertEqual(try Data(contentsOf: url), bytes,
                       "the on-disk file must be left untouched")
    }

    func testAgentDocumentStoreSavePreservesUnreadableOriginal() throws {
        let url = tempDir.appendingPathComponent("memory.md")
        let bytes = Data([0xFF, 0xFE, 0xFD])
        try bytes.write(to: url)

        let store = AgentDocumentStore(directory: tempDir)
        store.save(.memory, content: "fresh content")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh content")
        let preserved = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("memory.md.unreadable-") }
        XCTAssertEqual(preserved.count, 1, "the unreadable original must be moved aside, not destroyed")
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(preserved[0])), bytes)
    }

    // MARK: - SemanticMemoryStore: SQL safety + migration retirement

    func testMemoryWithApostropheRoundTrips() {
        let store = SemanticMemoryStore(directory: tempDir)
        XCTAssertTrue(store.remember("Daughter's birthday", value: "June 3"))
        XCTAssertEqual(store.recall("daughter's birthday"), "June 3")

        // Persisted, not just cached: a second store over the same directory sees it.
        let reopened = SemanticMemoryStore(directory: tempDir)
        XCTAssertEqual(reopened.recall("daughter's birthday"), "June 3")
    }

    func testForgetWithApostropheActuallyDeletes() {
        let store = SemanticMemoryStore(directory: tempDir)
        XCTAssertTrue(store.remember("dog's vet", value: "Dr. Smith"))
        XCTAssertTrue(store.forget("dog's vet"))
        XCTAssertNil(store.recall("dog's vet"))
        XCTAssertNil(SemanticMemoryStore(directory: tempDir).recall("dog's vet"))
    }

    func testHostileValueIsStoredVerbatim() {
        let store = SemanticMemoryStore(directory: tempDir)
        let value = #"it's "quoted" 🎉 '); DROP TABLE memories; --"#
        XCTAssertTrue(store.remember("hostile", value: value))
        XCTAssertEqual(store.recall("hostile"), value)
        // The table survived the attempt.
        XCTAssertTrue(store.remember("still works", value: "yes"))
    }

    func testLegacyMemoryFileIsRetiredAfterMigration() throws {
        let legacy = tempDir.appendingPathComponent("user_memories.json")
        try #"{"favourite colour": "green"}"#.write(to: legacy, atomically: true, encoding: .utf8)

        let store = SemanticMemoryStore(directory: tempDir)
        XCTAssertEqual(store.recall("favourite colour"), "green", "legacy memories migrate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "the legacy file must be retired after migration")

        // The old bug: clearAll + relaunch re-imported the legacy file, resurrecting
        // deliberately-forgotten memories.
        store.clearAll()
        let relaunched = SemanticMemoryStore(directory: tempDir)
        XCTAssertNil(relaunched.recall("favourite colour"), "cleared memories must stay cleared")
    }

    // MARK: - ConversationStore

    func testConversationStoreLeavesCorruptFileForRecovery() throws {
        let url = tempDir.appendingPathComponent("conversations.json")
        let corrupt = Data("<<<garbage>>>".utf8)
        try corrupt.write(to: url)

        let store = ConversationStore(directory: tempDir)

        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), corrupt,
                       "init must not save over the corrupt file")
    }

    func testConversationStoreBlocksSavesWhenFileUnreadable() throws {
        // A directory at the storage path: exists, unreadable as data.
        let url = tempDir.appendingPathComponent("conversations.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let store = ConversationStore(directory: tempDir)
        _ = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "hello")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "the unreadable item must survive every save attempt")
    }

    func testConversationStoreRoundTrips() {
        let store = ConversationStore(directory: tempDir)
        _ = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "hello")

        let reopened = ConversationStore(directory: tempDir)
        XCTAssertEqual(reopened.threads.count, 1)
        XCTAssertEqual(reopened.threads.first?.messages.first?.content, "hello")
    }

    func testConversationStoreRepairsDuplicatePersistedThreadIDsWithoutLosingConversations() throws {
        var first = ConversationThread(mode: "direct", title: "First")
        first.messages.append(ConversationMessage(role: "user", content: "alpha"))
        var second = first
        second.title = "Second"
        second.messages = [ConversationMessage(role: "user", content: "beta")]
        let data = try JSONEncoder().encode([first, second])
        try data.write(to: tempDir.appendingPathComponent("conversations.json"))

        let store = ConversationStore(directory: tempDir)

        XCTAssertEqual(store.threads.count, 2)
        XCTAssertEqual(Set(store.threads.map(\.id)).count, 2)
        XCTAssertEqual(Set(store.threads.map(\.title)), ["First", "Second"])
        XCTAssertEqual(Set(store.threads.flatMap(\.messages).map(\.content)), ["alpha", "beta"])

        let repairedIDs = store.threads.map(\.id)
        let reopened = ConversationStore(directory: tempDir)
        XCTAssertEqual(reopened.threads.map(\.id), repairedIDs,
                       "repaired row identities must remain stable across launches")
    }

    // MARK: - Teleprompter share inbox: drain must not outrun the save

    func testInboxPeekDoesNotConsume() {
        SharedTeleprompterInbox.testContainerURL = tempDir
        SharedTeleprompterInbox.append(title: "A", text: "aaa")
        SharedTeleprompterInbox.append(title: "B", text: "bbb")

        XCTAssertEqual(SharedTeleprompterInbox.peek().count, 2)
        XCTAssertEqual(SharedTeleprompterInbox.peek().count, 2, "peek must not consume")
    }

    func testInboxRemoveRemovesOnlyGivenItems() {
        SharedTeleprompterInbox.testContainerURL = tempDir
        SharedTeleprompterInbox.append(title: "A", text: "aaa")
        SharedTeleprompterInbox.append(title: "B", text: "bbb")

        let all = SharedTeleprompterInbox.peek()
        SharedTeleprompterInbox.remove([all[0]])

        let remaining = SharedTeleprompterInbox.peek()
        XCTAssertEqual(remaining.map(\.title), ["B"], "items appended since the peek must survive")
    }

    func testImportClearsInboxOnlyAfterSuccessfulSave() throws {
        SharedTeleprompterInbox.testContainerURL = tempDir
        SharedTeleprompterInbox.append(title: "Talk", text: "script body")

        // Scripts file is unreadable → the store's save is suppressed → the share must stay
        // in the inbox for the next attempt instead of being lost from both places.
        let scriptsURL = tempDir.appendingPathComponent("teleprompter_scripts.json")
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)

        _ = TeleprompterScriptStore(directory: tempDir)

        XCTAssertEqual(SharedTeleprompterInbox.peek().count, 1,
                       "a failed save must leave the share in the inbox")
    }

    func testImportClearsInboxAfterSuccessfulSave() {
        SharedTeleprompterInbox.testContainerURL = tempDir
        SharedTeleprompterInbox.append(title: "Talk", text: "script body")

        let store = TeleprompterScriptStore(directory: tempDir)

        XCTAssertEqual(store.scripts.count, 1)
        XCTAssertTrue(SharedTeleprompterInbox.peek().isEmpty,
                      "committed shares are removed from the inbox")
    }

    // MARK: - StudyStore / SafetyAssessmentStore: corrupt files preserved, unreadable blocks saves

    func testStudyStorePreservesCorruptDecksFile() throws {
        let decksURL = tempDir.appendingPathComponent("decks.json")
        let corrupt = Data("junk".utf8)
        try corrupt.write(to: decksURL)

        let store = StudyStore(directory: tempDir)

        XCTAssertTrue(store.decks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: decksURL), corrupt)
    }

    func testStudyStoreBlocksReviewSaveWhenFileUnreadable() throws {
        let reviewsURL = tempDir.appendingPathComponent("reviews.json")
        try FileManager.default.createDirectory(at: reviewsURL, withIntermediateDirectories: true)

        let store = StudyStore(directory: tempDir)
        store.saveReviewRecord(ReviewRecord(cardID: "c1", box: 1, dueAt: 0, lastReviewed: 0))

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewsURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "unreadable reviews file must not be overwritten")
    }

    func testSafetyStorePreservesCorruptHistory() throws {
        let historyURL = tempDir.appendingPathComponent("history.json")
        let corrupt = Data("not reports".utf8)
        try corrupt.write(to: historyURL)

        let store = SafetyAssessmentStore(directory: tempDir)

        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: historyURL), corrupt)
    }

    // MARK: - VaultStore: append must not clobber a log it couldn't read

    func testVaultAppendThrowsOnUnreadableExistingFile() throws {
        let manifest = VaultManifest(
            id: "test_vault", name: "Test", version: "1.0.0", files: ["log.md"],
            proceduresDir: nil, gating: .init(iap: nil), promptRules: [],
            sourceAttributionFormat: nil, sourceAttributionRequired: false
        )
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempDir)
        let logURL = tempDir.appendingPathComponent("log.md")
        let bytes = Data([0xFF, 0xFE, 0xFD])   // invalid UTF-8: read throws, file exists
        try bytes.write(to: logURL)

        XCTAssertThrowsError(try store.append("log.md", entry: "new entry"),
                             "append must not rebuild the log from a failed read")
        XCTAssertEqual(try Data(contentsOf: logURL), bytes, "the log must be untouched")
    }

    func testVaultAppendStillWorksNormally() throws {
        let manifest = VaultManifest(
            id: "test_vault", name: "Test", version: "1.0.0", files: ["log.md"],
            proceduresDir: nil, gating: .init(iap: nil), promptRules: [],
            sourceAttributionFormat: nil, sourceAttributionRequired: false
        )
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempDir)

        try store.append("log.md", entry: "first")
        try store.append("log.md", entry: "second")

        let contents = try XCTUnwrap(store.read("log.md"))
        XCTAssertTrue(contents.contains("first"))
        XCTAssertTrue(contents.contains("second"))
    }
}
