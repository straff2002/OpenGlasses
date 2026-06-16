import Foundation
import CoreLocation

/// The deterministic safety rules the `SafetySupervisor` enforces (Plan S). Each is
/// user-toggleable in `SafetyRulesView`; the defaults below ship enabled except the geofence
/// rule, which stays off until a home region is set.
enum SafetyRuleKind: String, CaseIterable, Identifiable, Codable {
    case needsVoiceApproval   // any high-impact tool → spoken confirm
    case irreversibleGuard    // the most irreversible tools → always confirm (a floor)
    case timeOfDay            // outbound messaging during quiet hours → confirm
    case geofence             // smart-home / HA actuation away from home → block

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsVoiceApproval: return "Voice approval for risky actions"
        case .irreversibleGuard:  return "Always confirm irreversible actions"
        case .timeOfDay:          return "Quiet-hours messaging guard"
        case .geofence:           return "Block actuation away from home"
        }
    }

    var detail: String {
        switch self {
        case .needsVoiceApproval: return "Sending messages, calling, smart-home, shortcuts and exports ask for a spoken “confirm” first."
        case .irreversibleGuard:  return "Exports and phone calls always require approval, even if other rules are off."
        case .timeOfDay:          return "During quiet hours, confirm before sending any message."
        case .geofence:           return "Smart-home and Home Assistant actuation is blocked when you're away from your home region."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .geofence: return false      // needs a home region first
        default:        return true
        }
    }
}

/// A saved home region for the geofence rule (centre + radius in metres).
struct HomeRegion: Equatable {
    let latitude: Double
    let longitude: Double
    let radius: Double

    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Persisted settings backing the supervisor's `SafetyContext` (UserDefaults). Read when the
/// context is built per tool call, so toggles take effect immediately. Kept out of the supervisor
/// itself so the supervisor stays a pure function of its injected context.
enum SafetySettings {
    private static let d = UserDefaults.standard

    // MARK: Rule toggles

    static func isRuleEnabled(_ kind: SafetyRuleKind) -> Bool {
        d.object(forKey: "agentSafety.rule.\(kind.rawValue)") as? Bool ?? kind.defaultEnabled
    }

    static func setRuleEnabled(_ kind: SafetyRuleKind, _ enabled: Bool) {
        d.set(enabled, forKey: "agentSafety.rule.\(kind.rawValue)")
    }

    static var enabledRules: Set<SafetyRuleKind> {
        Set(SafetyRuleKind.allCases.filter(isRuleEnabled))
    }

    // MARK: Quiet hours (local-clock hours; window wraps midnight when start > end)

    static var quietHoursStart: Int { d.object(forKey: "agentSafety.quietStart") as? Int ?? 22 }
    static var quietHoursEnd: Int { d.object(forKey: "agentSafety.quietEnd") as? Int ?? 7 }

    static func setQuietHours(start: Int, end: Int) {
        d.set(start, forKey: "agentSafety.quietStart")
        d.set(end, forKey: "agentSafety.quietEnd")
    }

    // MARK: Plan step budget

    static var stepBudget: Int { max(1, d.object(forKey: "agentSafety.stepBudget") as? Int ?? 8) }

    static func setStepBudget(_ n: Int) { d.set(max(1, n), forKey: "agentSafety.stepBudget") }

    // MARK: Home region

    static var homeRegion: HomeRegion? {
        guard d.object(forKey: "agentSafety.homeLat") != nil else { return nil }
        return HomeRegion(latitude: d.double(forKey: "agentSafety.homeLat"),
                          longitude: d.double(forKey: "agentSafety.homeLon"),
                          radius: max(1, d.double(forKey: "agentSafety.homeRadius")))
    }

    static func setHomeRegion(_ region: HomeRegion?) {
        guard let region else {
            ["agentSafety.homeLat", "agentSafety.homeLon", "agentSafety.homeRadius"].forEach { d.removeObject(forKey: $0) }
            return
        }
        d.set(region.latitude, forKey: "agentSafety.homeLat")
        d.set(region.longitude, forKey: "agentSafety.homeLon")
        d.set(region.radius, forKey: "agentSafety.homeRadius")
    }
}
