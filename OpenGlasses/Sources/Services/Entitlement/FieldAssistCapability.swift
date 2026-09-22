import Foundation

/// What a Field Assist entitlement lets the app **do**.
///
/// A tier says what a licence *is*; a capability says what code may do with it. Those were the same
/// question for as long as every gate read `tier >= .team`, and they stopped being the same question
/// the day a subscriber was allowed to build their own vaults while the retired one-time unlock was
/// not: both grant `solo`, so no ordering over tiers can separate them. Gates therefore ask for a
/// capability, and nothing outside this file compares tiers.
enum FieldAssistCapability: String, CaseIterable, Sendable {
    /// Read the vaults that ship with the app, or come from a pack the reader is entitled to.
    case bundledVaults
    /// Import a vault of your own and index its manuals on this phone.
    case ownVaults
    /// Produce the audited work-order export of a field session.
    case auditedExport
    /// Apply an organisation-issued configuration profile.
    case orgConfiguration
    /// Every vault pack, without buying each one.
    case everyVaultPack

    /// Capabilities one piece of evidence grants on its own. Whether the evidence is still live is
    /// the caller's business — see the set overload.
    static func capabilities(for evidence: FieldAssistEntitlementEvidence) -> Set<FieldAssistCapability> {
        switch evidence {
        case .verifiedStoreProduct(let productID, _):
            // A subscription is the store product that includes vaults of your own. The retired
            // one-time unlock grants exactly what it was sold as — the bundled vaults — and so does
            // any store product this build does not recognise.
            return StoreKitService.fieldAssistSubscriptionIds.contains(productID)
                ? [.bundledVaults, .ownVaults]
                : [.bundledVaults]
        case .verifiedOrganizationLicense(_, _, let tier, _):
            switch tier {
            case .solo:
                return [.bundledVaults]
            case .team:
                return [.bundledVaults, .ownVaults, .auditedExport, .orgConfiguration]
            case .enterprise:
                return [.bundledVaults, .ownVaults, .auditedExport, .orgConfiguration, .everyVaultPack]
            }
        #if DEBUG
        case .internalDeveloper:
            return Set(FieldAssistCapability.allCases)
        #endif
        }
    }

    /// Every capability the live evidence grants between it, unioned.
    ///
    /// The union is deliberate and differs from `FieldAssistEntitlementEvaluator.decide`, which
    /// picks one winning piece: a technician holding a personal subscription *and* the firm's team
    /// code keeps both what he bought and what his employer licensed, and loses each when it lapses
    /// rather than when the strongest one does. Lapsed evidence contributes nothing, exactly as it
    /// contributes no tier.
    static func capabilities(for set: FieldAssistEntitlementEvidenceSet,
                             now: Date = Date()) -> Set<FieldAssistCapability> {
        var granted = Set<FieldAssistCapability>()
        for candidate in set.evidence {
            if let expiry = candidate.expiration, expiry <= now { continue }
            granted.formUnion(capabilities(for: candidate))
        }
        return granted
    }
}

/// What a capability gate learned: yes, entitled-but-not-this, or not entitled at all.
///
/// The middle case is the one a screen has to be able to explain — "your purchase covers the
/// bundled vaults; vaults of your own come with a subscription" — instead of a generic lock.
enum FieldAssistCapabilityCheck: Equatable, Sendable {
    case granted
    /// Entitled, but this entitlement does not include the capability asked for. `held` is
    /// everything it *does* include, so the explanation can be specific.
    case notIncluded(held: Set<FieldAssistCapability>)
    case denied(FieldAssistEntitlementDecision.DenialReason)

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    /// Pure resolution, so every state renders in a test without StoreKit or a stored code.
    static func resolve(_ capability: FieldAssistCapability,
                        capabilities: Set<FieldAssistCapability>,
                        decision: FieldAssistEntitlementDecision) -> FieldAssistCapabilityCheck {
        if capabilities.contains(capability) { return .granted }
        if decision.isGranted { return .notIncluded(held: capabilities) }
        return .denied(decision.denial ?? .noEvidence)
    }
}
