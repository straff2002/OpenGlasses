import Foundation
@testable import OpenGlasses

/// Grants Field Assist unconditionally at `tier` (enterprise by default, so "feature on" means every
/// capability). Feature tests that need the feature *on* say so with this, instead of writing a
/// global preference and relying on a gate to read it back. Pass `.solo` to state the solo condition.
struct AlwaysGrantedEntitlementProvider: FieldAssistEntitlementProvider {
    var tier: FieldAssistTier = .enterprise
    var expiration: Date?

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        switch tier {
        case .solo:
            return FieldAssistEntitlementEvidenceSet(evidence: [
                .verifiedStoreProduct(productID: "com.openglasses.field_assist", expiration: expiration)
            ])
        case .team, .enterprise:
            return FieldAssistEntitlementEvidenceSet(evidence: [
                .verifiedOrganizationLicense(licenseIDHash: "test-grant", expiration: expiration, tier: tier)
            ])
        }
    }
}

/// Denies unconditionally, with a stated reason.
struct DeniedEntitlementProvider: FieldAssistEntitlementProvider {
    var hasUnverifiableLicense = false

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        FieldAssistEntitlementEvidenceSet(hasUnverifiableLicense: hasUnverifiableLicense)
    }
}

/// Returns a fixed evidence set — for stating an exact access condition (expired, forged, revoked).
struct StubEntitlementProvider: FieldAssistEntitlementProvider {
    let set: FieldAssistEntitlementEvidenceSet

    init(_ set: FieldAssistEntitlementEvidenceSet) { self.set = set }

    func evidence() -> FieldAssistEntitlementEvidenceSet { set }
}

/// Swap the shared entitlement in for the duration of a test, returning the previous provider so
/// `tearDown` can put it back. Kept explicit rather than automatic so a test that forgets to restore
/// is obvious in review.
enum EntitlementTestScope {
    static func grant(tier: FieldAssistTier = .enterprise) -> FieldAssistEntitlementProvider {
        let previous = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: tier)
        return previous
    }

    static func restore(_ provider: FieldAssistEntitlementProvider) {
        FieldAssistEntitlement.shared.provider = provider
        FieldAssistEntitlement.shared.clock = Date.init
        #if DEBUG
        FieldAssistEntitlement.shared.setInternalDeveloperGrant(false)
        #endif
    }
}
