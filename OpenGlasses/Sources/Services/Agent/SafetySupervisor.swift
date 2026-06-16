import Foundation
import CoreLocation

/// Everything the supervisor needs to decide, captured at the moment of a tool call. Injected
/// so the supervisor stays a pure function — no clock, no GPS, no UserDefaults reads inside it.
struct SafetyContext {
    var now: Date
    var location: CLLocationCoordinate2D?
    var homeRegion: HomeRegion?
    var enabledRules: Set<SafetyRuleKind>
    var quietHoursStart: Int
    var quietHoursEnd: Int
    /// The presence-derived autonomy ceiling (Plan W). `.autoAct` is the default and matches the
    /// pre-Plan-W behaviour; `.recommend`/`.paused` lower what an *acting* tool may do without the
    /// user (see the ceiling in `evaluate`). Injected so the supervisor stays a pure function.
    var autonomy: Autonomy = .autoAct

    /// Snapshot live settings + current location into a context (used by the router/AppState).
    /// `autonomy` defaults to `.autoAct` so callers that don't track presence are unaffected.
    static func live(now: Date, location: CLLocationCoordinate2D?, autonomy: Autonomy = .autoAct) -> SafetyContext {
        SafetyContext(
            now: now,
            location: location,
            homeRegion: SafetySettings.homeRegion,
            enabledRules: SafetySettings.enabledRules,
            quietHoursStart: SafetySettings.quietHoursStart,
            quietHoursEnd: SafetySettings.quietHoursEnd,
            autonomy: autonomy
        )
    }
}

/// The supervisor's decision for one action.
enum SafetyVerdict: Equatable {
    case allow
    case confirm(reason: String)   // route through ToolConfirmationCoordinator (spoken approval)
    case block(reason: String)     // no execution; a no-retry failure

    var severity: Int {
        switch self {
        case .allow:   return 0
        case .confirm: return 1
        case .block:   return 2
        }
    }
}

/// Deterministic, pre-execution safety veto (Plan S). A pure constraint check — no LLM, no I/O,
/// sub-millisecond — run after the model/executor selects an action but before it runs. It is the
/// single place a constraint ("never actuate locks away from home", "no late-night texts") is
/// enforced, so it holds even if the model is confused or talked into an action. Pairs with
/// [[PromptInjectionPolicy]] (the prompt-level rules) as the deterministic backstop.
enum SafetySupervisor {

    /// Outbound messaging tools the quiet-hours rule guards.
    static let messagingTools: Set<String> = ["send_message", "send_via"]
    /// Physical-world actuation tools the geofence rule guards.
    static let actuationTools: Set<String> = ["smart_home", "home_assistant"]
    /// The hard floor for `irreversibleGuard` — always confirm, regardless of other toggles.
    static let alwaysConfirmTools: Set<String> = ["medical_export", "phone_call"]

    /// Evaluate `tool` against the enabled rules. Iterates `SafetyRuleKind.allCases` (a fixed
    /// order) and returns the most severe verdict, breaking ties toward the earlier rule, so the
    /// result — including the reason string — is deterministic.
    static func evaluate(tool: String, args: [String: Any], context: SafetyContext) -> SafetyVerdict {
        var best: SafetyVerdict = .allow
        for rule in SafetyRuleKind.allCases where context.enabledRules.contains(rule) {
            if let verdict = apply(rule, tool: tool, context: context), verdict.severity > best.severity {
                best = verdict
            }
        }
        // Presence autonomy ceiling (Plan W). When the user has disengaged, an *acting* (high-impact)
        // tool must not run autonomously: `.recommend` requires explicit human confirmation, `.paused`
        // blocks it outright. Read-only tools are untouched (reading is fine while idle), and this
        // only ever *raises* severity — it never overrides a stricter rule verdict.
        if let ceiling = autonomyCeiling(tool: tool, autonomy: context.autonomy), ceiling.severity > best.severity {
            best = ceiling
        }
        return best
    }

    /// The verdict floor imposed by the autonomy ceiling for `tool`, or `nil` when it doesn't apply
    /// (autonomy is full, or the tool takes no real-world action). Both lowered levels `.block`
    /// rather than `.confirm`: a disengaged user can't answer a spoken prompt (and
    /// `requestConfirmation` would suspend the agent loop indefinitely), so the action is held — not
    /// run, not prompted — and surfaced on re-engagement via the held-recommendation store.
    private static func autonomyCeiling(tool: String, autonomy: Autonomy) -> SafetyVerdict? {
        guard PromptInjectionPolicy.isHighImpact(toolName: tool) else { return nil }
        switch autonomy {
        case .autoAct:   return nil
        case .recommend: return .block(reason: "held — you've been idle, so ‘\(tool)’ wasn't run automatically")
        case .paused:    return .block(reason: "‘\(tool)’ is paused while you're away from the glasses")
        }
    }

    private static func apply(_ rule: SafetyRuleKind, tool: String, context: SafetyContext) -> SafetyVerdict? {
        switch rule {
        case .needsVoiceApproval:
            return PromptInjectionPolicy.isHighImpact(toolName: tool)
                ? .confirm(reason: "‘\(tool)’ can take a real action — confirm first")
                : nil

        case .irreversibleGuard:
            return alwaysConfirmTools.contains(tool)
                ? .confirm(reason: "‘\(tool)’ is irreversible and always needs approval")
                : nil

        case .timeOfDay:
            guard messagingTools.contains(tool), isQuietHour(context) else { return nil }
            return .confirm(reason: "it's quiet hours — confirm before sending a message")

        case .geofence:
            guard actuationTools.contains(tool),
                  let home = context.homeRegion,
                  let location = context.location else { return nil }
            let here = CLLocation(latitude: location.latitude, longitude: location.longitude)
            let center = CLLocation(latitude: home.latitude, longitude: home.longitude)
            return here.distance(from: center) > home.radius
                ? .block(reason: "‘\(tool)’ is blocked while you're away from home")
                : nil
        }
    }

    /// Whether `context.now` falls inside the quiet-hours window. Same-day when start < end,
    /// otherwise the window wraps midnight (e.g. 22:00–07:00).
    static func isQuietHour(_ context: SafetyContext) -> Bool {
        let hour = Calendar.current.component(.hour, from: context.now)
        let start = context.quietHoursStart, end = context.quietHoursEnd
        if start == end { return false }
        return start < end ? (hour >= start && hour < end)
                           : (hour >= start || hour < end)
    }
}
