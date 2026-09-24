import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT P1 — verifying an organisation profile or revocation. Tests sign with ephemeral keys
/// under a test key id, so they never need the production private key.
@MainActor
final class OrgProfileVerificationTests: XCTestCase {

    private let keyId = "test-key"
    private var privateKey: Curve25519.Signing.PrivateKey!
    private var keys: [String: String] = [:]

    override func setUp() {
        super.setUp()
        privateKey = Curve25519.Signing.PrivateKey()
        keys = [keyId: privateKey.publicKey.rawRepresentation.base64EncodedString()]
    }

    private var privateKeyBase64: String { privateKey.rawRepresentation.base64EncodedString() }

    private func profile(schemaVersion: Int = ConfigProfile.supportedSchemaVersion,
                         policyExpiry: Date? = nil,
                         licenceCode: String? = nil) -> ConfigProfile {
        ConfigProfile(
            keyId: keyId, profileId: "northbridge-field", organizationName: "Northbridge Mechanical",
            issued: Date(timeIntervalSince1970: 1_790_000_000), policyExpiry: policyExpiry,
            leaseDays: 30, licenceCode: licenceCode,
            settings: ["privacyFilterEnabled": RawSetting(.bool(true), .ceiling)],
            schemaVersion: schemaVersion)
    }

    /// Sign arbitrary bytes under an arbitrary domain — for building documents the real minting
    /// path would never produce.
    private func document(payload: Data, domain: Data) throws -> String {
        let signature = try privateKey.signature(for: domain + payload)
        return "\(payload.base64EncodedString()).\(signature.base64EncodedString())"
    }

    // MARK: - Round trips

    func testSignedProfileVerifies() throws {
        let original = profile()
        let text = try ProfileVerification.makeDocument(original, privateKeyBase64: privateKeyBase64)
        XCTAssertEqual(try ProfileVerification.verify(text, keys: keys), .profile(original))
    }

    func testSignedRevocationVerifies() throws {
        let revocation = ProfileRevocation(keyId: keyId, profileId: "northbridge-field",
                                           issued: Date(timeIntervalSince1970: 1_790_000_000))
        let text = try ProfileVerification.makeDocument(revocation, privateKeyBase64: privateKeyBase64)
        XCTAssertEqual(try ProfileVerification.verify(text, keys: keys), .revocation(revocation))
    }

    // MARK: - Refusals

    func testTamperedPayloadIsRefused() throws {
        let text = try ProfileVerification.makeDocument(profile(), privateKeyBase64: privateKeyBase64)
        let parts = text.split(separator: ".").map(String.init)
        var payload = try XCTUnwrap(Data(base64Encoded: parts[0]))
        let json = String(decoding: payload, as: UTF8.self)
            .replacingOccurrences(of: "Northbridge Mechanical", with: "Someone Else Entirely")
        payload = Data(json.utf8)
        let tampered = "\(payload.base64EncodedString()).\(parts[1])"
        XCTAssertThrowsError(try ProfileVerification.verify(tampered, keys: keys)) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .badSignature)
        }
    }

    func testUnknownKeyIdIsRefusedByName() throws {
        let text = try ProfileVerification.makeDocument(profile(), privateKeyBase64: privateKeyBase64)
        XCTAssertThrowsError(try ProfileVerification.verify(text, keys: ["other": keys[keyId]!])) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .unknownKey(self.keyId))
        }
    }

    func testRightKeyIdWrongKeyIsRefused() throws {
        let text = try ProfileVerification.makeDocument(profile(), privateKeyBase64: privateKeyBase64)
        let impostor = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try ProfileVerification.verify(text, keys: [keyId: impostor])) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .badSignature)
        }
    }

    /// Signed without the domain prefix — the licence code's construction — is not a profile.
    func testProfileSignedLikeALicenceIsRefused() throws {
        let payload = try ProfileVerification.encoder.encode(profile())
        let text = try document(payload: payload, domain: Data())
        XCTAssertThrowsError(try ProfileVerification.verify(text, keys: keys)) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .badSignature)
        }
    }

    /// A profile payload signed under the revocation domain must not verify as either.
    func testProfileSignedUnderTheRevocationDomainIsRefused() throws {
        let payload = try ProfileVerification.encoder.encode(profile())
        let text = try document(payload: payload, domain: ProfileVerification.revocationDomain)
        XCTAssertThrowsError(try ProfileVerification.verify(text, keys: keys)) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .badSignature)
        }
    }

    func testLicenceCodeIsNotAProfileAndAProfileIsNotALicenceCode() throws {
        let licence = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: Date(), expires: nil)
        let code = try LicenseService.makeCode(payload: licence, privateKeyBase64: privateKeyBase64)
        XCTAssertThrowsError(try ProfileVerification.verify(code, keys: keys)) {
            XCTAssertEqual($0 as? ProfileVerification.Failure, .malformed)
        }

        let text = try ProfileVerification.makeDocument(profile(), privateKeyBase64: privateKeyBase64)
        XCTAssertThrowsError(try LicenseService.decode(code: text, publicKeyBase64: keys[keyId]!))
    }

    func testNewerSchemaIsRefusedWithAReason() throws {
        let text = try ProfileVerification.makeDocument(
            profile(schemaVersion: ConfigProfile.supportedSchemaVersion + 1),
            privateKeyBase64: privateKeyBase64)
        XCTAssertThrowsError(try ProfileVerification.verify(text, keys: keys)) {
            XCTAssertEqual($0 as? ProfileVerification.Failure,
                           .unsupportedSchema(ConfigProfile.supportedSchemaVersion + 1))
        }
    }

    func testGarbageIsMalformed() {
        for text in ["", "not a profile", "a.b.c", "Zm9v.YmFy"] {
            XCTAssertThrowsError(try ProfileVerification.verify(text, keys: keys)) {
                XCTAssertEqual($0 as? ProfileVerification.Failure, .malformed, text)
            }
        }
    }

    // MARK: - Clocks at enrolment

    func testPolicyExpiryIsARefusalNamingThatClock() {
        let ended = Date(timeIntervalSince1970: 1_790_000_000)
        let refusal = ProfileVerification.enrolmentRefusal(
            for: profile(policyExpiry: ended), now: ended.addingTimeInterval(1), licenceKey: keys[keyId]!)
        XCTAssertEqual(refusal, .policyExpired(ended))
    }

    func testLicenceExpiryIsARefusalNamingThatClock() throws {
        let expired = Date(timeIntervalSince1970: 1_790_000_000)
        let licence = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: expired.addingTimeInterval(-86_400),
                                                    expires: expired)
        let code = try LicenseService.makeCode(payload: licence, privateKeyBase64: privateKeyBase64)
        let refusal = ProfileVerification.enrolmentRefusal(
            for: profile(licenceCode: code), now: expired.addingTimeInterval(1), licenceKey: keys[keyId]!)
        XCTAssertEqual(refusal, .licenceExpired(expired))
    }

    func testForgedLicenceIsARefusal() throws {
        let licence = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: Date(), expires: nil)
        let forger = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let code = try LicenseService.makeCode(payload: licence, privateKeyBase64: forger)
        XCTAssertEqual(ProfileVerification.enrolmentRefusal(
            for: profile(licenceCode: code), now: Date(), licenceKey: keys[keyId]!), .licenceInvalid)
    }

    func testLiveClocksAndNoLicenceAreNotRefused() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(ProfileVerification.enrolmentRefusal(for: profile(), now: now, licenceKey: keys[keyId]!))

        let licence = LicenseService.LicensePayload(feature: "field_assist", licensee: "Northbridge",
                                                    issued: now, expires: now.addingTimeInterval(86_400))
        let code = try LicenseService.makeCode(payload: licence, privateKeyBase64: privateKeyBase64)
        XCTAssertNil(ProfileVerification.enrolmentRefusal(
            for: profile(policyExpiry: now.addingTimeInterval(86_400), licenceCode: code),
            now: now, licenceKey: keys[keyId]!))
    }

    // MARK: - The production keyring

    func testProductionKeyringHoldsTheCurrentKeyAndItIsNoOtherKey() throws {
        let current = try XCTUnwrap(ProfileVerification.productionKeys[ProfileVerification.currentKeyId])
        let data = try XCTUnwrap(Data(base64Encoded: current))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data))
        for key in ProfileVerification.productionKeys.values {
            XCTAssertNotEqual(key, LicenseService.productionPublicKeyBase64,
                              "the profile key must be distinct from the licence key")
            XCTAssertNotEqual(key, SkillPackSignature.productionPublicKeyBase64,
                              "the profile key must be distinct from the pack key")
        }
    }

    // MARK: - Source

    func testOnlyAnMDMDeliveredProfileIsNotLocallyRemovable() {
        XCTAssertTrue(ProfileSource.link.isLocallyRemovable)
        XCTAssertTrue(ProfileSource.scan.isLocallyRemovable)
        XCTAssertFalse(ProfileSource.managedConfig.isLocallyRemovable)
    }
}
