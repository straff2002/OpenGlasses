import Foundation
import MWDATCamera
import MWDATCore

/// Pure mapping from the DAT SDK's typed camera `StreamError` (unified `DatError` model) to a
/// user-facing message and a capture-recovery decision.
///
/// Replaces fragile `String(describing:).contains(...)` matching with the typed enum, and decides
/// whether a *pending photo capture* should be abandoned immediately when an error arrives — so a
/// terminal condition (hinges closed, thermal/battery shutdown, device gone) falls back to the latest
/// video frame at once instead of hanging on the capture timeout. Pure and fully unit-testable.
enum CameraErrorPolicy {

    /// A short, user-facing message for a typed camera stream error.
    static func message(for error: StreamError) -> String {
        switch error {
        case .hingesClosed:
            return "Glasses hinges are closed — open them to use the camera."
        case .thermalCritical, .thermalEmergency:
            return "Glasses are too hot — let them cool down."
        case .batteryCritical:
            return "Glasses battery is too low — charge them to use the camera."
        case .peakPowerShutdown:
            return "Glasses hit a power limit — try again in a moment."
        case .permissionDenied:
            return "Camera permission is required."
        case .deviceNotConnected:
            return "Glasses disconnected — check the Bluetooth connection."
        case .deviceNotFound:
            return "Glasses not found — check that they're connected."
        case .timeout:
            return "The glasses camera timed out — try again."
        case .videoStreamingError:
            return "Glasses video streaming hit an error — try again."
        case .internalError:
            return "The glasses camera hit an internal error — try again."
        case .photoCaptureFailed:
            return "The glasses couldn't take that photo — try again."
        @unknown default:
            return error.errorDescription ?? "The glasses camera hit an error."
        }
    }

    /// Whether a pending photo capture should be abandoned (fall back to the latest frame / fail)
    /// the moment this error arrives, rather than waiting for the capture timeout. `true` for
    /// terminal conditions where the photo will not arrive; `false` for transient errors where the
    /// capture (or the existing timeout backstop) may still resolve.
    static func abortsCapture(_ error: StreamError) -> Bool {
        switch error {
        case .hingesClosed, .timeout, .thermalCritical, .thermalEmergency,
             .peakPowerShutdown, .batteryCritical, .permissionDenied,
             .deviceNotConnected, .deviceNotFound, .photoCaptureFailed:
            // .photoCaptureFailed (0.9.0, replaces the never-emitted CaptureError) is the
            // device saying THIS capture is dead — fall back to the latest frame now.
            return true
        case .internalError, .videoStreamingError:
            return false
        @unknown default:
            return false
        }
    }

    /// Whether a *warmup wait* (waiting for the stream to reach `.streaming`) should abort now
    /// rather than keep nudging `start()` until the timeout.
    ///
    /// Deliberately the inverse of `abortsCapture` for these two: a pending capture may still be
    /// rescued by its own timeout backstop, but these errors mean `start()` itself already failed,
    /// and every further nudge just replays the same cycle (field log: waiting → starting →
    /// stopping → error, three times, then a 20 s timeout that was never going to be reached).
    /// The stream has to be rebuilt, which only the caller can do.
    ///
    /// The terminal conditions (`hingesClosed`, thermal, battery, device gone) are *not* listed:
    /// whether they also arrive transiently during the ~15–18 s cold-start churn is unverified, and
    /// an over-eager abort would break exactly the healthy slow start the full timeout protects.
    /// They are still bounded by the timeout, as they are today.
    static func abortsWarmup(_ error: StreamError) -> Bool {
        switch error {
        case .internalError, .videoStreamingError:
            return true
        default:
            return false
        }
    }

    // MARK: - Retrying (Plan FD P1)

    /// Whether a bounded retry of the *stream* — another start, another rebuild, the next rung of
    /// the reconnect ladder — can succeed, given what the SDK last said went wrong.
    ///
    /// The reconnect ladder used to ask only "does anybody still want the stream", and so it spent
    /// its full ~88 s budget on failures that the first attempt had already settled: a permission
    /// the wearer revoked in the Meta AI app, a companion app that needs updating, glasses too hot
    /// to run the camera, hinges closed. None of those is a link hiccup, and retrying them is both
    /// useless and silent — the wearer waits out a minute and a half of "reconnecting" to be told
    /// nothing they could have acted on ninety seconds earlier.
    enum RetryDisposition: Equatable {
        /// A transient startup or link failure: the ladder may climb.
        case retryWithBackoff
        /// Retrying cannot succeed until something outside the app changes. `notice` is the copy
        /// that says what — written to be shown to the wearer as-is.
        case stopRetrying(notice: String)
    }

    /// Classify a camera stream error.
    ///
    /// The copy is reused from `message(for:)` rather than written twice, so a failure that stops
    /// the ladder says exactly what the same failure says anywhere else in the app.
    static func retryDisposition(for error: StreamError) -> RetryDisposition {
        switch error {
        case .permissionDenied,
             // Since 0.9.0 this also fires on a doff, so it covers both physical causes: the
             // glasses are folded, or they are off the wearer's face. Either way the camera is
             // off because a person put it that way, and the fix is theirs to make.
             .hingesClosed,
             // Device conditions. The glasses have switched the camera off to protect themselves;
             // a retry every 1.5 s neither cools them down nor charges them.
             .thermalCritical, .thermalEmergency, .peakPowerShutdown, .batteryCritical:
            return .stopRetrying(notice: message(for: error))
        case .timeout, .videoStreamingError, .internalError,
             // Deliberately transient: the link flapping is the ordinary case the ladder exists
             // for — glasses waking, a Bluetooth handshake, a walk out of range and back.
             .deviceNotConnected, .deviceNotFound:
            return .retryWithBackoff
        case .photoCaptureFailed:
            // Says nothing about the stream: one capture failed and the stream is still up. Never
            // a reason to stop a reconnect that is about something else.
            return .retryWithBackoff
        @unknown default:
            return .retryWithBackoff
        }
    }

    /// Classify a device-session error. Compatibility refusals arrive here, not on the camera
    /// stream's error publisher.
    static func retryDisposition(for error: DeviceSessionError) -> RetryDisposition {
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            return .stopRetrying(notice: DATCompatibilityMessage.message(for: error)
                                 ?? error.localizedDescription)
        case .thermalCritical, .thermalEmergency, .peakPowerShutdown, .batteryCritical:
            return .stopRetrying(notice: deviceConditionNotice)
        default:
            // Everything else is a window that closes: a link mid-wake (`noEligibleDevice`), a
            // session still tearing down on the glasses (`sessionAlreadyExists`), a capability not
            // yet freed (`capabilityAlreadyActive`). Waiting is exactly the right response.
            return .retryWithBackoff
        }
    }

    /// Shared copy for the device-level power/thermal refusals, which carry no per-case message of
    /// their own.
    static let deviceConditionNotice =
        "The glasses stopped the camera to protect themselves — let them cool down or charge them, then start the camera again."
}
