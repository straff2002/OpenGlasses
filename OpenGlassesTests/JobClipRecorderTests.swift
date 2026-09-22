import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// The recorder itself, driven with an injected frame source, an injected clock and a fake writer
/// (Plan FO P2b).
///
/// Nothing here touches `AVFoundation`, a camera, or the shared services. The behaviour that has to
/// be right is the refusals, the cap, the stall, the poster frame and what lands on the session —
/// and every one of those is decided by this class rather than by a video encoder.
@MainActor
final class JobClipRecorderTests: XCTestCase {

    // MARK: - Doubles

    /// A writer that remembers what it was handed.
    private final class FakeWriter: ClipWriting {
        var appended: [TimeInterval] = []
        var finished = false
        var cancelled = false
        var finishResult = true

        func append(_ image: UIImage, at seconds: TimeInterval) { appended.append(seconds) }
        func finish() async -> Bool { finished = true; return finishResult }
        func cancel() { cancelled = true }
    }

    /// A session store that records what was filed against it.
    private final class FakeSessions: JobClipFiling {
        var isOpenForEvidence = true
        var filed: [(bytes: Int, poster: Data?, caption: String?, duration: TimeInterval,
                     filterWasOn: Bool, cutShort: Bool)] = []
        var accepts = true

        func attachClip(_ data: Data, posterJPEG: Data?, caption: String?,
                        durationSeconds: TimeInterval, filterWasOn: Bool,
                        cutShort: Bool) -> String? {
            guard accepts else { return nil }
            filed.append((data.count, posterJPEG, caption, durationSeconds, filterWasOn, cutShort))
            return "clip-\(filed.count).mp4"
        }
    }

    private var sessions: FakeSessions!
    private var writer: FakeWriter!
    private var frames: PassthroughSubject<UIImage, Never>!
    private var clock: Date!
    private var scratch: URL!
    private var madeWriters = 0
    private var writerFails = false

    override func setUp() {
        super.setUp()
        sessions = FakeSessions()
        writer = FakeWriter()
        frames = PassthroughSubject<UIImage, Never>()
        clock = Date(timeIntervalSince1970: 1_000_000)
        madeWriters = 0
        writerFails = false
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobClip-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// A camera that is producing pictures right now — the only state a clip may start in.
    private static let streaming = CameraReadiness(phase: .ready, frameAge: 0.1, session: 1,
                                                   userWantsStream: true)

    private func makeRecorder(readiness: CameraReadiness? = JobClipRecorderTests.streaming,
                              filterOn: Bool = false) -> JobClipRecorder {
        JobClipRecorder(seams: .init(
            sessions: { [sessions] in sessions! },
            readiness: { readiness },
            filterEnabled: { filterOn },
            makeWriter: { [weak self] url, _ in
                guard let self else { throw CocoaError(.fileNoSuchFile) }
                self.madeWriters += 1
                if self.writerFails { throw CocoaError(.fileWriteUnknown) }
                // The recorder reads the file back before filing it, so the fake writer's output
                // has to exist on disk — otherwise the test would be proving the wrong thing.
                try? Data(repeating: 7, count: 2_048).write(to: url)
                return self.writer
            },
            now: { [weak self] in self?.clock ?? Date() },
            scratchDirectory: { [weak self] in self?.scratch ?? FileManager.default.temporaryDirectory }))
    }

    private func frame(_ colour: UIColor = .systemTeal,
                       size: CGSize = CGSize(width: 64, height: 48)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Refusals

    func testNothingIsRecordedWithoutAnOpenJob() {
        sessions.isOpenForEvidence = false
        let recorder = makeRecorder()
        guard case .failure(let refusal) = recorder.start(from: frames) else {
            return XCTFail("a clip started with no job open")
        }
        XCTAssertEqual(refusal, .noOpenJob)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(refusal.spoken.contains("no job open"))
    }

    /// The defect this exists to prevent: a "clip" that is thirty seconds of the last frame the
    /// glasses managed before they went flat.
    func testAStaleStreamIsRefusedRatherThanRecordedBlack() {
        let stale = CameraReadiness(phase: .ready, frameAge: 30, session: 1, userWantsStream: true)
        guard case .failure(let refusal) = makeRecorder(readiness: stale).start(from: frames) else {
            return XCTFail("a clip started off a stalled stream")
        }
        guard case .cameraNotReady = refusal else {
            return XCTFail("expected a camera refusal, got \(refusal)")
        }
    }

    func testAnAbsentCameraIsRefused() {
        guard case .failure(let refusal) = makeRecorder(readiness: nil).start(from: frames) else {
            return XCTFail("a clip started with no camera at all")
        }
        guard case .cameraNotReady = refusal else {
            return XCTFail("expected a camera refusal, got \(refusal)")
        }
    }

    func testASecondStartWhileOneIsRunningIsRefusedAndSaysHowLongItHasBeenGoing() {
        let recorder = makeRecorder()
        XCTAssertNoThrow(try XCTUnwrap(recorder.start(from: frames).success))
        clock = clock.addingTimeInterval(7)
        guard case .failure(let refusal) = recorder.start(from: frames) else {
            return XCTFail("two clips started at once")
        }
        XCTAssertEqual(refusal, .alreadyRecording(elapsed: recorder.elapsed))
    }

    // MARK: - Caps

    func testTheCapDefaultsClampsAndNeverExceedsTheMaximum() {
        XCTAssertEqual(JobClipRecorder.cap(forRequested: nil), JobClipRecorder.defaultCapSeconds)
        XCTAssertEqual(JobClipRecorder.cap(forRequested: 0), JobClipRecorder.defaultCapSeconds)
        XCTAssertEqual(JobClipRecorder.cap(forRequested: 10), 10)
        XCTAssertEqual(JobClipRecorder.cap(forRequested: 0.2), 1)
        XCTAssertEqual(JobClipRecorder.cap(forRequested: 9_999),
                       JobClipRecorder.maximumCapSeconds)
    }

    func testTheDefaultCapIsWithinTheMaximum() {
        XCTAssertLessThanOrEqual(JobClipRecorder.defaultCapSeconds,
                                 JobClipRecorder.maximumCapSeconds)
    }

    // MARK: - Frames

    func testFramesFromTheRelayAreWrittenAndTheFirstOneBecomesThePoster() async throws {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames, caption: "compressor cycling", seconds: 30)
        frames.send(frame(.systemRed))
        clock = clock.addingTimeInterval(1)
        frames.send(frame(.systemGreen))
        clock = clock.addingTimeInterval(1)
        frames.send(frame(.systemBlue))

        XCTAssertEqual(writer.appended, [0, 1, 2])
        clock = clock.addingTimeInterval(1)
        let finished = await recorder.stop()

        XCTAssertNotNil(finished)
        XCTAssertEqual(sessions.filed.count, 1)
        // The poster is the *first* frame off the relay — already blurred, captured at record
        // time, never decoded back out of the file.
        XCTAssertNotNil(try XCTUnwrap(sessions.filed[0].poster))
        XCTAssertEqual(sessions.filed[0].caption, "compressor cycling")
        XCTAssertTrue(writer.finished)
    }

    func testAClipWithNoFramesAtAllFilesNothing() async {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames)
        let finished = await recorder.stop()
        XCTAssertNil(finished)
        XCTAssertTrue(sessions.filed.isEmpty, "an empty file must not reach a work order")
    }

    func testAWriterThatCannotBeMadeStopsTheRecordingRatherThanFailingOncePerFrame() async {
        writerFails = true
        let recorder = makeRecorder()
        _ = recorder.start(from: frames)
        frames.send(frame())
        // The abandon runs on the main actor from the frame callback; let it land.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(madeWriters, 1)
        XCTAssertTrue(sessions.filed.isEmpty)
    }

    func testAWriterThatFailsToFinishFilesNothing() async {
        writer.finishResult = false
        let recorder = makeRecorder()
        _ = recorder.start(from: frames)
        frames.send(frame())
        let finished = await recorder.stop()
        XCTAssertNil(finished)
        XCTAssertTrue(sessions.filed.isEmpty)
    }

    // MARK: - The blur setting, recorded per clip

    /// P2a's lesson, applied to clips: the review labels an item from what was recorded against
    /// it, never from the setting as it stands at review time.
    func testTheBlurSettingIsRecordedAsItStoodWhenTheClipWasRecorded() async {
        let recorder = makeRecorder(filterOn: true)
        _ = recorder.start(from: frames)
        frames.send(frame())
        _ = await recorder.stop()
        XCTAssertEqual(sessions.filed.first?.filterWasOn, true)
    }

    // MARK: - Endings

    func testAStopTheTechnicianAskedForIsNotCutShort() async throws {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames)
        frames.send(frame())
        let stopped = await recorder.stop()
        let finished = try XCTUnwrap(stopped)
        XCTAssertEqual(finished.ending, .asked)
        XCTAssertFalse(finished.cutShort)
        XCTAssertEqual(sessions.filed.first?.cutShort, false)
    }

    func testTheCapStopsTheWriterAndMarksTheClipCutShort() async {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames, seconds: 5)
        frames.send(frame())
        clock = clock.addingTimeInterval(6)
        await recorder.tick()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(writer.finished)
        XCTAssertEqual(sessions.filed.first?.cutShort, true)
    }

    func testAStreamThatStopsFinalisesWhatWasCapturedAndLabelsIt() async throws {
        var announced: JobClipRecorder.Finished?
        let recorder = makeRecorder()
        recorder.onFinished = { announced = $0 }
        _ = recorder.start(from: frames, seconds: 30)
        frames.send(frame())
        clock = clock.addingTimeInterval(JobClipRecorder.stallSeconds + 1)
        await recorder.tick()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(sessions.filed.count, 1, "what was captured before the stall is kept")
        XCTAssertEqual(sessions.filed.first?.cutShort, true)
        XCTAssertEqual(announced?.ending, .streamStopped)
        XCTAssertTrue(try XCTUnwrap(announced).spoken.contains("cut short"))
        XCTAssertNotNil(announced)
    }

    func testTheJobClosingUnderneathARunningClipFinishesIt() async {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames, seconds: 30)
        frames.send(frame())
        sessions.isOpenForEvidence = false
        clock = clock.addingTimeInterval(1)
        await recorder.tick()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(sessions.filed.first?.cutShort, true)
    }

    /// The stall rule as a table, so the boundary is not a guess about a timer.
    func testTheStallRule() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(JobClipRecorder.streamHasStopped(
            lastFrameAt: start.addingTimeInterval(1), startedAt: start,
            now: start.addingTimeInterval(2), stallSeconds: 4))
        XCTAssertTrue(JobClipRecorder.streamHasStopped(
            lastFrameAt: start.addingTimeInterval(1), startedAt: start,
            now: start.addingTimeInterval(5), stallSeconds: 4))
        // Never a frame at all: judged from the start, unlike the long-form recorder, because a
        // thirty-second clip cannot spend half of itself waiting for a stream that isn't coming.
        XCTAssertTrue(JobClipRecorder.streamHasStopped(
            lastFrameAt: nil, startedAt: start, now: start.addingTimeInterval(4),
            stallSeconds: 4))
    }

    // MARK: - The countdown

    func testTheCountdownStatesBothHalvesAndTheRemainderNeverGoesNegative() {
        let recorder = makeRecorder()
        _ = recorder.start(from: frames, seconds: 30)
        XCTAssertEqual(recorder.countdownLabel, "0:00 of 0:30")
        clock = clock.addingTimeInterval(12)
        frames.send(frame())
        XCTAssertEqual(recorder.remainingSeconds, 30, accuracy: 0.001,
                       "elapsed only moves on the tick, which is what the label is drawn from")
    }

    // MARK: - Geometry

    func testTheEncodeSizeIsEvenBecauseH264NeedsItToBe() throws {
        let odd = frame(size: CGSize(width: 65, height: 49))
        let size = try XCTUnwrap(JobClipRecorder.encodeSize(of: odd))
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
    }

    // MARK: - Where the pixels come from

    /// The rule the roster exists to enforce, asserted against this recorder's own source: it must
    /// take its frames as a parameter and must never reach for the raw camera. A recorder reading
    /// `CameraService.framePublisher` would write unblurred faces into a file that then goes out
    /// with a customer's work order.
    func testTheRecorderNeverReadsTheRawCameraTap() throws {
        let source = try String(contentsOf: Self.sourceFile("Services/FieldAssist/Job/JobClipRecorder.swift"),
                                encoding: .utf8)
        let code = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
        for forbidden in ["framePublisher", "latestFrame", "onVideoFrame", "capturePhoto("] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "JobClipRecorder must not reach for \(forbidden) — it records off the "
                           + "blurred relay it is handed")
        }
    }

    /// And the one place that hands it a publisher hands it the relay's.
    func testTheAppWiresTheRecorderToTheBlurRelay() throws {
        let source = try String(contentsOf: Self.sourceFile("App/OpenGlassesApp.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "jobClips.start(from:"))
        let line = source[start.lowerBound...].prefix(120)
        XCTAssertTrue(line.contains("outboundFrames.publisher"), String(line))
    }

    private static func sourceFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
            .appendingPathComponent(relative)
    }
}

private extension Result {
    var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
