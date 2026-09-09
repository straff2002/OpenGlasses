import XCTest
@testable import OpenGlasses

/// W03.4 — every export family staged the way the clinical one already was.
///
/// `MedicalSecretLifecycleTests` is the model, and deliberately so: these assert the same
/// properties against the same mechanism (`ProtectedExportFileStore`), so a regression in the
/// shared store fails in both places rather than only in the clinical suite. `RecordingProtector`
/// is reused from that file for the same reason — the simulator does not reliably report file
/// protection back, so "the applier ran, for the directory before the file" is the observable
/// contract everywhere.

// MARK: - The shared coordinator

@MainActor
final class StagedExportCoordinatorTests: XCTestCase {
    private var root: URL!
    private var protector: RecordingProtector!
    private var coordinator: StagedExportCoordinator!
    private var now = Date()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedExportTests_\(UUID().uuidString)")
        protector = RecordingProtector()
        now = Date()
        coordinator = makeCoordinator()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeCoordinator(protector: RecordingProtector? = nil) -> StagedExportCoordinator {
        StagedExportCoordinator(
            channel: .agentExport,
            rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused", root: root,
                                            protector: protector ?? self.protector),
            clock: { [unowned self] in self.now }
        )
    }

    private func makeLease(_ body: String = "content") throws -> StagedExportLease {
        try coordinator.makeLease(data: Data(body.utf8), fileExtension: "txt",
                                  displayName: "export.txt", fallbackName: "export.txt")
    }

    private func sessionCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.count ?? 0
    }

    func testDirectoryIsProtectedBeforeTheFileIsWritten() throws {
        let lease = try makeLease()
        let directoryIndex = try XCTUnwrap(protector.protected.firstIndex { $0.path == lease.sessionDirectory.path })
        let fileIndex = try XCTUnwrap(protector.protected.firstIndex { $0.path == lease.fileURL.path })
        XCTAssertLessThan(directoryIndex, fileIndex)

        // Backup exclusion is reported back by the simulator; file protection is not, so assert it
        // only where the platform actually answers.
        for url in [lease.sessionDirectory, lease.fileURL] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "\(url.lastPathComponent) must be backup-excluded")
        }
        if let protection = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
    }

    func testDisplayNameNeverBecomesTheFilename() throws {
        let lease = try coordinator.makeLease(data: Data("x".utf8), fileExtension: "zip",
                                              displayName: "../../etc/passwd",
                                              fallbackName: "fallback.zip")
        XCTAssertTrue(ProtectedExportFileStore.isContained(lease.fileURL, within: root))
        XCTAssertFalse(lease.displayName.contains("/"))
        XCTAssertFalse(lease.displayName.contains(".."))
        XCTAssertEqual(lease.fileURL.pathExtension, "zip")
    }

    func testDirectoryAttributeFailureRemovesSession() {
        protector.failure = .directory
        XCTAssertThrowsError(try makeLease())
        XCTAssertEqual(sessionCount(), 0, "a session that could not be protected must not survive")
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testFileAttributeFailureRemovesPartialOutput() {
        protector.failure = .file
        XCTAssertThrowsError(try makeLease("sensitive"))
        XCTAssertEqual(sessionCount(), 0)
    }

    func testWriteFailureRemovesSession() {
        XCTAssertThrowsError(try coordinator.makeLease(
            fileExtension: "txt", displayName: "export.txt", fallbackName: "export.txt"
        ) { _ in throw ProtectedExportFault.writeFailed }) { error in
            XCTAssertEqual(error as? ProtectedExportFault, .writeFailed)
        }
        XCTAssertEqual(sessionCount(), 0)
    }

    func testPartiallyWrittenStagingDoesNotSurviveAFailure() {
        // The multi-file exports stage inside the session directory. A failure part-way through
        // must take the staged plaintext with it, not only the finished artifact.
        XCTAssertThrowsError(try coordinator.makeLease(
            fileExtension: "zip", displayName: "a.zip", fallbackName: "a.zip"
        ) { url in
            let staging = StagedExportCoordinator.stagingDirectory(for: url)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data("plaintext".utf8).write(to: staging.appendingPathComponent("memory.md"))
            throw ProtectedExportFault.writeFailed
        })
        XCTAssertEqual(sessionCount(), 0)
    }

    func testShareOutcomesAllRelease() throws {
        for outcome in [StagedExportCoordinator.ShareOutcome.completed, .cancelled, .failed] {
            let lease = try makeLease()
            coordinator.beginShare(lease)
            coordinator.finishShare(lease, outcome: outcome)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path),
                           "\(outcome.rawValue) must release the file")
        }
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testDoubleReleaseIsHarmless() throws {
        let lease = try makeLease()
        coordinator.release(lease)
        coordinator.release(lease)
        coordinator.finishShare(lease, outcome: .completed)
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testBackgroundingReleasesLeasesNotOwnedByAShare() throws {
        let shared = try makeLease()
        let abandoned = try makeLease("other")
        coordinator.beginShare(shared)

        coordinator.handleBackground()

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.sessionDirectory.path))
        XCTAssertEqual(coordinator.activeLeaseCount, 1)
    }

    func testScavengeSparesFreshActiveLease() throws {
        let lease = try makeLease()
        coordinator.scavenge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.fileURL.path))
    }

    func testCrashAbandonedSessionIsSweptOnceTheTTLPasses() throws {
        let lease = try makeLease()
        // Forget the lease the way a crash would, leaving the completed session on disk.
        coordinator = makeCoordinator(protector: RecordingProtector())

        coordinator.scavenge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.sessionDirectory.path),
                      "inside the crash-recovery window a completed session is kept")

        now = now.addingTimeInterval(7200)
        coordinator.scavenge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }

    func testScavengeRemovesIncompleteSessionImmediately() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stray = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("half-written".utf8).write(to: stray.appendingPathComponent("\(UUID().uuidString).zip"))

        coordinator.scavenge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testRevokeAllRemovesActiveLeases() throws {
        let first = try makeLease()
        let second = try makeLease("second")
        XCTAssertEqual(coordinator.revokeAll(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.sessionDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.sessionDirectory.path))
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }
}

// MARK: - The agent archive

@MainActor
final class AgentArchiveExportLifecycleTests: XCTestCase {
    private var workspace: URL!
    private var root: URL!
    private var protector: RecordingProtector!
    private var coordinator: StagedExportCoordinator!
    private var agentDocs: AgentDocumentStore!
    private var memory: SemanticMemoryStore!
    private var conversations: ConversationStore!

    /// A token that must reach the archive, and must not survive outside it.
    private let canary = "CANARY-ARCHIVE-\(UUID().uuidString.prefix(8))"

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentArchiveTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        root = workspace.appendingPathComponent("exports", isDirectory: true)
        protector = RecordingProtector()
        coordinator = StagedExportCoordinator(
            channel: .agentExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused", root: root, protector: protector))
        agentDocs = AgentDocumentStore(directory: workspace)
        memory = SemanticMemoryStore(directory: workspace)
        conversations = ConversationStore(directory: workspace)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    private func seed() {
        agentDocs.save(.memory, content: "- \(canary)")
        _ = conversations.startThread(mode: "test")
        conversations.appendMessage(role: "user", content: canary)
    }

    private func makeArchive() throws -> StagedExportLease {
        try AgentDataExporter.exportAll(agentDocs: agentDocs, memoryStore: memory,
                                        conversationStore: conversations, coordinator: coordinator)
    }

    func testArchiveIsStagedProtectedAndInsideTheExportRoot() throws {
        seed()
        let lease = try makeArchive()

        XCTAssertTrue(ProtectedExportFileStore.isContained(lease.fileURL, within: root))
        XCTAssertEqual(lease.fileURL.pathExtension, "zip")
        XCTAssertGreaterThan(try Data(contentsOf: lease.fileURL).count, 0)

        let directoryIndex = try XCTUnwrap(protector.protected.firstIndex { $0.path == lease.sessionDirectory.path })
        let fileIndex = try XCTUnwrap(protector.protected.firstIndex { $0.path == lease.fileURL.path })
        XCTAssertLessThan(directoryIndex, fileIndex, "the container is protected before it holds anything")

        let values = try lease.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testPlaintextStagingDoesNotSurviveTheExport() throws {
        seed()
        let lease = try makeArchive()

        let staging = StagedExportCoordinator.stagingDirectory(for: lease.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path),
                       "the readable tree must not outlive the archive it produced")

        // Nor may it have been built in the shared temporary directory, where the previous
        // implementation put it: nothing outside the export root mentions the canary.
        let temp = FileManager.default.temporaryDirectory
        let strays = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        XCTAssertFalse(strays.contains { $0.hasPrefix("openglasses-export-") },
                       "staging must not be built in the shared temporary directory")
    }

    func testReleaseRemovesTheArchiveAndIsIdempotent() throws {
        seed()
        let lease = try makeArchive()
        coordinator.release(lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
        coordinator.release(lease)
        XCTAssertEqual(coordinator.activeLeaseCount, 0)
    }

    func testCancelledShareRemovesTheArchive() throws {
        seed()
        let lease = try makeArchive()
        coordinator.beginShare(lease)
        coordinator.finishShare(lease, outcome: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.sessionDirectory.path))
    }

    func testAttributeFailureLeavesNoArchiveAtAll() {
        seed()
        protector.failure = .file
        XCTAssertThrowsError(try makeArchive())
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(sessions.isEmpty, "a partially protected archive must not survive")
    }
}

// MARK: - The field session record

@MainActor
final class FieldSessionStagedExportTests: XCTestCase {
    private var root: URL!
    private var coordinator: StagedExportCoordinator!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldStagedExportTests_\(UUID().uuidString)")
        coordinator = StagedExportCoordinator(
            channel: .fieldSessionExport, rootDirectoryName: "unused",
            store: ProtectedExportFileStore(rootDirectoryName: "unused", root: root,
                                            protector: RecordingProtector()))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A missing session fails before any staging directory is made — the export root is never
    /// even created, so a failed export leaves nothing to scavenge.
    func testMissingSessionCreatesNoStagingAtAll() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-session-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try SessionExporter.export(sessionDir: missing, formats: [.json],
                                                        coordinator: coordinator))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
