import Foundation

/// Pure entitlement policy: evidence plus a clock in, a decision out. No I/O, no globals, no
/// `UserDefaults`, so the truth table is testable without a device, a receipt, or a paywall.
enum FieldAssistEntitlementEvaluator {

    /// Grant when at least one piece of evidence is still live at `now`.
    ///
    /// Expiry is exclusive: evidence whose expiry equals `now` has lapsed. Among live evidence the
    /// **highest tier wins**, then the perpetual piece, then the one that lasts longest — so a solo
    /// purchase beside a live team code grants team until the code lapses, a solo purchase beside a
    /// lapsed team code grants solo perpetually, and a decision reports the date the user actually
    /// loses the tier it granted. Absent or unverifiable evidence is a denial — never a fallback
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
            if outranks(candidate, incumbent) { best = candidate }
        }

        if let best {
            return .granted(source: best.source, tier: best.tier, expiresAt: best.expiration)
        }
        if let latestLapse {
            return .denied(.expired(latestLapse))
        }
        if set.hasUnverifiableLicense {
            return .denied(.unverifiableLicense)
        }
        return .denied(.noEvidence)
    }

    /// Every pack any *live* licence includes. Packs are not a tier: a solo purchase beside a live
    /// team code that lists a pack gets that pack, and a lapsed code contributes nothing.
    static func livePacks(_ set: FieldAssistEntitlementEvidenceSet, now: Date = Date()) -> Set<String> {
        var packs = Set<String>()
        for candidate in set.evidence {
            if let expiry = candidate.expiration, expiry <= now { continue }
            packs.formUnion(candidate.packs)
        }
        return packs
    }

    /// Higher tier wins; at equal tier perpetual outlasts dated; between two dated pieces the later
    /// expiry wins.
    private static func outranks(_ lhs: FieldAssistEntitlementEvidence,
                                 _ rhs: FieldAssistEntitlementEvidence) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        guard let lhsExpiry = lhs.expiration else { return true }
        guard let rhsExpiry = rhs.expiration else { return false }
        return lhsExpiry > rhsExpiry
    }
}
