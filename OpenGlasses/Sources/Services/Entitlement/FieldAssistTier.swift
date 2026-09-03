import Foundation

/// What a Field Assist entitlement is *for*. Two tiers with different capabilities rather than one
/// capability with two prices: a solo purchase covers the bundled vaults, procedures, session log
/// and escalation; a team licence adds the organisation's own vaults and manuals, audited export,
/// and (later) org-issued configuration; enterprise is contract terms on top of team.
///
/// Ordered so a gate can ask for "at least team" and an evaluator can prefer the strongest live
/// evidence. Raw values are what a signed licence payload carries.
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
        case .solo: return "Bundled vaults, guided procedures, domain calculators, session log, and expert escalation."
        case .team: return "Everything in Solo, plus your own vaults and manuals, audited PDF export, and organisation-issued configuration."
        case .enterprise: return "Everything in Team, under contract terms: white-label, SLA, retention, and a self-hosted expert relay."
        }
    }
}
