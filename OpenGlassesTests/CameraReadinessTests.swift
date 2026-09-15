import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FD P0 — camera readiness, driven through the real `CameraService` over a fake backend.
///
/// The asserts are deliberately taken at the *boundary a consumer actually uses* wherever there is
/// one — `filteredStill(for:)`'s outcome, the control bar's label source, the status chip, the
/// preview's accessibility label — rather than only on the enum. An enum that says `paused` while a
/// button still says "Streaming" has fixed nothing, and that gap is exactly what this plan is about.
@MainActor
final class CameraReadinessTests: XCTestCase {

    /// A clock the test moves by hand, so a frame can be aged without waiting for it to age.
    private final class FakeClock {
        private(set) var now: TimeInterval = 100
        func advance(by delta: TimeInterval) { now += delta }
    }

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeService() -> (CameraService, MockCameraBackend, FakeClock) {
        let backend = MockCameraBackend(capabilities: .meta)
        let clock = FakeClock()
        let service = CameraService(backend: backend, phoneCamera: MockPhoneCamera())
        service.monotonicClock = { clock.now }
        return (service, backend, clock)
    }

    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    // MARK: - The phase table (pure)

    func testAnObservedReasonBeatsEveryFlag() {
        // The ordering rule: what the backend *watched happen* outranks the stream flag, because
        // `isStreaming` stays true across a pause and across a decoder that has stopped producing.
        for reason: CameraWaitReason in [.paused, .decodingStalled, .framesUnavailable, .stopping] {
            let readiness = CameraReadiness.derive(waitReason: reason,
                                                   streamIsUp: true,
                                                   startIsPending: false,
                                                   userWantsStream: true,
                                                   frameAge: 0,
                                                   session: 1)
            XCTAssertNotEqual(readiness.phase, .ready,
                              "\(reason) with a brand-new frame still must not read as ready")
            XCTAssertFalse(readiness.hasFreshVisualEvidence)
        }
    }

    func testAStreamWithNoPictureYetIsAwaitingNotReady() {
        let readiness = CameraReadiness.derive(waitReason: nil, streamIsUp: true,
                                               startIsPending: false, userWantsStream: true,
                                               frameAge: nil, session: 1)
        XCTAssertEqual(readiness.phase, .awaitingFirstFrame)
        XCTAssertFalse(readiness.hasFreshVisualEvidence)
    }

    func testAPendingStartWithNoStreamIsConnectingNotStopped() {
        let readiness = CameraReadiness.derive(waitReason: nil, streamIsUp: false,
                                               startIsPending: true, userWantsStream: true,
                                               frameAge: nil, session: 1)
        XCTAssertEqual(readiness.phase, .connecting)
    }

    func testAgeIsWhatSeparatesReadyFromUsableEvidence() {
        func evidence(at age: TimeInterval) -> Bool {
            CameraReadiness.derive(waitReason: nil, streamIsUp: true, startIsPending: false,
                                   userWantsStream: true, frameAge: age, session: 1)
                .hasFreshVisualEvidence
        }
        XCTAssertTrue(evidence(at: CameraReadiness.evidenceMaxAge), "at the limit, still usable")
        XCTAssertFalse(evidence(at: CameraReadiness.evidenceMaxAge + 0.01), "past the limit, not")
    }

    func testTheFreshnessCeilingSitsAboveTheStallThreshold() {
        // Not a taste question: if this dropped below the stall threshold, readiness would start
        // refusing evidence before the backend's detector noticed anything, and the app would have
        // two disagreeing stall detectors instead of one authoritative one.
        XCTAssertGreaterThan(CameraReadiness.evidenceMaxAge, StreamLiveness.stallThreshold)
    }

    // MARK: - Through the service, over a fake backend

    func testConnectedWithNoFramesReportsAwaitingFirstFrame() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true

        try await service.startStreaming()
        backend.emitStreamUp()

        XCTAssertEqual(service.readiness.phase, .awaitingFirstFrame)
        XCTAssertTrue(service.readiness.userWantsStream)
        XCTAssertNil(service.readiness.frameAge, "no picture is not the same as an old one")
    }

    func testAFreshlyDecodedPictureIsReadyWithNoAge() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()

        backend.emitFreshPicture(image())

        XCTAssertEqual(service.readiness.phase, .ready)
        XCTAssertEqual(service.readiness.frameAge ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(service.readinessNow.hasFreshVisualEvidence)
    }

    func testAHeldPictureDoesNotRefreshTheClock() async throws {
        // The decoder hands the previous picture over again while it waits for a keyframe. The app
        // should keep seeing it; it is not a new look at the world and must not read as one.
        let (service, backend, clock) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        clock.advance(by: 5)
        backend.emitHeldPicture(image())

        XCTAssertGreaterThan(service.readinessNow.frameAge ?? 0, 4.9)
        XCTAssertFalse(service.readinessNow.hasFreshVisualEvidence)
    }

    func testSamplesArrivingWithoutDecodingReportDecodingStalled() async throws {
        // The verdict comes from the backend's own liveness clocks — this asserts the coordinator
        // reports what it was told rather than inventing a second detector.
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        backend.events.send(.waitReason(.decodingStalled))

        XCTAssertEqual(service.readiness.phase, .decodingStalled)
        XCTAssertFalse(service.readinessNow.hasFreshVisualEvidence,
                       "a stalled decoder's last picture is not a current view")
    }

    func testNothingArrivingAtAllReportsFramesUnavailable() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()

        backend.events.send(.waitReason(.framesUnavailable))

        XCTAssertEqual(service.readiness.phase, .framesUnavailable)
    }

    func testAPausedStreamReportsPausedRatherThanStreaming() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        // What the real backend sends on a doff since DAT 0.9.
        backend.events.send(.streamingChanged(false))
        backend.events.send(.status(.waiting))
        backend.events.send(.waitReason(.paused))

        XCTAssertEqual(service.readiness.phase, .paused)
        XCTAssertFalse(service.readinessNow.hasFreshVisualEvidence)
    }

    func testDisconnectClearsReadinessAndTheEvidenceWithIt() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())
        XCTAssertEqual(service.readiness.phase, .ready)

        // The backend invalidating its cache is what a disconnect looks like from here.
        backend.events.send(.frameCleared)
        backend.events.send(.streamingChanged(false))
        backend.events.send(.status(.stopped))

        XCTAssertEqual(service.readiness.phase, .stopped)
        XCTAssertNil(service.readiness.frameAge)
        XCTAssertFalse(service.hasLatestStill)
    }

    func testASnapshotFromABeforeSessionIsRecognisedAsStale() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())
        let held = service.readiness
        XCTAssertTrue(service.isCurrent(held))

        // Stop and start again: same camera, different session.
        await service.stopStreaming()
        try await service.startStreaming()
        backend.emitStreamUp()

        XCTAssertFalse(service.isCurrent(held),
                       "a snapshot from the session before must not pass for one about this camera")
        XCTAssertTrue(service.isCurrent(service.readiness))
    }

    func testStoppingForgetsTheLastPicturesAge() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        await service.stopStreaming()

        XCTAssertEqual(service.readiness.phase, .stopped)
        XCTAssertNil(service.readiness.frameAge)
        XCTAssertFalse(service.readiness.userWantsStream)
    }

    // MARK: - The evidence boundary: `filteredStill(for:)`

    func testAStaleCachedPictureIsRefusedAsEvidenceEvenThoughOneExists() async throws {
        let (service, backend, clock) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        clock.advance(by: CameraReadiness.evidenceMaxAge + 1)

        let result = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameOnly)
        XCTAssertNil(result.image, "the previous room is a wrong answer, not a partial one")
        XCTAssertEqual(result.unavailableReason, .noFreshView)
        XCTAssertTrue(service.hasLatestStill,
                      "the picture is still cached — the refusal is about its age, not its absence")
    }

    func testAFreshCachedPictureStillSatisfiesAStillReader() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())

        let result = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameOnly)
        XCTAssertNotNil(result.image)
    }

    func testAStalePictureFallsThroughToACaptureWhenTheReaderAllowsOne() async throws {
        // `cachedFrameThenPhoto` readers have a bounded acquisition contract of their own, and a
        // stale cache is exactly the situation it exists for.
        let (service, backend, clock) = makeService()
        backend.ready = true
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())
        clock.advance(by: CameraReadiness.evidenceMaxAge + 1)

        _ = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameThenPhoto)

        XCTAssertEqual(backend.captureCount, 1,
                       "a reader that may take a photo takes one rather than reusing a stale frame")
    }

    func testAPausedStreamsLastPictureCannotAnswerAVisionQuestion() async throws {
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())
        backend.events.send(.streamingChanged(false))
        backend.events.send(.waitReason(.paused))

        let result = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameOnly)
        XCTAssertEqual(result.unavailableReason, .noFreshView)
    }

    func testNoPictureAtAllStillReadsAsNoStill() async {
        // The two refusals must stay distinguishable: one says the camera gave nothing, the other
        // says the only thing it gave is old, and they suggest different next moves.
        let (service, _, _) = makeService()
        let result = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameOnly)
        XCTAssertEqual(result.unavailableReason, .noStill)
    }

    func testTheFilterReasonsAreNotTreatedAsRetryable() {
        XCTAssertTrue(FilteredStillResult.Reason.noStill.mayFallBackToCapture)
        XCTAssertTrue(FilteredStillResult.Reason.noFreshView.mayFallBackToCapture)
        XCTAssertFalse(FilteredStillResult.Reason.filterNotWired.mayFallBackToCapture,
                       "retrying past a closed privacy gate is what the gate exists to stop")
        XCTAssertFalse(FilteredStillResult.Reason.filterUnavailable.mayFallBackToCapture)
    }

    // MARK: - No deadlock: starting never requires frames

    func testStartingTheStreamNeverRequiresAPicture() async throws {
        let (service, backend, _) = makeService()
        XCTAssertEqual(service.readiness.phase, .stopped)
        XCTAssertFalse(service.hasLatestStill)

        let started = try await service.startStreaming()

        XCTAssertTrue(started)
        XCTAssertEqual(backend.startStreamingCount, 1,
                       "Start must be reachable from a camera that has never produced a frame")
    }

    func testALiveSessionsCameraClaimComesUpWithNoFramesAnywhere() async throws {
        // The live-session start handler claims the stream and reads back whether it holds the
        // claim. Nothing in that path may depend on a picture having arrived.
        let (service, backend, _) = makeService()
        backend.emitsStreamingEvents = true

        try await service.claimStream(for: .liveSession)

        XCTAssertTrue(service.holdsStreamClaim(.liveSession))
        XCTAssertEqual(backend.startStreamingCount, 1)
        XCTAssertFalse(service.readinessNow.hasFreshVisualEvidence,
                       "the claim is held and there is still no evidence — both are true at once")
    }

    func testAnAudioOnlyTurnProceedsWithTheCameraStopped() async {
        // "Audio-only works" means: nothing about the stopped camera throws, blocks, or starts it.
        // The vision path simply declines, which is what makes the turn text-only rather than stuck.
        let (service, backend, _) = makeService()

        let result = await service.filteredStill(for: .onDeviceVision, source: .cachedFrameOnly)

        XCTAssertEqual(result.unavailableReason, .noStill)
        XCTAssertEqual(service.readiness.phase, .stopped)
        XCTAssertEqual(backend.startStreamingCount, 0, "a turn without vision starts no camera")
        XCTAssertEqual(backend.captureCount, 0)
    }

    func testAOneOffCaptureKeepsItsOwnContractAndIgnoresTheFreshnessCeiling() async throws {
        // `capturePhoto()` acquires its own picture and is not served from the cache, so an aged
        // cache must not refuse it. This is the path `look_closely` and the photo button take.
        let (service, backend, clock) = makeService()
        backend.ready = true
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        backend.emitsStreamingEvents = true
        try await service.startStreaming()
        backend.emitStreamUp()
        backend.emitFreshPicture(image())
        clock.advance(by: 60)

        let data = try await service.capturePhoto()

        XCTAssertEqual(data, Data([0xDE, 0xAD]))
        XCTAssertEqual(backend.captureCount, 1)
    }

    // MARK: - What the surfaces say

    func testEveryPhaseHasItsOwnControlLabelAndSentence() {
        var labels: Set<String> = []
        var phrases: Set<String> = []
        for phase in CameraReadiness.Phase.allCases {
            let readiness = CameraReadiness(phase: phase, frameAge: nil,
                                            session: 1, userWantsStream: true)
            labels.insert(readiness.controlLabel)
            phrases.insert(readiness.statusPhrase)
            XCTAssertNotNil(readiness.controlHint, "\(phase) has no hint for a VoiceOver user")
        }
        XCTAssertEqual(labels.count, CameraReadiness.Phase.allCases.count,
                       "two phases sharing a label is how 'Streaming' came to cover 'paused'")
        XCTAssertEqual(phrases.count, CameraReadiness.Phase.allCases.count)
    }

    func testTheControlNeverSaysStreamingForAPausedOrStalledCamera() {
        for phase: CameraReadiness.Phase in [.paused, .framesUnavailable, .decodingStalled,
                                             .awaitingFirstFrame, .connecting] {
            let readiness = CameraReadiness(phase: phase, frameAge: 0,
                                            session: 1, userWantsStream: true)
            XCTAssertNotEqual(readiness.controlLabel, "Streaming")
            XCTAssertFalse(readiness.controlHint?.contains("already streaming") ?? false)
        }
    }

    func testTheStatusChipIsGreenOnlyWhilePicturesFlow() {
        let ready = CameraReadiness(phase: .ready, frameAge: 0, session: 1, userWantsStream: true)
        XCTAssertEqual(ready.statusChip?.isHealthy, true)
        XCTAssertEqual(ready.statusChip?.label, "CAM")

        for phase: CameraReadiness.Phase in [.paused, .framesUnavailable, .decodingStalled,
                                             .connecting, .awaitingFirstFrame] {
            let readiness = CameraReadiness(phase: phase, frameAge: 0,
                                            session: 1, userWantsStream: true)
            XCTAssertEqual(readiness.statusChip?.isHealthy, false, "\(phase) is not a healthy camera")
            XCTAssertNotNil(readiness.statusChip?.spoken)
        }
    }

    func testTheStatusChipDisappearsWhenThereIsNoCameraToReportOn() {
        let stopped = CameraReadiness.cleared(session: 1)
        XCTAssertNil(stopped.statusChip)
    }

    func testAHeldPreviewIsMarkedAndSaysSoToVoiceOver() {
        for phase: CameraReadiness.Phase in [.paused, .framesUnavailable, .decodingStalled,
                                             .connecting, .stopped] {
            let readiness = CameraReadiness(phase: phase, frameAge: 30,
                                            session: 1, userWantsStream: true)
            let marker = readiness.heldPictureMarker
            XCTAssertNotNil(marker, "\(phase) is showing a picture that is not a live view")
            XCTAssertTrue(marker?.localizedCaseInsensitiveContains("not a live view") ?? false,
                          "the marker has to say what the picture is not: \(marker ?? "nil")")
            XCTAssertEqual(readiness.previewAccessibilityLabel, marker,
                           "a held picture read out as a live feed is the same untruth, spoken")
        }
    }

    func testALivePreviewIsLabelledAsOneOnlyWhenItReallyIs() {
        let live = CameraReadiness(phase: .ready, frameAge: 0, session: 1, userWantsStream: true)
        XCTAssertNil(live.heldPictureMarker)
        XCTAssertEqual(live.previewAccessibilityLabel, "Live camera feed from glasses")

        let aged = CameraReadiness(phase: .ready, frameAge: 30, session: 1, userWantsStream: true)
        XCTAssertNotNil(aged.heldPictureMarker, "a ready stream whose pictures aged is still held")
    }

    func testNoticeCopyNamesNoCauseTheAppCannotSee() {
        // The plan's copy rule, asserted rather than remembered: rapid start failures must not be
        // turned into claims about another app owning the camera, about whether the glasses are
        // being worn, or about needing a power cycle.
        let forbidden = ["another app", "restart your glasses", "reboot", "power cycle",
                         "you took", "took them off", "turn your glasses off"]
        var corpus = [CameraStreamStatePolicy.pausedNotice,
                      CameraStreamStatePolicy.stoppedNotice,
                      CameraStreamStatePolicy.coldStartHint]
        for phase in CameraReadiness.Phase.allCases {
            let readiness = CameraReadiness(phase: phase, frameAge: 30,
                                            session: 1, userWantsStream: true)
            corpus.append(readiness.statusPhrase)
            corpus.append(readiness.controlHint ?? "")
            corpus.append(readiness.heldPictureMarker ?? "")
        }
        for line in corpus {
            for phrase in forbidden {
                XCTAssertFalse(line.localizedCaseInsensitiveContains(phrase),
                               "\"\(line)\" infers \"\(phrase)\", which the app cannot observe")
            }
        }
    }

    func testNoUserFacingCameraCopyNamesAnInternalPlan() {
        // House rule: plan letters live in code comments, never in a rendered string.
        for phase in CameraReadiness.Phase.allCases {
            let readiness = CameraReadiness(phase: phase, frameAge: 30,
                                            session: 1, userWantsStream: true)
            for line in [readiness.controlLabel, readiness.statusPhrase,
                         readiness.controlHint ?? "", readiness.heldPictureMarker ?? "",
                         readiness.previewAccessibilityLabel] {
                XCTAssertFalse(line.contains("Plan "), "\(line) names an internal plan")
            }
        }
    }
}
