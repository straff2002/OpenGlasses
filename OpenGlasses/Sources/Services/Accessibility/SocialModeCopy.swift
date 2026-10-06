import Foundation

/// What the wearer is told about Assistive Mode's Social mode (Plan HP P2 item 11), from the
/// refusal `AssistiveModePolicy` decided. Pure, so the mapping is tested headless; the settings
/// footer and the Assistive toggle both read it, so the two never disagree.
enum SocialModeCopy {

    /// Said wherever Social mode is offered or explained: what it describes, and that it does not
    /// guess at feelings (Plan HR P2 item 5 — the mode is observe-only).
    static var standingFooter: String {
        String(localized: "Social mode describes what you can see about the person in front of you: their expression, where they're looking and what they're doing. It doesn't guess how they feel.")
    }

    /// Why Social mode is not available, or nil when there is nothing to explain — it is offered,
    /// or the wearer's own switch (or the Accessibility tier) is what is off, which the switch
    /// itself already shows.
    static func refusalLine(_ refusal: AssistiveModePolicy.Refusal?) -> String? {
        switch refusal {
        case .organisationManaged:
            return String(localized: "Social mode isn't available on a phone managed by an organisation.")
        case .fieldAssistEdition:
            return String(localized: "Social mode isn't available in a Field Assist edition.")
        case .turnedOff, .accessibilityTierOff, nil:
            return nil
        }
    }

    /// Whether the wearer's Social mode switch can be changed. Not where the phone is a work tool:
    /// there, Social mode is never offered whatever the switch says, and a live switch would
    /// suggest otherwise.
    static func switchIsEditable(_ refusal: AssistiveModePolicy.Refusal?) -> Bool {
        switch refusal {
        case .organisationManaged, .fieldAssistEdition:
            return false
        case .turnedOff, .accessibilityTierOff, nil:
            return true
        }
    }
}
