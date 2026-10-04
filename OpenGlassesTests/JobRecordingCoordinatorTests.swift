import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// "Record this job", driven with a fake recorder, a fake clock and real stores in a temporary
/// folder (Plan HE P1).
///
/// Nothing here touches a camera, an encoder, the glasses or a shared service. What has to be
/// right is decided by the coordinator: when nothing is recorded and why, where the frames come
/// from and where the parts go, how parts and gaps land on the clock, the two size limits, and
/// what is sealed for the office.
@MainActor
final class JobRecordingCoordinatorTests: XCTestCase {
    private typealias Coordinator = JobRecordingCoordinator

    // MARK: - Doubles

    /// A recorder that writes a file where it is told to and reports the part's timing from the
    /// test's own clock.
    private final class FakeRecorder: JobPartRecording {
        var onStalled: ((RecordingTimebase?) -> Void)?
        var started: [(frames: PassthroughSubject<UIImage, Never>, file: URL)] = []
        var finished = 0
        var bytesPerPart = 2_048
        var failNextStart: JobPartStartError?
        /// When false, a part ends having recorded nothing.
        var records = true
        var soundless = false
        let monotonic: () -> TimeInterval
        private var partStarted: TimeInterval?

        init(monotonic: @escaping () -> TimeInterval) { self.monotonic = monotonic }

        func startPart(from frames: PassthroughSubject<UIImage, Never>, to file: URL) throws {
            if let failure = failNextStart {
                failNextStart = nil
                throw failure
            }
            started.append((frames, file))
            // The coordinator reads the part's size and seals its bytes, so it has to be on disk.
            try Data(repeating: UInt8(started.count), count: bytesPerPart).write(to: file)
            partStarted = monotonic()
        }

        private func endPart() -> RecordingTimebase? {
            guard let began = partStarted else { return nil }
            partStarted = nil
            guard records else { return nil }
            let length = monotonic() - began
            // The sound starts a fifth of a second after the pictures, as a real recorder's does.
            return RecordingTimebase(video: .init(firstSample: began, duration: length),
                                     audio: soundless ? nil : .init(firstSample: began + 0.2, duration: length - 0.2))
        }

        func finishPart() async -> RecordingTimebase? {
            finished += 1
            return endPart()
        }

        /// The glasses stopped sending pictures.
        func stall() { onStalled?(endPart()) }
    }

    /// A blur pass that does no blurring: it writes what it was given, under a prefix that says
    /// it came out of the pass, and reports what the test tells it to. What has to be right here
    /// is what the coordinator does around a pass, not the pass.
    private final class FakeBlur {
        static let prefix = Data("blurred:".utf8)

        var available = true
        /// The parts handed over, by file name, with where each was to be written.
        var asked: [(part: String, output: String)] = []
        /// What the pass reports for a part, by part name. One not named here is blurred whole.
        var results: [String: Result<BlurredPart.Report, JobPartBlur.Failure>] = [:]
        var awake: [Bool] = []
        var progressSeen: [Double] = []
        /// When true a part takes for ever: the pass goes on until it is cancelled, as a real one
        /// goes on frame after frame, and only then says what `results` tells it to.
        var runsUntilCancelled = false
        /// How many parts are in the middle of being blurred.
        var running = 0

        static let whole = BlurredPart.Report(framesWritten: 480, framesDropped: 0, keptSound: true)

        var seam: JobPartBlur {
            JobPartBlur(
                isAvailable: { self.available },
                blur: { part, output, progress in
                    if await MainActor.run(body: { self.runsUntilCancelled }) {
                        await MainActor.run { self.running += 1 }
                        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
                        await MainActor.run { self.running -= 1 }
                    }
                    return await MainActor.run { () -> Result<BlurredPart.Report, JobPartBlur.Failure> in
                        self.asked.append((part.lastPathComponent, output.lastPathComponent))
                        progress(0.5)
                        let name = part.deletingPathExtension().lastPathComponent
                        let result = self.results[name] ?? .success(Self.whole)
                        switch result {
                        case .success(let report) where !report.keptNothing:
                            try? (Self.prefix + ((try? Data(contentsOf: part)) ?? Data())).write(to: output)
                        case .success:
                            break
                        case .failure:
                            // A real pass removes what it had written. This one leaves it, so the
                            // coordinator's own clearing up is what is tested.
                            try? Data("half a part".utf8).write(to: output)
                        }
                        return result
                    }
                },
                keepAwake: { self.awake.append($0) })
        }
    }

    // MARK: - The world

    private var root: URL!
    private var recorder: FakeRecorder!
    private var blur: FakeBlur?
    private var rawFrames: PassthroughSubject<UIImage, Never>!
    private var relayFrames: PassthroughSubject<UIImage, Never>!

    private var monotonic: TimeInterval = 5_000
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)

    private var rules = Coordinator.Rules(officeTransportInBuild: true, fieldAssistEntitled: true,
                                          organizationForbidsRecording: false, organizationRequiresBlur: false,
                                          medicalComplianceMode: false, officeRouteRefused: false)
    private var binding: BundleManifest.Binding?
    private var job: Coordinator.OpenJob?
    private var consent: RecordingConsent.Acknowledgement?
    private var readiness: CameraReadiness?
    private var streamResult = ClipStreamWarmup.Result.claimFailed
    private var streamClaims = 0
    private var streamReleases = 0
    private var limits = RetentionDecision.Limits.standard
    private var logEntries: [RecordedJobAssembly.LogEntry] = []
    private var words: [TimedTranscript.Utterance] = []
    private var logged: [(sessionID: String, kind: SessionLogger.Event.Kind, payload: [String: AnyCodable])] = []
    private var auditedConsents: [RecordingConsent.Acknowledgement] = []
    private var signed = 0
    private var signFailuresLeft = 0
    private var holdTranscription = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdSigning = false
    private var signingWaiters: [CheckedContinuation<Void, Never>] = []
    /// The jobs whose sealed bundle the coordinator asked to have taken back out of the office's folder.
    private var withdrawn: [String] = []
    private struct Failed: Error {}
    private var sealedCalls = 0
    private var bundleIDs = 0

    private let sessionID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private static let streaming = CameraReadiness(phase: .ready, frameAge: 0.1, session: 1, userWantsStream: true)

    private static let office = BundleManifest.Binding(
        organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment",
        officeID: "office-6c20b57a74ba2a4be634f3dd", generation: 1,
        phoneTransportID: "A44GCYW-HLGLMZV-EG2RHLW-YRQ773E-7GZUZMH-26RQHUT-MGGFBAI-JF7G6AW")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobRecordingCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        recorder = FakeRecorder { [unowned self] in self.monotonic }
        rawFrames = PassthroughSubject<UIImage, Never>()
        relayFrames = PassthroughSubject<UIImage, Never>()
        binding = Self.office
        job = .init(sessionID: sessionID, jobNumber: "JOB-1042")
        consent = .init(at: wall.addingTimeInterval(-3_600), organizationID: Self.office.organizationID)
        readiness = Self.streaming
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var sessionsRoot: URL { root.appendingPathComponent("FieldSessions", isDirectory: true) }
    private var bundles: JobRecordingBundleStore { .init(sessionsRoot: sessionsRoot) }
    private var capture: JobRecordingCaptureStore { .init(sessionsRoot: sessionsRoot) }

    private func advance(_ seconds: TimeInterval) {
        monotonic += seconds
        wall = wall.addingTimeInterval(seconds)
    }

    /// The usual seams with another blur pass in place of the test's own.
    private func lyingSeams(_ pass: JobPartBlur) -> Coordinator.Seams {
        var seams = makeSeams()
        seams.blur = pass
        return seams
    }

    private func makeCoordinator() -> Coordinator { Coordinator(seams: makeSeams()) }

    private func makeSeams() -> Coordinator.Seams {
        .init(
            rules: { [unowned self] in self.rules },
            binding: { [unowned self] in self.binding },
            job: { [unowned self] in self.job },
            consent: { [unowned self] in self.consent },
            saveConsent: { [unowned self] in self.consent = $0 },
            recorder: recorder,
            frames: { [unowned self] in self.rawFrames },
            readiness: { [unowned self] in self.readiness },
            ensureStream: { [unowned self] in
                self.streamClaims += 1
                return self.streamResult
            },
            releaseStream: { [unowned self] in self.streamReleases += 1 },
            capture: capture,
            bundles: bundles,
            sign: { [unowned self] _ in
                let fails = await MainActor.run { () -> Bool in
                    self.signed += 1
                    guard self.signFailuresLeft > 0 else { return false }
                    self.signFailuresLeft -= 1
                    return true
                }
                if fails { throw Failed() }
                await self.waitWhileSigningIsHeld()
                return Data(repeating: 7, count: 64)
            },
            blur: blur?.seam,
            transcribe: { [unowned self] _ in
                if self.holdTranscription {
                    await withCheckedContinuation { self.transcriptionWaiters.append($0) }
                }
                return self.words
            },
            logEntries: { [unowned self] _ in self.logEntries },
            log: { [unowned self] sessionID, kind, payload in self.logged.append((sessionID, kind, payload)) },
            auditConsent: { [unowned self] in self.auditedConsents.append($0) },
            sealed: { [unowned self] in self.sealedCalls += 1 },
            withdrawSealed: { [unowned self] in self.withdrawn.append($0) },
            limits: limits,
            wallNow: { [unowned self] in self.wall },
            monotonicNow: { [unowned self] in self.monotonic },
            newBundleID: { [unowned self] in
                self.bundleIDs += 1
                return String(format: "%032x", self.bundleIDs)
            })
    }

    /// Lets work the coordinator started on the main actor run.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// The signer in the middle of signing, for as long as the test holds it there.
    private func waitWhileSigningIsHeld() async {
        guard holdSigning else { return }
        await withCheckedContinuation { signingWaiters.append($0) }
    }

    /// Waits for something that happens off the main actor, for at most a few seconds.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<3_000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func started(_ coordinator: Coordinator, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await coordinator.start()
        guard case .success = result else {
            return XCTFail("the recording did not start: \(result)", file: file, line: line)
        }
    }

    private func refusal(_ coordinator: Coordinator) async -> Coordinator.Refusal? {
        if case .failure(let refusal) = await coordinator.start() { return refusal }
        return nil
    }

    /// Starting is refused, for this reason.
    private func assertRefused(_ coordinator: Coordinator, _ expected: Coordinator.Refusal,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let refused = await refusal(coordinator)
        XCTAssertEqual(refused, expected, file: file, line: line)
    }

    private func kinds() -> [SessionLogger.Event.Kind] { logged.map(\.kind) }

    private func timeline(_ record: JobRecordingBundleStore.Record) throws -> SessionTimeline {
        try SessionTimeline.decode(Data(contentsOf: bundles.timelineFile(record)))
    }

    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    // MARK: - Starting

    func testARecordingTakesTheRawFramesAndWritesIntoTheJobsOwnFolder() async throws {
        let coordinator = makeCoordinator()
        let result = await coordinator.start()

        XCTAssertEqual(try result.get(), RecordingConsent.reminder, "the one line shown at every start")
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        XCTAssertEqual(recorder.started.count, 1)
        let part = try XCTUnwrap(recorder.started.first)
        XCTAssertTrue(part.frames === rawFrames, "the recorder is handed the camera's own publisher")
        XCTAssertFalse(part.frames === relayFrames)

        // The job's own folder: Documents/FieldSessions/{id}/recording/ — and nowhere else.
        let folder = sessionsRoot.appendingPathComponent(sessionID).appendingPathComponent("recording")
        XCTAssertTrue(part.file.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                      part.file.path)
        XCTAssertEqual(part.file.lastPathComponent, "part-1.mp4")
        XCTAssertFalse(part.file.path.contains("/Recordings/"))
        XCTAssertFalse(part.file.path.contains("/tmp/OpenGlasses_"))

        XCTAssertEqual(kinds(), [.recordingStarted])
        XCTAssertEqual(streamClaims, 0, "a camera already producing pictures is not claimed again")
    }

    func testTheFolderARecordingIsWrittenIntoIsKeptOutOfBackup() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        let folder = capture.directory(sessionID: sessionID)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(SensitiveStore.jobRecordingCapture.record.protection, .completeUnlessOpen)
        XCTAssertTrue(SensitiveStore.jobRecordingCapture.record.backupExcluded)
    }

    func testACameraThatIsNotRunningIsClaimedAndGivenBackWhenTheRecordingStops() async {
        readiness = nil
        streamResult = .ready
        let coordinator = makeCoordinator()
        await started(coordinator)
        XCTAssertEqual(streamClaims, 1)
        advance(10)
        await coordinator.stop()
        XCTAssertEqual(streamReleases, 1)
    }

    // MARK: - Refusals: nothing is recorded, and it says why

    private func assertNothingWasRecorded(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(recorder.started.isEmpty, "something was recorded", file: file, line: line)
        XCTAssertNil(capture.journal(sessionID: sessionID), file: file, line: line)
        XCTAssertTrue(bundles.records().isEmpty, file: file, line: line)
        XCTAssertFalse(kinds().contains(.recordingStarted), file: file, line: line)
    }

    func testWithNoOfficeBindingNothingIsRecorded() async {
        binding = nil
        let coordinator = makeCoordinator()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.verdict, .notOffered, "the option is not shown at all")
        await assertRefused(coordinator, .notOffered)
        assertNothingWasRecorded()
    }

    func testInABuildWithoutTheOfficeTransportOrWithoutFieldAssistNothingIsRecorded() async {
        rules.officeTransportInBuild = false
        await assertRefused(makeCoordinator(), .notOffered)
        rules.officeTransportInBuild = true
        rules.fieldAssistEntitled = false
        await assertRefused(makeCoordinator(), .notOffered)
        assertNothingWasRecorded()
    }

    func testWhereTheOrganisationForbidsItNothingIsRecorded() async {
        rules.organizationForbidsRecording = true
        await assertRefused(makeCoordinator(), .unavailable(.forbiddenByOrganization))
        assertNothingWasRecorded()
    }

    /// In an app with no blur pass, where blur is required a job is not recorded at all — never
    /// recorded and sent unblurred, never recorded and held.
    func testWhereBlurIsRequiredAndTheAppCannotBlurNothingIsRecordedAndItSaysWhy() async {
        rules.organizationRequiresBlur = true
        let coordinator = makeCoordinator()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.verdict, .unavailable(.blurRequiredButNotPossible))
        let refused = await refusal(coordinator)
        XCTAssertEqual(refused, .unavailable(.blurRequiredButNotPossible))
        XCTAssertTrue(refused?.explanation.contains("blurred") == true)
        assertNothingWasRecorded()
    }

    func testInMedicalComplianceModeNothingIsRecorded() async {
        rules.medicalComplianceMode = true
        await assertRefused(makeCoordinator(), .unavailable(.medicalComplianceMode))
        rules.medicalComplianceMode = false
        rules.officeRouteRefused = true
        await assertRefused(makeCoordinator(), .unavailable(.officeRouteRefused))
        assertNothingWasRecorded()
    }

    func testWithNoJobOpenNothingIsRecorded() async {
        job = nil
        await assertRefused(makeCoordinator(), .unavailable(.noOpenJob))
        assertNothingWasRecorded()
    }

    func testConsentIsRequired() async {
        consent = nil
        let coordinator = makeCoordinator()
        let stands = await coordinator.consentStands()
        XCTAssertFalse(stands)
        await assertRefused(coordinator, .consentRequired)
        assertNothingWasRecorded()
        XCTAssertEqual(streamClaims, 0, "the camera is not touched before consent")
    }

    func testConsentGivenForAnotherOrganisationOrOtherWordsDoesNotStand() async {
        consent = .init(at: wall.addingTimeInterval(-60), organizationID: "another-organisation")
        await assertRefused(makeCoordinator(), .consentRequired)
        consent = .init(at: wall.addingTimeInterval(-60), wordingVersion: RecordingConsent.wordingVersion - 1,
                        organizationID: Self.office.organizationID)
        await assertRefused(makeCoordinator(), .consentRequired)
        assertNothingWasRecorded()
    }

    func testACameraThatWillNotStartRefusesRatherThanRecordingNothing() async {
        readiness = nil
        streamResult = .claimFailed
        await assertRefused(makeCoordinator(), .cameraNotReady("The glasses camera couldn't be started"))
        streamResult = .timedOut("The camera is still starting")
        let refused = await refusal(makeCoordinator())
        XCTAssertEqual(refused, .cameraNotReady("The camera is still starting"))
        XCTAssertEqual(streamReleases, 1, "a claim that never produced pictures is given back")
        assertNothingWasRecorded()
    }

    func testARecorderThatCannotStartRefusesAndLeavesNothingBehind() async {
        recorder.failNextStart = .notEnoughStorage
        let coordinator = makeCoordinator()
        await assertRefused(coordinator, .notEnoughStorage)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
        assertNothingWasRecorded()
    }

    func testOnlyOneRecordingRunsAtATime() async {
        let coordinator = makeCoordinator()
        await started(coordinator)
        await assertRefused(coordinator, .alreadyRecording)
        XCTAssertEqual(recorder.started.count, 1)
    }

    // MARK: - The limits

    /// At the limit on unsent recordings a new one is refused, with what to do about it. What is
    /// waiting counts whether it has been sealed or not.
    func testAtTheLimitOnUnsentRecordingsANewOneIsRefused() async throws {
        limits.unsyncedBytes = 4_000
        // Another job's recording, stopped and not yet sealed.
        let other = "another-job"
        try capture.prepare(sessionID: other)
        try Data(repeating: 1, count: 4_096).write(to: capture.partFile(sessionID: other, partID: "part-1"))
        var journal = JobRecordingCaptureStore.Journal(sessionID: other, jobNumber: nil, wallStart: wall, consentAt: wall)
        journal.stoppedAt = .zero
        try capture.save(journal)

        let refused = await refusal(makeCoordinator())
        XCTAssertEqual(refused, .unavailable(.unsyncedLimitReached))
        XCTAssertEqual(refused?.explanation, RetentionDecision.unsyncedLimitNote)
        XCTAssertTrue(recorder.started.isEmpty)
    }

    /// At the limit for one job the recording stops, is saved, and says so.
    func testAtTheSessionLimitTheRecordingStopsIsSavedAndSaysSo() async throws {
        limits.sessionBytes = 3_000
        recorder.bytesPerPart = 4_096
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.tick()

        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertTrue(coordinator.lastNote?.hasPrefix(RetentionDecision.stoppedAtLimitNote) == true)
        let record = try XCTUnwrap(bundles.records().first, "what was recorded is saved, not lost")
        XCTAssertEqual(record.mediaBytes, 4_096)
        let stopped = try XCTUnwrap(logged.first { $0.kind == .recordingStopped })
        XCTAssertEqual(stopped.payload["reason"]?.value as? String, "size_limit")
    }

    func testUnderTheSessionLimitATickChangesNothing() async {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.tick()
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        XCTAssertEqual(coordinator.elapsed, 30, accuracy: 0.001)
        XCTAssertEqual(coordinator.recordedBytes, 2_048)
    }

    // MARK: - Parts and gaps

    func testAStallStartsANewPartAndTheGapIsWrittenDown() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(60)
        recorder.stall()
        await settle { coordinator.status == .waitingForVideo(sessionID: self.sessionID) }
        XCTAssertEqual(coordinator.status, .waitingForVideo(sessionID: sessionID))
        XCTAssertEqual(recorder.started.count, 1, "nothing is recorded while there are no pictures")

        advance(6.5)
        await coordinator.videoReturned()
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        XCTAssertEqual(recorder.started.count, 2)
        XCTAssertEqual(recorder.started[1].file.lastPathComponent, "part-2.mp4")

        advance(40)
        let outcome = await coordinator.stop()
        guard case .sealed = outcome else { return XCTFail("not sealed: \(String(describing: outcome))") }

        let timeline = try timeline(try XCTUnwrap(bundles.records().first))
        let video = try XCTUnwrap(timeline.tracks.first { $0.track == .video })
        XCTAssertEqual(video.parts, [.init(partID: "part-1", tZero: t(0), duration: t(60)),
                                     .init(partID: "part-2", tZero: t(66.5), duration: t(40))])
        XCTAssertTrue(timeline.gaps.contains(.init(track: .video, from: t(60), to: t(66.5), reason: .stall)))
        let audio = try XCTUnwrap(timeline.tracks.first { $0.track == .audio })
        XCTAssertEqual(audio.parts.map(\.tZero), [t(0.2), t(66.7)], "each track from its own first sample")
    }

    func testTheNextPictureAfterAStallBeginsTheNewPartByItself() async {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        recorder.stall()
        await settle { coordinator.status == .waitingForVideo(sessionID: self.sessionID) }
        advance(3)
        rawFrames.send(UIImage())
        await settle { coordinator.status == .recording(sessionID: self.sessionID) }
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        XCTAssertEqual(recorder.started.count, 2)
    }

    /// The glasses come back and the next part cannot begin — the phone has filled up. The
    /// recording is finished with what it has rather than left waiting.
    func testARecordingThatCannotCarryOnAfterAStallIsSealedWithWhatItHas() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(40)
        recorder.stall()
        await settle { coordinator.status == .waitingForVideo(sessionID: self.sessionID) }
        recorder.failNextStart = .notEnoughStorage
        advance(5)
        await coordinator.videoReturned()

        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(try timeline(try XCTUnwrap(bundles.records().first)).tracks.first?.parts.map(\.partID), ["part-1"])
        XCTAssertEqual(logged.first { $0.kind == .recordingStopped }?.payload["reason"]?.value as? String,
                       "could_not_carry_on")
        XCTAssertEqual(coordinator.lastNoteSessionID, sessionID)
    }

    /// Pausing and stopping at once must not lose the part the pause is still finishing.
    func testStoppingWhileAPauseIsStillFinishingKeepsThePart() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        async let paused: Void = coordinator.pause()
        async let stopped = coordinator.stop()
        _ = await (paused, stopped)

        XCTAssertEqual(coordinator.status, .idle)
        let record = try XCTUnwrap(bundles.records().first, "the part was sealed, not dropped")
        XCTAssertEqual(try timeline(record).tracks.first?.parts.map(\.partID), ["part-1"])
        XCTAssertEqual(recorder.finished, 1, "the recorder is asked to finish the part once")
    }

    func testAPauseEndsThePartAndCarryingOnStartsANewOne() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        XCTAssertEqual(coordinator.status, .paused(sessionID: sessionID))
        advance(70)
        let carriedOn = await coordinator.resume()
        XCTAssertNil(carriedOn)
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        advance(30)
        await coordinator.stop()

        let timeline = try timeline(try XCTUnwrap(bundles.records().first))
        XCTAssertEqual(timeline.tracks.first?.parts.map(\.partID), ["part-1", "part-2"])
        XCTAssertEqual(timeline.gaps.map(\.reason), [.pause, .pause], "the pictures' gap and the sound's")
        XCTAssertEqual(timeline.gaps.first, .init(track: .video, from: t(30), to: t(100), reason: .pause))
    }

    func testStoppingWhilePausedSealsWhatWasRecorded() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        advance(10)
        let outcome = await coordinator.stop()
        guard case .sealed = outcome else { return XCTFail("not sealed") }
        XCTAssertEqual(try timeline(try XCTUnwrap(bundles.records().first)).gaps, [])
    }

    // MARK: - The timeline

    func testWhatIsNotedAndWhatTheJobLogWroteDownLandOnTheTimeline() async throws {
        let coordinator = makeCoordinator()
        let startedAt = wall
        await started(coordinator)
        advance(99.5)
        coordinator.note(.turnStarted)
        advance(4.5)
        coordinator.note(.toolCall, ref: "manual_lookup")
        advance(4)
        coordinator.note(.assistantSpeakingBegan)
        coordinator.note(.captureSilenced)
        advance(3)
        coordinator.note(.assistantSpeakingEnded)
        coordinator.note(.capturePassed)
        advance(39)
        XCTAssertTrue(coordinator.mark())
        advance(50)

        words = [.init(start: t(99.8), end: t(102.8), text: "What's the torque for the flange bolts?")]
        logEntries = [
            .init(at: startedAt.addingTimeInterval(107),
                  kind: .technicianTurn(ref: "turn-1", text: "what is the torque for the flange bolts")),
            .init(at: startedAt.addingTimeInterval(108), kind: .assistantTurn(ref: "assistant:turn-1", text: "Twenty-five.")),
            .init(at: startedAt.addingTimeInterval(140), kind: .photo(ref: "photo-1.jpg")),
            .init(at: startedAt.addingTimeInterval(-30), kind: .photo(ref: "before-the-recording.jpg")),
        ]
        await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        let timeline = try timeline(record)
        XCTAssertEqual(timeline.wallStart, 1_800_000_000_000)
        XCTAssertEqual(timeline.events.map(\.kind), [
            .turnStarted, .turnLogged, .toolCall, .assistantSpeakingBegan, .captureSilenced, .turnLogged,
            .assistantSpeakingEnded, .capturePassed, .photo, .userMarker,
        ])
        XCTAssertEqual(timeline.events.first { $0.kind == .toolCall }?.ref, "manual_lookup")
        let turn = try XCTUnwrap(timeline.events.first { $0.kind == .turnLogged })
        XCTAssertEqual(turn.t, t(100), "moved from its log stamp to where its words begin in the sound")
        XCTAssertEqual(turn.precision, .aligned)
        XCTAssertEqual(timeline.events.first { $0.kind == .userMarker }?.t, t(150))
        XCTAssertEqual(timeline.candidates.map(\.reason), [ProcedureCandidateDetector.Reason.userMarker])

        let transcript = try TimedTranscript.decode(Data(contentsOf: bundles.transcriptFile(record)))
        XCTAssertEqual(transcript.utterances.map(\.id), ["u1"])
        XCTAssertEqual(transcript.utterances.first?.start, t(100), "placed by the sound's own first sample")
    }

    func testNothingIsNotedWhenNoRecordingIsRunning() {
        let coordinator = makeCoordinator()
        coordinator.note(.turnStarted)
        XCTAssertFalse(coordinator.mark())
        XCTAssertNil(capture.journal(sessionID: sessionID))
    }

    // MARK: - Stopping and sealing

    func testStoppingSealsTheBundleAndRemovesTheRecordedParts() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(45)
        let outcome = await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(outcome, .sealed(bundleID: record.bundleID))
        XCTAssertEqual(record.sessionID, sessionID)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(sealedCalls, 1)
        XCTAssertEqual(signed, 1)
        XCTAssertEqual(recorder.finished, 1)

        // The manifest says what was recorded, under which consent, and that nothing was blurred.
        let manifest = try XCTUnwrap(BundleManifest(payload: bundles.manifest(record).payload))
        XCTAssertEqual(manifest.jobSessionID, sessionID)
        XCTAssertEqual(manifest.jobNumber, "JOB-1042")
        XCTAssertEqual(manifest.binding, Self.office)
        XCTAssertFalse(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 0)
        XCTAssertEqual(manifest.consentAt, Int64(try XCTUnwrap(consent).at.timeIntervalSince1970))
        XCTAssertEqual(manifest.parts.map(\.partID), ["part-1"])
        XCTAssertEqual(manifest.parts.first?.track, "video")
        XCTAssertEqual(manifest.parts.first?.container, "mp4")

        // The recorder's part is gone: the chunks are the recording from here on.
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
        XCTAssertEqual(capture.totalBytes(), 0)
        XCTAssertEqual(kinds(), [.recordingStarted, .recordingStopped, .recordingBundleSealed])
    }

    func testAJobHasOneRecording() async {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(10)
        await coordinator.stop()
        await assertRefused(coordinator, .unavailable(.alreadyRecorded))
        XCTAssertEqual(bundles.records().count, 1, "the first recording is not replaced")
    }

    func testARecordingThatRecordedNothingLeavesNothingBehind() async {
        recorder.records = false
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(5)
        let outcome = await coordinator.stop()
        XCTAssertEqual(outcome, .nothingRecorded)
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
        XCTAssertEqual(signed, 0)
        XCTAssertTrue(coordinator.lastNote?.contains("Nothing was recorded") == true)
    }

    func testAPartWithNoSoundIsSealedAsPicturesOnly() async throws {
        recorder.soundless = true
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        await coordinator.stop()
        let timeline = try timeline(try XCTUnwrap(bundles.records().first))
        XCTAssertEqual(timeline.tracks.map(\.track), [.video])
    }

    func testAJobNumberTheManifestCannotSpellIsLeftOutRatherThanAltered() async throws {
        job = .init(sessionID: sessionID, jobNumber: "Wāhi \"7\"")
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(10)
        let outcome = await coordinator.stop()
        guard case .sealed = outcome else { return XCTFail("a job number must not stop a recording being sealed") }
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(try XCTUnwrap(BundleManifest(payload: bundles.manifest(record).payload)).jobNumber, "")
    }

    /// Nothing is sealed, and nothing signed, on a pairing that does not verify at that moment.
    /// The recording stays on the phone and is sealed when it can be.
    func testWithThePairingGoneAtStopTheRecordingIsKeptAndSealedLater() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        binding = nil
        let outcome = await coordinator.stop()

        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertEqual(signed, 0)
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(capture.journal(sessionID: sessionID)?.isStopped, true)
        XCTAssertEqual(capture.bytes(sessionID: sessionID), 2_048, "the recorded part is still there")
        XCTAssertEqual(coordinator.unsealed, .waitingToPrepare)
        XCTAssertTrue(coordinator.hasUnsealedRecording(sessionID: sessionID))

        await coordinator.sealPending()
        XCTAssertTrue(bundles.records().isEmpty, "still no pairing, still nothing sealed")

        binding = Self.office
        await coordinator.sealPending()
        XCTAssertEqual(bundles.records().count, 1)
        XCTAssertNil(capture.journal(sessionID: sessionID))
        XCTAssertNil(coordinator.unsealed)
        XCTAssertFalse(coordinator.hasUnsealedRecording(sessionID: sessionID))
    }

    /// Sealing transcribes the whole recording and can take minutes. It must never hold up
    /// stopping — or starting — another recording meanwhile.
    func testSealingOneRecordingDoesNotHoldUpAnother() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        holdTranscription = true
        let stopping = Task { await coordinator.stop() }
        await settle { !self.transcriptionWaiters.isEmpty }
        XCTAssertEqual(coordinator.status, .idle, "the capture has ended; only the sealing is still going")
        XCTAssertEqual(coordinator.preparing, [sessionID])
        XCTAssertEqual(recorder.finished, 1)
        await assertRefused(coordinator, .unavailable(.alreadyRecorded))

        // Another job is opened, recorded and stopped while the first is still being prepared.
        let second = "second-job"
        job = .init(sessionID: second, jobNumber: nil)
        holdTranscription = false
        await started(coordinator)
        XCTAssertEqual(coordinator.status, .recording(sessionID: second))
        advance(10)
        let outcome = await coordinator.stop()
        guard case .sealed = outcome else { return XCTFail("the second recording was held up") }
        XCTAssertEqual(bundles.records().map(\.sessionID), [second])

        transcriptionWaiters.forEach { $0.resume() }
        transcriptionWaiters = []
        _ = await stopping.value
        XCTAssertEqual(Set(bundles.records().map(\.sessionID)), [sessionID, second])
        XCTAssertTrue(coordinator.preparing.isEmpty)
    }

    /// A recording that could not be sealed — the phone is full — is kept and tried again later,
    /// not on every pass: each try transcribes it from the start.
    func testARecordingThatCouldNotBeSealedIsKeptAndTriedAgainLater() async throws {
        signFailuresLeft = 1
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        let outcome = await coordinator.stop()
        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertEqual(signed, 1)
        XCTAssertEqual(capture.bytes(sessionID: sessionID), 2_048, "the recorded part is still there")
        XCTAssertTrue(bundles.records().isEmpty, "half a bundle is no bundle")

        await coordinator.sealPending()
        XCTAssertEqual(signed, 1, "not tried again on the very next pass")

        advance(Coordinator.sealRetryInterval + 1)
        await coordinator.sealPending()
        XCTAssertEqual(signed, 2)
        XCTAssertEqual(bundles.records().count, 1)
        XCTAssertNil(capture.journal(sessionID: sessionID))
    }

    // MARK: - While it runs

    func testTheJobClosingStopsAndSealsTheRecording() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(25)
        job = nil
        await coordinator.tick()
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(bundles.records().count, 1)
        XCTAssertEqual(logged.first { $0.kind == .recordingStopped }?.payload["reason"]?.value as? String, "job_closed")
    }

    func testARuleComingIntoForceStopsARunningRecording() async {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(25)
        rules.medicalComplianceMode = true
        await coordinator.tick()
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(logged.first { $0.kind == .recordingStopped }?.payload["reason"]?.value as? String, "not_allowed")
        XCTAssertTrue(coordinator.lastNote?.contains("Medical Compliance") == true)
        XCTAssertEqual(recorder.started.count, 1)
    }

    // MARK: - The app closed in the middle of it

    func testARecordingTheAppWasClosedInCanBeCarriedOnAfterARestartGap() async throws {
        let first = makeCoordinator()
        await started(first)
        advance(30)
        await first.pause()          // part-1 finished and written down
        advance(5)
        await first.resume()         // part-2 being written when the app goes away
        advance(10)

        // A new launch: a new coordinator, a new recorder, and a monotonic clock that started again.
        advance(600)
        monotonic = 40
        recorder = FakeRecorder { [unowned self] in self.monotonic }
        let second = makeCoordinator()
        await second.refresh()
        XCTAssertEqual(second.unsealed, .interrupted)
        XCTAssertEqual(second.verdict, .available, "it can be carried on")

        await started(second)
        XCTAssertEqual(recorder.started.first?.file.lastPathComponent, "part-3.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.partFile(sessionID: sessionID, partID: "part-2").path),
                       "the part that never finished does not play, and is not kept")
        XCTAssertEqual(logged.last?.payload["carried_on"]?.value as? Bool, true)
        advance(20)
        await second.stop()

        let timeline = try timeline(try XCTUnwrap(bundles.records().first))
        XCTAssertEqual(timeline.wallStart, 1_800_000_000_000, "the same session, the same zero")
        XCTAssertEqual(timeline.tracks.first?.parts, [.init(partID: "part-1", tZero: t(0), duration: t(30)),
                                                      .init(partID: "part-3", tZero: t(645), duration: t(20))])
        XCTAssertEqual(timeline.gaps.first, .init(track: .video, from: t(30), to: t(645), reason: .pause),
                       "the part before the gap had ended on a pause")
    }

    func testARecordingInterruptedMidPartIsCarriedOnAfterARestart() async throws {
        let first = makeCoordinator()
        await started(first)
        advance(30)
        recorder.stall()
        await settle { first.status == .waitingForVideo(sessionID: self.sessionID) }
        // The app goes away while it waits for the glasses. Part 1 ended on a stall.
        var journal = try XCTUnwrap(capture.journal(sessionID: sessionID))
        journal.parts[0].endedBy = nil   // as if it had ended with the app
        try capture.save(journal)

        advance(100)
        recorder = FakeRecorder { [unowned self] in self.monotonic }
        let second = makeCoordinator()
        await started(second)
        advance(10)
        await second.stop()
        let timeline = try timeline(try XCTUnwrap(bundles.records().first))
        XCTAssertEqual(timeline.gaps.first?.reason, .restart)
    }

    func testAnInterruptedRecordingWhoseJobHasClosedIsSealedFromWhatItHad() async throws {
        let first = makeCoordinator()
        await started(first)
        advance(30)
        await first.pause()
        advance(5)
        await first.resume()

        recorder = FakeRecorder { [unowned self] in self.monotonic }
        let second = makeCoordinator()
        await second.sealPending()
        XCTAssertTrue(bundles.records().isEmpty, "the job is still open: it is left to be carried on")

        job = nil
        await second.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(try timeline(record).tracks.first?.parts.map(\.partID), ["part-1"])
        XCTAssertEqual(logged.last { $0.kind == .recordingStopped }?.payload["reason"]?.value as? String, "interrupted")
        XCTAssertNil(capture.journal(sessionID: sessionID))
    }

    func testAnInterruptedRecordingCanBeFinishedAsItIs() async throws {
        let first = makeCoordinator()
        await started(first)
        advance(30)
        await first.pause()

        recorder = FakeRecorder { [unowned self] in self.monotonic }
        let second = makeCoordinator()
        let outcome = await second.finishInterrupted()
        guard case .sealed = outcome else { return XCTFail("not sealed: \(String(describing: outcome))") }
        XCTAssertTrue(recorder.started.isEmpty, "finishing records nothing more")
        await assertRefused(second, .unavailable(.alreadyRecorded))
    }

    /// A journal that is on disk and cannot be read — a locked phone, a damaged file — is still a
    /// recording. Starting over it would write a new journal across it and lose what it holds.
    func testAJournalThatCannotBeReadIsNotStartedOver() async throws {
        try capture.prepare(sessionID: sessionID)
        let journal = capture.directory(sessionID: sessionID).appendingPathComponent("journal.json")
        try Data("not a journal".utf8).write(to: journal)
        try Data(repeating: 9, count: 512).write(to: capture.partFile(sessionID: sessionID, partID: "part-1"))

        await assertRefused(makeCoordinator(), .unavailable(.alreadyRecorded))
        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertEqual(try Data(contentsOf: journal), Data("not a journal".utf8), "left exactly as it was")
        XCTAssertEqual(capture.bytes(sessionID: sessionID), 512)
    }

    // MARK: - Deleting a recording that is not sealed

    /// The folder a job's recording is in, sealed or not.
    private var recordingFolder: URL { capture.directory(sessionID: sessionID).deletingLastPathComponent() }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Something else of the job's beside its recording: its log and a photograph.
    private func otherFilesOfTheJob() throws -> [URL] {
        let folder = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        let photos = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("events.jsonl")
        let photo = photos.appendingPathComponent("photo-1.jpg")
        try Data("the job's own log".utf8).write(to: log)
        try Data(repeating: 3, count: 64).write(to: photo)
        return [log, photo]
    }

    /// Nothing of the recording is on the phone: no part, no journal, no bundle, no signature,
    /// and the coordinator holds nothing about it.
    private func assertNothingIsLeft(_ coordinator: Coordinator, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(exists(recordingFolder), "the recording's folder is still there: \(captureFiles())", file: file, line: line)
        XCTAssertTrue(bundles.records().isEmpty, "a bundle was sealed from a deleted recording", file: file, line: line)
        XCTAssertFalse(kinds().contains(.recordingBundleSealed), file: file, line: line)
        XCTAssertEqual(sealedCalls, 0, "the sender was told of a bundle", file: file, line: line)
        XCTAssertTrue(coordinator.preparing.isEmpty, file: file, line: line)
        XCTAssertTrue(coordinator.deferredForBlur.isEmpty, file: file, line: line)
        XCTAssertTrue(coordinator.blurProgress.isEmpty, file: file, line: line)
        XCTAssertTrue(coordinator.unsealedRecordings().isEmpty, file: file, line: line)
        XCTAssertFalse(coordinator.hasUnsealedRecording(sessionID: sessionID), file: file, line: line)
        XCTAssertNil(coordinator.askToDeleteUnsealed(sessionID: sessionID), file: file, line: line)
    }

    func testDeletingAnUnsealedRecordingAsksFirstAndTakesTheRecordingAndNothingElseOfTheJob() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        XCTAssertNil(coordinator.askToDeleteUnsealed(sessionID: sessionID),
                     "a recording that is running is stopped first, not deleted from under the recorder")
        binding = nil
        let outcome = await coordinator.stop()
        XCTAssertEqual(outcome, .waitingToPrepare)
        let kept = try otherFilesOfTheJob()
        XCTAssertEqual(coordinator.unsealedRecordings().map(\.sessionID), [sessionID])
        XCTAssertEqual(coordinator.unsealedRecordings().first?.waiting, .toBePrepared)

        // It asks first, in the words used for any recording the office has not got.
        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        XCTAssertEqual(asked.sessionID, sessionID)
        XCTAssertEqual(asked.warning, RetentionDecision.unacknowledgedRecordingDeletionWarning)
        XCTAssertEqual(asked.warning, "The office hasn't received this recording yet. Deleting it removes the only copy.")
        XCTAssertNil(coordinator.askToDeleteUnsealed(sessionID: "another-job"), "a job with no recording has no question")
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"], "asking removes nothing")
        XCTAssertFalse(kinds().contains(.recordingDeleted))

        binding = Self.office
        let deleted = await coordinator.deleteUnsealed(asked)
        XCTAssertTrue(deleted)
        assertNothingIsLeft(coordinator)
        XCTAssertEqual(signed, 0)
        for file in kept { XCTAssertTrue(exists(file), "\(file.lastPathComponent) is the job's, not the recording's") }
        XCTAssertNil(coordinator.unsealed)
        XCTAssertEqual(coordinator.lastNote, "The recording was deleted from this phone.")
        XCTAssertEqual(coordinator.lastNoteSessionID, sessionID)
        XCTAssertEqual(coordinator.verdict, .available, "the job can be recorded again")

        // Written down as counts, and nothing else.
        XCTAssertEqual(kinds(), [.recordingStarted, .recordingStopped, .recordingDeleted])
        let line = try XCTUnwrap(logged.last)
        XCTAssertEqual(line.sessionID, sessionID)
        XCTAssertEqual(line.payload["sealed"]?.value as? Bool, false)
        XCTAssertEqual(line.payload["acknowledged"]?.value as? Bool, false)
        XCTAssertEqual(line.payload["parts"]?.value as? Int, 1)
        XCTAssertEqual(line.payload["bytes"]?.value as? Int, 2_048)
        XCTAssertEqual(line.payload.count, 4)

        // Nothing comes back on a later pass, and the same answer deletes nothing twice.
        await coordinator.sealPending()
        let again = await coordinator.deleteUnsealed(asked)
        XCTAssertFalse(again)
        assertNothingIsLeft(coordinator)
        XCTAssertEqual(kinds().filter { $0 == .recordingDeleted }.count, 1)
        XCTAssertTrue(withdrawn.isEmpty, "nothing was sealed, so nothing is taken back from the office")
    }

    /// A sealed bundle beside it is another thing, with its own delete, and is not touched.
    func testDeletingTheUnsealedPartsLeavesASealedBundleAlone() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        await coordinator.stop()
        let record = try XCTUnwrap(bundles.records().first)
        // As if the app had gone away between sealing and clearing up: parts and a journal again.
        try capture.prepare(sessionID: sessionID)
        try capture.save(.init(sessionID: sessionID, jobNumber: nil, wallStart: wall, consentAt: wall,
                               stoppedAt: t(20)))
        try Data(repeating: 9, count: 512).write(to: capture.directory(sessionID: sessionID).appendingPathComponent("part-1.mp4"))

        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        let deleted = await coordinator.deleteUnsealed(asked)
        XCTAssertTrue(deleted)
        XCTAssertFalse(exists(capture.directory(sessionID: sessionID)))
        XCTAssertEqual(bundles.records(), [record], "the sealed recording is still whole")
        XCTAssertNoThrow(try bundles.manifest(record))
    }

    func testARecordingTheAppWasClosedInCanBeDeletedAndTheJobRecordedAgain() async throws {
        let first = makeCoordinator()
        await started(first)
        advance(30)
        await first.pause()
        advance(5)
        await first.resume()         // part-2 being written when the app goes away

        recorder = FakeRecorder { [unowned self] in self.monotonic }
        let second = makeCoordinator()
        await second.refresh()
        XCTAssertEqual(second.unsealed, .interrupted)
        XCTAssertEqual(second.unsealedRecordings().first?.waiting, .interrupted)

        let asked = try XCTUnwrap(second.askToDeleteUnsealed(sessionID: sessionID))
        let deleted = await second.deleteUnsealed(asked)
        XCTAssertTrue(deleted)
        assertNothingIsLeft(second)
        XCTAssertNil(second.unsealed)
        XCTAssertFalse(kinds().contains(.recordingStopped), "it was deleted, not finished")

        await started(second)
        XCTAssertEqual(recorder.started.first?.file.lastPathComponent, "part-1.mp4", "a new recording, from its first part")
        XCTAssertEqual(logged.last?.payload["carried_on"]?.value as? Bool, false)
    }

    /// A journal that cannot be read is still a recording, and can still be deleted.
    func testARecordingWhoseJournalCannotBeReadCanBeDeleted() async throws {
        try capture.prepare(sessionID: sessionID)
        try Data("not a journal".utf8).write(to: capture.directory(sessionID: sessionID).appendingPathComponent("journal.json"))
        try Data(repeating: 9, count: 512).write(to: capture.directory(sessionID: sessionID).appendingPathComponent("part-1.mp4"))
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.unsealedRecordings().first?.waiting, .toBePrepared)

        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        let deleted = await coordinator.deleteUnsealed(asked)
        XCTAssertTrue(deleted)
        assertNothingIsLeft(coordinator)
        XCTAssertEqual(logged.last?.payload["bytes"]?.value as? Int, 512)
    }

    /// Deleted while its faces are being blurred. The pass is stopped, and whatever it says and
    /// whatever it had written, nothing is kept and nothing is sealed.
    func testDeletingWhileFacesAreBeingBlurredStopsThePassAndLeavesNothingBehind() async throws {
        for answer: Result<BlurredPart.Report, JobPartBlur.Failure> in [.failure(.interrupted), .success(FakeBlur.whole)] {
            try? FileManager.default.removeItem(at: sessionsRoot)
            logged = []
            recorder = FakeRecorder { [unowned self] in self.monotonic }
            let blur = requireBlur()
            blur.runsUntilCancelled = true
            // A real pass says it was interrupted and removes what it wrote. The other answer is
            // a pass that claims a whole blurred part after it was stopped: it is not believed.
            blur.results["part-1"] = answer
            let coordinator = makeCoordinator()
            await started(coordinator)
            advance(20)
            let stopping = Task { await coordinator.stop() }
            await wait { blur.running == 1 }
            XCTAssertEqual(coordinator.preparing, [sessionID])
            XCTAssertEqual(coordinator.unsealedRecordings().first?.waiting, .beingPrepared)
            XCTAssertEqual(blur.awake, [true], "the phone is being kept awake for the pass")

            let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
            let deleted = await coordinator.deleteUnsealed(asked)
            XCTAssertTrue(deleted)
            let outcome = await stopping.value
            XCTAssertEqual(outcome, .deleted)

            assertNothingIsLeft(coordinator)
            XCTAssertEqual(blur.running, 0, "the pass was stopped, not left running")
            XCTAssertEqual(blur.asked.count, 1)
            XCTAssertEqual(blur.awake, [true, false], "and the phone is let lock itself again")
            XCTAssertEqual(signed, 0)
            XCTAssertEqual(kinds(), [.recordingStarted, .recordingStopped, .recordingDeleted])
            XCTAssertEqual(coordinator.lastNote, "The recording was deleted from this phone.")

            // The next pass has nothing to find, and the job can be recorded again.
            blur.runsUntilCancelled = false
            await coordinator.sealPending()
            assertNothingIsLeft(coordinator)
            XCTAssertEqual(blur.asked.count, 1)
            XCTAssertEqual(coordinator.verdict, .available)
        }
    }

    /// Deleted while its words are being read. Nothing is signed, and nothing is sealed.
    func testDeletingWhileTheWordsAreBeingReadLeavesNothingBehind() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        holdTranscription = true
        let stopping = Task { await coordinator.stop() }
        await settle { !self.transcriptionWaiters.isEmpty }

        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        let deleting = Task { await coordinator.deleteUnsealed(asked) }
        // The delete waits for the pass; until the pass has stopped, the parts are not pulled out
        // from under it.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"])
        holdTranscription = false
        transcriptionWaiters.forEach { $0.resume() }
        transcriptionWaiters = []

        let deleted = await deleting.value
        let outcome = await stopping.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(signed, 0, "nothing is signed for a recording that has been deleted")
        assertNothingIsLeft(coordinator)
        XCTAssertTrue(withdrawn.isEmpty)
    }

    /// Deleted in the moment the manifest is being signed: the seal finishes, and what it sealed
    /// is removed and taken back out of the office's folder before anything is told of it.
    func testDeletingAtTheMomentOfSigningRemovesWhatWasSealed() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        holdSigning = true
        let stopping = Task { await coordinator.stop() }
        await wait { !self.signingWaiters.isEmpty }

        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        let deleting = Task { await coordinator.deleteUnsealed(asked) }
        for _ in 0..<50 { await Task.yield() }
        holdSigning = false
        signingWaiters.forEach { $0.resume() }
        signingWaiters = []

        let deleted = await deleting.value
        let outcome = await stopping.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(signed, 1, "the signer had already been asked")
        XCTAssertEqual(withdrawn, [sessionID], "what was sealed is taken back out of the office's folder")
        assertNothingIsLeft(coordinator)
        XCTAssertEqual(kinds(), [.recordingStarted, .recordingStopped, .recordingDeleted])
    }

    /// The same for a recording a later pass is preparing, rather than the stop itself.
    func testDeletingWhileALaterPassPreparesItLeavesNothingBehind() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        binding = nil
        await coordinator.stop()
        binding = Self.office
        holdTranscription = true
        let preparing = Task { await coordinator.sealPending() }
        await settle { !self.transcriptionWaiters.isEmpty }
        let asked = try XCTUnwrap(coordinator.askToDeleteUnsealed(sessionID: sessionID))
        let deleting = Task { await coordinator.deleteUnsealed(asked) }
        for _ in 0..<50 { await Task.yield() }
        holdTranscription = false
        transcriptionWaiters.forEach { $0.resume() }
        transcriptionWaiters = []
        let deleted = await deleting.value
        await preparing.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(signed, 0)
        assertNothingIsLeft(coordinator)
    }

    /// What the Jobs list and the job-day card are told of recordings that are not sealed.
    func testEveryUnsealedRecordingIsOwedWithItsOwnReason() async throws {
        let blur = requireBlur()
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.unsealedRecordings().isEmpty)
        await started(coordinator)
        advance(20)
        XCTAssertTrue(coordinator.unsealedRecordings().isEmpty, "a recording that is running is not owed yet")
        XCTAssertTrue(JobRecordingOwed.gather(coordinator: coordinator, sync: nil, label: { _ in "Job 1042" }).isEmpty)

        blur.available = false
        await coordinator.stop()
        XCTAssertEqual(coordinator.unsealedRecordings().first?.waiting, .forTheAppToBeOpen)
        let owed = JobRecordingOwed.gather(coordinator: coordinator, sync: nil, label: { _ in "Job 1042" })
        XCTAssertEqual(owed, [JobDayRecording(sessionId: sessionID, label: "Job 1042", title: "Recording waiting to sync",
                                              reason: "Open Avenkin to prepare the recording.")])

        blur.available = true
        await coordinator.sealPending()
        XCTAssertTrue(coordinator.unsealedRecordings().isEmpty, "sealed: from here it is the sender's to report")
        XCTAssertTrue(JobRecordingOwed.gather(coordinator: coordinator, sync: nil, label: { _ in "Job 1042" }).isEmpty)
    }

    // MARK: - Consent

    func testAcknowledgingConsentIsRecordedOnceAndThenStands() async throws {
        consent = nil
        let coordinator = makeCoordinator()
        let acknowledged = await coordinator.acknowledgeConsent()
        XCTAssertTrue(acknowledged)

        let saved = try XCTUnwrap(consent)
        XCTAssertEqual(saved.at, wall)
        XCTAssertEqual(saved.organizationID, Self.office.organizationID)
        XCTAssertEqual(saved.wordingVersion, RecordingConsent.wordingVersion)
        XCTAssertEqual(auditedConsents, [saved], "handed to the audit log as a consent change")
        XCTAssertEqual(kinds(), [.recordingConsent])
        XCTAssertEqual(logged.first?.payload["wording"]?.value as? Int, RecordingConsent.wordingVersion)
        let stands = await coordinator.consentStands()
        XCTAssertTrue(stands)

        // And the acknowledgement's time is the one the manifest carries.
        advance(120)
        await started(coordinator)
        advance(10)
        await coordinator.stop()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(try XCTUnwrap(BundleManifest(payload: bundles.manifest(record).payload)).consentAt,
                       Int64(saved.at.timeIntervalSince1970))
    }

    func testThereIsNothingToConsentToWithoutAnOffice() async {
        consent = nil
        binding = nil
        let coordinator = makeCoordinator()
        let acknowledged = await coordinator.acknowledgeConsent()
        XCTAssertFalse(acknowledged)
        XCTAssertNil(consent)
        XCTAssertTrue(auditedConsents.isEmpty)
    }

    // MARK: - Audit without content

    /// The job log's lines about a recording carry counts, fixed words and digests — never a word
    /// that was said, a job number or a path.
    func testTheJobLogCarriesCountsAndDigestsOnly() async throws {
        let coordinator = makeCoordinator()
        let startedAt = wall
        await started(coordinator)
        advance(30)
        words = [.init(start: t(1), end: t(3), text: "The customer's alarm code is four two seven one.")]
        logEntries = [.init(at: startedAt.addingTimeInterval(4),
                            kind: .technicianTurn(ref: "turn-1", text: "the customer's alarm code is four two seven one"))]
        await coordinator.stop()

        XCTAssertEqual(kinds(), [.recordingStarted, .recordingStopped, .recordingBundleSealed])
        let record = try XCTUnwrap(bundles.records().first)
        let sealed = try XCTUnwrap(logged.last)
        XCTAssertEqual(sealed.payload["manifest_sha256"]?.value as? String, record.manifestSHA256)
        XCTAssertEqual(sealed.payload["chunks"]?.value as? Int, 1)
        XCTAssertEqual(sealed.payload["utterances"]?.value as? Int, 1)
        XCTAssertEqual(logged[1].payload["parts"]?.value as? Int, 1)
        XCTAssertEqual(logged[1].payload["seconds"]?.value as? Int, 30)

        let allowedWords: Set<String> = ["asked", "size_limit", "job_closed", "not_allowed", "interrupted",
                                         "could_not_carry_on"]
        for line in logged {
            XCTAssertEqual(line.sessionID, sessionID)
            for (key, value) in line.payload {
                switch value.value {
                case is Int, is Bool:
                    continue
                case let text as String:
                    let isDigest = text.count == 64 && text.allSatisfy { $0.isHexDigit }
                    XCTAssertTrue(isDigest || allowedWords.contains(text), "\(line.kind.rawValue).\(key) carries \(text)")
                default:
                    XCTFail("\(line.kind.rawValue).\(key) carries something that is not a count, a word or a digest")
                }
            }
        }
    }

    // MARK: - The job log's lines and the transcriber's windows

    func testTheJobLogsLinesAreReadAsTheTimelineNeedsThem() {
        func event(_ kind: SessionLogger.Event.Kind, _ text: String?, _ payload: [String: AnyCodable]? = nil)
            -> SessionLogger.Event { .init(timestamp: wall, kind: kind, text: text, payload: payload) }
        let entries = JobRecordingLogReader.entries([
            event(.userMessage, " Is it reusable? ", ["source_id": AnyCodable("turn-9")]),
            event(.appInstruction, "Introduce yourself.", ["source_id": AnyCodable("turn-10")]),
            event(.assistantMessage, "Yes.", ["source_id": AnyCodable("assistant:turn-9")]),
            event(.assistantMessage, "   "),
            event(.photoAttached, "the caption", ["path": AnyCodable("2026-10-05_ab12.jpg")]),
            event(.procedureStarted, "No heat", ["procedure_id": AnyCodable("no-heat-check")]),
            event(.procedureStep, "Remove the cover", ["step_id": AnyCodable("remove-cover")]),
            event(.procedureCompleted, "No heat", ["procedure_id": AnyCodable("no-heat-check")]),
            event(.readingRecorded, "42"),
        ])
        XCTAssertEqual(entries.map(\.kind), [
            .technicianTurn(ref: "turn-9", text: "Is it reusable?"),
            .assistantTurn(ref: "assistant:turn-9", text: "Yes."),
            .photo(ref: "2026-10-05_ab12.jpg"),
            .procedureStarted(procedureID: "no-heat-check"),
            .procedureStep(stepID: "remove-cover"),
            .procedureCompleted(procedureID: "no-heat-check"),
        ], "an instruction the app sent is not a turn, and a photograph's caption is not carried")
    }

    func testAWindowOfWordsIsAnUtteranceTheLengthOfTheWindow() {
        XCTAssertEqual(TimedTranscriptSource.utterance(text: " Next, refit the cover. ", offset: 20, duration: 10),
                       .init(start: t(20), end: t(30), text: "Next, refit the cover."))
        XCTAssertNil(TimedTranscriptSource.utterance(text: "  ", offset: 20, duration: 10))
        XCTAssertNil(TimedTranscriptSource.utterance(text: "Hello.", offset: 20, duration: 0))
        XCTAssertEqual(TimedTranscriptSource.windowSeconds, 10)
    }

    // MARK: - The capture store

    func testTheJournalIsKeptAndReadBack() throws {
        try capture.prepare(sessionID: sessionID)
        var journal = JobRecordingCaptureStore.Journal(sessionID: sessionID, jobNumber: "JOB-1042", wallStart: wall,
                                                       consentAt: wall.addingTimeInterval(-60))
        journal.noted = [.init(t: t(1.5), kind: .toolCall, ref: "manual_lookup")]
        journal.partsBegun = 2
        try capture.save(journal)
        XCTAssertEqual(capture.journal(sessionID: sessionID), journal)
        XCTAssertEqual(capture.journals().map(\.sessionID), [sessionID])
        XCTAssertEqual(journal.noted.first?.event, .init(t: t(1.5), kind: .toolCall, ref: "manual_lookup"))

        capture.remove(sessionID: sessionID)
        XCTAssertNil(capture.journal(sessionID: sessionID))
    }

    func testASessionNameThatIsNotAnIdentifierBuildsNoPath() {
        XCTAssertThrowsError(try capture.prepare(sessionID: "../elsewhere"))
        XCTAssertNil(capture.journal(sessionID: "../elsewhere"))
    }
    // MARK: - Blur, where the organisation requires it (Plan HE §1)

    private func manifest(_ record: JobRecordingBundleStore.Record) throws -> BundleManifest {
        try XCTUnwrap(BundleManifest(payload: bundles.manifest(record).payload))
    }

    /// Every byte of media in a sealed bundle, chunk by chunk.
    private func media(_ record: JobRecordingBundleStore.Record) throws -> [Data] {
        try record.chunks.map { try Data(contentsOf: bundles.chunkFile(record, sha256: $0.sha256)) }
    }

    private func captureFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: capture.directory(sessionID: sessionID).path)) ?? [])
            .sorted()
    }

    @discardableResult
    private func requireBlur() -> FakeBlur {
        let blur = FakeBlur()
        self.blur = blur
        rules.organizationRequiresBlur = true
        return blur
    }

    func testWhereBlurIsRequiredAJobCanBeRecordedAndIsSealedBlurred() async throws {
        let blur = requireBlur()
        let coordinator = makeCoordinator()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.verdict, .available, "the rule no longer stands in the way of recording")

        await started(coordinator)
        XCTAssertEqual(capture.journal(sessionID: sessionID)?.blurRequired, true)
        advance(20)
        await coordinator.tick()
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID), "and does not stop one that is running")
        let outcome = await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(outcome, .sealed(bundleID: record.bundleID))
        let manifest = try manifest(record)
        XCTAssertTrue(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 0)
        XCTAssertEqual(manifest.parts.map(\.partID), ["part-1"])
        XCTAssertTrue(bundles.isBlurred(record))

        // What was sealed is what came out of the pass, and nothing else.
        XCTAssertEqual(blur.asked.map(\.part), ["part-1.mp4"])
        XCTAssertEqual(blur.asked.map(\.output), ["part-1.blurring.mp4"])
        let sealed = try media(record)
        XCTAssertEqual(sealed.count, 1)
        XCTAssertTrue(sealed.allSatisfy { $0.starts(with: FakeBlur.prefix) }, "an unblurred part was sealed")
        XCTAssertEqual(sealed.first?.count, FakeBlur.prefix.count + 2_048)

        // No unblurred part is left on the phone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
        XCTAssertEqual(blur.awake, [true, false], "the phone is kept awake for the pass and let go after")
        XCTAssertEqual(coordinator.blurProgress, [:])
        XCTAssertTrue(coordinator.deferredForBlur.isEmpty)
        let sealedLine = try XCTUnwrap(logged.last { $0.kind == .recordingBundleSealed })
        XCTAssertEqual(sealedLine.payload["blurred"]?.value as? Bool, true)
        XCTAssertEqual(sealedLine.payload["dropped_frames"]?.value as? Int, 0)
    }

    func testTheDroppedFramesAreCountedInTheManifestAndWrittenOnTheTimeline() async throws {
        let blur = requireBlur()
        // The second part loses a stretch of pictures three seconds long, and a single frame.
        blur.results["part-2"] = .success(.init(
            framesWritten: 400, framesDropped: 80,
            droppedRuns: [.init(from: 5, to: 8), .init(from: 12, to: 12.04)], keptSound: true))
        blur.results["part-1"] = .success(.init(framesWritten: 475, framesDropped: 5, keptSound: true))
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        advance(10)
        await coordinator.resume()
        advance(20)
        await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        let manifest = try manifest(record)
        XCTAssertTrue(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 85, "every frame dropped, across every part")
        XCTAssertEqual(blur.asked.map(\.part), ["part-1.mp4", "part-2.mp4"])
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })

        let timeline = try timeline(record)
        XCTAssertEqual(timeline.gaps.filter { $0.track == .video }, [
            .init(track: .video, from: t(30), to: t(40), reason: .pause),
            .init(track: .video, from: t(45), to: t(48), reason: .filter),
        ], "the long stretch is a gap where it fell in the session; the single frame is only counted")
        XCTAssertEqual(timeline.tracks.first?.parts.map(\.partID), ["part-1", "part-2"])
        XCTAssertTrue(coordinator.lastNote?.contains("couldn't have faces blurred") == true,
                      "the technician is told some of the video was left out")
        XCTAssertEqual(logged.last { $0.kind == .recordingBundleSealed }?.payload["dropped_frames"]?.value as? Int, 85)
    }

    func testWhereBlurIsNotRequiredNoPassRunsAndNothingChanges() async throws {
        let blur = FakeBlur()
        self.blur = blur
        let coordinator = makeCoordinator()
        await started(coordinator)
        XCTAssertNil(capture.journal(sessionID: sessionID)?.blurRequired)
        advance(20)
        await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        let manifest = try manifest(record)
        XCTAssertFalse(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 0)
        XCTAssertFalse(bundles.isBlurred(record))
        XCTAssertTrue(blur.asked.isEmpty, "a pass ran where none was required")
        XCTAssertTrue(blur.awake.isEmpty)
        XCTAssertEqual(try media(record), [Data(repeating: 1, count: 2_048)], "sealed exactly as it was recorded")
        XCTAssertEqual(logged.last { $0.kind == .recordingBundleSealed }?.payload["blurred"]?.value as? Bool, false)
    }

    /// The blur runs only with the app in front. A recording that stops while it is not waits,
    /// says to open the app, and is prepared the next time a pass finds the blur available.
    func testWithTheBlurUnavailableTheRecordingWaitsAndIsPreparedWhenTheAppIsOpen() async throws {
        let blur = requireBlur()
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        blur.available = false
        let outcome = await coordinator.stop()

        XCTAssertEqual(outcome, .waitingForBlur)
        XCTAssertTrue(bundles.records().isEmpty, "nothing is sealed with an unblurred part in it")
        XCTAssertEqual(signed, 0)
        XCTAssertTrue(blur.asked.isEmpty)
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"], "the recorded part is where it was")
        XCTAssertEqual(coordinator.deferredForBlur, [sessionID])
        XCTAssertEqual(coordinator.preparationPhase(sessionID: sessionID), .waiting(.openAppToPrepare))
        XCTAssertEqual(coordinator.unsealed, .waitingToPrepare)
        XCTAssertTrue(coordinator.lastNote?.contains("Open Avenkin to prepare the recording.") == true,
                      coordinator.lastNote ?? "")

        // Still not in front: asked again, still waiting, and not put off for a quarter of an hour.
        await coordinator.sealPending()
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(coordinator.preparationPhase(sessionID: sessionID), .waiting(.openAppToPrepare))

        blur.available = true
        await coordinator.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertTrue(try manifest(record).blurred)
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })
        XCTAssertTrue(coordinator.deferredForBlur.isEmpty)
        XCTAssertNil(coordinator.preparationPhase(sessionID: sessionID))
        XCTAssertTrue(coordinator.lastNote?.contains("ready to go to the office") == true, coordinator.lastNote ?? "")
    }

    /// The rule can come in while a recording waits. What is prepared under the rule is blurred.
    func testARuleTurnedOnBetweenStoppingAndPreparingIsMet() async throws {
        let blur = FakeBlur()
        self.blur = blur
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        binding = nil
        let outcome = await coordinator.stop()
        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertNil(capture.journal(sessionID: sessionID)?.blurRequired)
        XCTAssertTrue(blur.asked.isEmpty)

        rules.organizationRequiresBlur = true
        binding = Self.office
        await coordinator.sealPending()

        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertTrue(try manifest(record).blurred)
        XCTAssertEqual(blur.asked.map(\.part), ["part-1.mp4"])
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })
    }

    /// And the other way: what was recorded under the rule is blurred, whatever the rule says by
    /// the time it is prepared. The people in it were recorded on that understanding.
    func testARecordingMadeUnderTheRuleIsBlurredEvenIfTheRuleHasSinceGone() async throws {
        let blur = requireBlur()
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        blur.available = false
        await coordinator.stop()

        rules.organizationRequiresBlur = false
        blur.available = true
        await coordinator.sealPending()

        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertTrue(try manifest(record).blurred)
        XCTAssertEqual(blur.asked.count, 1)
    }

    func testARuleThatCameAndWentDuringTheRecordingStillBlursIt() async throws {
        let blur = FakeBlur()
        self.blur = blur
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(10)
        rules.organizationRequiresBlur = true
        await coordinator.tick()
        XCTAssertEqual(coordinator.status, .recording(sessionID: sessionID))
        XCTAssertEqual(capture.journal(sessionID: sessionID)?.blurRequired, true, "written down when it was seen")
        rules.organizationRequiresBlur = false
        advance(10)
        await coordinator.stop()
        XCTAssertTrue(try manifest(try XCTUnwrap(bundles.records().first)).blurred)
        XCTAssertEqual(blur.asked.count, 1)
    }

    /// Transcribing takes minutes, and the rule can come in meanwhile. An unblurred bundle sealed
    /// then could never be sent and cannot be blurred once signed — so it is not sealed.
    func testARuleThatComesInWhileTheWordsAreBeingReadLeavesTheRecordingUnsealed() async throws {
        let blur = FakeBlur()
        self.blur = blur
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        holdTranscription = true
        let stopping = Task { await coordinator.stop() }
        await settle { !self.transcriptionWaiters.isEmpty }
        rules.organizationRequiresBlur = true
        holdTranscription = false
        transcriptionWaiters.forEach { $0.resume() }
        transcriptionWaiters = []
        let outcome = await stopping.value

        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(signed, 0)

        await coordinator.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertTrue(try manifest(record).blurred)
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })
    }

    /// A pass the app left the foreground in the middle of: the recorded part stays, nothing that
    /// could pass for a blurred part is left, and it is done again from the start.
    func testAnInterruptedPassLeavesTheRecordedPartAndNothingThatCouldPassForABlurredOne() async throws {
        let blur = requireBlur()
        blur.results["part-1"] = .failure(.interrupted)
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        let outcome = await coordinator.stop()

        XCTAssertEqual(outcome, .waitingForBlur)
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"], "what the pass had written is gone")
        XCTAssertNil(capture.journal(sessionID: sessionID)?.blurred)
        XCTAssertEqual(try Data(contentsOf: capture.partFile(sessionID: sessionID, partID: "part-1")),
                       Data(repeating: 1, count: 2_048))
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(blur.awake, [true, false])

        blur.results["part-1"] = nil
        await coordinator.sealPending()
        XCTAssertEqual(blur.asked.count, 2, "done again from the start")
        XCTAssertTrue(try manifest(try XCTUnwrap(bundles.records().first)).blurred)
    }

    func testAPassThatFailsIsTriedAgainLaterAndNothingIsSealedMeanwhile() async throws {
        let blur = requireBlur()
        blur.results["part-1"] = .failure(.failed)
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        let outcome = await coordinator.stop()

        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"])
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(coordinator.preparationPhase(sessionID: sessionID), .preparing,
                       "it is not waiting for the app to be opened: opening it would not help")
        XCTAssertTrue(coordinator.deferredForBlur.isEmpty)

        blur.results["part-1"] = nil
        await coordinator.sealPending()
        XCTAssertEqual(blur.asked.count, 1, "not tried again on the very next pass")
        advance(Coordinator.sealRetryInterval + 1)
        await coordinator.sealPending()
        XCTAssertEqual(blur.asked.count, 2)
        XCTAssertTrue(try manifest(try XCTUnwrap(bundles.records().first)).blurred)
    }

    /// Parts are blurred one at a time, and each is safe to stop after. A pass that got through
    /// the first part and was interrupted in the second carries on from the second.
    func testAPassCarriesOnFromThePartItWasStoppedIn() async throws {
        let blur = requireBlur()
        blur.results["part-2"] = .failure(.interrupted)
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        advance(5)
        await coordinator.resume()
        advance(20)
        let outcome = await coordinator.stop()

        XCTAssertEqual(outcome, .waitingForBlur)
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.blurred.mp4", "part-2.mp4"],
                       "the first part's unblurred file went once its replacement was written down")
        XCTAssertEqual(capture.journal(sessionID: sessionID)?.blurred?.map(\.partID), ["part-1"])
        XCTAssertTrue(bundles.records().isEmpty, "nothing is sealed while one part is unblurred")

        blur.results["part-2"] = nil
        await coordinator.sealPending()
        XCTAssertEqual(blur.asked.map(\.part), ["part-1.mp4", "part-2.mp4", "part-2.mp4"], "part 1 is not blurred twice")
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(try manifest(record).parts.map(\.partID), ["part-1", "part-2"])
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })
    }

    /// The app closed between a blurred part being written down and the unblurred one being
    /// removed. The journal is what says a part is blurred: the unblurred file is removed on the
    /// next pass and is never sealed.
    func testAnUnblurredPartLeftBesideItsReplacementIsRemovedAndNeverSealed() async throws {
        let blur = requireBlur()
        blur.results["part-2"] = .failure(.interrupted)
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        advance(5)
        await coordinator.resume()
        advance(20)
        await coordinator.stop()
        // As if part 1's unblurred file had not been removed before the app went away.
        try Data(repeating: 1, count: 2_048).write(to: capture.partFile(sessionID: sessionID, partID: "part-1"))
        XCTAssertTrue(capture.holdsUnblurredParts(sessionID: sessionID))

        blur.results["part-2"] = nil
        await coordinator.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(blur.asked.filter { $0.part == "part-1.mp4" }.count, 1)
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) }, "an unblurred part was sealed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
    }

    /// A file under a blurred part's name that the journal does not name was never checked — the
    /// app closed after it was moved into place and before it was written down. It is not taken
    /// on trust: it is removed and the part is blurred again.
    func testABlurredFileTheJournalDoesNotNameIsMadeAgainNotTrusted() async throws {
        let blur = requireBlur()
        blur.available = false
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        await coordinator.stop()
        try Data("not what a pass wrote".utf8).write(to: capture.blurredPartFile(sessionID: sessionID, partID: "part-1"))
        try Data("left half made".utf8).write(to: capture.blurScratchFile(sessionID: sessionID, partID: "part-1"))

        blur.available = true
        await coordinator.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(blur.asked.count, 1)
        XCTAssertEqual(try media(record), [FakeBlur.prefix + Data(repeating: 1, count: 2_048)])
    }

    /// A file in the folder that the journal does not name is no part of the recording. Under the
    /// blur rule it is removed — never sealed, never blurred as if it were a part — and it does
    /// not hold the recording up.
    func testAFileTheJournalDoesNotNameIsRemovedAndNotSealed() async throws {
        let blur = requireBlur()
        blur.available = false
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        await coordinator.stop()
        try Data(repeating: 9, count: 512).write(to: capture.partFile(sessionID: sessionID, partID: "part-9"))

        blur.available = true
        await coordinator.sealPending()
        let record = try XCTUnwrap(bundles.records().first)
        XCTAssertEqual(try manifest(record).parts.map(\.partID), ["part-1"])
        XCTAssertEqual(blur.asked.map(\.part), ["part-1.mp4"])
        XCTAssertTrue(try media(record).allSatisfy { $0.starts(with: FakeBlur.prefix) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
    }

    /// Chosen: a part none of whose pictures could be blurred keeps its sound and is listed as
    /// sound. The whole of its video is a `filter` gap.
    func testAPartWithNoPictureLeftIsSealedAsSoundAlone() async throws {
        let blur = requireBlur()
        blur.results["part-1"] = .success(.init(framesWritten: 0, framesDropped: 480, keptSound: true))
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        let manifest = try manifest(record)
        XCTAssertTrue(manifest.blurred)
        XCTAssertEqual(manifest.droppedFrames, 480)
        XCTAssertEqual(manifest.parts.map(\.track), ["audio"])
        let timeline = try timeline(record)
        XCTAssertEqual(timeline.tracks.map(\.track), [.audio])
        XCTAssertEqual(timeline.gaps, [.init(track: .video, from: t(0), to: t(20), reason: .filter)])
    }

    /// And one with no sound either is not in the bundle at all.
    func testAPartWithNothingLeftIsNotInTheBundle() async throws {
        let blur = requireBlur()
        blur.results["part-1"] = .success(.init(framesWritten: 0, framesDropped: 700, keptSound: false))
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(30)
        await coordinator.pause()
        advance(10)
        await coordinator.resume()
        advance(20)
        await coordinator.stop()

        let record = try XCTUnwrap(bundles.records().first)
        let manifest = try manifest(record)
        XCTAssertEqual(manifest.parts.map(\.partID), ["part-2"])
        XCTAssertEqual(manifest.droppedFrames, 700)
        XCTAssertEqual(try media(record).count, 1)
        XCTAssertEqual(try timeline(record).gaps.filter { $0.track == .video },
                       [.init(track: .video, from: t(0), to: t(30), reason: .filter)])
    }

    func testARecordingWithNothingLeftAfterTheBlurLeavesNothingBehind() async throws {
        let blur = requireBlur()
        blur.results["part-1"] = .success(.init(framesWritten: 0, framesDropped: 480, keptSound: false))
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        let outcome = await coordinator.stop()
        XCTAssertEqual(outcome, .nothingRecorded)
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory(sessionID: sessionID).path))
    }

    /// A pass that says it succeeded and wrote nothing has not blurred the part.
    func testAPassThatReportsPicturesAndWritesNoFileIsNotTakenAtItsWord() async throws {
        rules.organizationRequiresBlur = true
        var pass = FakeBlur().seam
        pass.blur = { _, _, _ in .success(FakeBlur.whole) }   // says it did; wrote nothing
        let lying = Coordinator(seams: lyingSeams(pass))
        await started(lying)
        advance(20)
        let outcome = await lying.stop()
        XCTAssertEqual(outcome, .waitingToPrepare)
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(captureFiles(), ["journal.json", "part-1.mp4"])
        XCTAssertNil(capture.journal(sessionID: sessionID)?.blurred)
    }

    /// In an app with no blur pass, a recording that came under the rule after it was made is
    /// never sealed unblurred. It stays as it is.
    func testWithNoBlurPassARecordingThatCameUnderTheRuleIsNotSealed() async throws {
        let coordinator = makeCoordinator()
        await started(coordinator)
        advance(20)
        binding = nil
        await coordinator.stop()
        rules.organizationRequiresBlur = true
        binding = Self.office
        await coordinator.sealPending()
        XCTAssertTrue(bundles.records().isEmpty)
        XCTAssertEqual(signed, 0)
        XCTAssertEqual(capture.bytes(sessionID: sessionID), 2_048)
    }
}
