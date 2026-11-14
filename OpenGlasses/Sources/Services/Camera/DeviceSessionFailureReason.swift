import Foundation
#if !AVENKIN_PHONE_ONLY
import MWDATCore
#endif
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
        #if !AVENKIN_PHONE_ONLY
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
        #else
        return nil
        #endif
    }

    var notice: String {
        #if AVENKIN_PHONE_ONLY
        return GlassesSupportPolicy.unavailableReason()
        #else
        switch self {
        case .deviceUnavailable:
            return "The glasses couldn't start the camera. In Meta AI, check Developer Mode and apply its settings to the glasses. Then try again."
        case .developerAppUnavailable:
            return "The glasses camera component isn't available. Update Meta AI, then apply Developer Mode settings to the glasses and try again."
        case .sessionEndedByDevice:
            // Plan LT §7: a session the glasses end as soon as it starts is also how an out-of-date
            // glasses install shows. Kept within the spoken-error gate's 200 characters.
            return "The glasses ended the camera session. End any broadcast in Meta AI, or close the glasses in their case for a minute. If it ends just after it starts, open Meta AI and check for a glasses update."
        }
        #endif
    }

    /// One bounded retry for a device-side start refusal; none when its component is absent.
    /// Rapid session cycling can strand the glasses in a broadcast state (Meta issue #231).
    var maximumStartAttempts: Int { self == .developerAppUnavailable ? 1 : 2 }

    static func recoveryError(_ error: Error) -> Error {
        if let reason = DeviceSessionFailureReason(error) { return CameraError.sessionUnavailable(reason) }
        return error
    }
}
