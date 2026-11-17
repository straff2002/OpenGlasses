import Foundation

/// Whether the assistant may build add-ons right now, and if not, why. Pure over `Conditions`, so
/// the tool's declaration, its run-time check and the tests read one rule.
///
/// Building researches the web, reads pages and calls a new service: autonomous network work.
/// - Agent Mode must be on.
/// - Not under Medical Compliance (with or without Local Only): the research and the test are
///   egress, and network add-ons are hidden there anyway.
/// - Add-ons must be on, and the organisation's policy must allow an unsigned add-on (what the
///   assistant builds is never signed) and must not forbid self-built add-ons.
/// - At most three building sessions a calendar day.
enum AddOnAuthoringAvailability {

    enum Unavailable: Equatable, Sendable {
        case agentModeOff
        case medicalCompliance
        case addOnsOff
        case policy(AddOnPolicy.Refusal)
        case organisationForbids
        case dailyLimit
    }

    struct Conditions: Equatable, Sendable {
        var agentModeEnabled = false
        var hipaaMode = false
        var localOnly = false
        var addOnsEnabled = true
        var policy: AddOnPolicy = .unmanaged
        var organisationForbidsSelfBuilt = false
    }

    static let maxSessionsPerDay = 3

    /// Why the tool isn't offered, or nil when it is. The daily limit doesn't hide the tool: the
    /// assistant says so when asked.
    static func unavailable(_ conditions: Conditions) -> Unavailable? {
        guard conditions.agentModeEnabled else { return .agentModeOff }
        if conditions.hipaaMode || conditions.localOnly { return .medicalCompliance }
        guard conditions.addOnsEnabled else { return .addOnsOff }
        if conditions.organisationForbidsSelfBuilt { return .organisationForbids }
        if let refusal = conditions.policy.refusal(for: .community) { return .policy(refusal) }
        return nil
    }

    /// Whether another session may start today.
    static func allowsAnotherSession(starts: [Date], now: Date, calendar: Calendar = .current) -> Bool {
        starts.filter { calendar.isDate($0, inSameDayAs: now) }.count < maxSessionsPerDay
    }

    static func message(_ reason: Unavailable) -> String {
        switch reason {
        case .agentModeOff:
            return String(localized: "Building add-ons needs Agent Mode, which is off.")
        case .medicalCompliance:
            return String(localized: "I can't build add-ons while Medical Compliance is on.")
        case .addOnsOff:
            return String(localized: "Add-ons are turned off in Settings.")
        case .policy(let refusal):
            return AddOnAdmission.message(for: refusal)
        case .organisationForbids:
            return String(localized: "Your organisation doesn't allow the assistant to build add-ons on this phone.")
        case .dailyLimit:
            return String(localized: "I've built as many add-ons as I can today. Try again tomorrow.")
        }
    }
}
