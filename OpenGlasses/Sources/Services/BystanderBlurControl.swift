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

    /// Go Live's answer when the phone camera can't be blurred.
    struct Refusal: Equatable {
        let message: String
        /// `false` when nobody on this phone can change it, so the alert must not offer to.
        let offersTurningOff: Bool
    }

    static func refusal(changeable: Bool, organization: String?) -> Refusal {
        if changeable {
            return Refusal(
                message: String(localized: "With no glasses connected, a stream would use the phone camera, which Blur Bystander Faces doesn't cover. Connect your glasses, or turn the blur off to stream from the phone. Turning it off applies everywhere: recordings, streams and pictures sent to the assistant stop being blurred until you turn it back on."),
                offersTurningOff: true)
        }
        let who = organization ?? String(localized: "your organisation")
        return Refusal(
            message: String(localized: "With no glasses connected, a stream would use the phone camera, which Blur Bystander Faces doesn't cover. The blur is set by \(who), so connect your glasses to stream."),
            offersTurningOff: false)
    }
}
