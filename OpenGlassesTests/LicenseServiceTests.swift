import XCTest
import CryptoKit
@testable import OpenGlasses

/// Field Assist license-code validation: a code signed by the matching private key activates the
/// feature; tampered, wrong-feature, expired, or wrong-key codes are rejected. Tests sign with an
/// ephemeral keypair and inject its public key, so they never need the production private key.
@MainActor
final class LicenseServiceTests: XCTestCase {

    private var privateKey: Curve25519.Signing.PrivateKey!
    private var service: LicenseService!

    override func setUp() {
        super.setUp()
        privateKey = Curve25519.Signing.PrivateKey()
        service = LicenseService(publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString())
        service.clear()
    }

    override func tearDown() {
        service.clear()
        super.tearDown()
    }

    private var privateKeyBase64: String { privateKey.rawRepresentation.base64EncodedString() }

    /// The entitlement a gate would compute right now from the stored code, verified with this
    /// test's key. Asserting through this rather than a cached flag is the point: the code is the
    /// evidence.
    private func storedCodeDecision() -> FieldAssistEntitlementDecision {
        let provider = LiveFieldAssistEntitlementProvider(
            storePurchases: VerifiedStorePurchaseRecorder(),
            licensePublicKeyBase64: service.publicKeyBase64)
        return FieldAssistEntitlementEvaluator.decide(provider.evidence())
    }

    private func code(feature: String = "field_assist", licensee: String = "Acme Co", expires: Date? = nil) throws -> String {
        let payload = LicenseService.LicensePayload(feature: feature, licensee: licensee, issued: Date(), expires: expires)
        return try LicenseService.makeCode(payload: payload, privateKeyBase64: privateKeyBase64)
    }

    func testValidCodeActivates() throws {
        let payload = try service.activate(code: try code(licensee: "Globex"))
        XCTAssertEqual(payload.licensee, "Globex")
        XCTAssertTrue(Config.fieldAssistLicenseValid)
        XCTAssertTrue(storedCodeDecision().isGranted)
        XCTAssertNotNil(service.activeLicense)
    }

    func testFutureExpiryActivatesPastExpiryRejected() throws {
        let future = try service.activate(code: try code(expires: Date().addingTimeInterval(86_400)))
        XCTAssertNotNil(future.expires)

        service.clear()
        XCTAssertThrowsError(try service.activate(code: try code(expires: Date().addingTimeInterval(-86_400)))) { error in
            guard case LicenseService.LicenseError.expired = error else {
                return XCTFail("Expected .expired, got \(error)")
            }
        }
        XCTAssertFalse(Config.fieldAssistLicenseValid)
    }

    func testTamperedSignatureRejected() throws {
        var valid = try code()
        // Flip a character in the signature half.
        let parts = valid.split(separator: ".")
        let sig = String(parts[1])
        let mutated = sig.first == "A" ? "B" + sig.dropFirst() : "A" + sig.dropFirst()
        valid = "\(parts[0]).\(mutated)"
        XCTAssertThrowsError(try service.verify(code: valid)) { error in
            guard case LicenseService.LicenseError.badSignature = error else {
                return XCTFail("Expected .badSignature, got \(error)")
            }
        }
    }

    func testWrongFeatureRejected() throws {
        XCTAssertThrowsError(try service.verify(code: try code(feature: "some_other_product"))) { error in
            guard case LicenseService.LicenseError.wrongFeature = error else {
                return XCTFail("Expected .wrongFeature, got \(error)")
            }
        }
    }

    func testCodeFromDifferentKeyRejected() throws {
        // Sign with a foreign key the service doesn't trust.
        let foreign = Curve25519.Signing.PrivateKey()
        let payload = LicenseService.LicensePayload(feature: "field_assist", licensee: "X", issued: Date(), expires: nil)
        let foreignCode = try LicenseService.makeCode(payload: payload, privateKeyBase64: foreign.rawRepresentation.base64EncodedString())
        XCTAssertThrowsError(try service.verify(code: foreignCode)) { error in
            guard case LicenseService.LicenseError.badSignature = error else {
                return XCTFail("Expected .badSignature, got \(error)")
            }
        }
    }

    func testClearDropsEntitlement() throws {
        _ = try service.activate(code: try code())
        XCTAssertTrue(storedCodeDecision().isGranted)
        service.clear()
        XCTAssertFalse(Config.fieldAssistLicenseValid)
        XCTAssertFalse(storedCodeDecision().isGranted)
        XCTAssertNil(service.activeLicense)
    }

    func testMalformedCodeRejected() {
        XCTAssertThrowsError(try service.verify(code: "not-a-valid-code")) { error in
            guard case LicenseService.LicenseError.malformed = error else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }
}
