import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan CQ P1 — the backend-neutral half of `CameraService`, driven through an injected mock.
///
/// The point of the seam is that this is now testable at all: before the split, every one of
/// these behaviours sat behind `Wearables`, which traps in a unit-test process.
@MainActor
final class CameraServiceCoordinatorTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Event mirroring

    func testFrameEventsReachEveryConsumerSurface() {
        let backend = MockCameraBackend()
        let service = CameraService(backend: backend)

        var published: [UIImage] = []
        service.framePublisher.sink { published.append($0) }.store(in: &cancellables)
        var callbackFrames: [UIImage] = []
        service.onVideoFrame = { callbackFrames.append($0) }

        let frame = UIImage(systemName: "camera")!
        backend.events.send(.frame(frame, fresh: true))

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(callbackFrames.count, 1)
        XCTAssertNotNil(service.latestFrame)
    }

    func testNilFrameClearsTheCacheWithoutPublishing() {
        // A torn-down session's last frame must not survive to stand in for the next capture.
        let backend = MockCameraBackend()
        let service = CameraService(backend: backend)
        backend.events.send(.frame(UIImage(systemName: "camera")!, fresh: true))
        XCTAssertNotNil(service.latestFrame)

        var publishedAfterClear = 0
        service.framePublisher.sink { _ in publishedAfterClear += 1 }.store(in: &cancellables)
        backend.events.send(.frameCleared)

        XCTAssertNil(service.latestFrame)
        XCTAssertEqual(publishedAfterClear, 0, "a cache clear is not a frame")
    }

    func testStatusAndStreamingEventsMirrorIntoPublishedState() {
        let backend = MockCameraBackend()
        let service = CameraService(backend: backend)

        backend.events.send(.status(.waiting))
        XCTAssertEqual(service.streamingStatus, .waiting)
        backend.events.send(.streamingChanged(true))
        XCTAssertTrue(service.isStreaming)
        backend.events.send(.status(.stopped))
        backend.events.send(.streamingChanged(false))
        XCTAssertEqual(service.streamingStatus, .stopped)
        XCTAssertFalse(service.isStreaming)
    }

    func testDebugCompatibilityAndRegistrationEventsAreForwarded() {
        let backend = MockCameraBackend()
        let service = CameraService(backend: backend)

        var debugMessages: [String] = []
        service.onDebugEvent = { debugMessages.append($0) }
        var registrationStates: [Int] = []
        service.onRegistrationProgress = { registrationStates.append($0) }

        backend.events.send(.debug("stall recovery #1"))
        backend.events.send(.registrationProgress(3))
        backend.events.send(.compatibilityNotice("Update the Meta AI app"))

        XCTAssertEqual(debugMessages, ["stall recovery #1"])
        XCTAssertEqual(registrationStates, [3])
        XCTAssertEqual(service.compatibilityNotice, "Update the Meta AI app")
    }

    // MARK: - Capture routing

    func testCaptureUsesTheBackendWhenItIsReady() async throws {
        let backend = MockCameraBackend(isReady: true)
        // Not decodable as an image on purpose: keeps the photo-library write out of a unit test.
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        let phone = MockPhoneCamera()
        let service = CameraService(backend: backend, phoneCamera: phone)

        let data = try await service.capturePhoto()

        XCTAssertEqual(data, Data([0xDE, 0xAD]))
        XCTAssertEqual(backend.captureCount, 1)
        XCTAssertEqual(phone.captureCount, 0, "usable glasses must not be second-guessed")
        XCTAssertEqual(service.lastCaptureSource, .glasses)
    }

    func testCaptureSkipsTheBackendWhenItIsNotReady() async throws {
        // The phone fallback exists so vision tools work without glasses. What matters here is
        // the absence: an unready backend must not be asked, because a failed glasses capture
        // silently served by the phone photographs a desk, not what the user is looking at.
        let backend = MockCameraBackend(isReady: false)
        let phone = MockPhoneCamera()
        let service = CameraService(backend: backend, phoneCamera: phone)

        let data = try await service.capturePhoto()

        XCTAssertEqual(backend.captureCount, 0)
        XCTAssertEqual(phone.captureCount, 1)
        XCTAssertEqual(data, Data([0xBE, 0xEF]))
        XCTAssertEqual(service.lastCaptureSource, .phone, "callers announce a phone capture")
    }

    func testCaptureSkipsABackendThatCannotTakeStills() async throws {
        let noStills = CameraCapabilities(
            liveFrames: false,
            stillCapture: false,
            stillLatency: .seconds,
            concurrentWithMic: true,
            hardwareEvents: false
        )
        let backend = MockCameraBackend(capabilities: noStills, isReady: true)
        let phone = MockPhoneCamera()
        let service = CameraService(backend: backend, phoneCamera: phone)

        let data = try await service.capturePhoto()

        XCTAssertEqual(backend.captureCount, 0)
        XCTAssertEqual(phone.captureCount, 1, "the phone is the only camera left")
        XCTAssertEqual(data, Data([0xBE, 0xEF]))
        XCTAssertEqual(service.lastCaptureSource, .phone)
    }

    func testCaptureFailureFromAReadyBackendPropagates() async {
        // A ready backend that fails must FAIL, not fall through to the phone camera.
        struct Boom: Error {}
        let backend = MockCameraBackend(isReady: true)
        backend.captureResult = .failure(Boom())
        let phone = MockPhoneCamera()
        let service = CameraService(backend: backend, phoneCamera: phone)

        do {
            _ = try await service.capturePhoto()
            XCTFail("expected the backend failure to propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(backend.captureCount, 1)
        XCTAssertEqual(phone.captureCount, 0, "a wrong-camera photo is worse than an error")
    }

    // MARK: - Streaming gate

    func testStreamingIsRefusedWithAReadableReasonWhenThereIsNoLiveFeed() async {
        let stillsOnly = CameraCapabilities(
            liveFrames: false,
            stillCapture: true,
            stillLatency: .subSecond,
            concurrentWithMic: true,
            hardwareEvents: true
        )
        let backend = MockCameraBackend(capabilities: stillsOnly)
        let service = CameraService(backend: backend)

        do {
            try await service.startStreaming()
            XCTFail("expected the gate to refuse streaming")
        } catch let error as CameraError {
            guard case .unsupported(let reason) = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("live camera feed"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(backend.startStreamingCount, 0)
    }

    func testStreamingProceedsOnABackendWithLiveFrames() async throws {
        let backend = MockCameraBackend(capabilities: .meta)
        let service = CameraService(backend: backend)

        try await service.startStreaming()
        await service.stopStreaming()

        XCTAssertEqual(backend.startStreamingCount, 1)
        XCTAssertEqual(backend.stopStreamingCount, 1)
    }

    // MARK: - Stream claims (Plan CV)

    private func makeClaimService() -> (CameraService, MockCameraBackend) {
        let backend = MockCameraBackend(capabilities: .meta)
        backend.emitsStreamingEvents = true
        return (CameraService(backend: backend), backend)
    }

    func testAClaimStartsTheStreamAndReleasingItStopsIt() async throws {
        let (service, backend) = makeClaimService()

        try await service.claimStream(for: .sceneNarration)
        XCTAssertEqual(backend.startStreamingCount, 1)
        XCTAssertTrue(service.hasStreamClaims)
        XCTAssertTrue(service.holdsStreamClaim(.sceneNarration))

        await service.releaseStream(for: .sceneNarration)
        XCTAssertEqual(backend.stopStreamingCount, 1)
        XCTAssertFalse(service.hasStreamClaims)
    }

    func testOneOwnerLeavingDoesNotStopAStreamAnotherStillHolds() async throws {
        let (service, backend) = makeClaimService()

        try await service.claimStream(for: .sceneNarration)
        try await service.claimStream(for: .fingerspelling)
        XCTAssertEqual(backend.startStreamingCount, 1, "The second claim joins rather than restarts")

        await service.releaseStream(for: .fingerspelling)
        XCTAssertEqual(backend.stopStreamingCount, 0,
                       "Narration is walking the wearer down a corridor with this stream")

        await service.releaseStream(for: .sceneNarration)
        XCTAssertEqual(backend.stopStreamingCount, 1)
    }

    func testAClaimNeverStopsAStreamItDidNotStart() async throws {
        let (service, backend) = makeClaimService()

        try await service.startStreaming()          // e.g. the manual control, or a live session
        try await service.claimStream(for: .sceneNarration)
        XCTAssertEqual(backend.startStreamingCount, 1)

        await service.releaseStream(for: .sceneNarration)
        XCTAssertEqual(backend.stopStreamingCount, 0,
                       "Ending narration must not close a stream somebody else opened")
    }

    func testAnUnclaimedConsumerKeepsTheStreamAlive() async throws {
        let (service, backend) = makeClaimService()
        service.otherStreamConsumersActive = { true }   // recording / broadcast / a live session

        try await service.claimStream(for: .sceneNarration)
        await service.releaseStream(for: .sceneNarration)
        XCTAssertEqual(backend.stopStreamingCount, 0)
    }

    func testAFailedClaimLeavesNoClaimBehind() async {
        let stillsOnly = CameraCapabilities(
            liveFrames: false,
            stillCapture: true,
            stillLatency: .subSecond,
            concurrentWithMic: true,
            hardwareEvents: true
        )
        let backend = MockCameraBackend(capabilities: stillsOnly)
        let service = CameraService(backend: backend)

        do {
            try await service.claimStream(for: .sceneNarration)
            XCTFail("expected the tier gate to refuse")
        } catch {
            // expected
        }
        XCTAssertFalse(service.hasStreamClaims,
                       "A claim on a stream that never came up would make a later release think it had something to give back")
    }

    func testTearDownForgetsEveryClaim() async throws {
        let (service, _) = makeClaimService()
        try await service.claimStream(for: .sceneNarration)
        await service.tearDown()
        XCTAssertFalse(service.hasStreamClaims, "No claim describes a camera that no longer exists")
    }

    // MARK: - Pass-through

    func testPermissionFlagAndTearDownDelegateToTheBackend() async {
        let backend = MockCameraBackend()
        let service = CameraService(backend: backend)

        service.permissionGranted = true
        XCTAssertTrue(backend.permissionGranted)
        XCTAssertTrue(service.permissionGranted)

        backend.events.send(.frame(UIImage(systemName: "camera")!, fresh: true))
        await service.tearDown()

        XCTAssertEqual(backend.tearDownCount, 1)
        XCTAssertNil(service.latestFrame)
    }

    func testActiveCapabilitiesReflectReadiness() {
        let backend = MockCameraBackend(isReady: false)
        let service = CameraService(backend: backend)
        XCTAssertNil(service.activeCapabilities, "an unreachable camera is not a connected one")

        backend.ready = true
        XCTAssertEqual(service.activeCapabilities, .meta)
    }

    func testReadinessSideEffectsAreAskedForOnlyOnTheCapturePath() async {
        // Configuring the Meta SDK prompts for Bluetooth. That is correct at a capture and
        // wrong from a view body describing the connected device, so the two callers must ask
        // different questions.
        let backend = MockCameraBackend(isReady: true)
        let service = CameraService(backend: backend, phoneCamera: MockPhoneCamera())

        _ = service.activeCapabilities
        XCTAssertEqual(backend.readyQueries, [false])

        backend.captureResult = .success(Data([0xDE, 0xAD]))
        _ = try? await service.capturePhoto()
        XCTAssertEqual(backend.readyQueries, [false, true])
    }
}
