import XCTest
import CryptoKit
@testable import OpenGlasses

/// How a profile or an office assignment names an organisation add-on: strict decode, validation,
/// and whether a fetched, verified envelope is the add-on referenced.
final class AddOnReferenceTests: XCTestCase {

    private typealias S = AddOnSigningFixtures
    private typealias R = AddOnReference

    private let acme = S.KeyPair()
    private let globex = S.KeyPair()
    private let vendor = S.KeyPair()

    private let base: [String: Any] = [
        "id": "org.example.test",
        "version": "1.0.0",
        "organizationID": "acme-heating",
        "url": "https://addons.example.org/test-1.0.0.json",
    ]

    private func reference(_ changes: [String: Any] = [:]) throws -> R {
        try R.decode(base.merging(changes) { _, new in new })
    }

    private func resolve(_ envelope: Data) throws -> AddOnSignature.Resolution {
        try AddOnSignature.resolve(envelope, vendorKeys: [S.vendorKeyID: vendor.publicBase64],
                                   trustedOrganisations: ["acme-heating": acme.publicBase64, "globex": globex.publicBase64])
    }

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: - Decode

    func testDecodesFromJSONAndObject() throws {
        let fromObject = try reference()
        XCTAssertEqual(fromObject, R(id: "org.example.test", version: "1.0.0", organizationID: "acme-heating",
                                     url: "https://addons.example.org/test-1.0.0.json"))
        let data = try JSONSerialization.data(withJSONObject: base)
        XCTAssertEqual(try R.decode(data), fromObject)
        XCTAssertTrue(fromObject.isValid)
        XCTAssertEqual(fromObject.fetchURL?.absoluteString, "https://addons.example.org/test-1.0.0.json")
    }

    func testDecodeIsStrict() {
        XCTAssertThrowsError(try reference(["file": "e30="])) {
            XCTAssertEqual($0 as? R.DecodeError, .unknownKey("file"), "a reference never embeds the add-on")
        }
        for key in ["id", "version", "organizationID", "url"] {
            var missing = base
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try R.decode(missing)) { XCTAssertEqual($0 as? R.DecodeError, .missing(key)) }
            XCTAssertThrowsError(try reference([key: 3])) { XCTAssertEqual($0 as? R.DecodeError, .wrongType(key)) }
        }
        XCTAssertThrowsError(try reference(["sha256": 3])) { XCTAssertEqual($0 as? R.DecodeError, .wrongType("sha256")) }
        XCTAssertThrowsError(try R.decode(Data("[]".utf8))) { XCTAssertEqual($0 as? R.DecodeError, .notJSON) }
    }

    // MARK: - Validate

    func testIDAndVersionUseTheManifestRules() throws {
        XCTAssertEqual(try reference(["id": "Not.Reverse DNS"]).validationIssues, [.idInvalid])
        XCTAssertEqual(try reference(["id": "single"]).validationIssues, [.idInvalid])
        XCTAssertEqual(try reference(["version": "1.0"]).validationIssues, [.versionInvalid])
        XCTAssertEqual(try reference(["version": "01.0.0"]).validationIssues, [.versionInvalid])
        XCTAssertTrue(try reference(["version": "2.1.0-beta.1"]).isValid)
        XCTAssertEqual(try reference(["organizationID": ".."]).validationIssues, [.organizationIDInvalid])
        XCTAssertEqual(try reference(["organizationID": "acme heating"]).validationIssues, [.organizationIDInvalid])
    }

    func testURLMustBeHTTPSWithNoUserinfo() throws {
        for bad in ["http://addons.example.org/a.json",
                    "https://user:pass@addons.example.org/a.json",
                    "https://user@addons.example.org/a.json",
                    "https:///a.json",
                    "ftp://addons.example.org/a.json",
                    "https://addons.example.org/a.json#frag",
                    "https://{{host}}/a.json",
                    "https://addons.example.org/a b.json",
                    "addons.example.org/a.json",
                    "https://addons.example.org/" + String(repeating: "a", count: R.maxURLLength)] {
            let r = try reference(["url": bad])
            XCTAssertEqual(r.validationIssues, [.urlInvalid], bad)
            XCTAssertNil(r.fetchURL, bad)
        }
        XCTAssertTrue(try reference(["url": "https://addons.example.org:8443/a.json?v=1"]).isValid)
    }

    func testDigestShape() throws {
        XCTAssertTrue(try reference(["sha256": String(repeating: "a", count: 64)]).isValid)
        XCTAssertEqual(try reference(["sha256": String(repeating: "A", count: 64)]).validationIssues, [.sha256Invalid])
        XCTAssertEqual(try reference(["sha256": "abc"]).validationIssues, [.sha256Invalid])
    }

    // MARK: - Match

    func testTheReferencedOrganisationAddOnMatches() throws {
        let bytes = S.file(reserved: [.credentials])
        let resolution = try resolve(try S.orgEnvelope(bytes, key: acme, organizationID: "acme-heating"))
        let manifest = try reference().check(resolution).get()
        XCTAssertEqual(manifest.id, "org.example.test")
        XCTAssertEqual(manifest.permissions.reserved, [.credentials])
        XCTAssertTrue(RecipeAddOnValidator.validate(resolution).isAccepted)
        XCTAssertNoThrow(try reference(["sha256": hex(bytes)]).check(resolution).get())
    }

    func testAnotherOrganisationsAddOnIsRefused() throws {
        let resolution = try resolve(try S.orgEnvelope(S.file(), key: globex, organizationID: "globex"))
        XCTAssertEqual(resolution.trust, .organisationSigned(organizationID: "globex"))
        XCTAssertEqual(mismatch(try reference(), resolution), .otherOrganisation(expected: "acme-heating", signedBy: "globex"))
    }

    func testAVendorOrCommunityFileIsNotAnOrganisationAddOn() throws {
        let vendorSigned = try resolve(try S.vendorEnvelope(S.file(), key: vendor))
        XCTAssertEqual(mismatch(try reference(), vendorSigned), .notOrganisationSigned(.vendorSigned, nil))

        let bare = try resolve(S.file())
        XCTAssertEqual(mismatch(try reference(), bare), .notOrganisationSigned(.community, nil))
    }

    func testAnEditedOrganisationFileIsRefusedNotDemotedIntoInstalling() throws {
        let bytes = S.file()
        var object = try S.object(try S.orgEnvelope(bytes, key: acme, organizationID: "acme-heating"))
        object["file"] = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Done.", with: "Dome.").utf8)
            .base64EncodedString()
        let resolution = try resolve(try S.data(object))
        XCTAssertEqual(mismatch(try reference(), resolution), .notOrganisationSigned(.community, .badSignature))
    }

    func testIDVersionAndDigestMustMatch() throws {
        let other = try resolve(try S.orgEnvelope(S.file(id: "org.example.other"), key: acme, organizationID: "acme-heating"))
        XCTAssertEqual(mismatch(try reference(), other), .idMismatch(expected: "org.example.test", found: "org.example.other"))

        let newer = try resolve(try S.orgEnvelope(S.file(version: "1.1.0"), key: acme, organizationID: "acme-heating"))
        XCTAssertEqual(mismatch(try reference(), newer), .versionMismatch(expected: "1.0.0", found: "1.1.0"))

        let right = try resolve(try S.orgEnvelope(S.file(), key: acme, organizationID: "acme-heating"))
        XCTAssertEqual(mismatch(try reference(["sha256": String(repeating: "0", count: 64)]), right), .digestMismatch)
    }

    func testSignedBytesThatAreNotAnAddOnAreRefused() throws {
        let resolution = try resolve(try S.orgEnvelope(Data(#"{"hello":1}"#.utf8), key: acme, organizationID: "acme-heating"))
        guard case .notAnAddOn = mismatch(try reference(), resolution) else {
            return XCTFail("expected notAnAddOn")
        }
    }

    func testAnInvalidReferenceMatchesNothing() throws {
        let resolution = try resolve(try S.orgEnvelope(S.file(), key: acme, organizationID: "acme-heating"))
        XCTAssertEqual(mismatch(try reference(["url": "http://addons.example.org/a.json"]), resolution),
                       .referenceInvalid([.urlInvalid]))
    }

    private func mismatch(_ reference: R, _ resolution: AddOnSignature.Resolution) -> R.Mismatch? {
        if case .failure(let m) = reference.check(resolution) { return m }
        return nil
    }
}
