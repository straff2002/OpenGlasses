import XCTest
@testable import OpenGlasses

/// Medical Compliance protection for recording artefacts: recordings (audio and video), their
/// transcripts and the recorded-sessions list.
///
/// Covers the class decision in and out of compliance mode, the enable-time sweep's target list
/// and its effect on real files, the audio filing path, the sessions list's write, and that a
/// missing file is never a failure. Everything runs over a temporary directory.
///
/// The simulator does not always report a file's protection class back, so the class is asserted
/// only where the platform answers. Backup exclusion is always reported, so it is always asserted.
@MainActor
final class RecordingArtefactProtectionTests: XCTestCase {

    private var workspace: URL!
    private var savedMode = false

    override func setUp() {
        super.setUp()
        savedMode = Config.hipaaMode
        Config.hipaaMode = false
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingArtefactProtectionTests_\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Config.hipaaMode = savedMode
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ name: String, in directory: URL? = nil,
                          contents: String = "clinical") throws -> URL {
        let folder = directory ?? workspace!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Read through a fresh URL: `URL` caches resource values, so re-reading the value an earlier
    /// assertion already fetched would report the old answer rather than the file's.
    private func isBackupExcluded(_ url: URL) throws -> Bool {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup ?? false
    }

    /// The class the platform reports, or nil where it does not report one.
    private func reportedProtection(_ url: URL) -> FileProtectionType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey]
            as? FileProtectionType
    }

    private func assertRecordingArtefactClass(_ url: URL,
                                              file: StaticString = #filePath, line: UInt = #line) {
        guard let reported = reportedProtection(url) else { return }
        XCTAssertEqual(reported, .completeUnlessOpen,
                       "\(url.lastPathComponent) carries the wrong protection class",
                       file: file, line: line)
    }

    // MARK: - The decision

    func testOutsideComplianceModeNoClassIsChosen() {
        XCTAssertNil(ComplianceFileProtection.protectionType(for: .recordingArtefact,
                                                             complianceMode: false))
        XCTAssertNil(ComplianceFileProtection.protectionType(for: .foregroundRecord,
                                                             complianceMode: false))
    }

    func testInsideComplianceModeRecordingsCanBeFinishedWhileLockedAndRecordsCannot() {
        XCTAssertEqual(ComplianceFileProtection.protectionType(for: .recordingArtefact,
                                                               complianceMode: true),
                       .completeUnlessOpen)
        // The audit log and exports are written only in the foreground; they keep the strongest.
        XCTAssertEqual(ComplianceFileProtection.protectionType(for: .foregroundRecord,
                                                               complianceMode: true),
                       .complete)
    }

    // MARK: - Applying it

    func testApplyingOutsideComplianceModeLeavesTheFileAlone() throws {
        let url = try makeFile("recording.m4a")
        XCTAssertNil(ComplianceFileProtection.apply(.recordingArtefact, to: url, complianceMode: false))
        XCTAssertFalse(try isBackupExcluded(url))
    }

    func testApplyingInsideComplianceModeProtectsTheFile() throws {
        let url = try makeFile("recording.m4a")
        let outcome = try XCTUnwrap(
            ComplianceFileProtection.apply(.recordingArtefact, to: url, complianceMode: true))
        XCTAssertEqual(outcome.applied, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertFalse(outcome.absent)
        XCTAssertTrue(try isBackupExcluded(url))
        assertRecordingArtefactClass(url)
    }

    func testApplyingToAMissingFileIsNotAFailure() throws {
        let missing = workspace.appendingPathComponent("never-written.m4a")
        let outcome = try XCTUnwrap(
            ComplianceFileProtection.apply(.recordingArtefact, to: missing, complianceMode: true))
        XCTAssertTrue(outcome.absent)
        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "must not create it")
    }

    func testServiceHelperToleratesAMissingFile() {
        Config.hipaaMode = true
        let service = HIPAAComplianceService()
        let missing = workspace.appendingPathComponent("gone.mp4")
        service.protectRecordingArtefact(at: missing)   // must neither throw nor crash
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testApplyingTwiceIsTheSameAsApplyingOnce() throws {
        let url = try makeFile("transcript.txt")
        let first = ComplianceFileProtection.apply(.recordingArtefact, to: url, complianceMode: true)
        let second = ComplianceFileProtection.apply(.recordingArtefact, to: url, complianceMode: true)
        XCTAssertEqual(first, second)
        XCTAssertTrue(try isBackupExcluded(url))
    }

    // MARK: - The sweep's targets

    func testSweepTargetsEveryLocationOnceInOrder() {
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
        let transcripts = workspace.appendingPathComponent("Transcripts", isDirectory: true)
        let sessions = workspace.appendingPathComponent("recorded_sessions.json")
        // The audio and video recorders share a folder; it is swept once.
        let locations = ComplianceFileProtection.Locations(
            recordingsDirectories: [recordings, workspace.appendingPathComponent("Recordings")],
            transcriptsDirectory: transcripts,
            recordedSessionsFile: sessions)

        XCTAssertEqual(ComplianceFileProtection.sweepTargets(locations),
                       [.directory(recordings), .directory(transcripts), .file(sessions)])
    }

    func testSweepTargetsSkipLocationsThatAreNotConfigured() {
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
        let locations = ComplianceFileProtection.Locations(
            recordingsDirectories: [recordings], transcriptsDirectory: nil, recordedSessionsFile: nil)
        XCTAssertEqual(ComplianceFileProtection.sweepTargets(locations), [.directory(recordings)])
    }

    func testProductionLocationsAreTheServicesOwnPaths() {
        let defaults = HIPAAComplianceService.defaultRecordingArtefactLocations
        XCTAssertEqual(defaults.recordingsDirectories, [RecordingFiler.defaultRecordingsDirectory])
        XCTAssertEqual(AudioRecordingService.recordingsDirectory, RecordingFiler.defaultRecordingsDirectory)
        XCTAssertEqual(defaults.recordedSessionsFile, RecordedSessionStore.defaultStorageURL)
        XCTAssertEqual(defaults.transcriptsDirectory?.lastPathComponent, "Transcripts")
        XCTAssertEqual(RecordedSessionStore().storageURL, RecordedSessionStore.defaultStorageURL)
    }

    // MARK: - The sweep itself

    private func seedExistingArtefacts() throws -> (ComplianceFileProtection.Locations, [URL]) {
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
        let transcripts = workspace.appendingPathComponent("Transcripts", isDirectory: true)
        let files = [
            try makeFile("OG_Audio_1_A.m4a", in: recordings),
            try makeFile("Recording_2026-09-15_101500.mp4", in: recordings),
            try makeFile("Recording_2026-09-15_101500.txt", in: recordings),
            try makeFile("transcript_2026-09-15_1015.txt", in: transcripts),
            try makeFile("recorded_sessions.json", contents: "[]"),
        ]
        let locations = ComplianceFileProtection.Locations(
            recordingsDirectories: [recordings], transcriptsDirectory: transcripts,
            recordedSessionsFile: workspace.appendingPathComponent("recorded_sessions.json"))
        return (locations, files)
    }

    func testSweepProtectsEveryExistingArtefactAndIsIdempotent() throws {
        let (locations, files) = try seedExistingArtefacts()
        for file in files { XCTAssertFalse(try isBackupExcluded(file), "sanity: starts unprotected") }

        let first = ComplianceFileProtection.sweep(locations)
        XCTAssertEqual(first.failed, 0)
        XCTAssertFalse(first.absent)
        // Two folders plus the five files.
        XCTAssertEqual(first.applied, 7)
        for file in files {
            XCTAssertTrue(try isBackupExcluded(file), "\(file.lastPathComponent) is still backed up")
            assertRecordingArtefactClass(file)
        }
        for folder in locations.recordingsDirectories + [locations.transcriptsDirectory!] {
            assertRecordingArtefactClass(folder)
        }

        XCTAssertEqual(ComplianceFileProtection.sweep(locations), first)
    }

    func testSweepOverNothingIsAbsentNotAFailure() {
        let locations = ComplianceFileProtection.Locations(
            recordingsDirectories: [workspace.appendingPathComponent("NoRecordings")],
            transcriptsDirectory: workspace.appendingPathComponent("NoTranscripts"),
            recordedSessionsFile: workspace.appendingPathComponent("none.json"))
        let outcome = ComplianceFileProtection.sweep(locations)
        XCTAssertTrue(outcome.absent)
        XCTAssertEqual(outcome.applied, 0)
        XCTAssertEqual(outcome.failed, 0)
    }

    func testTurningComplianceModeOnSweepsWhatIsAlreadySaved() throws {
        let (locations, files) = try seedExistingArtefacts()
        let service = HIPAAComplianceService()
        service.recordingArtefactLocations = { locations }
        defer {
            service.setMode(false)
            service.clearAuditLog(authorization: .granted)
        }

        XCTAssertNil(service.sweepRecordingArtefacts(), "no sweep while the mode is off")
        for file in files { XCTAssertFalse(try isBackupExcluded(file)) }

        service.setMode(true)

        for file in files {
            XCTAssertTrue(try isBackupExcluded(file),
                          "\(file.lastPathComponent) saved before the mode was on is still backed up")
            assertRecordingArtefactClass(file)
        }
    }

    // MARK: - In-progress recordings

    func testOutsideComplianceModeRecordingsStartInTheTemporaryDirectory() {
        let directory = ComplianceFileProtection.inProgressDirectory(
            complianceMode: false, temporaryDirectory: workspace)
        XCTAssertEqual(directory, workspace)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(ComplianceFileProtection.inProgressDirectoryName).path))
    }

    func testInsideComplianceModeRecordingsStartInAProtectedFolder() throws {
        let directory = ComplianceFileProtection.inProgressDirectory(
            complianceMode: true, temporaryDirectory: workspace)
        XCTAssertEqual(directory.lastPathComponent, ComplianceFileProtection.inProgressDirectoryName)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL,
                       workspace.standardizedFileURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        assertRecordingArtefactClass(directory)

        // A file the writer creates there takes the folder's class without anyone setting it.
        let inherited = try makeFile("OG_Audio_2_B.m4a", in: directory)
        assertRecordingArtefactClass(inherited)

        // Asking again for the next recording is harmless.
        XCTAssertEqual(ComplianceFileProtection.inProgressDirectory(
            complianceMode: true, temporaryDirectory: workspace), directory)
    }

    // MARK: - Filing an audio-only recording

    func testFilingAnAudioRecordingInComplianceModeProtectsItWhereItLands() throws {
        let source = try makeFile("OG_Audio_3_C.m4a", in: workspace.appendingPathComponent("tmp"))
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)

        let filed = AudioRecordingService.fileRecording(source, into: recordings, complianceMode: true)

        XCTAssertEqual(filed, recordings.appendingPathComponent("OG_Audio_3_C.m4a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: filed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try isBackupExcluded(filed))
        XCTAssertTrue(try isBackupExcluded(recordings))
        assertRecordingArtefactClass(filed)
        assertRecordingArtefactClass(recordings)
    }

    func testFilingAnAudioRecordingOutsideComplianceModeOnlyMovesIt() throws {
        let source = try makeFile("OG_Audio_4_D.m4a", in: workspace.appendingPathComponent("tmp"))
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)

        let filed = AudioRecordingService.fileRecording(source, into: recordings, complianceMode: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: filed.path))
        XCTAssertFalse(try isBackupExcluded(filed))
    }

    func testAFailedMoveKeepsTheRecordingWhereItWas() {
        let missing = workspace.appendingPathComponent("tmp/OG_Audio_5_E.m4a")
        let recordings = workspace.appendingPathComponent("Recordings", isDirectory: true)
        XCTAssertEqual(AudioRecordingService.fileRecording(missing, into: recordings, complianceMode: true),
                       missing)
    }

    // MARK: - The recorded-sessions list

    private func session() -> RecordedSession {
        RecordedSession(id: UUID(), title: "Consult", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        duration: 42, audioFileName: "OG_Audio_6_F.m4a", transcript: "notes",
                        state: .pending, failureReason: nil)
    }

    func testSessionsListIsProtectedWhenWrittenInComplianceMode() throws {
        let store = RecordedSessionStore(documentsDirectory: workspace, loadImmediately: false,
                                         complianceMode: { true })
        let added = session()
        store.add(added)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
        XCTAssertTrue(try isBackupExcluded(store.storageURL))
        assertRecordingArtefactClass(store.storageURL)

        // Every later atomic write replaces the file; the protection must be set again each time.
        var updated = added
        updated.state = .done
        store.update(updated)
        XCTAssertTrue(try isBackupExcluded(store.storageURL))

        // And it is still an ordinary, readable list.
        let reloaded = RecordedSessionStore(documentsDirectory: workspace, complianceMode: { true })
        XCTAssertEqual(reloaded.sessions.map(\.id), [added.id])
        XCTAssertEqual(reloaded.sessions.first?.state, .done)
    }

    func testSessionsListIsLeftAloneOutsideComplianceMode() throws {
        let store = RecordedSessionStore(documentsDirectory: workspace, loadImmediately: false,
                                         complianceMode: { false })
        store.add(session())
        XCTAssertFalse(try isBackupExcluded(store.storageURL))
    }

    // MARK: - The write paths use the right class

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every recording write path can run with the phone locked, so none of them may reach for
    /// `.complete` — the class that cannot be applied then.
    func testRecordingWritePathsUseTheRecordingArtefactClass() throws {
        let video = try source("OpenGlasses/Sources/Services/VideoRecordingService.swift")
        XCTAssertFalse(video.contains("protectFile("),
                       "a video recording path still applies .complete")
        XCTAssertGreaterThanOrEqual(video.components(separatedBy: "protectRecordingArtefact(at:").count - 1, 4,
                                    "video, sidecar, chosen-folder copy and transcripts copy")
        XCTAssertTrue(video.contains("ComplianceFileProtection.inProgressDirectory"))

        let audio = try source("OpenGlasses/Sources/Services/AudioRecordingService.swift")
        XCTAssertTrue(audio.contains("ComplianceFileProtection.inProgressDirectory"))
        XCTAssertTrue(audio.contains("ComplianceFileProtection.protect(dest, as: .recordingArtefact"))

        let sessions = try source("OpenGlasses/Sources/Services/RecordedSessionStore.swift")
        XCTAssertTrue(sessions.contains(".completeFileProtectionUnlessOpen"))
    }

    /// The foreground-only records keep the strongest class; this change must not weaken them.
    func testForegroundRecordsKeepCompleteProtection() throws {
        let service = try source("OpenGlasses/Sources/Services/HIPAAComplianceService.swift")
        XCTAssertTrue(service.contains("if let url = store.protectedFileURL { protectFile(at: url) }"))
        XCTAssertTrue(service.contains("[.protectionKey: FileProtectionType.complete]"))
        let exports = try source("OpenGlasses/Sources/Services/Export/ProtectedExportFileStore.swift")
        XCTAssertTrue(exports.contains("FileProtectionType.complete"))
        XCTAssertFalse(exports.contains("completeUnlessOpen"))
    }
}
