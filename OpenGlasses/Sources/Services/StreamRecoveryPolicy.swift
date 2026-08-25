import Foundation
import MWDATCore
import MWDATCamera

/// Plan BR P2 — tiered camera-stream recovery + DAT compatibility messaging (pure).
///
/// Stall recovery previously tore down the whole `DeviceSession` every time. The session
/// is the expensive, slow-to-restart half (BT connection + permission state); the `Camera`
/// capability is cheap. Policy: rebuild the camera on the retained session first, and only
/// escalate to a full session reset when camera-level rebuilds keep failing. (DAT 0.9 has
/// no `removeCamera` — a rebuild is `Camera.stop()` + `addCamera(config:)` on the live
/// session; if that throws, the caller escalates.)
enum StreamRecoveryPolicy {
    enum Action: Equatable {
        /// Stop + re-add the Stream; keep the DeviceSession.
        case rebuildStream
        /// Tear down and recreate the DeviceSession too.
        case resetSession
    }

    /// Consecutive failed recoveries (0 on the first attempt after healthy streaming).
    static func action(consecutiveFailures: Int) -> Action {
        consecutiveFailures < 2 ? .rebuildStream : .resetSession
    }

    /// The longest healthy cold start observed on device — ~15–18 s of `.stopped` /
    /// `.waitingForDevice` churn before the stream reaches `.streaming`.
    static let observedColdStart: TimeInterval = 18

    /// How long one warmup attempt gives the stream to reach `.streaming`.
    ///
    /// Every attempt gets the full window, including the first. A shortened first attempt looks
    /// like it makes a broken camera fail faster, but it sits *below* `observedColdStart`, so what
    /// it actually does is make every HEALTHY cold start fail attempt one, tear the stream down,
    /// sleep and rebuild — a slow start turned into a much slower one. Failing a dead start fast
    /// is `CameraErrorPolicy.abortsWarmup`'s job, which does it in a second or two without
    /// guessing from the clock.
    static let warmupTimeout: TimeInterval = 20

    /// Whether a frame-flow stall should trigger recovery at all, given the stream's
    /// current state. `.paused` is the temple-tap system hold: frames stopping is the
    /// EXPECTED behavior, there is no app-callable resume, and tearing the stream down
    /// collapses the media channel the tap would otherwise resume. Recovery must wait
    /// it out, not "fix" it.
    static func shouldRecoverFromStall(state: StreamState?) -> Bool {
        state != .paused
    }
}

/// Chooses the effective stream configuration for a capture session (pure).
///
/// Device-traced: at low resolution the video stream can ride the *Bluetooth* radio
/// instead of WiFi, starving the concurrent HFP/LE voice link — the glasses mic goes
/// silent while frames keep flowing. Medium and above keep video on the WiFi transport.
/// So when continuous streaming will run alongside glasses-mic audio (live voice modes),
/// the configured "low" tier is floored to "medium"; discrete photo sessions keep the
/// user's setting untouched.
enum StreamConfigPolicy {
    static func effectiveResolution(requested: String, concurrentGlassesVoice: Bool) -> String {
        if concurrentGlassesVoice && requested == "low" { return "medium" }
        return requested
    }

    /// Encoded frame size each `StreamingResolution` tier delivers, keyed by the same
    /// resolution string `Config.cameraResolution` stores. Used to preview the derived encode
    /// bitrate in Settings before a stream exists; the recorder itself measures real frames.
    /// Unknown strings fall through to `.high`, matching how `CameraService` maps them.
    static func encodedSize(for resolution: String) -> (width: Int, height: Int) {
        switch resolution {
        case "low": return (360, 640)
        case "medium": return (504, 896)
        default: return (720, 1280)
        }
    }
}

/// Maps DAT compatibility signals to actionable user copy — an outdated Meta AI app or
/// glasses firmware otherwise presents as a mystery connection failure.
enum DATCompatibilityMessage {
    static func message(for error: DeviceSessionError) -> String? {
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            // Device-traced 2026-08-23: this used to say "open the Meta AI app and install the
            // pending update", and Meta AI showed no pending update — because the glasses-side DAT
            // app is a different artefact from the phone app and the firmware. Point at the screen
            // that actually opens it (Settings → Hardware & Privacy → Update Glasses App, which
            // deep-links via the SDK) rather than sending the user hunting.
            return "The glasses' companion app needs updating — Settings › Hardware & Privacy › Update Glasses App."
        default:
            return nil
        }
    }

    static func message(for compatibility: Compatibility) -> String? {
        switch compatibility {
        case .deviceUpdateRequired:
            return "Your glasses need a firmware update — open the Meta AI app to update them."
        case .sdkUpdateRequired:
            return "This version of OpenGlasses is too old for your glasses — update OpenGlasses from the App Store."
        case .compatible, .undefined:
            return nil
        @unknown default:
            return nil
        }
    }
}
