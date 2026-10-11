import Foundation
import MWDATCore

/// The SDK wraps several different startup failures in `unexpectedError(String)`. Keep only
/// exact, known reasons: an arbitrary SDK payload must never become a public log or AI prompt.
enum DeviceSessionFailureReason: String, Equatable {
    case deviceUnavailable
    case sessionEndedByDevice
    case developerAppUnavailable

    init?(_ error: Error) {
        if let cameraError = error as? CameraError, case .sessionUnavailable(let reason) = cameraError {
            self = reason
            return
        }
        guard let sessionError = error as? DeviceSessionError else { return nil }
        switch sessionError {
        case .dwaUnavailable:
            self = .developerAppUnavailable
        case .unexpectedError(let description):
            switch description.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Device unavailable": self = .deviceUnavailable
            case "Session ended by device": self = .sessionEndedByDevice
            default: return nil
            }
        default: return nil
        }
    }

    var notice: String {
        switch self {
        case .deviceUnavailable:
            return "The glasses couldn't start the camera. In Meta AI, check Developer Mode and apply its settings to the glasses. Then try again."
        case .developerAppUnavailable:
            return "The glasses camera component isn't available. Update Meta AI, then apply Developer Mode settings to the glasses and try again."
        case .sessionEndedByDevice:
            return "The glasses ended the camera session. End any broadcast in Meta AI. If it keeps happening, put the glasses in their case, close it for a minute, then try again."
        }
    }

    /// One bounded retry for a device-side start refusal; none when its component is absent.
    /// Rapid session cycling can strand the glasses in a broadcast state (Meta issue #231).
    var maximumStartAttempts: Int { self == .developerAppUnavailable ? 1 : 2 }

    static func recoveryError(_ error: Error) -> Error {
        if let reason = DeviceSessionFailureReason(error) { return CameraError.sessionUnavailable(reason) }
        return error
    }
}
