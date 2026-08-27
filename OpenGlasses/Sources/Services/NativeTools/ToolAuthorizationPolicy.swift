import Foundation

/// Why a call was refused outright — recorded on the security event, never shown to the user.
enum ToolRefusalReason: String, Sendable, Equatable {
    case packChaining
    case parentCycle
    case depthLimit
    case restrictedTarget
}

/// What the authority decided about one resolved call. Carrying the model-facing text here (rather
/// than building it at the dispatch site) is what lets a test assert a verdict without executing a
/// tool or presenting a confirmation.
enum ToolAuthorizationDecision: Equatable {
    case allow
    /// The composition floor refused it: nothing executes, nothing is confirmed.
    case refuse(reason: ToolRefusalReason, message: String)
    /// A deterministic safety rule vetoed it.
    case block(message: String)
    /// The presence autonomy ceiling held an acting call for re-engagement.
    case hold(summary: String, message: String)
    /// Requires human approval before it runs; `summary` is the confirmation copy.
    case confirm(summary: String)
}

/// The single policy evaluation behind every tool call, split out from dispatch so a decision can
/// be asserted in isolation — no registry, no confirmation UI, no global `Config`.
///
/// Order matches the ladder the router has always applied: the composition floor first (a
/// user-authored binding replayed by a machine), then the agent-mode-off actuation floor
/// ([[HighImpactToolPolicy]]), then the deterministic supervisor ([[SafetySupervisor]]) when agent
/// mode is on. The two build-mode halves stay mutually exclusive so a high-impact call is never
/// confirmed twice.
enum ToolAuthorizationPolicy {

    struct Input {
        let call: ResolvedToolCall
        let agentModeEnabled: Bool
        /// Supervisor context; only consulted when agent mode is on.
        let safetyContext: SafetyContext
        /// How a composition whose resolved target the router would gate is handled.
        let composedTargets: ComposedToolPolicy.Mode

        /// The default context has no rules enabled and reads no settings — the router always
        /// passes a live one, so this keeps a policy assertion free of global state.
        init(call: ResolvedToolCall, agentModeEnabled: Bool,
             safetyContext: SafetyContext = SafetyContext(
                now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                quietHoursStart: 0, quietHoursEnd: 0),
             composedTargets: ComposedToolPolicy.Mode = .refuse) {
            self.call = call
            self.agentModeEnabled = agentModeEnabled
            self.safetyContext = safetyContext
            self.composedTargets = composedTargets
        }
    }

    static func evaluate(_ input: Input) -> ToolAuthorizationDecision {
        let call = input.call
        let name = call.name
        let args = call.arguments.rawValues
        let context = call.context

        // 0. Composition floor. A binding is authored once and replayed by a machine, so the
        //    structural limits apply before any argument is looked at.
        if context.depth > 0, name.hasPrefix(SkillPackToolWrapper.namePrefix) {
            return .refuse(reason: .packChaining, message: ComposedToolPolicy.chainingRefusal(target: name))
        }
        if context.depth > 0, context.wouldCycle(name) {
            return .refuse(reason: .parentCycle, message: ComposedToolPolicy.cycleRefusal(target: name))
        }
        if context.depth > ToolInvocationContext.maxDepth {
            return .refuse(reason: .depthLimit, message: ComposedToolPolicy.depthRefusal(target: name))
        }
        if context.origin.isComposition, input.composedTargets == .refuse,
           ComposedToolPolicy.isRestrictedTarget(name) {
            return .refuse(reason: .restrictedTarget, message: ComposedToolPolicy.refusalMessage(target: name))
        }

        // 1. Actuation floor (Plan BC): confirmation before irreversible, security-relevant physical
        //    actions even when agent mode is OFF, so a prompt-injected sign or web result can't
        //    silently actuate. With agent mode on, the supervisor below already covers these tools
        //    and this floor would only double-prompt.
        if !input.agentModeEnabled, HighImpactToolPolicy.mayRequireConfirmation(tool: name),
           case .requiresConfirmation(let summary) = HighImpactToolPolicy.evaluate(tool: name, args: args) {
            return .confirm(summary: attributed(summary, call: call))
        }

        // 2. Deterministic safety supervisor (Plan S) — the single pre-execution gate when agent
        //    mode is on. Even if untrusted content talked the model into a destructive tool, nothing
        //    runs without this.
        guard input.agentModeEnabled else { return .allow }
        switch SafetySupervisor.evaluate(tool: name, args: args, context: input.safetyContext) {
        case .allow:
            return .allow
        case .block(let reason):
            // Plan W: when the block is the presence autonomy ceiling on an acting tool (the user
            // is idle or away), the action was deferred, not forbidden — hold it for re-engagement.
            if input.safetyContext.autonomy != .autoAct,
               PromptInjectionPolicy.isHighImpact(toolName: name, args: args) {
                return .hold(summary: PromptInjectionPolicy.actionSummary(toolName: name, args: args),
                             message: holdMessage(name))
            }
            return .block(message: blockMessage(name, reason: reason))
        case .confirm(let reason):
            // High-impact tools get the richer action summary; other rules speak their reason.
            let summary = PromptInjectionPolicy.isHighImpact(toolName: name, args: args)
                ? PromptInjectionPolicy.actionSummary(toolName: name, args: args)
                : reason
            return .confirm(summary: attributed(summary, call: call))
        }
    }

    // MARK: - Model-facing copy

    /// Confirmation copy names the real action; a composed call also names what asked for it, so
    /// approving is a decision about the action *and* its source.
    private static func attributed(_ summary: String, call: ResolvedToolCall) -> String {
        guard let composer = call.context.parent?.composerID else { return summary }
        return "\(summary) — requested by the ‘\(composer)’ skill"
    }

    static func declineMessage(_ name: String) -> String {
        "The user did NOT approve this action, so '\(name)' was not performed. Do not retry it; tell the user it was cancelled unless they explicitly ask again."
    }

    static func unavailableConfirmationMessage(_ name: String) -> String {
        "'\(name)' requires user confirmation, which isn't available right now, so it was not performed. Tell the user to try again with the app in the foreground."
    }

    static func blockMessage(_ name: String, reason: String) -> String {
        "'\(name)' was blocked by a safety rule (\(reason)). Do not retry; tell the user it was blocked for safety."
    }

    static func holdMessage(_ name: String) -> String {
        "'\(name)' wasn't run because you've been away from the glasses; I've held it to raise when you're back. Do not retry automatically."
    }
}
