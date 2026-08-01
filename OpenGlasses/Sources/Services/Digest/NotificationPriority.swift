import Foundation

/// Shared notification priority (Plan BZ) — lifted out of `AgentNotificationQueue` so the
/// digest and the queue rank and age items by one model. Raw values are unchanged, so the
/// queue's persisted JSON keeps decoding.
enum NotificationPriority: String, Codable, Comparable, CaseIterable {
    case low       // Can be discarded if stale (weather, routine check-ins)
    case medium    // Deliver if <2 hours old (calendar reminders, email summaries)
    case high      // Always deliver (urgent alerts, security, user-requested)

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: NotificationPriority, rhs: NotificationPriority) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The age-by-priority staleness rule (the numbers `AgentNotificationQueue` shipped with).
    func isStale(age: TimeInterval) -> Bool {
        switch self {
        case .low: return age > 1800      // 30 minutes
        case .medium: return age > 7200   // 2 hours
        case .high: return false          // Never stale
        }
    }
}
