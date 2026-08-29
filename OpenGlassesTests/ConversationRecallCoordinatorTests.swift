import XCTest
@testable import OpenGlasses

@MainActor
final class ConversationRecallCoordinatorTests: XCTestCase {
    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        func markStarted() { lock.withLock { started = true } }
        func markCancelled() { lock.withLock { cancelled = true } }
        var hasStarted: Bool { lock.withLock { started } }
        var wasCancelled: Bool { lock.withLock { cancelled } }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationRecallCoordinatorTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func waitUntilReady(_ coordinator: ConversationRecallCoordinator) async {
        for _ in 0..<200 {
            if case .ready = coordinator.state { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Recall coordinator did not become ready")
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           failure: String) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(failure)
    }

    private func readyCoordinator() async -> ConversationRecallCoordinator {
        let coordinator = ConversationRecallCoordinator()
        coordinator.start(threads: [], isLocked: false, legacyDirectory: tempDir)
        await waitUntilReady(coordinator)
        return coordinator
    }

    private func turn(_ id: String, text: String, thread: String = "thread") -> IndexedTurn {
        IndexedTurn(id: id, threadID: thread, role: "user", text: text, timestamp: Date())
    }

    func testMigrationRemovesDatabaseAndSidecars() throws {
        for name in RecallIndexMigration.legacyNames {
            try Data("plaintext".utf8).write(to: tempDir.appendingPathComponent(name))
        }

        XCTAssertTrue(RecallIndexMigration(directory: tempDir).removeLegacyArtifacts())
        for name in RecallIndexMigration.legacyNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(name).path))
        }
    }

    func testFailedMigrationStaysUnavailableAndRetriesOnUnlock() async {
        var attempts = 0
        let coordinator = ConversationRecallCoordinator { _ in
            attempts += 1
            return attempts > 1
        }

        coordinator.start(threads: [], isLocked: false, legacyDirectory: tempDir)
        XCTAssertEqual(coordinator.state, .unavailable)
        XCTAssertEqual(coordinator.search("anything"), .unavailable)

        coordinator.storeDidUnlock(threads: [])
        await waitUntilReady(coordinator)
        XCTAssertEqual(attempts, 2)
        guard case .ready = coordinator.state else { return XCTFail("Expected retry to rebuild") }
    }

    func testProductionCoordinatorCreatesNoPersistentIndex() async {
        let coordinator = await readyCoordinator()
        guard case .ready = coordinator.state else { return XCTFail("Expected ready state") }

        XCTAssertTrue(RecallIndexMigration.legacyNames.allSatisfy {
            !FileManager.default.fileExists(atPath: tempDir.appendingPathComponent($0).path)
        })
    }

    func testLockDestroysSearchableProjection() async {
        let coordinator = await readyCoordinator()
        coordinator.apply(.messageUpsert(turn("a", text: "museum launch")), persistedSnapshot: [])
        guard case .ready(let before, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertEqual(before.map(\.id), ["a"])

        coordinator.storeDidLock()
        XCTAssertEqual(coordinator.search("museum"), .locked)
    }

    func testProtectedDataLossDestroysAndAvailabilityRebuildsProjection() async {
        let coordinator = await readyCoordinator()
        let store = ConversationStore(directory: tempDir)
        store.recallCoordinator = coordinator
        _ = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "protected museum memory")

        store.protectedDataWillBecomeUnavailable()
        XCTAssertEqual(coordinator.search("museum"), .locked)

        store.protectedDataDidBecomeAvailable()
        await waitUntilReady(coordinator)
        guard case .ready(let hits, _) = coordinator.search("museum") else {
            return XCTFail("Expected rebuilt search")
        }
        XCTAssertEqual(hits.count, 1)
    }

    func testProtectedDataAvailabilityDoesNotBypassConversationLock() async {
        let coordinator = await readyCoordinator()
        let store = ConversationStore(directory: tempDir)
        store.recallCoordinator = coordinator
        store.isLocked = true

        coordinator.storeDidLock()
        store.protectedDataDidBecomeAvailable()
        XCTAssertEqual(coordinator.state, .locked)
    }

    func testLockDuringRebuildCancelsDetachedWorker() async {
        let probe = CancellationProbe()
        let coordinator = ConversationRecallCoordinator(buildIndex: { _, shouldCancel in
            probe.markStarted()
            while !shouldCancel() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            probe.markCancelled()
            return nil
        })

        coordinator.start(threads: [], isLocked: false, legacyDirectory: tempDir)
        await waitUntil({ probe.hasStarted }, failure: "Rebuild worker did not start")
        coordinator.storeDidLock()
        await waitUntil({ probe.wasCancelled }, failure: "Detached rebuild was not cancelled")

        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertEqual(coordinator.search("anything"), .locked)
    }

    func testRelaunchRebuildsWithoutLeavingRecallArtifacts() async {
        let store = ConversationStore(directory: tempDir)
        let first = ConversationRecallCoordinator()
        store.recallCoordinator = first
        first.start(threads: store.threads, isLocked: false, legacyDirectory: tempDir)
        await waitUntilReady(first)
        _ = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "relaunch museum memory")
        first.storeDidLock()

        let relaunched = ConversationRecallCoordinator()
        store.recallCoordinator = relaunched
        relaunched.start(threads: store.threads, isLocked: false, legacyDirectory: tempDir)
        await waitUntilReady(relaunched)

        guard case .ready(let hits, _) = relaunched.search("museum") else {
            return XCTFail("Expected rebuilt search after relaunch")
        }
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(RecallIndexMigration.legacyNames.allSatisfy {
            !FileManager.default.fileExists(atPath: tempDir.appendingPathComponent($0).path)
        })
    }

    func testMessageAndThreadDeletionUpdateProjection() async {
        let coordinator = await readyCoordinator()
        coordinator.apply(.messageUpsert(turn("a", text: "museum alpha", thread: "one")),
                          persistedSnapshot: [])
        coordinator.apply(.messageUpsert(turn("b", text: "museum beta", thread: "one")),
                          persistedSnapshot: [])
        coordinator.apply(.messageUpsert(turn("c", text: "museum gamma", thread: "two")),
                          persistedSnapshot: [])

        coordinator.apply(.messageDelete(ids: ["b"]), persistedSnapshot: [])
        guard case .ready(let afterMessageDelete, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertEqual(Set(afterMessageDelete.map(\.id)), ["a", "c"])

        coordinator.apply(.threadDelete(id: "one"), persistedSnapshot: [])
        guard case .ready(let afterThreadDelete, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertEqual(afterThreadDelete.map(\.id), ["c"])
    }

    func testFailedConversationSaveDoesNotReachProjection() async throws {
        let coordinator = await readyCoordinator()
        let badDirectory = tempDir.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: badDirectory.appendingPathComponent("conversations.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        let store = ConversationStore(directory: badDirectory)
        store.recallCoordinator = coordinator
        _ = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "private museum decision")

        guard case .ready(let hits, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertTrue(hits.isEmpty, "a mutation that was not persisted must not enter recall")
    }

    func testStoreAppendTruncateAndDeleteStayInSync() async {
        let coordinator = await readyCoordinator()
        let store = ConversationStore(directory: tempDir)
        store.recallCoordinator = coordinator
        let thread = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "museum first")
        store.appendMessage(role: "assistant", content: "museum second")

        guard let firstID = store.threads.first?.messages.first?.id else {
            return XCTFail("Expected a persisted message")
        }
        store.truncate(from: firstID, in: thread.id)
        guard case .ready(let afterTruncate, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertTrue(afterTruncate.isEmpty)

        store.appendMessage(role: "user", content: "museum replacement")
        store.deleteThread(thread.id)
        guard case .ready(let afterDelete, _) = coordinator.search("museum") else {
            return XCTFail("Expected ready search")
        }
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
