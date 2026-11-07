import Foundation

/// Who stands behind an add-on file, as its signature proves — never as the file claims.
///
/// `AddOnSignature.resolve` is the only thing that produces a signed class: a bare file is
/// `community`, and so is any file whose signature fails for any reason (an edited byte, an
/// unknown key, an organisation the phone does not trust). The class decides whether the file may
/// hold reserved capabilities (`RecipeAddOnValidator`) and whether an organisation's ceiling lets
/// it install or run (`AddOnPolicy`).
enum AddOnTrustClass: Equatable, Hashable, Sendable {
    /// Nobody signed it (a file, link or QR), or its signature did not verify. Holds only the
    /// four ordinary permissions.
    case community
    /// Signed with the vendor's key.
    case vendorSigned
    /// Signed with the administrator key of the named organisation, as the phone's enrolled
    /// organisation profile vouches for it.
    case organisationSigned(organizationID: String)

    var isSigned: Bool { self != .community }

    /// Whether a file in this class may name a reserved capability.
    var mayHoldReservedCapabilities: Bool { isSigned }

    /// The organisation that signed it, for an organisation-signed file.
    var organizationID: String? {
        if case .organisationSigned(let id) = self { return id }
        return nil
    }
}
