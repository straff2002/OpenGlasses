import Foundation

/// Plan HP P1 item 3 — whether Assistive Mode's Social mode is offered on this phone.
///
/// Social mode once asked a model for the apparent emotional state of the person in front of the
/// wearer, which is emotion recognition (EU AI Act review §3.2), prohibited in the workplace and in
/// education whatever the consent; so it used to be refused on an organisation-managed phone and
/// under a Field Assist edition. Plan HR made it observe-only (`SocialObservationContract`,
/// `EmotionLabelFilter`), which takes it out of the Act's definition, and Plan HS P1 item 2 lifted
/// those two workplace refusals by owner decision on 2026-10-07. What is left is the wearer's own
/// switch and the Accessibility tier it belongs to. Scene mode is unaffected everywhere.
///
/// Pure: the facts are plain values, so every corner is tested without `UserDefaults`.
/// `current()` is the thin adapter that reads the real ones.
enum AssistiveModePolicy {

    struct Facts: Equatable {
        /// The Accessibility tier is on (`Config.accessibilityModeEnabled`). Assistive Mode is part
        /// of it, so without it there is no Social mode to offer.
        var accessibilityTierOn: Bool
        /// The wearer's own Social mode switch (`Config.assistiveSocialEnabled`, default on).
        var socialSwitchOn: Bool
    }

    /// Why Social mode is not offered. Both are shown by the switches themselves, so neither has
    /// copy of its own; none is shown to the wearer by its case name.
    enum Refusal: String, Equatable, CaseIterable {
        /// The wearer turned Social mode off.
        case turnedOff
        /// The Accessibility tier is off, so Assistive Mode itself is not available.
        case accessibilityTierOff
    }

    enum Decision: Equatable {
        case offered
        case notOffered(Refusal)

        var isOffered: Bool { self == .offered }

        var refusal: Refusal? {
            if case .notOffered(let refusal) = self { return refusal }
            return nil
        }
    }

    /// The rule. The wearer's switch comes first: it is the one they moved.
    static func evaluate(_ facts: Facts) -> Decision {
        if !facts.socialSwitchOn { return .notOffered(.turnedOff) }
        if !facts.accessibilityTierOn { return .notOffered(.accessibilityTierOff) }
        return .offered
    }

    /// The facts as this phone has them now.
    static func currentFacts() -> Facts {
        Facts(accessibilityTierOn: Config.accessibilityModeEnabled,
              socialSwitchOn: Config.assistiveSocialEnabled)
    }

    /// The decision as this phone has it now.
    static func current() -> Decision {
        evaluate(currentFacts())
    }
}
