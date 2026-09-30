import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan GB P4 — `record_clip` claims the glasses stream and waits within FD's cold-start window,
/// instead of refusing because nothing had restarted the stream after a relaunch.
@MainActor
final class JobClipStreamClaimTests: XCTestCase {

    private final class Sessions: JobClipFiling {
        var isOpenForEvidence = true
        func attachClip(_ data: Data, posterJPEG: Data?, caption: String?,
                        durationSeconds: TimeInterval, filterWasOn: Bool, cutShort: Bool) -> String? { "clip.mp4" }
    }

    private final class Writer: ClipWriting {
        func append(_ image: UIImage, at seconds: TimeInterval) {}
        func finish() async -> Bool { true }
        func cancel() {}
    }

    private static let ready = CameraReadiness(phase: .ready, frameAge: 0.1, session: 1, userWantsStream: true)
    private static let stopped = CameraReadiness(phase: .stopped, frameAge: nil, session: 0, userWantsStream: false)
    private static let connecting = CameraReadiness(phase: .connecting, frameAge: nil, session: 1, userWantsStream: true)

    private var readiness: CameraReadiness? = JobClipStreamClaimTests.stopped
    private var ensureResult: ClipStreamWarmup.Result = .ready
    private var ensureCalls = 0
    private var releases = 0
    private let sessions = Sessions()
    private let frames = PassthroughSubject<UIImage, Never>()

    private func recorder() -> JobClipRecorder {
        JobClipRecorder(seams: .init(
            sessions: { [sessions] in sessions },
            readiness: { [weak self] in self?.readiness },
            filterEnabled: { false },
            makeWriter: { _, _ in Writer() },
            ensureStream: { [weak self] in
                guard let self else { return .claimFailed }
                self.ensureCalls += 1
                if self.ensureResult == .ready { self.readiness = Self.ready }
                return self.ensureResult
            },
            releaseStream: { [weak self] in self?.releases += 1 }))
    }

    func testAStoppedStreamIsClaimedAndTheClipStarts() async {
        let clip = recorder()
        let result = await clip.startClaimingStream(from: frames)
        XCTAssertNotNil(try? result.get())
        XCTAssertEqual(ensureCalls, 1)
        XCTAssertTrue(clip.holdsStreamClaim)
        XCTAssertTrue(clip.isRecording)

        _ = await clip.stop()
        XCTAssertEqual(releases, 1, "the claim is given back when the clip ends")
        XCTAssertFalse(clip.holdsStreamClaim)
    }

    func testARunningStreamIsNotClaimedAgain() async {
        readiness = Self.ready
        let clip = recorder()
        _ = await clip.startClaimingStream(from: frames)
        XCTAssertEqual(ensureCalls, 0)
        _ = await clip.stop()
        XCTAssertEqual(releases, 0, "a stream the clip didn't open is not the clip's to stop")
    }

    func testATimeoutIsASpokenRefusalAndReleasesTheClaim() async {
        ensureResult = .timedOut("The glasses are still connecting")
        let clip = recorder()
        let result = await clip.startClaimingStream(from: frames)
        guard case .failure(.cameraNotReady(let phrase)) = result else {
            return XCTFail("expected a camera refusal, got \(result)")
        }
        XCTAssertEqual(phrase, "The glasses are still connecting")
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(clip.isRecording)
    }

    func testAFailedClaimIsARefusal() async {
        ensureResult = .claimFailed
        let result = await recorder().startClaimingStream(from: frames)
        guard case .failure(.cameraNotReady) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(releases, 0, "nothing was claimed, so nothing is given back")
    }

    func testNoJobMeansNoClaim() async {
        sessions.isOpenForEvidence = false
        let result = await recorder().startClaimingStream(from: frames)
        XCTAssertEqual(result.failureValue, .noOpenJob)
        XCTAssertEqual(ensureCalls, 0)
    }

    func testASecondStartWhileTheFirstWaitsCannotReleaseItsClaim() async {
        let clip = recorder()
        async let first = clip.startClaimingStream(from: frames)
        async let second = clip.startClaimingStream(from: frames)
        let results = await [first, second]
        XCTAssertEqual(results.filter { (try? $0.get()) != nil }.count, 1)
        XCTAssertTrue(clip.isRecording)
        XCTAssertTrue(clip.holdsStreamClaim)
        XCTAssertEqual(releases, 0, "the refused start gave nothing back")
    }

    // MARK: - The warm-up wait

    func testWarmupWaitsThroughConnectingToReady() async {
        var clock = Date(timeIntervalSince1970: 0)
        var sequence: [CameraReadiness?] = [Self.stopped, Self.connecting, Self.connecting, Self.ready]
        let result = await ClipStreamWarmup.waitForFreshEvidence(
            timeout: 20, pollInterval: 1,
            readiness: { sequence.count > 1 ? sequence.removeFirst() : sequence.first ?? nil },
            now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) })
        XCTAssertEqual(result, .ready)
        XCTAssertEqual(clock.timeIntervalSince1970, 3)
    }

    func testWarmupTimesOutWithinTheColdStartWindow() async {
        var clock = Date(timeIntervalSince1970: 0)
        let result = await ClipStreamWarmup.waitForFreshEvidence(
            readiness: { Self.connecting },
            now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) })
        guard case .timedOut = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(clock.timeIntervalSince1970, StreamRecoveryPolicy.warmupTimeout, accuracy: 0.5)
    }

    func testRecordClipToolAwaitsTheClaimingStart() async throws {
        let tool = RecordClipTool(seams: .init(
            start: { _, _ in
                try? await Task.sleep(nanoseconds: 1_000_000)
                return .success(30)
            },
            stop: { nil }, isRecording: { false }, elapsed: { 0 }))
        guard Config.fieldAssistActive else { return }
        let line = try await tool.execute(args: [:])
        XCTAssertTrue(line.hasPrefix("Recording"))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
