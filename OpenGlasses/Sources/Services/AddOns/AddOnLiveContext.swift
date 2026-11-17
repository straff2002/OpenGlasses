import Foundation

/// The live values add-ons are judged against (Plan GF P2), read from the phone's settings and
/// its enrolled organisation profile. Everything that decides uses the pure types
/// (`AddOnAdmission`, `AddOnAvailability`, `AddOnPolicy`); this is only where their inputs come
/// from in the running app.
@MainActor
enum AddOnLiveContext {

    /// The enrolled organisation's id and administrator key — the one organisation whose
    /// signature an add-on can carry on this phone. Empty when the phone is not enrolled or the
    /// profile names no administrator key.
    static func trustedOrganisations(manager: OrgProfileManager? = nil) -> [String: String] {
        guard let authority = (manager ?? .shared).profile?.officeAuthority,
              AddOnSignature.isValidOrganizationID(authority.organizationID),
              AddOnSignature.isValidPublicKey(authority.administratorPublicKey) else { return [:] }
        return [authority.organizationID: authority.administratorPublicKey]
    }

    static func policy(manager: OrgProfileManager? = nil) -> AddOnPolicy {
        AddOnPolicy(ceiling: Config.addOnCeiling,
                    enrolledOrganizationID: (manager ?? .shared).profile?.officeAuthority?.organizationID)
    }

    static func trustKeys() -> AddOnStore.TrustKeys {
        AddOnStore.TrustKeys(vendorKeys: AddOnSignature.productionVendorKeys,
                             trustedOrganisations: trustedOrganisations())
    }

    static func conditions() -> AddOnAvailability.Conditions {
        AddOnAvailability.Conditions(addOnsEnabled: Config.addOnsEnabled,
                                     hipaaMode: Config.hipaaMode,
                                     region: Locale.current.region?.identifier,
                                     policy: policy())
    }

    static func admission(nativeToolNames: Set<String>) -> AddOnAdmission.Context {
        AddOnAdmission.Context(vendorKeys: AddOnSignature.productionVendorKeys,
                               trustedOrganisations: trustedOrganisations(),
                               policy: policy(),
                               nativeToolNames: nativeToolNames,
                               currentBuild: Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0)
    }
}
