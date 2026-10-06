import Foundation

/// Plan HP P1 item 3 — whether Assistive Mode's Social mode is offered on this phone.
///
/// Social mode used to ask a model for the apparent emotional state of the person in front of the
/// wearer, which is emotion recognition (EU AI Act review §3.2), prohibited in the workplace and in
/// education whatever the consent. So it is never offered where this app is a work tool: on an
/// organisation-managed phone or under a Field Assist edition. Scene mode is unaffected everywhere.
/// A personal wearer keeps Social mode, with its own switch.
///
/// Plan HR made Social mode observe-only (`SocialObservationContract`, `EmotionLabelFilter`), which
/// takes it out of the Act's definition, so the legal reason for the two workplace refusals is
/// gone. They stay deliberately: lifting them is a follow-up that waits for device evidence that the
/// filter holds on real frames.
///
/// Pure: the facts are plain values, so every corner is tested without a profile, an entitlement
/// or `UserDefaults`. `current()` is the thin adapter that reads the real ones.
enum AssistiveModePolicy {

    struct Facts: Equatable {
        /// An organisation profile is in force (`PolicyEnvelope.isManaged`).
        var organisationManaged: Bool
        /// A Field Assist edition is active (`Config.fieldAssistEnabled`).
        var fieldAssistEditionActive: Bool
        /// The Accessibility tier is on (`Config.accessibilityModeEnabled`). Assistive Mode is part
        /// of it, so without it there is no Social mode to offer.
        var accessibilityTierOn: Bool
        /// The wearer's own Social mode switch (`Config.assistiveSocialEnabled`, default on).
        var socialSwitchOn: Bool
    }

    /// Why Social mode is not offered. The UI turns each into its own copy (Plan HP P2); none of
    /// them is shown to the wearer by its case name.
    enum Refusal: String, Equatable, CaseIterable {
        /// The phone is managed by an organisation: a workplace, where emotion inference is banned.
        case organisationManaged
        /// A Field Assist edition is active: a work tool, for the same reason.
        case fieldAssistEdition
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

    /// The rule. The two workplace refusals come first: they hold whatever the wearer's own switches
    /// say, and they are the reasons the wearer most needs told.
    static func evaluate(_ facts: Facts) -> Decision {
        if facts.organisationManaged { return .notOffered(.organisationManaged) }
        if facts.fieldAssistEditionActive { return .notOffered(.fieldAssistEdition) }
        if !facts.socialSwitchOn { return .notOffered(.turnedOff) }
        if !facts.accessibilityTierOn { return .notOffered(.accessibilityTierOff) }
        return .offered
    }

    /// The facts as this phone has them now.
    static func currentFacts() -> Facts {
        Facts(organisationManaged: PolicyEnvelope.isManaged,
              fieldAssistEditionActive: Config.fieldAssistEnabled,
              accessibilityTierOn: Config.accessibilityModeEnabled,
              socialSwitchOn: Config.assistiveSocialEnabled)
    }

    /// The decision as this phone has it now.
    static func current() -> Decision {
        evaluate(currentFacts())
    }
}
