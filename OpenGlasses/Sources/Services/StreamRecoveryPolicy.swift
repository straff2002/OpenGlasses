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

    /// Delay before reconnect attempt `attempt` (0-based) after a stream we still wanted
    /// dropped to `.stopped`. `nil` once the budget is spent.
    ///
    /// The shape is earned by what is on the other end: a glasses wake plus a Bluetooth
    /// handshake can take most of a minute, so the ladder stays cheap and fast while the drop
    /// might be a hiccup, then settles to a slow poll rather than hammering a radio that is
    /// busy re-associating. It stops at ~90 s because past that the glasses are off, out of
    /// range or flat — none of which more retries fix, and all of which deserve to be said.
    static func reconnectDelay(attempt: Int) -> TimeInterval? {
        switch attempt {
        case ..<0: return nil
        case 0..<3: return 1.5     // a hiccup: back before the wearer notices
        case 3..<6: return 3
        case 6..<21: return 5      // a wake + handshake: poll, don't hammer
        default: return nil        // ~88 s spent; this is not coming back on its own
        }
    }

    /// Total wall-clock the reconnect ladder is allowed. Derived from the cadence rather than
    /// asserted, so the two can never drift apart.
    static var reconnectBudget: TimeInterval {
        var total: TimeInterval = 0
        var attempt = 0
        while let delay = reconnectDelay(attempt: attempt) {
            total += delay
            attempt += 1
        }
        return total
    }

    /// Said once when the ladder gives up. The earlier notice promised a reconnect; this one has
    /// to retract that promise, or the wearer keeps waiting on a camera that stopped trying.
    static let reconnectGaveUpNotice =
        "Camera didn't come back. Check the glasses are on and charged, then start the camera again."

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
