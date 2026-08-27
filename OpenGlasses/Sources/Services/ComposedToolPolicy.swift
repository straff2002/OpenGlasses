import Foundation

/// The composition floor: which native tools a user-authored *composition* may not reach.
///
/// `NativeToolRouter` is the only path that applies the actuation floor (`HighImpactToolPolicy`),
/// the `SafetySupervisor`, and the confirmation gate. Composition surfaces — a skill pack's `.tool`
/// binding, a Siri Action's `.tool` binding — resolve a tool from the registry and execute it
/// directly, so the router only ever sees the wrapper's harmless name (or nothing at all) and none
/// of those checks run against the real target. A pack action bound to `smart_home` with
/// `{"action":"unlock"}` would therefore actuate with no confirmation, while the identical call
/// through the model always confirms.
///
/// Until composed calls are routed through that one authority, any target the router *would* have
/// gated is refused at composition time instead. The classification is a query over the policies
/// the router itself consults, never a second hand-maintained list: adding a tool to
/// `PromptInjectionPolicy.highImpactTools` or to `HighImpactToolPolicy` contains it here too.
enum ComposedToolPolicy {

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

    /// Remediation shown on an installed pack whose actions were held back at merge time.
    static func quarantineNotice(actionNames: [String]) -> String {
        let names = actionNames.sorted().joined(separator: ", ")
        return "Turned off for safety: \(names). "
            + "These run a tool that can unlock, actuate, or share data, which only happens after "
            + "you confirm it yourself. The rest of the pack still works."
    }
}
