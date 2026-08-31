import Foundation

/// Pure entitlement policy: evidence plus a clock in, a decision out. No I/O, no globals, no
/// `UserDefaults`, so the truth table is testable without a device, a receipt, or a paywall.
enum FieldAssistEntitlementEvaluator {

    /// Grant when at least one piece of evidence is still live at `now`.
    ///
    /// Expiry is exclusive: evidence whose expiry equals `now` has lapsed. Among live evidence the
    /// perpetual piece wins, otherwise the one that lasts longest, so a decision reports the date the
    /// user actually loses access. Absent or unverifiable evidence is a denial — never a fallback
    /// grant, and never a reason to consult a preference instead.
    static func decide(_ set: FieldAssistEntitlementEvidenceSet,
                       now: Date = Date()) -> FieldAssistEntitlementDecision {
        var best: FieldAssistEntitlementEvidence?
        var latestLapse: Date?

        for candidate in set.evidence {
            if let expiry = candidate.expiration, expiry <= now {
                latestLapse = max(latestLapse ?? expiry, expiry)
                continue
            }
            guard let incumbent = best else {
                best = candidate
                continue
            }
            if outlasts(candidate, incumbent) { best = candidate }
        }

        if let best {
            return .granted(source: best.source, expiresAt: best.expiration)
        }
        if let latestLapse {
            return .denied(.expired(latestLapse))
        }
        if set.hasUnverifiableLicense {
            return .denied(.unverifiableLicense)
        }
        return .denied(.noEvidence)
    }

    /// Perpetual outlasts dated; between two dated pieces the later expiry wins.
    private static func outlasts(_ lhs: FieldAssistEntitlementEvidence,
                                 _ rhs: FieldAssistEntitlementEvidence) -> Bool {
        guard let lhsExpiry = lhs.expiration else { return true }
        guard let rhsExpiry = rhs.expiration else { return false }
        return lhsExpiry > rhsExpiry
    }
}
