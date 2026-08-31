import Foundation
@testable import OpenGlasses

/// Grants Field Assist unconditionally. Feature tests that need the feature *on* say so with this,
/// instead of writing a global preference and relying on a gate to read it back.
struct AlwaysGrantedEntitlementProvider: FieldAssistEntitlementProvider {
    var productID = "com.openglasses.field_assist"
    var expiration: Date?

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        FieldAssistEntitlementEvidenceSet(evidence: [
            .verifiedStoreProduct(productID: productID, expiration: expiration)
        ])
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
    static func grant() -> FieldAssistEntitlementProvider {
        let previous = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider()
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
