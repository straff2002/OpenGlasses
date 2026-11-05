import Foundation

/// The wearer's choice for map cards on the watch: Settings › Devices & Privacy › Apple Watch.
enum WatchMapCardsSetting: String, CaseIterable, Sendable {
    case automatic, onlyWhenAsked, never

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatically")
        case .onlyWhenAsked: return String(localized: "Only when I ask")
        case .never: return String(localized: "Never")
        }
    }
}

extension Config {
    /// Place, where-am-I and nearby cards on the watch (Plan GM). Automatic by default: the push
    /// is latest-wins and silent, and a card nobody looks at costs nothing.
    static var watchMapCards: WatchMapCardsSetting {
        get {
            UserDefaults.standard.string(forKey: "watchMapCards")
                .flatMap(WatchMapCardsSetting.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "watchMapCards") }
    }

    /// Lists longer than four items go to the watch without being asked (Plan GM P2).
    static var watchSendsLongLists: Bool {
        get { UserDefaults.standard.object(forKey: "watchSendsLongLists") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "watchSendsLongLists") }
    }
}

/// Plan GM P0 — when a surface goes to the wrist, whether it may draw a map, whether it taps, and
/// how long it lasts. Pure: every input is a value, so the whole table is a test.
enum GlanceSurfacePolicy {

    struct Inputs: Equatable {
        var setting: WatchMapCardsSetting
        /// "Show me on my watch" — the wearer asked for this one.
        var asked: Bool
        var watchAppInstalled: Bool
        var medical: MedicalEgressGuard.Mode
        /// Lists only: "Send long lists to watch".
        var sendsLongLists: Bool = false
    }

    enum Refusal: Equatable {
        case watchAppNotInstalled
        case settingNever
        case notAsked
        case medicalCompliance
    }

    enum Decision: Equatable {
        case send(mapAllowed: Bool, playsTap: Bool)
        case skip(Refusal)

        var isSend: Bool { if case .send = self { return true } else { return false } }
    }

    /// The decision for `kind` under `inputs`.
    static func decide(_ kind: GlanceSurface.Kind, _ inputs: Inputs) -> Decision {
        guard inputs.watchAppInstalled else { return .skip(.watchAppNotInstalled) }
        let mapAllowed = mapAllowed(inputs.medical)

        switch kind {
        case .route:
            // Guidance was itself asked for, so the route follows it to the wrist unless maps on
            // the watch are off altogether. Turn taps are P1b's haptics, not an arrival tap.
            guard inputs.setting != .never else { return .skip(.settingNever) }
            return .send(mapAllowed: mapAllowed, playsTap: false)

        case .place, .whereAmI, .places:
            switch inputs.setting {
            case .never:
                return .skip(.settingNever)
            case .onlyWhenAsked where !inputs.asked:
                return .skip(.notAsked)
            case .automatic, .onlyWhenAsked:
                // Automatic cards arrive silently; an explicit ask plays one tap.
                return .send(mapAllowed: mapAllowed, playsTap: inputs.asked)
            }

        case .list(let card):
            // Lists and images are not map content: Medical Compliance keeps them off the wrist.
            guard !inputs.medical.hipaaMode else { return .skip(.medicalCompliance) }
            if inputs.asked { return .send(mapAllowed: mapAllowed, playsTap: true) }
            if inputs.sendsLongLists, card.items.count > 4 { return .send(mapAllowed: mapAllowed, playsTap: false) }
            return .skip(.notAsked)

        case .image:
            guard !inputs.medical.hipaaMode else { return .skip(.medicalCompliance) }
            guard inputs.asked else { return .skip(.notAsked) }
            return .send(mapAllowed: mapAllowed, playsTap: true)
        }
    }

    /// Under Medical Local Only no `Map` is drawn: tiles are fetched from Apple around the
    /// wearer's position, which is location leaving the devices. Medical Compliance without Local
    /// Only changes nothing here (location, no health data).
    static func mapAllowed(_ medical: MedicalEgressGuard.Mode) -> Bool {
        !medical.isEnforcing
    }

    /// How long a card of `kind` stays up: place and places 15 min, where-am-I 5 min, a route
    /// until guidance ends (nil), lists and images until replaced (nil).
    static func lifetime(of kind: GlanceSurface.Kind) -> TimeInterval? {
        switch kind {
        case .place, .places: return 15 * 60
        case .whereAmI: return 5 * 60
        case .route, .list, .image: return nil
        }
    }
}
