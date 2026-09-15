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

/// Why the backend currently is not delivering pictures.
///
/// Plan FD P0. `CameraStreamingStatus` collapses every one of these into `.waiting`, which is the
/// right amount of detail for the two call sites that grew up with it and far too little for a
/// wearer: "connecting", "paused", "nothing is arriving" and "nothing is decoding" are four
/// different situations, and only one of them is the one they can fix by putting the glasses back
/// on. Carried alongside the coarse status rather than replacing it.
///
/// Every case is something the backend **observed** — a state the SDK reported, or a verdict from
/// the decoder's own liveness clocks. Nothing here is inferred from a quiet moment, and nothing
/// here names a cause the app cannot see.
enum CameraWaitReason: String, Sendable, Equatable {
    /// A start, a warm-up or a reconnect is under way.
    case connecting
    /// The SDK paused the stream. Since DAT 0.9 a doff lands here, as do closed hinges.
    case paused
    /// The liveness clocks say nothing is arriving from the glasses at all.
    case framesUnavailable
    /// The liveness clocks say samples are arriving and none of them is becoming a picture.
    case decodingStalled
    /// A stop is in flight.
    case stopping
}

/// Backend → coordinator notifications.
enum CameraBackendEvent {
    /// A new frame, or nil to invalidate the cached frame.
    ///
    /// The nil case matters: a torn-down session's last frame must not survive to stand in for
    /// the next capture. That rule is enforced twice on purpose — here, and by the freshness
    /// check inside the backend that refuses a stale frame as a photo fallback.
    ///
    /// `fresh` says whether this picture was newly produced from this frame, or is the previous
    /// one handed over again while the decoder waits for a keyframe. The app should keep seeing a
    /// held picture — that is why one is held — but it is not a new view of the world, so it must
    /// not move the freshness clock. The distinction was already made inside the backend; carrying
    /// it across the seam is what lets the coordinator answer "how old is what I can see".
    case frame(UIImage?, fresh: Bool)
    case status(CameraStreamingStatus)
    /// Why pictures are not flowing, or nil when the backend has no such observation. Emitted on
    /// change rather than per frame.
    case waitReason(CameraWaitReason?)
    case streamingChanged(Bool)
    case debug(String)
    /// Actionable compatibility copy ("update the Meta AI app…"), or nil when compatible.
    case compatibilityNotice(String?)
    /// Transient, actionable condition the wearer can clear right now — a stream paused because
    /// the glasses were taken off, say. Deliberately not `compatibilityNotice`: telling someone to
    /// update their firmware when they simply doffed the glasses sends them somewhere useless.
    case transientNotice(String)
    case registrationProgress(Int)
}

extension CameraBackendEvent {
    /// Invalidate the cached frame. A cleared cache has nothing to be fresh about, so spelling the
    /// label out at every teardown would be noise.
    static var frameCleared: CameraBackendEvent { .frame(nil, fresh: false) }
}
