import Foundation

/// A fact that can grant Field Assist access.
///
/// Evidence is only ever constructed by code that has already done the verification it names — a
/// StoreKit `VerificationResult` that came back `.verified` and unrevoked, or an Ed25519 license
/// signature checked against the embedded public key. Nothing here is derived from a stored
/// preference, because a writable boolean is a mirror of a past check, not evidence of a current
/// entitlement.
enum FieldAssistEntitlementEvidence: Equatable, Sendable {
    /// A StoreKit transaction verified and observed unrevoked in this process.
    /// `expiration` is nil for the non-consumable unlock.
    case verifiedStoreProduct(productID: String, expiration: Date?)

    /// An organization license code whose signature and feature claim verified. `licenseIDHash`
    /// identifies which code granted access without carrying the code itself.
    /// `expiration` is the signed expiry claim (nil = perpetual).
    case verifiedOrganizationLicense(licenseIDHash: String, expiration: Date?)

    #if DEBUG
    /// Internal-build convenience. Compiled out of Release, so no shipped code path can construct
    /// it and no shipped decision can be reached through it.
    case internalDeveloper
    #endif

    /// The moment this evidence stops being valid, or nil when it never does.
    var expiration: Date? {
        switch self {
        case .verifiedStoreProduct(_, let expiration): return expiration
        case .verifiedOrganizationLicense(_, let expiration): return expiration
        #if DEBUG
        case .internalDeveloper: return nil
        #endif
        }
    }

    /// The decision source this evidence maps to when it wins.
    var source: FieldAssistEntitlementDecision.Source {
        switch self {
        case .verifiedStoreProduct(let productID, _): return .storeProduct(productID: productID)
        case .verifiedOrganizationLicense(let hash, _): return .organizationLicense(licenseIDHash: hash)
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
/// accurate paywall instead of a generic lock.
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
    let expiresAt: Date?
    let denial: DenialReason?

    static func granted(source: Source, expiresAt: Date?) -> FieldAssistEntitlementDecision {
        FieldAssistEntitlementDecision(isGranted: true, source: source, expiresAt: expiresAt, denial: nil)
    }

    static func denied(_ reason: DenialReason) -> FieldAssistEntitlementDecision {
        FieldAssistEntitlementDecision(isGranted: false, source: nil, expiresAt: nil, denial: reason)
    }
}
