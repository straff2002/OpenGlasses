import Foundation

/// Plan KX §1: the display is offered when Display glasses connect, and turned on only when the
/// wearer says yes.
///
/// The in-lens HUD is off by default (`Config.glassesDisplayEnabled`), behind a switch a new
/// wearer has to find. The owner's rule (2026-11-11): offer it once Display glasses are connected
/// and let the wearer choose. Nothing turns on by itself, and an answer — **Turn on**, **Not now**,
/// or the switch moved by hand — is never asked for again.
///
/// Pure, so the rule is testable without glasses: `AppState` reads the inputs after the link has
/// settled and shows `DisplayOfferBanner` while `shouldOffer` says so.
enum DisplayOfferPolicy {
    /// How long after the link comes up the offer is considered, so the SDK's device lookup (which
    /// says whether this pair has a display) has settled. A link that drops inside it offers nothing.
    static let settleSeconds: Double = 3

    /// Whether to show the offer now.
    ///
    /// - `supported`: this copy offers glasses at all (`GlassesSupportPolicy.isSupported`).
    /// - `connected`: `linkState == .connected`, nothing else.
    /// - `hasDisplay`: the active display backend reports an in-lens display for the connected pair.
    /// - `hudEnabled`: the HUD switch is already on, so there is nothing to offer.
    /// - `answered`: the offer was answered, or the switch was moved by hand.
    static func shouldOffer(supported: Bool, connected: Bool, hasDisplay: Bool,
                            hudEnabled: Bool, answered: Bool) -> Bool {
        supported && connected && hasDisplay && !hudEnabled && !answered
    }

    /// What the wearer chose.
    enum Answer: Equatable {
        case turnOn
        case notNow
    }

    /// The HUD switch after `answer`, from `current`. **Not now** leaves the switch as it was.
    static func hudEnabled(after answer: Answer, current: Bool) -> Bool {
        switch answer {
        case .turnOn: return true
        case .notNow: return current
        }
    }

    static var title: String {
        String(localized: "Your glasses have a display",
               comment: "Phone banner shown once when Meta Ray-Ban Display glasses first connect.")
    }

    static var message: String {
        String(localized: "Show answers, captions and directions on it? You can change this in Devices & Privacy › Glasses.",
               comment: "Phone banner body offering to turn on the in-lens display.")
    }
}
