import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Sealed company credentials: the company secret in the activation file, and the Workiz key sealed under it in the profile.
extension CustomerTests {
    var fixtureKey: String { "wz_fixture_0123456789abcdefa1b2" }

    func testACredentialSealsAndOpensOnlyForItsSecretProfileAndName() throws {
        let secret = ProfileContract.Credential.newSecret()
        XCTAssertEqual(secret.count, 32)
        XCTAssertNotEqual(secret, ProfileContract.Credential.newSecret())
        let box = try ProfileContract.Credential.seal(fixtureKey, name: "workiz", profileId: "fixture-profile", companySecret: secret)
        XCTAssertFalse(box.contains(fixtureKey))
        XCTAssertNotEqual(box, try ProfileContract.Credential.seal(fixtureKey, name: "workiz", profileId: "fixture-profile", companySecret: secret),
                          "a fresh nonce every time")
        XCTAssertEqual(try ProfileContract.Credential.open(box, name: "workiz", profileId: "fixture-profile", companySecret: secret), fixtureKey)
        for (profileId, other) in [("fixture-profile", ProfileContract.Credential.newSecret()), ("another-profile", secret)] {
            XCTAssertThrowsError(try ProfileContract.Credential.open(box, name: "workiz", profileId: profileId, companySecret: other)) {
                XCTAssertEqual($0 as? ProfileContract.Credential.Problem, .unreadable)
            }
        }
        XCTAssertThrowsError(try ProfileContract.Credential.seal(fixtureKey, name: "servicetitan", profileId: "p", companySecret: secret))
        for bad in ["short", "has a space in it", String(repeating: "k", count: 257), "tab\there-and-more"] {
            XCTAssertThrowsError(try ProfileContract.Credential.seal(bad, name: "workiz", profileId: "p", companySecret: secret)) {
                XCTAssertEqual($0 as? ProfileContract.Credential.Problem, .invalidValue)
            }
        }
        XCTAssertThrowsError(try ProfileContract.Credential.seal(fixtureKey, name: "workiz", profileId: "p", companySecret: Data(count: 16)))
    }

    /// Fixed inputs, so the app's mirror (`OrgCredentialSeal`) can be checked against the same box.
    func testTheSealingKeyAndAuthenticatedDataArePinned() throws {
        let secret = Data((0..<32).map { UInt8($0) })
        let key = ProfileContract.Credential.key(secret).withUnsafeBytes { Data($0) }
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                              info: Data("openglasses.org-credential.v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        XCTAssertEqual(key, expected)
        XCTAssertEqual(ProfileContract.Credential.authenticated(name: "workiz", profileId: "fixture-profile"),
                       Data("openglasses.org-credential.v1\nfixture-profile\nworkiz".utf8))
        let box = try AES.GCM.seal(Data(fixtureKey.utf8), using: SymmetricKey(data: expected),
                                   nonce: AES.GCM.Nonce(data: Data(repeating: 7, count: 12)),
                                   authenticating: Data("openglasses.org-credential.v1\nfixture-profile\nworkiz".utf8))
        XCTAssertEqual(try ProfileContract.Credential.open(XCTUnwrap(box.combined).base64EncodedString(), name: "workiz",
                                                           profileId: "fixture-profile", companySecret: secret), fixtureKey)
    }

    func testVersionOneActivationFilesStillOpenWithoutASecret() throws {
        let canonical = ActivationKeyMint.generate()
        let v1 = try ActivationKeyMint.seal("fixture.licence.code", canonical: canonical)
        XCTAssertEqual(ActivationKeyMint.open(v1, canonical: canonical), .init(licenceCode: "fixture.licence.code", companySecret: nil))
        let secret = ProfileContract.Credential.newSecret()
        let v2 = try ActivationKeyMint.seal("fixture.licence.code", companySecret: secret, canonical: canonical)
        XCTAssertEqual(ActivationKeyMint.open(v2, canonical: canonical), .init(licenceCode: "fixture.licence.code", companySecret: secret))
        XCTAssertNil(ActivationKeyMint.open(v2, canonical: ActivationKeyMint.generate()))
        XCTAssertThrowsError(try ActivationKeyMint.seal("x", companySecret: Data(count: 31), canonical: canonical))
        // The version 2 plaintext is the sorted-key JSON object the app reads (JSONEncoder escapes "/" in the base64).
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: v2))), using: ActivationKeyMint.sealingKey(canonical: canonical))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self).components(separatedBy: "\"").filter { ["companySecret", "format", "licenceCode", "version"].contains($0) },
                       ["companySecret", "format", "licenceCode", "version"], "keys in sorted order")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(object.count, 4)
        XCTAssertEqual(object["companySecret"] as? String, secret.base64EncodedString())
        XCTAssertEqual(object["format"] as? String, "openglasses.activation")
        XCTAssertEqual(object["licenceCode"] as? String, "fixture.licence.code")
        XCTAssertEqual((object["version"] as? NSNumber)?.intValue, 2)
        // Pinned against a secret containing "/" and "+", the characters JSON may escape.
        let slashed = Data(base64Encoded: "//+/" + String(repeating: "A", count: 39) + "=")!
        XCTAssertEqual(ActivationKeyMint.open(try ActivationKeyMint.seal("c", companySecret: slashed, canonical: canonical), canonical: canonical)?.companySecret, slashed)
    }

    func testTheProfileCarriesTheWorkizKeySealedNeverReadable() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        let full = try XCTUnwrap(pay(&book))
        XCTAssertThrowsError(try book.sealCredential(fixtureKey, name: "workiz", customerId: "c1", companySecret: ProfileContract.Credential.newSecret())) {
            XCTAssertEqual($0 as? CustomerRefusal, .companySecretMismatch)
        }
        let box = try book.sealCredential(fixtureKey, name: "workiz", customerId: "c1", companySecret: s.companySecret)
        let document = try book.profileDocument(customerId: "c1", code: full.code, preset: preset, grant: grant, credentials: ["workiz": box],
                                                keyID: "fixture", issued: date(2), signer: profileKey.signature(for:))
        let text = String(decoding: try XCTUnwrap(Data(base64Encoded: String(document.split(separator: ".")[0]))), as: UTF8.self)
        XCTAssertFalse(text.contains(fixtureKey)); XCTAssertFalse(document.contains(fixtureKey))
        XCTAssertFalse(text.contains(s.companySecret.base64EncodedString()))
        let carried = try XCTUnwrap(profile(document).credentials?["workiz"])
        XCTAssertEqual(try ProfileContract.Credential.open(carried, name: "workiz", profileId: "fixture-profile", companySecret: s.companySecret), fixtureKey)
        // Sealing with the licence code would have been readable from the public profile: the code is not the key.
        let code = try XCTUnwrap(profile(document).licenceCode)
        let fromCode = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                              info: Data("openglasses.org-credential.v1".utf8), outputByteCount: 32)
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: carried))), using: fromCode,
                                              authenticating: Data("openglasses.org-credential.v1\nfixture-profile\nworkiz".utf8)))
        // Without credentials the profile is the same document as before.
        let plain = try book.profileDocument(customerId: "c1", code: full.code, preset: preset, grant: grant,
                                             keyID: "fixture", issued: date(2), signer: profileKey.signature(for:))
        XCTAssertNil(try profile(plain).credentials); XCTAssertNil(try payload(ofProfile: plain)["credentials"])
        // The journal records the secret's id, never the secret, the key or the box.
        let json = String(decoding: try IssuanceWire.encoder().encode(book.ledger), as: UTF8.self)
        for secret in [fixtureKey, box, s.companySecret.base64EncodedString()] { XCTAssertFalse(json.contains(secret)) }
    }

    func testProfileCredentialsAreChecked() throws {
        var book = try SalesBook(); _ = try signUp(&book)
        let full = try XCTUnwrap(pay(&book))
        func build(_ credentials: [String: String]) throws -> String {
            try book.profileDocument(customerId: "c1", code: full.code, preset: preset, grant: grant, credentials: credentials,
                                     keyID: "fixture", issued: date(2), signer: profileKey.signature(for:))
        }
        let shaped = Data(repeating: 1, count: 60).base64EncodedString()
        XCTAssertThrowsError(try build(["servicetitan": shaped]))
        XCTAssertThrowsError(try build(["workiz": "not base64!"]))
        XCTAssertThrowsError(try build(["workiz": Data(repeating: 1, count: 12).base64EncodedString()]))
        XCTAssertThrowsError(try build(["workiz": fixtureKey]), "a readable key is never a box")
        XCTAssertThrowsError(try ProfileContract.check(.init(profileId: "p", organizationName: "o", leaseDays: 30, credentials: [:]),
                                                       adminPasscode: false, now: now))
        XCTAssertNoThrow(try ProfileContract.check(.init(profileId: "p", organizationName: "o", leaseDays: 30, credentials: ["workiz": shaped]),
                                                   adminPasscode: false, now: now))
    }

    func testACustomerSignedUpBeforeSealedCredentialsGetsASecretAtItsNextRotation() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        let full = try XCTUnwrap(pay(&book))
        // As the journal reads for a customer signed up before this change: no secret id.
        var legacy = s.customer; legacy.companySecretId = nil
        var ledger = book.ledger
        try ledger.append(.customerChange(.init(customer: legacy, at: date(2), operatorId: "fixture", kind: .preset)))
        book = try SalesBook(ledger: ledger)
        XCTAssertThrowsError(try book.sealCredential(fixtureKey, name: "workiz", customerId: "c1", companySecret: s.companySecret)) {
            XCTAssertEqual($0 as? CustomerRefusal, .noCompanySecret)
        }
        XCTAssertThrowsError(try book.profileDocument(customerId: "c1", code: full.code, preset: preset, grant: grant,
                                                      credentials: ["workiz": Data(repeating: 1, count: 60).base64EncodedString()],
                                                      keyID: "fixture", issued: date(2), signer: profileKey.signature(for:))) {
            XCTAssertEqual($0 as? CustomerRefusal, .noCompanySecret)
        }
        let rotated = try book.rotateActivationKey(customerId: "c1", currentCode: full.code, operatorId: "fixture", now: date(3))
        XCTAssertEqual(rotated.customer.companySecretId, ProfileContract.Credential.secretId(rotated.companySecret))
        XCTAssertEqual(ActivationKeyMint.open(rotated.sealedFile, canonical: rotated.activationKey.replacingOccurrences(of: "-", with: ""))?.companySecret,
                       rotated.companySecret)
        XCTAssertNoThrow(try book.sealCredential(fixtureKey, name: "workiz", customerId: "c1", companySecret: rotated.companySecret))
    }

    func testWorkizEnabledIsAProfileOwnedFlag() throws {
        XCTAssertEqual(ProfileContract.allowList["workizEnabled"], "owned:bool")
        XCTAssertNoThrow(try ProfileContract.checkSetting("workizEnabled", .init(value: .bool(true), disposition: "owned")))
        XCTAssertThrowsError(try ProfileContract.checkSetting("workizEnabled", .init(value: .string("yes"), disposition: "owned")))
    }
}
