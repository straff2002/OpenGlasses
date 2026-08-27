import Foundation

/// The composition floor: which native tools a user-authored *composition* may not reach.
///
/// A composition — a skill pack's `.tool` binding, a Siri Action's `.tool` binding — is a target
/// and arguments a person authored once and a machine replays later, with nobody present to answer
/// for it. Composed calls reach the same authority a model call does ([[ToolAuthorizationPolicy]]),
/// carrying their resolved target and merged arguments, so the actuation floor
/// (`HighImpactToolPolicy`), the `SafetySupervisor`, and the confirmation gate *can* run on the real
/// action rather than on a harmless `pack_*` name.
///
/// What a composition may reach is nonetheless narrowed by `Mode`. The shipping default refuses any
/// target the router would have gated: admission-time rejection and merge-time quarantine already
/// keep such a binding out of the registry, and a refusal nobody has to answer is safer than a
/// prompt raised by a replayed binding. The classification is a query over the policies the router
/// itself consults, never a second hand-maintained list — adding a tool to
/// `PromptInjectionPolicy.highImpactTools` or to `HighImpactToolPolicy` contains it here too.
enum ComposedToolPolicy {

    /// What the authority does with a composition whose resolved target the router would gate.
    enum Mode: Equatable {
        /// Refuse it outright. The shipping default.
        case refuse
        /// Route it: the resolved target and merged arguments go to the same confirmation gate a
        /// direct call gets, with the composing pack named in the copy.
        case confirmResolved
    }

    /// Whether a resolved target is off-limits to composition.
    ///
    /// Classified on the tool *name* alone, with no arguments: a binding merges the caller's
    /// arguments at call time, so a target that is high-impact for any argument shape must be
    /// treated as high-impact for all of them. Empty arguments are the conservative probe —
    /// `PromptInjectionPolicy` reads an absent action as the dispatching one, and
    /// `mayRequireConfirmation` is already argument-independent.
    static func isRestrictedTarget(_ toolName: String) -> Bool {
        HighImpactToolPolicy.mayRequireConfirmation(tool: toolName)
            || PromptInjectionPolicy.isHighImpact(toolName: toolName, args: [:])
    }

    /// Why a binding to `target` can't be admitted — for an install-time rejection list.
    static func admissionReason(target: String) -> String {
        "binds to '\(target)', which takes an action the user has to confirm directly"
    }

    /// What a refused composed call tells its caller. Phrased for both the model (which must not
    /// retry) and Siri (which reads it aloud).
    static func refusalMessage(target: String) -> String {
        "'\(target)' takes an action that needs the user's direct confirmation, which a saved "
            + "shortcut or skill can't ask for, so nothing was done. Do not retry; ask the user to "
            + "run it themselves."
    }

    /// A composition reaching another composition. Chaining stays forbidden: each link would widen
    /// what a single authored binding can reach, and nothing legitimate needs it.
    static func chainingRefusal(target: String) -> String {
        "'\(target)' is itself a skill, and one skill can't call another, so nothing was done. "
            + "Do not retry."
    }

    /// A composed call that would re-enter something already running above it.
    static func cycleRefusal(target: String) -> String {
        "'\(target)' is already running further up this request, so it was not started again. "
            + "Do not retry."
    }

    /// The composition depth ceiling — a guard for future aliases and procedures, not a limit
    /// anything legitimate reaches today.
    static func depthRefusal(target: String) -> String {
        "'\(target)' was reached through too many chained skills, so it was not run. Do not retry."
    }

    /// What a composed call is told when no execution authority is wired up — a misconfigured or
    /// headless build. Composed calls fail closed there rather than executing unchecked.
    static func unroutedRefusal(target: String) -> String {
        "'\(target)' couldn't be checked for safety right now, so it was not run. Do not retry; "
            + "ask the user to try again with the app in the foreground."
    }

    /// Remediation shown on an installed pack whose actions were held back at merge time.
    static func quarantineNotice(actionNames: [String]) -> String {
        let names = actionNames.sorted().joined(separator: ", ")
        return "Turned off for safety: \(names). "
            + "These run a tool that can unlock, actuate, or share data, which only happens after "
            + "you confirm it yourself. The rest of the pack still works."
    }
}
