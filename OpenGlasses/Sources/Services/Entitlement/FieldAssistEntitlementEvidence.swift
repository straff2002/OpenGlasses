import Foundation

/// A fact that can grant Field Assist access.
///
/// Evidence is only ever constructed by code that has already done the verification it names — a
/// StoreKit `VerificationResult` that came back `.verified` and unrevoked, or an Ed25519 license
/// signature checked against the embedded public key. Nothing here is derived from a stored
/// preference, because a writable boolean is a mirror of a past check, not evidence of a current
/// entitlement.
///
/// Every piece of evidence carries a tier. Store products are always solo — the App Store sells to
/// a person, and there is no organisation concept in a receipt. A licence code carries the tier
/// it was signed with; a code issued before tiers existed went to an organisation, so it reads as
/// team.
enum FieldAssistEntitlementEvidence: Equatable, Sendable {
    /// A StoreKit transaction verified and observed unrevoked in this process.
    /// `expiration` is nil for the non-consumable unlock and the renewal date for a subscription.
    case verifiedStoreProduct(productID: String, expiration: Date?)

    /// An organization license code whose signature and feature claim verified. `licenseIDHash`
    /// identifies which code granted access without carrying the code itself.
    /// `expiration` is the signed expiry claim (nil = perpetual); `tier` the signed tier claim.
    case verifiedOrganizationLicense(licenseIDHash: String, expiration: Date?, tier: FieldAssistTier = .team)

    #if DEBUG
    /// Internal-build convenience. Compiled out of Release, so no shipped code path can construct
    /// it and no shipped decision can be reached through it.
    case internalDeveloper
    #endif

    /// The moment this evidence stops being valid, or nil when it never does.
    var expiration: Date? {
        switch self {
        case .verifiedStoreProduct(_, let expiration): return expiration
        case .verifiedOrganizationLicense(_, let expiration, _): return expiration
        #if DEBUG
        case .internalDeveloper: return nil
        #endif
        }
    }

    /// The tier this evidence grants.
    var tier: FieldAssistTier {
        switch self {
        case .verifiedStoreProduct: return .solo
        case .verifiedOrganizationLicense(_, _, let tier): return tier
        #if DEBUG
        case .internalDeveloper: return .enterprise
        #endif
        }
    }

    /// The decision source this evidence maps to when it wins.
    var source: FieldAssistEntitlementDecision.Source {
        switch self {
        case .verifiedStoreProduct(let productID, _): return .storeProduct(productID: productID)
        case .verifiedOrganizationLicense(let hash, _, _): return .organizationLicense(licenseIDHash: hash)
        #if DEBUG
        case .internalDeveloper: return .internalDeveloper
        #endif
        }
    }
}

/// Everything a provider found this read, including the fact that something failed to verify.
///
/// The failure flag exists so a forged or corrupted license denies with a reason the UI can explain,
/// rather than looking identical to "never bought it".
struct FieldAssistEntitlementEvidenceSet: Equatable, Sendable {
    var evidence: [FieldAssistEntitlementEvidence]

    /// A stored license code was present but failed signature, feature, or format verification.
    var hasUnverifiableLicense: Bool

    init(evidence: [FieldAssistEntitlementEvidence] = [], hasUnverifiableLicense: Bool = false) {
        self.evidence = evidence
        self.hasUnverifiableLicense = hasUnverifiableLicense
    }

    static let empty = FieldAssistEntitlementEvidenceSet()
}

/// The outcome of evaluating evidence against a clock. Carries the reason so callers can render an
/// accurate paywall instead of a generic lock, and the tier so a gate can ask for more than "any".
struct FieldAssistEntitlementDecision: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case storeProduct(productID: String)
        case organizationLicense(licenseIDHash: String)
        #if DEBUG
        case internalDeveloper
        #endif
    }

    enum DenialReason: Equatable, Sendable {
        /// Nothing was presented — never purchased, never licensed.
        case noEvidence
        /// Evidence existed but every piece had lapsed; the date is the latest lapse seen.
        case expired(Date)
        /// A license code was stored but did not verify.
        case unverifiableLicense
    }

    let isGranted: Bool
    let source: Source?
    /// The tier granted; nil when denied.
    let tier: FieldAssistTier?
    /// When the *granted tier* lapses; nil for a perpetual grant or a denial.
    let expiresAt: Date?
    let denial: DenialReason?

    static func granted(source: Source, tier: FieldAssistTier, expiresAt: Date?) -> FieldAssistEntitlementDecision {
        FieldAssistEntitlementDecision(isGranted: true, source: source, tier: tier, expiresAt: expiresAt, denial: nil)
    }

    static func denied(_ reason: DenialReason) -> FieldAssistEntitlementDecision {
        FieldAssistEntitlementDecision(isGranted: false, source: nil, tier: nil, expiresAt: nil, denial: reason)
    }

    /// Whether this decision covers a capability that needs `required`.
    func satisfies(_ required: FieldAssistTier) -> Bool {
        guard isGranted, let tier else { return false }
        return tier >= required
    }

    /// One token for an audit line: which kind of evidence, at which tier. Never the code itself.
    var auditLabel: String {
        guard isGranted, let tier else { return "none" }
        switch source {
        case .storeProduct(let productID): return "store:\(productID)/\(tier.rawValue)"
        case .organizationLicense(let hash): return "license:\(hash)/\(tier.rawValue)"
        #if DEBUG
        case .internalDeveloper: return "internal/\(tier.rawValue)"
        #endif
        case nil: return tier.rawValue
        }
    }
}

/// What a tiered gate learned: granted at some tier, granted but not high enough, or not granted.
/// The middle case is the one a paywall must be able to explain — "your purchase covers the bundled
/// vaults; your own vaults need a team licence" — instead of a generic lock.
enum FieldAssistTierCheck: Equatable, Sendable {
    case granted(FieldAssistTier)
    case insufficientTier(required: FieldAssistTier, held: FieldAssistTier)
    case denied(FieldAssistEntitlementDecision.DenialReason)

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }
}
