import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

@MainActor
final class OfficeInlineEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let profileSigner = Curve25519.Signing.PrivateKey()
    private let licenceSigner = Curve25519.Signing.PrivateKey()
    private let administrator = Curve25519.Signing.PrivateKey()

    private var profileKeys: [String: String] {
        ["profile-test": profileSigner.publicKey.rawRepresentation.base64EncodedString()]
    }
    private var licenceKey: String { licenceSigner.publicKey.rawRepresentation.base64EncodedString() }

    private func profile(organizationID: String = "northbridge", profileID: String = "northbridge-field",
                         embeddedLicence: String? = nil, schema: Int = 2) -> ConfigProfile {
        ConfigProfile(keyId: "profile-test", profileId: profileID, organizationName: "Northbridge",
                      issued: now.addingTimeInterval(-86_400),
                      policyExpiry: now.addingTimeInterval(86_400), leaseDays: 30,
                      licenceCode: embeddedLicence,
                      officeAuthority: schema == 2 ? .init(
                        organizationID: organizationID,
                        administratorPublicKey: administrator.publicKey.rawRepresentation.base64EncodedString(),
                        transportPolicy: "privateLan") : nil,
                      schemaVersion: schema)
    }

    private func code(organizationID: String? = "northbridge", profileID: String? = "northbridge-field",
                      hostedProfile: String? = nil, issued: Date? = nil,
                      expires: Date? = nil) throws -> String {
        try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: "Northbridge", issued: issued ?? now.addingTimeInterval(-86_400),
            expires: expires ?? now.addingTimeInterval(86_400), profile: hostedProfile,
            organizationID: organizationID, profileID: profileID),
            privateKeyBase64: licenceSigner.rawRepresentation.base64EncodedString())
    }

    private func document(_ profile: ConfigProfile) throws -> String {
        try ProfileVerification.makeDocument(profile,
            privateKeyBase64: profileSigner.rawRepresentation.base64EncodedString())
    }

    private func verify(_ profile: ConfigProfile, code: String) throws -> OfficeInlineEntitlement.Verified {
        try OfficeInlineEntitlement.verify(profileDocument: document(profile), licenceCode: code,
                                           profileKeys: profileKeys, licenceKey: licenceKey, now: now)
    }

    func testTwoIndependentVendorSignaturesBindOneStableOrganizationAndProfile() throws {
        let result = try verify(profile(), code: code())
        XCTAssertEqual(result.profile.profileId, "northbridge-field")
        XCTAssertEqual(result.licence.organizationID, result.root.organizationID)
        XCTAssertEqual(result.licence.profileID, result.root.profileID)
        XCTAssertEqual(result.root.administratorPublicKey, administrator.publicKey.rawRepresentation)
    }

    func testDisplayNameAndLegacyCodeCannotStandInForStableBinding() throws {
        for oldOrForeign in [try code(organizationID: nil, profileID: nil),
                             try code(organizationID: "other-firm"),
                             try code(profileID: "other-profile") ] {
            XCTAssertThrowsError(try verify(profile(), code: oldOrForeign)) {
                XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .missingOrWrongBinding)
            }
        }
        XCTAssertThrowsError(try verify(profile(schema: 1), code: code())) {
            XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .untrustedProfile)
        }
    }

    func testDesktopCodeCannotSecretlyRequireHostedProfileOrActivationDirectory() throws {
        XCTAssertThrowsError(try verify(profile(), code: code(hostedProfile: "https://example.test/profile"))) {
            XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .hostedProfileRoute)
        }
    }

    func testEmbeddedLicenceCannotDisagreeWithDeliveredLicence() throws {
        let delivered = try code()
        let other = try code(issued: now.addingTimeInterval(-60))
        XCTAssertThrowsError(try verify(profile(embeddedLicence: other), code: delivered)) {
            XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .conflictingEmbeddedLicence)
        }
        XCTAssertNoThrow(try verify(profile(embeddedLicence: delivered), code: delivered))
    }

    func testExpiredAndFutureClaimsAreRefusedAtDesktopEnrolment() throws {
        for bad in [try code(issued: now.addingTimeInterval(1)),
                    try code(expires: now)] {
            XCTAssertThrowsError(try verify(profile(), code: bad)) {
                XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .notCurrentlyValid)
            }
        }
    }

    func testTamperingEitherSignedDocumentIsRefused() throws {
        let validCode = try code()
        let validProfile = try document(profile())
        let parts = validCode.split(separator: ".").map(String.init)
        var signature = try XCTUnwrap(Data(base64Encoded: parts[1]))
        signature[signature.startIndex] ^= 1
        let modifiedCode = parts[0] + "." + signature.base64EncodedString()
        XCTAssertThrowsError(try OfficeInlineEntitlement.verify(
            profileDocument: validProfile, licenceCode: modifiedCode,
            profileKeys: profileKeys, licenceKey: licenceKey, now: now))
        let wrongProfileKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try OfficeInlineEntitlement.verify(
            profileDocument: validProfile, licenceCode: validCode,
            profileKeys: ["profile-test": wrongProfileKey], licenceKey: licenceKey, now: now)) {
            XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .untrustedProfile)
        }
    }

    func testLocalSetupFileCarriesTheSignedPairWithoutGrantingTrustItself() throws {
        let original = OfficeSetupPackage.Contents(version: 1, profileDocument: try document(profile()),
                                                   licenceCode: try code())
        let decoded = try OfficeSetupPackage.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertNoThrow(try verify(profile(), code: decoded.licenceCode))
        let unsignedForeignCode = try code(organizationID: "foreign-office")
        let foreign = OfficeSetupPackage.Contents(version: 1, profileDocument: original.profileDocument,
                                                  licenceCode: unsignedForeignCode)
        let parsedForeign = try OfficeSetupPackage.decode(JSONEncoder().encode(foreign))
        XCTAssertThrowsError(try OfficeInlineEntitlement.verify(
            profileDocument: parsedForeign.profileDocument, licenceCode: parsedForeign.licenceCode,
            profileKeys: profileKeys, licenceKey: licenceKey, now: now)) {
            XCTAssertEqual($0 as? OfficeInlineEntitlement.Refusal, .missingOrWrongBinding)
        }
    }

    func testLocalSetupFileRejectsOversizeDuplicateAndUnknownFields() throws {
        let valid = try JSONEncoder().encode(OfficeSetupPackage.Contents(
            version: 1, profileDocument: try document(profile()), licenceCode: try code()))
        let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
        for malformed in [text.replacingOccurrences(of: "{", with: "{\"version\":1,", range: text.startIndex..<text.endIndex),
                          text.replacingOccurrences(of: "{", with: "{\"hostedURL\":\"https://example.test\",", range: text.startIndex..<text.endIndex),
                          text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")] {
            XCTAssertThrowsError(try OfficeSetupPackage.decode(Data(malformed.utf8))) {
                XCTAssertEqual($0 as? OfficeSetupPackage.Refusal, .malformed)
            }
        }
        XCTAssertThrowsError(try OfficeSetupPackage.decode(Data(repeating: 65, count: OfficeSetupPackage.maximumBytes + 1)))
    }
}
