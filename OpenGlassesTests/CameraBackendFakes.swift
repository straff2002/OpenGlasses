import Combine
import UIKit
@testable import OpenGlasses

// The camera fakes, shared by every test that drives `CameraService` without hardware.
//
// They started nested inside `CameraServiceCoordinatorTests` and moved out when Plan FD's readiness
// tests needed the same two. Same types, same behaviour — a second copy would have been the more
// expensive mistake: these fakes encode what the real backend promises, and two of them drift.

/// A backend that records what it was asked to do and lets a test emit events by hand.
@MainActor
final class MockCameraBackend: GlassesCameraBackend {
    var capabilities: CameraCapabilities
    let events = PassthroughSubject<CameraBackendEvent, Never>()
    var ready: Bool
    var permissionGranted = false
    /// Records whether callers asked for the side-effecting form — the capture path must,
    /// and UI must not.
    private(set) var readyQueries: [Bool] = []

    func isReady(configuringIfNeeded: Bool) -> Bool {
        readyQueries.append(configuringIfNeeded)
        return ready
    }

    private(set) var captureCount = 0
    private(set) var startStreamingCount = 0
    private(set) var stopStreamingCount = 0
    private(set) var tearDownCount = 0
    var captureResult: Result<Data, Error> = .success(Data([0x01, 0x02, 0x03]))

    init(capabilities: CameraCapabilities = .meta, isReady: Bool = true) {
        self.capabilities = capabilities
        self.ready = isReady
    }

    func ensurePermission() async throws { permissionGranted = true }

    func capturePhoto() async throws -> Data {
        captureCount += 1
        return try captureResult.get()
    }

    /// Opt-in so the tests written before claims existed keep seeing exactly what they saw.
    var emitsStreamingEvents = false

    func startStreaming() async throws {
        startStreamingCount += 1
        if emitsStreamingEvents { events.send(.streamingChanged(true)) }
    }
    func stopStreaming() async {
        stopStreamingCount += 1
        if emitsStreamingEvents { events.send(.streamingChanged(false)) }
    }
    func tearDown() async { tearDownCount += 1 }
}

/// The iPhone-camera fallback, faked.
///
/// Every test that can reach the fallback branch has to inject this. The real
/// `PhoneCameraSource` is AVFoundation, and on a simulator whose camera privacy decision is
/// still unresolved it waits forever for a prompt no test runner can answer — so an
/// un-injected fallback doesn't fail the suite, it hangs it, and only on machines where the
/// permission hasn't already been cached by something else.
@MainActor
final class MockPhoneCamera: PhoneCameraCapturing {
    private(set) var captureCount = 0
    /// Not decodable as an image on purpose, same as the backend mock: it keeps the
    /// photo-library write out of a unit test.
    var captureResult: Result<Data, Error> = .success(Data([0xBE, 0xEF]))

    func capturePhoto() async throws -> Data {
        captureCount += 1
        return try captureResult.get()
    }
}

extension MockCameraBackend {
    /// A stream that came up. What the real backend sends when a warm-up finishes.
    func emitStreamUp() {
        events.send(.status(.streaming))
        events.send(.waitReason(nil))
        events.send(.streamingChanged(true))
    }

    /// A freshly decoded picture reached the coordinator.
    func emitFreshPicture(_ image: UIImage = UIImage(systemName: "camera")!) {
        events.send(.frame(image, fresh: true))
    }

    /// The previous picture handed over again while the decoder waits for a keyframe. The app sees
    /// an image; the world has not been looked at again.
    func emitHeldPicture(_ image: UIImage = UIImage(systemName: "camera")!) {
        events.send(.frame(image, fresh: false))
    }
}
