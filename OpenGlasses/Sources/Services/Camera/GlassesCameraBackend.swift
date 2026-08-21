import Combine
import UIKit

/// Plan CQ P1 — the camera seam.
///
/// Companion to Plan AH's `GlassesDisplayBackend`, and created for the same reason: the app had
/// exactly one implementation of a hardware capability, wired directly into the service that
/// every feature consumes. On the display side that was fixed before a second device arrived.
/// On the camera side it wasn't, so `CameraService` imported `MWDATCamera` and roughly fifty
/// files imported `CameraService`.
///
/// The split is: a backend owns the *device* (sessions, streams, permissions, recovery), and
/// `CameraService` owns everything backend-neutral (the published state features observe, the
/// iPhone-camera fallback, saving to the photo library, the frame cache). Consumers keep talking
/// to `CameraService` and never learn a backend exists.
@MainActor
protocol GlassesCameraBackend: AnyObject {

    /// What this backend can do. Static per backend; `CameraService` republishes it so features
    /// and Settings can ask without reaching for the backend itself.
    var capabilities: CameraCapabilities { get }

    /// Everything the backend wants the coordinator to know. One stream rather than a delegate
    /// so `CameraService` can mirror it into `@Published` state in a single place.
    var events: PassthroughSubject<CameraBackendEvent, Never> { get }

    /// Whether the backend could serve a capture *right now* — registered, connected, permitted.
    ///
    /// This drives the iPhone-camera fallback decision, and it is deliberately a live check
    /// rather than a cached flag: the failure it exists to prevent is a capture that silently
    /// photographs a phone lying on a desk while the user is pointing their glasses elsewhere.
    ///
    /// - Parameter configuringIfNeeded: whether the backend may do one-time setup in order to
    ///   answer. The Meta backend configures the SDK on demand here, and **that prompts for
    ///   Bluetooth** — which is correct at a capture, and wrong from a view body that merely
    ///   wants to describe the connected device. UI passes `false` and accepts a pessimistic
    ///   answer; anything about to actually use the camera passes `true`.
    func isReady(configuringIfNeeded: Bool) -> Bool

    /// Cached permission state. Settable because the app's early-permission path grants it out
    /// of band and tells the camera about it afterwards.
    var permissionGranted: Bool { get set }

    func ensurePermission() async throws

    /// Capture a single still. Implementations return encoded image data (JPEG).
    func capturePhoto() async throws -> Data

    func startStreaming() async throws
    func stopStreaming() async

    /// Release everything. Called on mode switch and app termination.
    func tearDown() async
}

/// Status of a backend's video stream, as the UI understands it.
enum CameraStreamingStatus: String, Sendable, Equatable {
    case streaming, waiting, stopped
}

/// Backend → coordinator notifications.
enum CameraBackendEvent {
    /// A new frame, or nil to invalidate the cached frame.
    ///
    /// The nil case matters: a torn-down session's last frame must not survive to stand in for
    /// the next capture. That rule is enforced twice on purpose — here, and by the freshness
    /// check inside the backend that refuses a stale frame as a photo fallback.
    case frame(UIImage?)
    case status(CameraStreamingStatus)
    case streamingChanged(Bool)
    case debug(String)
    /// Actionable compatibility copy ("update the Meta AI app…"), or nil when compatible.
    case compatibilityNotice(String?)
    case registrationProgress(Int)
}
