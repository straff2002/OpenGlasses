import Foundation

/// The rules for changing Blur Bystander Faces from anywhere it is offered (Plan KH, pure): the
/// switch in Settings, the row under Live Streaming, the live preview's control, and Go Live's
/// refusal. They all end at `AppState.setBystanderBlur(_:)`.
enum BystanderBlurControl {

    /// Whether whoever is holding the phone may change it. Two locks reach this switch: a profile
    /// can pin the key, and a lockdown can close the Devices & Privacy rows it lives among. A
    /// shortcut to it must not be a way round the second.
    ///
    /// Either way the state stays on show: `SettingsVisibilityPolicy.alwaysShown` is why the
    /// preview and Live Streaming draw it read-only rather than hide it.
    static func isChangeable(in context: ManagedSettingsContext) -> Bool {
        SettingsVisibilityPolicy.presentation(.key(.privacyFilterEnabled), in: context).isEditable
            && SettingsVisibilityPolicy.presentation(.row(in: .devices), in: context).isEditable
    }

    enum Action: Equatable {
        case none
        case set(Bool)
        /// Ask first: faces would go out unblurred to people watching now.
        case confirmTurningOff
    }

    /// What a request to change it does. Turning the blur on is never held up.
    static func request(_ wanted: Bool, isOn: Bool, changeable: Bool, isLive: Bool) -> Action {
        guard changeable, wanted != isOn else { return .none }
        return !wanted && isLive ? .confirmTurningOff : .set(wanted)
    }

    /// The answer when something asks for the phone camera, which can't be blurred.
    struct Refusal: Equatable {
        let message: String
        /// `false` when nobody on this phone can change it, so the alert must not offer to.
        let offersTurningOff: Bool
    }

    static func refusal(route: BroadcastGoLive.PhoneRoute = .fallback, changeable: Bool,
                        organization: String?) -> Refusal {
        if changeable {
            return Refusal(message: changeableMessage(route), offersTurningOff: true)
        }
        return Refusal(message: lockedMessage(route, who: organization ?? String(localized: "your organisation")),
                       offersTurningOff: false)
    }

    private static func changeableMessage(_ route: BroadcastGoLive.PhoneRoute) -> String {
        switch route {
        #if AVENKIN_PHONE_ONLY
        case .fallback, .chosen:
            return String(localized: "Blur Bystander Faces doesn't cover the phone camera, so Go Live is off while it's on. Turn the blur off to stream. Turning it off applies everywhere: recordings, streams and pictures sent to the assistant stop being blurred until you turn it back on.")
        #else
        case .fallback:
            return String(localized: "With no glasses connected, a stream would use the phone camera, which Blur Bystander Faces doesn't cover. Connect your glasses, or turn the blur off to stream from the phone. Turning it off applies everywhere: recordings, streams and pictures sent to the assistant stop being blurred until you turn it back on.")
        case .chosen:
            return String(localized: "Camera is set to the phone, which Blur Bystander Faces doesn't cover. Set Camera to Glasses under Live Streaming, or turn the blur off to stream from the phone. Turning it off applies everywhere: recordings, streams and pictures sent to the assistant stop being blurred until you turn it back on.")
        #endif
        case .inset:
            return String(localized: "Dual Capture puts the phone camera in the picture, and Blur Bystander Faces doesn't cover it. Turn Dual Capture off under Live Streaming, or turn the blur off. Turning it off applies everywhere: recordings, streams and pictures sent to the assistant stop being blurred until you turn it back on.")
        case .midStreamSwitch:
            return String(localized: "Blur Bystander Faces doesn't cover the phone camera, so the stream stays where it is. Turning the blur off lets you switch, but viewers will see faces straight away, and it applies everywhere until you turn it back on.")
        }
    }

    private static func lockedMessage(_ route: BroadcastGoLive.PhoneRoute, who: String) -> String {
        switch route {
        #if AVENKIN_PHONE_ONLY
        case .fallback, .chosen:
            return String(localized: "Blur Bystander Faces doesn't cover the phone camera, so Go Live is off while it's on. The blur is set by \(who).")
        #else
        case .fallback:
            return String(localized: "With no glasses connected, a stream would use the phone camera, which Blur Bystander Faces doesn't cover. The blur is set by \(who), so connect your glasses to stream.")
        case .chosen:
            return String(localized: "Camera is set to the phone, which Blur Bystander Faces doesn't cover. The blur is set by \(who), so set Camera to Glasses under Live Streaming.")
        #endif
        case .inset:
            return String(localized: "Dual Capture puts the phone camera in the picture, and Blur Bystander Faces doesn't cover it. The blur is set by \(who), so turn Dual Capture off under Live Streaming.")
        case .midStreamSwitch:
            return String(localized: "Blur Bystander Faces doesn't cover the phone camera, and it is set by \(who), so the stream stays where it is.")
        }
    }
}
