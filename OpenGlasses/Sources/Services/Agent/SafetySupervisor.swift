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

    /// Snapshot live settings + current location into a context (used by the router/AppState).
    static func live(now: Date, location: CLLocationCoordinate2D?) -> SafetyContext {
        SafetyContext(
            now: now,
            location: location,
            homeRegion: SafetySettings.homeRegion,
            enabledRules: SafetySettings.enabledRules,
            quietHoursStart: SafetySettings.quietHoursStart,
            quietHoursEnd: SafetySettings.quietHoursEnd
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
        return best
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
