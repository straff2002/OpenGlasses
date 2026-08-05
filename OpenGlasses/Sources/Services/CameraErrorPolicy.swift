import Foundation
import MWDATCamera

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
}
