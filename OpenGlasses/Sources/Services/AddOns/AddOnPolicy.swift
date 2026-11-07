import Foundation

/// What an organisation allows of add-ons on its phones — a ceiling over the trust classes, plus
/// which organisation the phone is enrolled with. Pure over an injected value: the install phase
/// reads it from the enrolled organisation profile; until then callers pass it.
///
/// Ceilings only ever subtract. With no ceiling every class may install and run (community files
/// still go through the approval sheet); each ceiling refuses more, and combining two keeps the
/// stricter (`strictest(_:_:)`). One rule holds under every ceiling: an organisation-signed add-on
/// belongs to its organisation, so it installs and runs only on a phone enrolled with that same
/// organisation.
struct AddOnPolicy: Equatable, Sendable {

    /// The organisation ceilings, from loosest to strictest.
    enum Ceiling: Int, Comparable, CaseIterable, Equatable, Sendable {
        /// No organisation limit.
        case noCeiling = 0
        /// Signed only, from any signer the phone trusts: no community add-ons.
        case signedOnly = 1
        /// Only add-ons signed by the enrolled organisation — nothing from the vendor's public
        /// catalogue either.
        case organisationSignedOnly = 2
        /// The whole feature is off.
        case addOnsDisabled = 3

        static func < (lhs: Ceiling, rhs: Ceiling) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var ceiling: Ceiling
    /// The organisation the phone is enrolled with, if any.
    var enrolledOrganizationID: String?

    /// No organisation: nothing is limited beyond the trust classes themselves.
    static let unmanaged = AddOnPolicy(ceiling: .noCeiling, enrolledOrganizationID: nil)

    init(ceiling: Ceiling = .noCeiling, enrolledOrganizationID: String? = nil) {
        self.ceiling = ceiling
        self.enrolledOrganizationID = enrolledOrganizationID
    }

    /// The stricter of two ceilings — what applies when two sources each set one.
    static func strictest(_ a: Ceiling, _ b: Ceiling) -> Ceiling { max(a, b) }

    /// Why an add-on may not install or run under this policy.
    enum Refusal: Error, Equatable, Sendable {
        /// The organisation has turned add-ons off.
        case addOnsDisabled
        /// The organisation allows signed add-ons only, and this one is not signed.
        case communityNotAllowed
        /// The organisation allows only add-ons it signed itself.
        case notSignedByOrganisation
        /// It is signed by an organisation, but not the one the phone is enrolled with (or the
        /// phone is enrolled with none).
        case otherOrganisation(signedBy: String, enrolled: String?)
    }

    /// Whether an add-on of this class may install, and run, now. Nil means allowed.
    func refusal(for trust: AddOnTrustClass) -> Refusal? {
        if ceiling == .addOnsDisabled { return .addOnsDisabled }
        if case .organisationSigned(let id) = trust, id != enrolledOrganizationID {
            return .otherOrganisation(signedBy: id, enrolled: enrolledOrganizationID)
        }
        switch (ceiling, trust) {
        case (.signedOnly, .community), (.organisationSignedOnly, .community):
            return .communityNotAllowed
        case (.organisationSignedOnly, .vendorSigned):
            return .notSignedByOrganisation
        default:
            return nil
        }
    }

    func allows(_ trust: AddOnTrustClass) -> Bool { refusal(for: trust) == nil }
}
