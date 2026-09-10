import XCTest
@testable import OpenGlasses

/// W03.5 — an erasure is only worth recording if the record survives what would undo it, and only
/// worth calling cryptographic if the bytes were actually sealed. Both claims are checked here,
/// and so is the one that matters most: a replay must only ever delete.
@MainActor
final class ErasureSemanticsTests: XCTestCase {

    private var workspace: URL!
    private var keys: InMemoryScopedKeyStore!
    private var keyring: ScopedKeyring!

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErasureSemantics_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        keys = InMemoryScopedKeyStore()
        keyring = ScopedKeyring(store: keys)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    // MARK: - Scoped keys

    func testSealedBytesRoundTripAndAreNotThePlaintext() throws {
        let plaintext = Data("Zylkorath's faceprint".utf8)
        let sealed = try XCTUnwrap(keyring.seal(plaintext, for: .faces))

        XCTAssertTrue(keyring.isSealed(sealed))
        XCTAssertFalse(sealed.contains(Data("Zylkorath".utf8)),
                       "the sealed blob still contains the plaintext")
        XCTAssertEqual(try keyring.open(sealed, for: .faces), plaintext)
    }

    func testUnsealedBytesAreReturnedUnchangedSoAdoptionDoesNotLoseData() throws {
        let legacy = Data(#"[{"name":"someone"}]"#.utf8)
        XCTAssertFalse(keyring.isSealed(legacy))
        XCTAssertEqual(try keyring.open(legacy, for: .faces), legacy)
    }

    func testSealingDegradesToPlaintextWhenNoKeyCanBeMinted() {
        keys.refusesKeys = true
        XCTAssertNil(keyring.seal(Data("x".utf8), for: .faces),
                     "a keyring that cannot mint a key must say so rather than pretend to seal")
    }

    func testOpeningSealedBytesAfterTheKeyIsGoneFails() throws {
        let sealed = try XCTUnwrap(keyring.seal(Data("secret".utf8), for: .faces))
        keyring.eraseClass(.faces, files: [])
        XCTAssertThrowsError(try keyring.open(sealed, for: .faces)) { error in
            XCTAssertEqual(error as? ScopedKeyringError, .keyUnavailable)
        }
    }

    /// The whole point of a scoped key: the copy this app never sees is unreadable afterwards.
    func testErasingASealedClassIsReportedAsCryptographicAndTheSnapshotIsUnreadable() throws {
        let file = workspace.appendingPathComponent("known_faces.json")
        let sealed = try XCTUnwrap(keyring.seal(Data("faceprints".utf8), for: .faces))
        try sealed.write(to: file)
        // Stand in for a copy in a snapshot or a backup: bytes this app cannot delete.
        let snapshot = sealed

        let receipt = keyring.eraseClass(.faces, files: [file])

        XCTAssertEqual(receipt.coverage, .cryptographic)
        XCTAssertTrue(receipt.keyDestroyed)
        XCTAssertEqual(receipt.filesRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try keyring.open(snapshot, for: .faces),
                             "the copy the erasure could not reach is still readable")
    }

    func testErasingAClassThatWasWritingPlaintextIsReportedAsLogicalOnly() throws {
        let file = workspace.appendingPathComponent("known_faces.json")
        try Data("faceprints in the clear".utf8).write(to: file)

        let receipt = keyring.eraseClass(.faces, files: [file])

        XCTAssertEqual(receipt.filesRemoved, 1)
        switch receipt.coverage {
        case .cryptographic:
            XCTFail("plaintext on disk must never be reported as cryptographic erasure")
        case .logicalOnly(let reason):
            XCTAssertTrue(reason.contains("snapshot") || reason.contains("backup"),
                          "the reason has to say what is not reached: \(reason)")
        }
    }

    func testTheKeyGoesBeforeTheFilesSoACrashBetweenThemLeavesCiphertext() throws {
        // Asserted by outcome rather than by ordering a mock: after an erasure in which the file
        // removal fails, the key is still gone and the bytes left behind cannot be opened.
        let directory = workspace.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("known_faces.json")
        let sealed = try XCTUnwrap(keyring.seal(Data("faceprints".utf8), for: .faces))
        try sealed.write(to: file)

        let receipt = keyring.eraseClass(.faces, files: [file], fileManager: RefusingFileManager())

        XCTAssertTrue(receipt.keyDestroyed)
        XCTAssertEqual(receipt.failures, 1)
        XCTAssertThrowsError(try keyring.open(sealed, for: .faces))
    }

    /// Clinical transcripts are deliberately not an erasable class; the plan says why, and this
    /// pins that nobody adds one without the sealing that would make it true.
    func testOnlyClassesWhoseBytesAreSealedAreErasable() {
        XCTAssertEqual(Set(ErasableClass.allCases), [.conversationContent, .faces])
    }

    // MARK: - The face database, sealed end to end

    func testTheFaceDatabaseIsSealedOnDiskAndStillReadsBack() throws {
        let service = FaceRecognitionService(directory: workspace, keyring: keyring)
        _ = service.forgetFace(name: "nobody")   // forces a save

        let file = workspace.appendingPathComponent("known_faces.json")
        let onDisk = try Data(contentsOf: file)
        XCTAssertTrue(keyring.isSealed(onDisk), "the face database was written in the clear")

        let reopened = FaceRecognitionService(directory: workspace, keyring: keyring)
        XCTAssertEqual(reopened.knownFaces.count, 0)
    }

    func testAPlaintextFaceDatabaseWrittenBeforeSealingStillOpens() throws {
        let file = workspace.appendingPathComponent("known_faces.json")
        let legacy = [FaceRecognitionService.KnownFace(name: "Zylkorath",
                                                       faceprint: Array(repeating: 0.1, count: 128))]
        try JSONEncoder().encode(legacy).write(to: file)

        let service = FaceRecognitionService(directory: workspace, keyring: keyring)

        XCTAssertEqual(service.knownFaces.map(\.name), ["Zylkorath"],
                       "adopting sealing must not lose a database written before it")
    }

    // MARK: - The ledger

    func testTheLedgerRoundTripsThroughItsFile() {
        let ledger = ErasureLedger(directory: workspace)
        let first = ledger.record(.subject(kind: "person", token: "Zylkorath"),
                                  coverage: .logicalOnly("walk"), storesCompleted: 12,
                                  storesWalked: 22)
        let second = ledger.record(.dataClass(.faces), coverage: .cryptographic)

        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2, "ids are monotonic")

        let reopened = ErasureLedger(directory: workspace)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.lastID, 2)
        XCTAssertEqual(reopened.entries.first?.scope, .subject(kind: "person", token: "Zylkorath"))
        XCTAssertEqual(reopened.entries.first?.storesCompleted, 12)
        XCTAssertEqual(reopened.entries.last?.coverage, "cryptographic")
    }

    func testTheLedgerFileIsProtectedAndExcludedFromBackup() throws {
        let ledger = ErasureLedger(directory: workspace)
        ledger.record(.dataClass(.faces), coverage: .cryptographic)

        let file = workspace.appendingPathComponent("erasure-ledger.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let excluded = (try file.resourceValues(forKeys: [.isExcludedFromBackupKey]))
            .isExcludedFromBackup ?? false
        XCTAssertTrue(excluded, "the ledger names people who asked to be forgotten; it must not "
                      + "travel into a backup")
        if let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, ErasureLedger.fileProtection)
        }
    }

    func testTheLedgerIsCappedSoItIsNotAnArchiveOfWhoWasForgotten() {
        let ledger = ErasureLedger(directory: workspace)
        for index in 0..<(ErasureLedger.maxEntries + 25) {
            ledger.record(.subject(kind: "person", token: "person-\(index)"),
                          coverage: .logicalOnly("walk"))
        }
        XCTAssertEqual(ledger.entries.count, ErasureLedger.maxEntries)
        XCTAssertEqual(ledger.entries.first?.id, 26, "the oldest entries went, not the newest")
    }

    func testPurgingTheLedgerRemovesOnlyEntriesPastTheCutoff() {
        let ledger = ErasureLedger(directory: workspace)
        let now = Date()
        ledger.record(.dataClass(.faces), coverage: .cryptographic,
                      now: now.addingTimeInterval(-200 * 86_400))
        ledger.record(.dataClass(.conversationContent), coverage: .cryptographic, now: now)

        let removed = ledger.purge(olderThan: now.addingTimeInterval(-90 * 86_400))

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ErasureLedger(directory: workspace).entries.count, 1)
    }

    // MARK: - Replay

    /// The case the ledger exists for: the store came back, and the erasure is honoured again.
    func testReplayReErasesASubjectWhoseStoreReappeared() async throws {
        let ledger = ErasureLedger(directory: workspace)
        let memory = SemanticMemoryStore(directory: workspace)
        var stores = SubjectErasureCoordinator.Stores()
        stores.semanticMemory = memory
        let coordinator = SubjectErasureCoordinator(stores: stores, ledger: ledger)

        _ = memory.remember("colleague", value: "Zylkorath prefers morning meetings")
        await coordinator.erase(.person("Zylkorath"))
        XCTAssertTrue(memory.memories.values.allSatisfy { !$0.contains("Zylkorath") })
        XCTAssertEqual(ledger.entries.count, 1)

        // The restore: the record is back in the store, and nothing else changed.
        _ = memory.remember("colleague", value: "Zylkorath prefers morning meetings")
        XCTAssertTrue(memory.memories.values.contains { $0.contains("Zylkorath") })

        var sources = ErasureReplay.Sources()
        sources.subjects = SubjectErasureCoordinator(stores: stores)
        let outcomes = await ErasureReplay.replay(ledger: ledger, sources: sources)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0].resurrected)
        XCTAssertTrue(memory.memories.values.allSatisfy { !$0.contains("Zylkorath") },
                      "the restored record survived the replay")
        XCTAssertNotNil(ledger.entries.first?.lastReplayedAt)
        XCTAssertEqual(ledger.entries.count, 1, "a replay must not record itself as a new erasure")
    }

    func testReplayReRemovesAClassFileThatCameBack() async throws {
        let ledger = ErasureLedger(directory: workspace)
        let file = workspace.appendingPathComponent("known_faces.json")
        try Data("faceprints".utf8).write(to: file)
        keyring.eraseClass(.faces, files: [file])
        ledger.record(.dataClass(.faces), coverage: .cryptographic)

        // The restore puts the file back. The key is still gone, so these bytes are already
        // unreadable — the replay removes them anyway rather than leaving them lying about.
        try Data("faceprints".utf8).write(to: file)

        var sources = ErasureReplay.Sources()
        sources.keyring = keyring
        sources.classFiles = { _ in [file] }
        let outcomes = await ErasureReplay.replay(ledger: ledger, sources: sources)

        XCTAssertEqual(outcomes.map(\.removed), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// The safety property. A replay is a delete-only operation: with nothing to remove it removes
    /// nothing, and it never puts anything back.
    func testReplayNeverResurrectsAnythingAndLeavesUnrelatedRecordsAlone() async {
        let ledger = ErasureLedger(directory: workspace)
        let memory = SemanticMemoryStore(directory: workspace)
        var stores = SubjectErasureCoordinator.Stores()
        stores.semanticMemory = memory
        ledger.record(.subject(kind: "person", token: "Zylkorath"), coverage: .logicalOnly("walk"))

        _ = memory.remember("unrelated", value: "the depot opens at seven")

        var sources = ErasureReplay.Sources()
        sources.subjects = SubjectErasureCoordinator(stores: stores)
        let outcomes = await ErasureReplay.replay(ledger: ledger, sources: sources)

        XCTAssertEqual(outcomes.map(\.removed), [0], "nothing came back, so nothing was removed")
        XCTAssertFalse(outcomes[0].resurrected)
        XCTAssertEqual(memory.recall("unrelated"), "the depot opens at seven",
                       "a replay took an unrelated record with it")
        XCTAssertNil(ledger.entries.first?.lastReplayedAt,
                     "a replay that found nothing must not claim to have re-applied anything")
    }

    func testReplayIgnoresEntriesOlderThanItsWindow() async {
        let ledger = ErasureLedger(directory: workspace)
        let memory = SemanticMemoryStore(directory: workspace)
        var stores = SubjectErasureCoordinator.Stores()
        stores.semanticMemory = memory
        ledger.record(.subject(kind: "person", token: "Zylkorath"), coverage: .logicalOnly("walk"),
                      now: Date().addingTimeInterval(-(ErasureReplay.window + 86_400)))
        _ = memory.remember("colleague", value: "Zylkorath prefers morning meetings")

        var sources = ErasureReplay.Sources()
        sources.subjects = SubjectErasureCoordinator(stores: stores)
        let outcomes = await ErasureReplay.replay(ledger: ledger, sources: sources)

        XCTAssertTrue(outcomes.isEmpty)
    }

    func testAnUnwiredSourceIsNotReportedAsReplayed() async {
        let ledger = ErasureLedger(directory: workspace)
        ledger.record(.subject(kind: "person", token: "Zylkorath"), coverage: .logicalOnly("walk"))

        let outcomes = await ErasureReplay.replay(ledger: ledger, sources: ErasureReplay.Sources())

        XCTAssertTrue(outcomes.isEmpty, "with nothing wired in, nothing may be claimed")
    }

    // MARK: - Deletion honesty

    func testTheDeletionAPINoLongerClaimsToOverwrite() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("OpenGlasses/Sources/Services/HIPAAComplianceService.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("randomData"),
                       "the overwrite-then-remove claim is back; on flash it does not do what it says")
        XCTAssertTrue(source.contains("func deleteFile(at url: URL)"))
    }
}

/// A `FileManager` that reports files as present and refuses to remove them, standing in for the
/// window where protected data is locked.
private final class RefusingFileManager: FileManager {
    override func fileExists(atPath path: String) -> Bool { true }
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
