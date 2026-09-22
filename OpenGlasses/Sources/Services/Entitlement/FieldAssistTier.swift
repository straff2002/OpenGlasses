import Foundation

/// What a Field Assist entitlement is *for*. Solo is what the App Store sells to a person; a team
/// licence adds audited export and organisation-issued configuration on top; enterprise is contract
/// terms on top of team.
///
/// Ordered so the evaluator can prefer the strongest live evidence, and so the entitlement screen
/// can name what a licence is. Raw values are what a signed licence payload carries. **A tier is
/// not a gate**: what the code may do is a `FieldAssistCapability`, because a subscription and the
/// retired one-time unlock are both `solo` and only one of them includes vaults of your own.
enum FieldAssistTier: String, Codable, Comparable, Sendable, CaseIterable {
    case solo
    case team
    case enterprise

    private var rank: Int {
        switch self {
        case .solo: return 0
        case .team: return 1
        case .enterprise: return 2
        }
    }

    static func < (lhs: FieldAssistTier, rhs: FieldAssistTier) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .solo: return "Solo"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        }
    }

    /// One line for the paywall: what this tier unlocks.
    var capabilitySummary: String {
        switch self {
        case .solo: return "Bundled vaults, guided procedures, domain calculators, session log, and expert escalation — and, with a subscription, vaults of your own with your manuals."
        case .team: return "Everything in Solo, plus your own vaults and manuals on every seat, audited PDF export, and organisation-issued configuration."
        case .enterprise: return "Everything in Team, under contract terms: white-label, SLA, retention, and a self-hosted expert relay."
        }
    }
}
