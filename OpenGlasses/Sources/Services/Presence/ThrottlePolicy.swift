import Foundation

/// How engaged the user currently is with the glasses (Plan W). Fused from cheap on-device signals
/// by [[PresenceMonitor]]; consumed by `ThrottlePolicy` to scale loop cadence and the autonomy
/// ceiling. Ordered by `rank` (most → least engaged) so a `minMode` floor can clamp it.
enum EngagementMode: String, CaseIterable, Comparable, Codable {
    case active     // actively talking / looking — recent interaction or live voice
    case present    // connected, in-foreground, but no recent interaction
    case idle       // connected but disengaged past the idle threshold (>5 min)
    case away       // disconnected or backgrounded — nothing should run

    /// Higher = more engaged. Used to order modes and apply a `minMode` floor.
    var rank: Int {
        switch self {
        case .active:  return 3
        case .present: return 2
        case .idle:    return 1
        case .away:    return 0
        }
    }

    static func < (lhs: EngagementMode, rhs: EngagementMode) -> Bool { lhs.rank < rhs.rank }

    /// The canonical engagement factor (0–1) for this mode. Banded rather than continuous so the
    /// throttle is deterministic and the bands line up with the policy table.
    var engagement: Double {
        switch self {
        case .active:  return 1.0
        case .present: return 0.5
        case .idle:    return 0.2
        case .away:    return 0.0
        }
    }
}

/// The autonomy ceiling a loop is allowed to operate at. Presence lowers this when the user
/// disengages: an agent that hasn't seen the user in minutes should *advise*, not *act*. Composes
/// with the Plan S `SafetySupervisor` (which still vetoes individual high-impact calls) — this is a
/// global ceiling on top of the per-call gate, not a replacement for it.
enum Autonomy: String, CaseIterable, Comparable, Codable {
    case paused      // do nothing
    case recommend   // surface suggestions; never auto-act
    case autoAct     // may act (subject to the supervisor)

    var rank: Int {
        switch self {
        case .paused:    return 0
        case .recommend: return 1
        case .autoAct:   return 2
        }
    }

    static func < (lhs: Autonomy, rhs: Autonomy) -> Bool { lhs.rank < rhs.rank }
}

/// The throttle's output for one loop: how much to stretch its cadence, and the autonomy ceiling.
struct ThrottleDecision: Equatable {
    /// Multiplier on a loop's base interval. `1.0` = full cadence; `4.0` = a quarter as often;
    /// `.infinity` = paused.
    let intervalMultiplier: Double
    let autonomy: Autonomy

    var isPaused: Bool { intervalMultiplier.isInfinite || autonomy == .paused }

    /// Apply the multiplier to a loop's base interval. Returns `.infinity` when paused, which a
    /// caller treats as "don't schedule the next tick".
    func interval(base: TimeInterval) -> TimeInterval {
        isPaused ? .infinity : base * intervalMultiplier
    }
}

/// Pure mapping from engagement → throttle decision (Plan W). No clock, no I/O — a function of the
/// mode (and an optional `minMode` floor), so it's fully unit-testable and identical across runs.
///
/// | Mode      | interval × | autonomy   |
/// |-----------|-----------|------------|
/// | `active`  | 1.0       | autoAct    |
/// | `present` | 2.0       | autoAct    |
/// | `idle`    | 4.0       | recommend  |
/// | `away`    | paused    | paused     |
enum ThrottlePolicy {

    /// Decide for `mode`. `minMode` is a per-loop floor: a safety-critical loop (e.g. hazard
    /// navigation) passes `.active`/`.present` so the throttle can never starve or downgrade it
    /// below that level, no matter how disengaged the user looks.
    static func decide(mode: EngagementMode, minMode: EngagementMode = .away) -> ThrottleDecision {
        let effective = max(mode, minMode)
        switch effective {
        case .active:  return ThrottleDecision(intervalMultiplier: 1.0, autonomy: .autoAct)
        case .present: return ThrottleDecision(intervalMultiplier: 2.0, autonomy: .autoAct)
        case .idle:    return ThrottleDecision(intervalMultiplier: 4.0, autonomy: .recommend)
        case .away:    return ThrottleDecision(intervalMultiplier: .infinity, autonomy: .paused)
        }
    }

    /// Convenience overload taking a raw engagement factor; the mode is the source of truth, the
    /// factor is accepted for symmetry with `PresenceMonitor`'s published pair.
    static func decide(engagement: Double, mode: EngagementMode, minMode: EngagementMode = .away) -> ThrottleDecision {
        decide(mode: mode, minMode: minMode)
    }
}
