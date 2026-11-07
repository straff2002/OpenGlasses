import XCTest
import CryptoKit
@testable import OpenGlasses

/// Signed add-ons: the envelope, the exact-bytes signature, domain separation, and demotion to
/// community on every kind of failure. Ephemeral keys only.
final class AddOnSignatureTests: XCTestCase {

    private typealias S = AddOnSigningFixtures

    private let vendor = S.KeyPair()
    private let acme = S.KeyPair()
    private let globex = S.KeyPair()

    private var vendorKeys: [String: String] { [S.vendorKeyID: vendor.publicBase64] }
    private var trusted: [String: String] { ["acme-heating": acme.publicBase64, "globex": globex.publicBase64] }

    private func resolve(_ data: Data, orgs: [String: String]? = nil) throws -> AddOnSignature.Resolution {
        try AddOnSignature.resolve(data, vendorKeys: vendorKeys, trustedOrganisations: orgs ?? trusted)
    }

    // MARK: - Valid signatures

    func testVendorSignatureVerifies() throws {
        let bytes = S.file(reserved: [.credentials])
        let r = try resolve(try S.vendorEnvelope(bytes, key: vendor))
        XCTAssertEqual(r.trust, .vendorSigned)
        XCTAssertEqual(r.fileBytes, bytes, "the exact bytes signed come back")
        XCTAssertNil(r.failure)
        XCTAssertTrue(r.wasSigned)
        XCTAssertTrue(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testOrganisationSignatureVerifies() throws {
        let bytes = S.file(reserved: [.parts, .workRecord, .office])
        let r = try resolve(try S.orgEnvelope(bytes, key: acme, organizationID: "acme-heating"))
        XCTAssertEqual(r.trust, .organisationSigned(organizationID: "acme-heating"))
        XCTAssertEqual(r.fileBytes, bytes)
        XCTAssertNil(r.failure)
        XCTAssertTrue(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testABareFileIsCommunity() throws {
        let bytes = S.file()
        let r = try resolve(bytes)
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.fileBytes, bytes)
        XCTAssertNil(r.failure)
        XCTAssertFalse(r.wasSigned)
        XCTAssertTrue(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testNonJSONAndOtherFormatsAreBareFilesForTheValidatorToJudge() throws {
        for data in [Data("not json".utf8), Data(#"{"format":"avenkin.addon/2"}"#.utf8), Data("[1]".utf8)] {
            let r = try resolve(data)
            XCTAssertEqual(r.trust, .community)
            XCTAssertEqual(r.fileBytes, data)
            XCTAssertFalse(RecipeAddOnValidator.validate(r).isAccepted)
        }
    }

    func testTheProductionVendorKeyIsThePackKey() {
        XCTAssertEqual(AddOnSignature.productionVendorKeys, [AddOnSignature.vendorKeyID: SkillPackSignature.productionPublicKeyBase64])
        XCTAssertNotEqual(AddOnSignature.productionVendorKeys.values.first, LicenseService.productionPublicKeyBase64)
        XCTAssertTrue(AddOnSignature.isValidPublicKey(SkillPackSignature.productionPublicKeyBase64))
    }

    func testTheSigningDomainAndFormatArePinned() {
        // Never change these: every signed add-on already issued would demote to community.
        XCTAssertEqual(String(decoding: AddOnSignature.signingDomain, as: UTF8.self), "avenkin.addon-signature/1\n")
        XCTAssertEqual(AddOnSignature.envelopeFormat, "avenkin.addon-signed/1")
        XCTAssertEqual(AddOnSignature.signingMessage(fileBytes: Data("x".utf8)), Data("avenkin.addon-signature/1\nx".utf8))
    }

    // MARK: - Demotion

    func testOneEditedByteDemotesToCommunity() throws {
        let bytes = S.file()
        var object = try S.object(try S.vendorEnvelope(bytes, key: vendor))
        var edited = bytes
        let index = try XCTUnwrap(edited.firstIndex(of: UInt8(ascii: "D")))   // "Done."
        edited[index] = UInt8(ascii: "G")
        object["file"] = edited.base64EncodedString()
        let r = try resolve(try S.data(object))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .badSignature)
        XCTAssertEqual(r.fileBytes, edited, "the demoted file is the bytes that arrived")
        XCTAssertTrue(RecipeAddOnValidator.validate(r).isAccepted, "an edited file with no reserved capability is an ordinary add-on")
    }

    func testADemotedFileNamingAReservedCapabilityIsRefused() throws {
        let bytes = S.file(reserved: [.credentials])
        var object = try S.object(try S.orgEnvelope(bytes, key: acme, organizationID: "acme-heating"))
        let edited = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Done.", with: "Dome.").utf8)
        object["file"] = edited.base64EncodedString()
        let r = try resolve(try S.data(object))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .badSignature)
        let report = RecipeAddOnValidator.validate(r)
        XCTAssertFalse(report.isAccepted)
        XCTAssertEqual(report.issues.map(\.code), [.reservedCapabilityNeedsSignature])
        XCTAssertEqual(report.issues.first?.path, "permissions.credentials")
    }

    func testASignatureFromAnotherKeyDemotes() throws {
        let impostor = S.KeyPair()
        let r = try resolve(try S.vendorEnvelope(S.file(reserved: [.parts]), key: impostor))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .badSignature)
        XCTAssertFalse(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testUnknownVendorKeyIDDemotes() throws {
        let r = try resolve(try S.vendorEnvelope(S.file(), key: vendor, keyId: "vendor-2099-01"))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .unknownKeyID("vendor-2099-01"))
    }

    func testUnknownOrganisationDemotes() throws {
        let stranger = S.KeyPair()
        let r = try resolve(try S.orgEnvelope(S.file(reserved: [.office]), key: stranger, organizationID: "initech"))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .unknownOrganisation("initech"))
        XCTAssertFalse(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testNoTrustedOrganisationsMeansNoOrganisationSignatureVerifies() throws {
        let r = try resolve(try S.orgEnvelope(S.file(), key: acme, organizationID: "acme-heating"), orgs: [:])
        XCTAssertEqual(r.failure, .unknownOrganisation("acme-heating"))
        XCTAssertEqual(r.trust, .community)
    }

    func testAnotherOrganisationsKeyUnderThisOrganisationsNameDemotes() throws {
        // Globex signs with its own key but claims to be Acme.
        let envelope = try S.orgEnvelope(S.file(reserved: [.parts]), key: globex, organizationID: "acme-heating")
        let r = try resolve(envelope)
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .organisationMismatch(named: "acme-heating", keyBelongsTo: "globex"))
    }

    func testOrganisationKeyIDThatMatchesNoTrustedKeyDemotes() throws {
        let envelope = try S.orgEnvelope(S.file(), key: acme, organizationID: "acme-heating", keyId: "org-0000000000000000")
        let r = try resolve(envelope)
        XCTAssertEqual(r.failure, .unknownKeyID("org-0000000000000000"))
        XCTAssertEqual(r.trust, .community)
    }

    func testOrganisationKeyIDWithTheRightIDButTheWrongKeyDemotes() throws {
        // Right key id for Acme, signed with Globex's private key.
        let envelope = try AddOnSignature.sign(fileBytes: S.file(), keyId: acme.orgKeyID, signer: .organisation,
                                               organizationID: "acme-heating", privateKeyBase64: globex.privateBase64)
        XCTAssertEqual(try resolve(envelope).failure, .badSignature)
    }

    func testAVendorKeyIDCannotSignAsAnOrganisation() throws {
        // The vendor's key is not an organisation's key: an envelope naming a trusted organisation
        // but signed by the vendor demotes.
        let envelope = try S.orgEnvelope(S.file(), key: vendor, organizationID: "acme-heating")
        let r = try resolve(envelope)
        XCTAssertEqual(r.trust, .community)
        XCTAssertNotNil(r.failure)
    }

    func testAnInvalidTrustedKeyDemotes() throws {
        let envelope = try S.orgEnvelope(S.file(), key: acme, organizationID: "acme-heating")
        let short = Data(repeating: 7, count: 31).base64EncodedString()
        XCTAssertEqual(try resolve(envelope, orgs: ["acme-heating": short]).failure, .trustedKeyInvalid)
        let vendorBad = try AddOnSignature.resolve(try S.vendorEnvelope(S.file(), key: vendor),
                                                   vendorKeys: [S.vendorKeyID: "not base64"])
        XCTAssertEqual(vendorBad.failure, .trustedKeyInvalid)
        XCTAssertEqual(vendorBad.trust, .community)
    }

    func testTheProductionDefaultsTrustNoTestKey() throws {
        // With the production vendor table and no enrolled organisation, a test-signed file demotes.
        let r = try AddOnSignature.resolve(try S.vendorEnvelope(S.file(), key: vendor, keyId: AddOnSignature.vendorKeyID))
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .badSignature)
    }

    // MARK: - Domain separation

    func testASkillPackSignatureOverTheSameBytesDoesNotVerify() throws {
        let bytes = S.file(reserved: [.credentials])
        let packSignature = try SkillPackSignature.sign(manifestData: bytes, payloadFiles: [:],
                                                        privateKeyBase64: vendor.privateBase64)
        XCTAssertTrue(SkillPackSignature.verify(signatureBase64: packSignature, manifestData: bytes, payloadFiles: [:],
                                                publicKeyBase64: vendor.publicBase64), "the pack signature is genuine")
        let envelope = try AddOnSignature.envelopeData(fileBytes: bytes, keyId: S.vendorKeyID, signer: .vendor,
                                                       organizationID: nil,
                                                       signature: try XCTUnwrap(Data(base64Encoded: packSignature)))
        let r = try resolve(envelope)
        XCTAssertEqual(r.trust, .community)
        XCTAssertEqual(r.failure, .badSignature)
        XCTAssertFalse(RecipeAddOnValidator.validate(r).isAccepted)
    }

    func testARawSignatureOverTheBytesDoesNotVerify() throws {
        // The catalog's shape: a signature straight over the payload bytes, no prefix.
        let bytes = S.file()
        let raw = try vendor.privateKey.signature(for: bytes)
        let envelope = try AddOnSignature.envelopeData(fileBytes: bytes, keyId: S.vendorKeyID, signer: .vendor,
                                                       organizationID: nil, signature: raw)
        XCTAssertEqual(try resolve(envelope).failure, .badSignature)
    }

    func testAnAddOnSignatureDoesNotVerifyAsASkillPackSignature() throws {
        let bytes = S.file()
        let object = try S.object(try S.vendorEnvelope(bytes, key: vendor))
        let signature = try XCTUnwrap(object["signature"] as? String)
        XCTAssertFalse(SkillPackSignature.verify(signatureBase64: signature, manifestData: bytes, payloadFiles: [:],
                                                 publicKeyBase64: vendor.publicBase64))
    }

    // MARK: - Envelope strict decode

    private func envelopeError(_ object: [String: Any]) throws -> AddOnSignature.EnvelopeError? {
        do {
            _ = try resolve(try S.data(object))
            return nil
        } catch let error as AddOnSignature.EnvelopeError {
            return error
        }
    }

    func testEnvelopeUnknownKeyIsRefused() throws {
        var object = try S.object(try S.vendorEnvelope(S.file(), key: vendor))
        object["trust"] = "vendor"
        XCTAssertEqual(try envelopeError(object), .unknownKey("trust"))
    }

    func testEnvelopeMissingAndWrongTypedFieldsAreRefused() throws {
        let base = try S.object(try S.vendorEnvelope(S.file(), key: vendor))
        for key in ["keyId", "signer", "file", "signature"] {
            var missing = base
            missing.removeValue(forKey: key)
            XCTAssertEqual(try envelopeError(missing), .missing(key), key)
            var wrong = base
            wrong[key] = 1
            XCTAssertEqual(try envelopeError(wrong), .wrongType(key), key)
        }
    }

    func testEnvelopeFieldShapesAreChecked() throws {
        let base = try S.object(try S.vendorEnvelope(S.file(), key: vendor))
        var signer = base; signer["signer"] = "community"
        XCTAssertEqual(try envelopeError(signer), .invalid(field: "signer", reason: "vendor or organisation"))

        var vendorWithOrg = base; vendorWithOrg["organizationID"] = "acme-heating"
        XCTAssertEqual(try envelopeError(vendorWithOrg)?.field, "organizationID")

        var orgWithout = base; orgWithout["signer"] = "organisation"
        XCTAssertEqual(try envelopeError(orgWithout), .missing("organizationID"))

        var badOrg = base; badOrg["signer"] = "organisation"; badOrg["organizationID"] = "../acme"
        XCTAssertEqual(try envelopeError(badOrg)?.field, "organizationID")

        var keyId = base; keyId["keyId"] = "vendor 2026"
        XCTAssertEqual(try envelopeError(keyId)?.field, "keyId")

        var file = base; file["file"] = "!!!"
        XCTAssertEqual(try envelopeError(file)?.field, "file")

        var empty = base; empty["file"] = ""
        XCTAssertEqual(try envelopeError(empty)?.field, "file")

        var shortSig = base; shortSig["signature"] = Data(repeating: 1, count: 63).base64EncodedString()
        XCTAssertEqual(try envelopeError(shortSig)?.field, "signature")

        var big = base; big["file"] = Data(repeating: 32, count: AddOnSignature.maxFileBytes + 1).base64EncodedString()
        XCTAssertEqual(try envelopeError(big)?.field, "file")
    }

    func testEnvelopeThatIsNotJSONOrTooLargeIsRefused() {
        XCTAssertThrowsError(try AddOnSignature.decodeEnvelope(Data("nope".utf8))) {
            XCTAssertEqual($0 as? AddOnSignature.EnvelopeError, .notJSON)
        }
        XCTAssertThrowsError(try AddOnSignature.decodeEnvelope(Data(repeating: 32, count: AddOnSignature.maxEnvelopeBytes + 1))) {
            XCTAssertEqual($0 as? AddOnSignature.EnvelopeError, .tooLarge)
        }
        XCTAssertThrowsError(try AddOnSignature.decodeEnvelope(Data(#"{"format":"avenkin.addon-signed/2"}"#.utf8))) {
            XCTAssertEqual($0 as? AddOnSignature.EnvelopeError, .unsupportedFormat("avenkin.addon-signed/2"))
        }
    }

    func testAnEnvelopeInsideAnEnvelopeIsNotAnAddOn() throws {
        let inner = try S.vendorEnvelope(S.file(), key: vendor)
        let r = try resolve(try S.vendorEnvelope(inner, key: vendor))
        XCTAssertEqual(r.trust, .vendorSigned)
        XCTAssertFalse(RecipeAddOnValidator.validate(r).isAccepted, "the signed bytes must themselves be an add-on file")
    }

    func testOrganisationKeyIDIsAFingerprintOfTheKey() {
        let id = acme.orgKeyID
        XCTAssertTrue(id.hasPrefix("org-"))
        XCTAssertEqual(id.count, 20)
        XCTAssertNotEqual(id, globex.orgKeyID)
        XCTAssertNil(AddOnSignature.keyID(forOrganisationKey: "short"))
    }
}

private extension AddOnSignature.EnvelopeError {
    var field: String? {
        if case .invalid(let field, _) = self { return field }
        return nil
    }
}
