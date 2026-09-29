import Foundation

/// A vendor-signed licence and vendor-signed profile delivered together by the desktop.
/// Neither a matching display name nor an administrator-signed peer binding can create an
/// entitlement. Existing hosted-profile licences remain on their separate legacy ingress.
enum OfficeInlineEntitlement {
    struct Verified {
        let profile: ConfigProfile
        let licence: LicenseService.LicensePayload
        let root: OfficePeerBinding.VendorRoot
    }

    enum Refusal: Error, Equatable {
        case malformed
        case untrustedProfile
        case untrustedLicence
        case missingOrWrongBinding
        case hostedProfileRoute
        case conflictingEmbeddedLicence
        case notCurrentlyValid
    }

    static func verify(profileDocument: String, licenceCode: String,
                       profileKeys: [String: String] = ProfileVerification.productionKeys,
                       licenceKey: String = LicenseService.productionPublicKeyBase64,
                       now: Date) throws -> Verified {
        guard profileDocument.utf8.count <= 32_768, licenceCode.utf8.count <= 16_384 else {
            throw Refusal.malformed
        }
        guard let document = try? ProfileVerification.verify(profileDocument, keys: profileKeys),
              case .profile(let profile) = document,
              profile.schemaVersion == 2,
              profile.officeAuthority != nil else { throw Refusal.untrustedProfile }
        guard let licence = try? LicenseService.decode(code: licenceCode, publicKeyBase64: licenceKey) else {
            throw Refusal.untrustedLicence
        }
        guard licence.organizationID == profile.officeAuthority?.organizationID,
              licence.profileID == profile.profileId,
              OfficeManualAssignment.safeIdentifier(licence.organizationID ?? ""),
              OfficeManualAssignment.safeIdentifier(licence.profileID ?? "") else {
            throw Refusal.missingOrWrongBinding
        }
        guard licence.profile == nil else { throw Refusal.hostedProfileRoute }
        if let embedded = profile.licenceCode,
           embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            != licenceCode.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw Refusal.conflictingEmbeddedLicence
        }
        guard profile.issued <= now, licence.issued <= now,
              profile.policyExpiry.map({ now < $0 }) ?? true,
              licence.expires.map({ now < $0 }) ?? true else { throw Refusal.notCurrentlyValid }
        let root = try OfficePeerBinding.vendorRoot(profileDocument: profileDocument,
                                                    vendorKeys: profileKeys, now: now)
        return Verified(profile: profile, licence: licence, root: root)
    }
}
