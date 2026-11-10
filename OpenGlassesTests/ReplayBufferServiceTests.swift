import Combine
import XCTest
@testable import OpenGlasses

/// Instant Replay P1/P2 — the buffer's lifecycle and what a save files where, driven headless:
/// a fake segment writer and composer, a hand-moved clock, and temporary directories.
@MainActor
final class ReplayBufferServiceTests: XCTestCase {

    // MARK: - Fakes

    final class FakeWriter: ReplaySegmentWriting {
        let url: URL
        var appended: [TimeInterval] = []
        var finished = false
        var cancelled = false
        var finishResult = true

        init(url: URL) {
            self.url = url
            // The real writer creates its file on start; so does this one, so deletion is real.
            FileManager.default.createFile(atPath: url.path, contents: Data("segment".utf8))
        }

        func append(_ image: UIImage, at seconds: TimeInterval) { appended.append(seconds) }
        func finish() async -> Bool { finished = true; return finishResult }
        func cancel() { cancelled = true }
    }

    final class FakeComposer: ReplayClipComposing, @unchecked Sendable {
        var composed: [[String]] = []
        var duration: TimeInterval?
        var fails = false
        /// Runs while the composition is "reading" its segments.
        var duringCompose: (@MainActor () async -> Void)?
        var missingDuringCompose: [String] = []

        struct Failure: Error {}

        func compose(_ segments: [URL], to output: URL) async throws -> TimeInterval {
            composed.append(segments.map(\.lastPathComponent))
            if let duringCompose { await duringCompose() }
            missingDuringCompose += segments.filter { !FileManager.default.fileExists(atPath: $0.path) }
                .map(\.lastPathComponent)
            if fails { throw Failure() }
            try Data("composed clip".utf8).write(to: output)
            return duration ?? Double(segments.count) * 2
        }

        func posterJPEG(of url: URL) async -> Data? { Data([0xFF, 0xD8, 0xFF]) }
    }

    final class FakeJob: JobClipFiling {
        var isOpenForEvidence = true
        struct Attached: Equatable {
            let bytes: Int
            let hasPoster: Bool
            let caption: String?
            let duration: TimeInterval
            let filterWasOn: Bool
            let cutShort: Bool
        }
        var attached: [Attached] = []

        func attachClip(_ data: Data, posterJPEG: Data?, caption: String?,
                        durationSeconds: TimeInterval, filterWasOn: Bool, cutShort: Bool) -> String? {
            attached.append(.init(bytes: data.count, hasPoster: posterJPEG != nil, caption: caption,
                                  duration: durationSeconds, filterWasOn: filterWasOn, cutShort: cutShort))
            return "clip-\(attached.count).mp4"
        }
    }

    // MARK: - Harness

    private var root: URL!
    private var clock: TimeInterval = 1000
    private var streaming = true
    private var setting = true
    private var org = false
    private var hipaa = false
    private var posture: PowerPosture = .normal
    private var free: Int64? = 50_000_000_000
    private var filter = true
    private var bufferSeconds: TimeInterval = 60
    private var writerFails = false
    private var writerAttempts = 0
    private var writers: [FakeWriter] = []
    private var photosCalls: [URL] = []
    private var composer = FakeComposer()
    private var job = FakeJob()
    private var relay = PassthroughSubject<UIImage, Never>()

    private var bufferDirectory: URL { root.appendingPathComponent("buffer") }
    private var recordings: URL { root.appendingPathComponent("Recordings") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayBufferServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService() -> ReplayBufferService {
        var seams = ReplayBufferService.Seams()
        seams.settingOn = { self.setting }
        seams.orgPinnedOff = { self.org }
        seams.medicalCompliance = { self.hipaa }
        seams.glassesStreaming = { self.streaming }
        seams.posture = { self.posture }
        seams.freeBytes = { self.free }
        seams.bufferSeconds = { self.bufferSeconds }
        seams.frameRate = { 15 }
        seams.resolution = { "high" }
        seams.filterEnabled = { self.filter }
        seams.now = { self.clock }
        seams.wallClock = { Date(timeIntervalSince1970: 1_800_000_000) }
        seams.directory = bufferDirectory
        seams.makeWriter = { url, _, _ in
            self.writerAttempts += 1
            if self.writerFails { throw FakeComposer.Failure() }
            let writer = FakeWriter(url: url)
            self.writers.append(writer)
            return writer
        }
        seams.composer = composer
        seams.scratchDirectory = { self.root.appendingPathComponent("scratch") }
        seams.recordingsDirectory = { self.recordings }
        seams.jobs = { self.job }
        seams.jobClipMaximum = { 60 }
        seams.saveToPhotos = { url in self.photosCalls.append(url); return true }
        seams.startsTicker = false
        let service = ReplayBufferService()
        service.connect(seams, source: relay)
        return service
    }

    private func frame(width: CGFloat = 64, height: CGFloat = 96) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// `seconds` of frames at 15 fps through the relay, the clock moving with them.
    private func feed(_ seconds: TimeInterval, width: CGFloat = 64, height: CGFloat = 96) {
        let image = frame(width: width, height: height)
        for _ in 0..<Int((seconds * 15).rounded()) {
            relay.send(image)
            clock += 1.0 / 15
        }
    }

    private func filesInBuffer() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: bufferDirectory.path)) ?? []).sorted()
    }

    // MARK: - Lifecycle

    func testNoBufferWithoutAStreamTheWearerStarted() {
        streaming = false
        let service = makeService()
        XCTAssertEqual(service.decision, .off(.cameraOff))
        feed(3)
        XCTAssertTrue(writers.isEmpty, "no stream, no frames kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bufferDirectory.path))
    }

    func testOffByDefaultWhenTheSettingIsOff() {
        setting = false
        let service = makeService()
        XCTAssertEqual(service.decision, .off(.settingOff))
        feed(2)
        XCTAssertTrue(writers.isEmpty)
    }

    func testRunsAlongsideAStreamAndStartsWithIt() {
        streaming = false
        let service = makeService()
        streaming = true
        service.reconcile()
        XCTAssertTrue(service.isRunning)
        feed(1)
        XCTAssertEqual(writers.count, 1)
    }

    func testSegmentsRotateEveryTwoSecondsAndEachStartsAtZero() async {
        let service = makeService()
        feed(7)
        await service.settle()
        XCTAssertEqual(service.ring.count, 3, "0–2, 2–4 and 4–6 closed; 6–7 still open")
        XCTAssertEqual(writers.count, 4)
        XCTAssertTrue(writers.prefix(3).allSatisfy(\.finished))
        for writer in writers {
            XCTAssertEqual(writer.appended.first ?? 0, 0, accuracy: 1e-9)
            XCTAssertLessThan(writer.appended.last ?? 0, ReplayBufferPlan.segmentSeconds)
        }
        XCTAssertGreaterThan(service.bufferedSeconds, 5)
    }

    func testTheOldestSegmentFileIsDeletedWhenTheRingIsFull() async {
        bufferSeconds = 30
        let service = makeService()
        feed(40)
        await service.settle()
        XCTAssertEqual(service.ring.count, 16)
        // The ring's segments plus the one being written; nothing older survives on disk.
        XCTAssertEqual(filesInBuffer().count, 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writers[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: writers.last!.url.path))
    }

    func testAFinishedSegmentIsProtectedAndOutOfBackup() async throws {
        let service = makeService()
        feed(3)
        await service.settle()
        let first = try XCTUnwrap(service.ring.segments.first)
        let url = bufferDirectory.appendingPathComponent(first.fileName)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
    }

    func testASizeChangeClosesTheSegment() async {
        let service = makeService()
        feed(1)
        feed(0.5, width: 32, height: 48)
        await service.settle()
        XCTAssertEqual(writers.count, 2)
        XCTAssertEqual(service.ring.segments.map(\.width), [64])
    }

    func testStoppingTheStreamDeletesEverything() async {
        let service = makeService()
        feed(5)
        await service.settle()
        XCTAssertFalse(filesInBuffer().isEmpty)
        streaming = false
        service.reconcile()
        XCTAssertEqual(service.decision, .off(.cameraOff))
        XCTAssertTrue(service.ring.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bufferDirectory.path))
        XCTAssertTrue(writers.last?.cancelled ?? false, "the segment being written is abandoned")
        feed(2)
        XCTAssertEqual(writers.count, 3, "frames after the stop are not kept")
    }

    func testEveryStopConditionDeletesTheBuffer() async {
        let flips: [(String, (ReplayBufferServiceTests) -> Void, ReplayOffReason)] = [
            ("hipaa", { $0.hipaa = true }, .medicalCompliance),
            ("posture", { $0.posture = .conserve }, .power),
            ("setting", { $0.setting = false }, .settingOff),
            ("org", { $0.org = true }, .organisationOff),
            ("storage", { $0.free = 1_000 }, .lowStorage),
        ]
        for (name, flip, reason) in flips {
            hipaa = false; posture = .normal; setting = true; org = false; free = 50_000_000_000
            let service = makeService()
            feed(3)
            await service.settle()
            XCTAssertFalse(service.ring.isEmpty, name)
            flip(self)
            service.reconcile()
            XCTAssertEqual(service.decision, .off(reason), name)
            XCTAssertTrue(service.ring.isEmpty, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bufferDirectory.path), name)
            service.deleteAll()
        }
    }

    func testAChangedLengthStartsAFreshBuffer() async {
        let service = makeService()
        feed(5)
        await service.settle()
        bufferSeconds = 120
        service.reconcile()
        XCTAssertTrue(service.isRunning)
        XCTAssertTrue(service.ring.isEmpty)
        XCTAssertEqual(service.ring.capacity, 61)
    }

    func testAWriterThatCannotBeMadeIsRetriedAfterASegmentNotEveryFrame() {
        writerFails = true
        let service = makeService()
        feed(1.5)
        XCTAssertEqual(writerAttempts, 1)
        feed(1)
        XCTAssertEqual(writerAttempts, 2)
        writerFails = false
        feed(2.2)
        XCTAssertEqual(writers.count, 1)
        XCTAssertTrue(service.isRunning)
    }

    func testDeleteAllClearsTheBufferAndKeepsRunning() async {
        let service = makeService()
        feed(5)
        await service.settle()
        XCTAssertEqual(service.deleteAll(), 2)
        XCTAssertTrue(service.ring.isEmpty)
        XCTAssertTrue(filesInBuffer().isEmpty)
        feed(3)
        await service.settle()
        XCTAssertEqual(service.ring.count, 1, "the buffer carries on from nothing")
    }

    func testLeftoversAreRemovedAtLaunch() throws {
        try FileManager.default.createDirectory(at: bufferDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bufferDirectory.appendingPathComponent("segment-000009.mp4").path,
                                       contents: Data("old".utf8))
        XCTAssertTrue(ReplayBufferService.removeLeftovers(in: bufferDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bufferDirectory.path))
        XCTAssertFalse(ReplayBufferService.removeLeftovers(in: bufferDirectory))
    }

    func testTheSubjectErasureClearsTheWholeBuffer() async {
        let service = makeService()
        feed(5)
        await service.settle()
        var stores = SubjectErasureCoordinator.Stores()
        stores.instantReplay = service
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.document(id: "doc"))
        XCTAssertEqual(receipts.first { $0.store == .instantReplayBuffer }?.removed, 0)
        XCTAssertFalse(service.ring.isEmpty, "a document is never in the buffer")
        let person = await SubjectErasureCoordinator(stores: stores).erase(.person("Sam"))
        let receipt = person.first { $0.store == .instantReplayBuffer }
        XCTAssertEqual(receipt?.removed, 2)
        XCTAssertEqual(receipt?.localComplete, true)
        XCTAssertTrue(service.ring.isEmpty)
    }

    // MARK: - Saving

    func testSaveKeepsTheLastThirtySecondsInRecordingsAndNotPhotos() async throws {
        let service = makeService()
        feed(40)
        let outcome = await service.save(ReplaySaveRequest())
        XCTAssertEqual(outcome.spoken, "Saved the last 30 seconds to Recordings.")
        let composed = try XCTUnwrap(composer.composed.first)
        XCTAssertTrue((15...16).contains(composed.count),
                      "thirty seconds of two-second segments, the one just closed included: \(composed.count)")
        XCTAssertEqual(composed, composed.sorted(), "oldest first")
        let filed = try FileManager.default.contentsOfDirectory(atPath: recordings.path)
        XCTAssertEqual(filed.count, 1)
        XCTAssertTrue(filed[0].hasPrefix("Replay_"), filed[0])
        XCTAssertTrue(photosCalls.isEmpty, "nothing reaches Photos unless asked")
        XCTAssertTrue(job.attached.isEmpty, "nothing reaches the job unless asked")
        let scratch = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scratch").path)
        XCTAssertTrue(scratch.isEmpty, "the composed clip was moved, not left behind")
    }

    func testSegmentsAreCopiedNotMovedSoAnotherSaveStillWorks() async {
        let service = makeService()
        feed(70)
        let before = service.ring.count
        _ = await service.save(ReplaySaveRequest())
        XCTAssertGreaterThanOrEqual(service.ring.count, before)
        let second = await service.save(ReplaySaveRequest(seconds: 60))
        XCTAssertEqual(second.spoken, "Saved the last minute to Recordings.")
        XCTAssertEqual(composer.composed.count, 2)
    }

    func testPhotosOnlyWhenAskedInTheSameRequest() async {
        let service = makeService()
        feed(35)
        let outcome = await service.save(ReplaySaveRequest(destination: .photos))
        XCTAssertEqual(outcome.spoken, "Saved the last 30 seconds to Recordings and Photos.")
        XCTAssertEqual(photosCalls.count, 1)
        XCTAssertTrue(photosCalls[0].lastPathComponent.hasPrefix("Replay_"))
    }

    func testTheJobGetsAClipThroughJobClipFiling() async throws {
        let service = makeService()
        feed(35)
        let outcome = await service.save(ReplaySaveRequest(destination: .job, caption: "fan wobble"))
        XCTAssertEqual(outcome.spoken, "Saved the last 30 seconds to the job.")
        let attached = try XCTUnwrap(job.attached.first)
        XCTAssertEqual(attached.caption, "fan wobble")
        XCTAssertTrue(attached.filterWasOn)
        XCTAssertFalse(attached.cutShort)
        XCTAssertTrue(attached.hasPoster)
        XCTAssertGreaterThanOrEqual(attached.duration, 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path), "a job clip is not a recording")
    }

    func testAJobClipRecordsWhetherTheBlurWasOnThroughout() async throws {
        let service = makeService()
        feed(20)
        filter = false
        feed(15)
        _ = await service.save(ReplaySaveRequest(destination: .job))
        XCTAssertEqual(job.attached.first?.filterWasOn, false)
    }

    func testNoOpenJobIsARefusalAndNothingIsComposed() async {
        job.isOpenForEvidence = false
        let service = makeService()
        feed(10)
        let outcome = await service.save(ReplaySaveRequest(destination: .job))
        XCTAssertEqual(outcome.result, .refused(.noOpenJob))
        XCTAssertTrue(composer.composed.isEmpty)
    }

    func testATwoMinuteReplayToTheJobIsCutToTheJobClipCap() async throws {
        bufferSeconds = 120
        let service = makeService()
        feed(130)
        let outcome = await service.save(ReplaySaveRequest(seconds: 120, destination: .job))
        XCTAssertEqual(outcome.spoken, "A job clip is at most a minute, so I saved the last minute to the job.")
        let composed = try XCTUnwrap(composer.composed.first)
        XCTAssertLessThanOrEqual(composed.count, 31)
    }

    func testAShortBufferSaysHowMuchItKept() async {
        let service = makeService()
        feed(10)
        let outcome = await service.save(ReplaySaveRequest())
        XCTAssertTrue(outcome.spoken.hasPrefix("I only have the last "), outcome.spoken)
        XCTAssertTrue(outcome.spoken.hasSuffix("saved those to Recordings."), outcome.spoken)
    }

    func testANotRunningBufferRefusesWithItsReason() async {
        streaming = false
        let service = makeService()
        let outcome = await service.save(ReplaySaveRequest())
        XCTAssertEqual(outcome.spoken, "Instant Replay isn't running: the camera's off.")
        XCTAssertTrue(composer.composed.isEmpty)
        hipaa = true
        let medical = await service.save(ReplaySaveRequest())
        XCTAssertEqual(medical.spoken, "Instant Replay isn't running: it's off in Medical Compliance mode.")
    }

    func testNothingBufferedYetIsSaid() async {
        let service = makeService()
        let outcome = await service.save(ReplaySaveRequest())
        XCTAssertEqual(outcome.result, .refused(.nothingBuffered))
    }

    func testAFailedCompositionFilesNothing() async {
        composer.fails = true
        let service = makeService()
        feed(10)
        let outcome = await service.save(ReplaySaveRequest())
        XCTAssertEqual(outcome.result, .refused(.couldNotSave))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path))
    }

    func testSegmentsASaveIsReadingAreNotDeletedUnderIt() async {
        bufferSeconds = 30
        let service = makeService()
        feed(40)
        // While the composition reads its sixteen segments, ten more seconds arrive and push
        // five of them out of the ring.
        composer.duringCompose = { [unowned self] in
            self.feed(10)
            await service.settle()
        }
        _ = await service.save(ReplaySaveRequest())
        XCTAssertTrue(composer.missingDuringCompose.isEmpty, "\(composer.missingDuringCompose)")
        let stillHeld = Set(service.ring.segments.map(\.fileName))
        let evictedAndReleased = composer.composed[0].filter { !stillHeld.contains($0) }
        XCTAssertGreaterThanOrEqual(evictedAndReleased.count, 3, "the save's oldest segments aged out under it")
        for name in evictedAndReleased {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bufferDirectory.appendingPathComponent(name).path),
                           "\(name) goes once the save is done with it")
        }
    }

    func testTheStatusLine() async {
        let service = makeService()
        XCTAssertEqual(service.statusLine, "Instant Replay is on and just getting started.")
        feed(9)
        await service.settle()
        XCTAssertTrue(service.statusLine.hasPrefix("Instant Replay is keeping the last "), service.statusLine)
        streaming = false
        service.reconcile()
        XCTAssertEqual(service.statusLine, "Instant Replay isn't running: the camera's off.")
    }
}
