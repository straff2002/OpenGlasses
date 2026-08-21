import Foundation

/// Plan CQ P1 — what a camera backend can actually do.
///
/// The app was written against exactly one camera (Meta's, over DAT), which streams live frames
/// and captures stills on demand. Every other glasses camera we might support does less than
/// that, and does less in *different* ways: one class captures stills to a webhook with no local
/// frame access at all, another captures to onboard storage and needs a network hop to fetch
/// anything usable, and that same class cannot run its camera and microphone at the same time.
///
/// Rather than discover those limits one crashed feature at a time, a backend declares them up
/// front and `CameraFeatureGate` turns them into an answer a user can read.
struct CameraCapabilities: Equatable, Sendable {

    /// How long a still capture takes, from request to bytes in hand. This is a *class*, not a
    /// measurement — it exists to let a caller decide whether a capture is cheap enough to do
    /// speculatively, or expensive enough that it needs announcing first.
    enum StillLatency: String, Sendable, Equatable {
        /// Frames are already flowing; a still is effectively free.
        case immediate
        /// A round trip to the device, but fast enough to feel like a shutter.
        case subSecond
        /// A network hop, a mode change, or a file transfer. Announce before doing this.
        case seconds
    }

    /// Does the backend deliver a continuous stream of frames to the app?
    ///
    /// This is the single most consequential flag: everything that watches, tracks, recognises,
    /// records, or broadcasts is built on `CameraService.framePublisher`. Note that "the glasses
    /// can stream" is **not** the same question — hardware that pushes video to a remote ingest
    /// endpoint still gives this app nothing, so this stays false until frames actually arrive
    /// in-process.
    var liveFrames: Bool

    /// Can the backend produce a single still image on request?
    var stillCapture: Bool

    /// Cost class of `stillCapture`. Meaningless when `stillCapture` is false.
    var stillLatency: StillLatency

    /// Can the camera be used while the device's microphone is in use?
    ///
    /// False on hardware where camera and mic are mutually exclusive modes — there, a capture
    /// makes the glasses deaf for its duration, which the voice loop has to be told about rather
    /// than discovering as silence.
    var concurrentWithMic: Bool

    /// Does the backend surface button, touch, or wear events from the hardware?
    var hardwareEvents: Bool

    /// The Meta/DAT backend: the capability set the whole app was written against.
    static let meta = CameraCapabilities(
        liveFrames: true,
        stillCapture: true,
        stillLatency: .immediate,
        concurrentWithMic: true,
        hardwareEvents: false
    )

    /// No glasses camera reachable. Distinct from "a backend that can't do much" — this is the
    /// simulator, an unregistered SDK, or glasses that aren't connected.
    static let unavailable = CameraCapabilities(
        liveFrames: false,
        stillCapture: false,
        stillLatency: .seconds,
        concurrentWithMic: true,
        hardwareEvents: false
    )
}

/// Every app feature that needs something from a camera, and which capability it needs.
///
/// Deliberately named after the *feature* the user knows, not the plumbing — the whole point is
/// to be able to say "Sign Language needs a live camera feed, and these glasses don't have one".
enum CameraDependentFeature: String, CaseIterable, Sendable {
    case photoCapture
    case livePreview
    case faceRecognition
    case signLanguage
    case readingCompanion
    case sceneWatcher
    case framePinning
    case videoRecording
    case broadcast
    case expertStream
    case offlineLiveSession
    case ambientCameraCaptions

    /// Needs frames arriving continuously, not a still on request.
    var requiresLiveFrames: Bool {
        switch self {
        case .photoCapture:
            return false
        case .livePreview, .faceRecognition, .signLanguage, .readingCompanion, .sceneWatcher,
             .framePinning, .videoRecording, .broadcast, .expertStream, .offlineLiveSession,
             .ambientCameraCaptions:
            return true
        }
    }

    /// User-facing name, used in the reason copy.
    var displayName: String {
        switch self {
        case .photoCapture: return "Photo Capture"
        case .livePreview: return "Live Preview"
        case .faceRecognition: return "Face Recognition"
        case .signLanguage: return "Sign Language"
        case .readingCompanion: return "Reading Companion"
        case .sceneWatcher: return "Scene Watcher"
        case .framePinning: return "Frame Pinning"
        case .videoRecording: return "Video Recording"
        case .broadcast: return "Broadcast"
        case .expertStream: return "Expert Stream"
        case .offlineLiveSession: return "Offline Live Session"
        case .ambientCameraCaptions: return "Ambient Captions (camera)"
        }
    }
}

/// Whether a feature can run on the current backend, and if not, what to tell the user.
enum CameraFeatureAvailability: Equatable, Sendable {
    case available
    /// Runs, but not the way the user expects — carries the caveat to surface.
    case degraded(String)
    /// Cannot run at all on this hardware.
    case unavailable(String)

    var isUsable: Bool {
        switch self {
        case .available, .degraded: return true
        case .unavailable: return false
        }
    }

    /// The caveat or refusal text, nil when fully available.
    var note: String? {
        switch self {
        case .available: return nil
        case .degraded(let text), .unavailable(let text): return text
        }
    }
}

/// Pure capability → availability decisions. No hardware, no SDK, no I/O.
enum CameraFeatureGate {

    /// Whether `feature` can run given the backend's `capabilities`.
    ///
    /// `phoneFallbackAvailable` reflects a behaviour that predates this gate and must be
    /// preserved: `CameraService.capturePhoto()` falls back to the iPhone's own back camera when
    /// the glasses camera isn't usable. So photo capture stays *available* almost everywhere —
    /// but degraded, because a phone in a pocket is not pointed where the user is looking, and
    /// callers already announce that (`CameraService.lastCaptureSource`).
    ///
    /// There is no equivalent fallback for live frames: the phone fallback is a one-shot still.
    static func availability(
        of feature: CameraDependentFeature,
        given capabilities: CameraCapabilities,
        phoneFallbackAvailable: Bool = true
    ) -> CameraFeatureAvailability {
        if feature.requiresLiveFrames {
            guard capabilities.liveFrames else {
                return .unavailable(
                    "\(feature.displayName) needs a live camera feed from the glasses, and the "
                    + "connected glasses don't provide one."
                )
            }
            return .available
        }

        if capabilities.stillCapture {
            switch capabilities.stillLatency {
            case .immediate, .subSecond:
                return .available
            case .seconds:
                return .degraded(
                    "Captures from these glasses take several seconds — they're fetched from the "
                    + "glasses rather than streamed."
                )
            }
        }

        guard phoneFallbackAvailable else {
            return .unavailable("No camera is available.")
        }
        return .degraded(
            "The connected glasses can't capture photos, so the iPhone camera is used instead — "
            + "point the phone at what you want captured."
        )
    }

    /// Features that cannot run at all on this backend. Used for the honest list in Settings,
    /// rather than making the user find out one failure at a time.
    static func unavailableFeatures(
        given capabilities: CameraCapabilities,
        phoneFallbackAvailable: Bool = true
    ) -> [CameraDependentFeature] {
        CameraDependentFeature.allCases.filter {
            !availability(of: $0, given: capabilities, phoneFallbackAvailable: phoneFallbackAvailable).isUsable
        }
    }

    /// A one-line summary for the Settings device row.
    static func summary(given capabilities: CameraCapabilities) -> String {
        if capabilities.liveFrames { return "Live video and photo capture" }
        if capabilities.stillCapture {
            return capabilities.stillLatency == .seconds
                ? "Photo capture only (several seconds per photo)"
                : "Photo capture only"
        }
        return "No camera — voice and text features only"
    }
}
