import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Plan JS P0b — customers and presets.
final class CustomerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = Curve25519.Signing.PrivateKey()
    let profileKey = Curve25519.Signing.PrivateKey()
    let catalog = VerifiedPackCatalog(verifiedKeys: ["hvac", "electrical", "other"])
    var grant: PartnerGrant {
        PartnerGrant(partnerId: "fixture-partner", packs: ["hvac", "electrical"], maxTermDays: 365,
                     maxSeatsPerCode: 10, seatQuota: 30, pilotsAllowed: true, maxPilotDays: 14,
                     validFrom: now.addingTimeInterval(-86_400), validUntil: now.addingTimeInterval(800 * 86_400),
                     prices: PriceTable(currency: "XXX", taxTreatment: "fixture only", perSeatByTermDays: [365: 100]),
                     maxUnpaidSeats: 10)
    }
    var preset: ProfilePreset {
        ProfilePreset(id: "field-assist", version: 1, edition: "fieldAssist", leaseDays: 365,
                      settings: ["privacyFilterEnabled": .init(value: .bool(true), disposition: "ceiling")],
                      choices: .init(vaultPacks: [.init(packId: "fixture.hvac", licensePack: "hvac"), .init(packId: "fixture.other", licensePack: "other")],
                                     aiModels: [.init(provider: "anthropic", model: "claude-sonnet-5-5")],
                                     settings: ["refrigerationUnits": .init(disposition: "default", values: [.string("kPa,C,kg"), .string("psi,F,lb")])]))
    }
    var newCustomer: NewCustomer {
        NewCustomer(customerId: "c1", licensee: "Fixture Ltd", organizationID: "fixture-org", profileId: "fixture-profile",
                    selection: .init(vaultPack: "fixture.hvac", aiModel: .init(provider: "anthropic", model: "claude-sonnet-5-5"),
                                     settings: ["refrigerationUnits": .string("kPa,C,kg")]))
    }
    func date(_ day: Int) -> Date { now.addingTimeInterval(Double(day) * 86_400) }
    func signUp(_ book: inout SalesBook, _ new: NewCustomer? = nil, seats: Int = 2, preset p: ProfilePreset? = nil) throws -> SignUp {
        try book.signUp(new ?? newCustomer, orderId: "o1", order: .init(seats: seats, termDays: 365, packs: ["hvac"], reference: "partner-ref"),
                        preset: p ?? preset, profileBase: "https://fixture.invalid", grant: grant, catalog: catalog,
                        bankDetails: "FIXTURE BANK", operatorId: "fixture-partner-user", now: now, signer: key.signature(for:))
    }
    @discardableResult func pay(_ book: inout SalesBook, _ invoice: String = "INV-000001", amount: Int64 = 200, day: Int = 1, id: String = "p1") throws -> IssuedCode? {
        try book.recordPayment(Payment(id: id, invoiceNumber: invoice, amountMinor: amount, receivedAt: date(day), bankReference: "fixture-ref"),
                               confirmed: true, operatorId: "fixture-vendor", now: date(day), signer: key.signature(for:))
    }
    func open(_ sealed: String, key display: String) throws -> String {
        let canonical = display.replacingOccurrences(of: "-", with: "")
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)), info: Data("openglasses.activation-key.v1".utf8), outputByteCount: 32)
        return String(decoding: try AES.GCM.open(AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: sealed))), using: derived), as: UTF8.self)
    }
    /// Typed, so a value compares the same on every platform (Linux's JSONSerialization reads `true` back as 1).
    func profile(_ document: String) throws -> ProfileContract.Document {
        try IssuanceWire.decoder().decode(ProfileContract.Document.self, from: XCTUnwrap(Data(base64Encoded: String(document.split(separator: ".")[0]))))
    }
    func payload(ofProfile document: String) throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64Encoded: String(document.split(separator: ".")[0])))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSignUpSealsTheFirstCodeAndTheLedgerKeepsNoKey() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        XCTAssertEqual(s.customer.profileAddress, "https://fixture.invalid/p/fixture-profile")
        XCTAssertEqual(s.code.payload.profile, s.customer.profileAddress); XCTAssertEqual(s.code.payload.licensee, "Fixture Ltd")
        XCTAssertEqual(s.code.payload.expires, date(35)); XCTAssertEqual(s.code.record.phase, .provisional)
        let opened = try XCTUnwrap(ActivationKeyMint.open(s.sealedFile, canonical: s.activationKey.replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(opened, .init(licenceCode: s.code.code, companySecret: s.companySecret))
        XCTAssertEqual(s.customer.companySecretId, ProfileContract.Credential.secretId(s.companySecret))
        XCTAssertEqual(s.customer.activationFile, ActivationKeyMint.fileName(s.activationKey.replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(book.ledger.entries.count, 1); XCTAssertEqual(book.ledger.invoices.count, 1)
        XCTAssertEqual(book.ledger.orders.first?.customerId, "c1"); XCTAssertEqual(book.ledger.customers["c1"], s.customer)
        let json = String(decoding: try IssuanceWire.encoder().encode(book.ledger), as: UTF8.self)
        for secret in [s.activationKey, s.activationKey.replacingOccurrences(of: "-", with: ""), s.sealedFile, s.code.code,
                       s.companySecret.base64EncodedString()] {
            XCTAssertFalse(json.contains(secret))
        }
        let reopened = try IssuanceWire.decoder().decode(Ledger.self, from: IssuanceWire.encoder().encode(book.ledger))
        XCTAssertNoThrow(try reopened.verify(expectedHead: book.ledger.entries.last?.rowHash))
        XCTAssertThrowsError(try signUp(&book)) { XCTAssertEqual($0 as? CustomerRefusal, .customerExists) }
        var other = newCustomer; other.customerId = "c2"; other.organizationID = "other-org"
        XCTAssertThrowsError(try signUp(&book, other)) { XCTAssertEqual($0 as? CustomerRefusal, .customerExists) }
    }

    func testFixedFieldsCannotChangeAfterSignUp() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        let c = s.customer
        let altered = [
            Customer(customerId: c.customerId, partnerId: c.partnerId, licensee: "Renamed Ltd", organizationID: c.organizationID, profileId: c.profileId, profileAddress: c.profileAddress, activationFile: c.activationFile, presetId: c.presetId, presetVersion: c.presetVersion, presetDigest: c.presetDigest, selection: c.selection),
            Customer(customerId: c.customerId, partnerId: c.partnerId, licensee: c.licensee, organizationID: c.organizationID, profileId: "another", profileAddress: c.profileAddress, activationFile: c.activationFile, presetId: c.presetId, presetVersion: c.presetVersion, presetDigest: c.presetDigest, selection: c.selection),
            Customer(customerId: c.customerId, partnerId: c.partnerId, licensee: c.licensee, organizationID: c.organizationID, profileId: c.profileId, profileAddress: "https://elsewhere.invalid/p/fixture-profile", activationFile: c.activationFile, presetId: c.presetId, presetVersion: c.presetVersion, presetDigest: c.presetDigest, selection: c.selection),
            Customer(customerId: c.customerId, partnerId: c.partnerId, licensee: c.licensee, organizationID: "other-org", profileId: c.profileId, profileAddress: c.profileAddress, activationFile: c.activationFile, presetId: c.presetId, presetVersion: c.presetVersion, presetDigest: c.presetDigest, selection: c.selection),
        ]
        for customer in altered {
            var ledger = book.ledger
            XCTAssertThrowsError(try ledger.append(.customerChange(.init(customer: customer, at: date(1), operatorId: "fixture", kind: .preset)))) {
                XCTAssertEqual($0 as? Ledger.IntegrityError, .customerMismatch(2))
            }
        }
        // An order outside the customer API cannot take over the customer's profile.
        var r = IssuanceRequest(licensee: "Fixture Ltd", seats: 1, termDays: 365, reference: "raw", profile: c.profileAddress)
        XCTAssertThrowsError(try book.order(id: "raw", request: r, grant: grant, catalog: catalog, profileId: "raw-profile", bankDetails: "B", operatorId: "o", now: date(1), signer: key.signature(for:)))
        r.profile = "https://fixture.invalid/p/raw"
        XCTAssertThrowsError(try book.order(id: "raw", request: r, grant: grant, catalog: catalog, profileId: c.profileId, bankDetails: "B", operatorId: "o", now: date(1), signer: key.signature(for:)))
    }

    func testLaterOrdersReuseTheProfileAndOneLiveCode() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        let order = CustomerOrder(seats: 2, termDays: 365, packs: ["hvac"], reference: "second")
        func place(_ id: String, at day: Int, renewal: String? = nil) throws -> IssuedCode? {
            try book.order(id: id, customerId: "c1", order: order, renewalOf: renewal, grant: grant, catalog: catalog,
                           bankDetails: "FIXTURE BANK", operatorId: "fixture", now: date(day), signer: key.signature(for:))
        }
        XCTAssertThrowsError(try place("early", at: 1)) { XCTAssertEqual($0 as? CustomerRefusal, .openOrder) }
        let full = try XCTUnwrap(pay(&book))
        XCTAssertEqual(full.payload.profile, s.customer.profileAddress); XCTAssertEqual(full.payload.expires, date(365))
        XCTAssertThrowsError(try place("second", at: 2)) { XCTAssertEqual($0 as? CustomerRefusal, .liveCodeExists) }
        var wrong = grant; wrong.partnerId = "someone-else"
        XCTAssertThrowsError(try book.order(id: "x", customerId: "c1", order: order, grant: wrong, catalog: catalog, bankDetails: "B", operatorId: "o", now: date(2), signer: key.signature(for:))) {
            XCTAssertEqual($0 as? CustomerRefusal, .wrongPartner)
        }
        XCTAssertNil(try place("renewal", at: 300, renewal: "o1"))
        let renewed = try XCTUnwrap(pay(&book, "INV-000002", day: 301, id: "p2"))
        XCTAssertEqual(renewed.payload.profile, s.customer.profileAddress); XCTAssertEqual(renewed.payload.expires, date(730))
        XCTAssertEqual(book.ledger.orders.last?.profileId, "fixture-profile")
        XCTAssertEqual(book.ledger.currentIssuance(for: "c1")?.issuanceId, renewed.record.issuanceId)
        // After the last code lapses, a fresh order starts again with a provisional code at the same address.
        let fresh = try XCTUnwrap(place("returning", at: 731))
        XCTAssertEqual(fresh.payload.profile, s.customer.profileAddress); XCTAssertEqual(fresh.payload.expires, date(766))
        XCTAssertEqual(book.ledger.orders.filter { $0.customerId == "c1" }.map(\.profileId), Array(repeating: "fixture-profile", count: 3))
    }

    func testSeatIncreaseIsCoTermedProRatedAndCountsAgainstQuota() throws {
        var book = try SalesBook(); _ = try signUp(&book)
        func increase(_ id: String, _ seats: Int, at day: Int, g: PartnerGrant? = nil) throws {
            try book.increaseSeats(id: id, customerId: "c1", additionalSeats: seats, grant: g ?? grant, catalog: catalog,
                                   bankDetails: "FIXTURE BANK", operatorId: "fixture", now: date(day))
        }
        XCTAssertThrowsError(try increase("too-soon", 1, at: 1)) { XCTAssertEqual($0 as? CustomerRefusal, .openOrder) }
        let paid = try XCTUnwrap(pay(&book))
        XCTAssertThrowsError(try increase("too-many", 9, at: 100)) { XCTAssertEqual($0 as? IssuanceRefusal, .seatsPerCodeExceeded(10)) }
        try increase("more", 3, at: 100)
        let invoice = try XCTUnwrap(book.ledger.invoices.last)
        // Three seats at 100 a year for 265 of its 365 days is 217.8, rounded half up to 218.
        XCTAssertEqual(invoice.seats, 3); XCTAssertEqual(invoice.coTermedDays, 265); XCTAssertEqual(invoice.totalMinor, 218)
        XCTAssertEqual(book.ledger.currentIssuance(for: "c1")?.issuanceId, paid.record.issuanceId, "no code until the increase is paid")
        XCTAssertThrowsError(try increase("again", 1, at: 101)) { XCTAssertEqual($0 as? CustomerRefusal, .openOrder) }
        let raised = try XCTUnwrap(pay(&book, "INV-000002", amount: 218, day: 110, id: "p2"))
        XCTAssertEqual(raised.payload.seats, 5); XCTAssertEqual(raised.payload.expires, paid.payload.expires)
        XCTAssertEqual(raised.record.replaces, paid.record.issuanceId); XCTAssertEqual(raised.payload.profile, paid.payload.profile)
        XCTAssertEqual(book.ledger.state(of: book.ledger.orders[0], now: date(110)), .replaced)
        XCTAssertEqual(book.ledger.state(of: book.ledger.orders[1], now: date(110)), .active)
        XCTAssertEqual(book.ledger.currentIssuance(for: "c1")?.issuanceId, raised.record.issuanceId)
        var g = grant; g.seatQuota = 5
        let probe = IssuanceRequest(licensee: "Probe", seats: 1, termDays: 365, reference: "probe", profile: "https://fixture.invalid/p/probe")
        guard case .failure(let refusal) = IssuancePolicy.validate(probe, grant: g, ledger: book.ledger, catalog: catalog, now: date(111)) else {
            return XCTFail("the increase's seats must count against the quota")
        }
        XCTAssertEqual(refusal, .quotaExceeded(0))
        XCTAssertThrowsError(try increase("lapsed", 1, at: 365)) { XCTAssertEqual($0 as? CustomerRefusal, .noPaidLiveCode) }
    }

    func testPresetRefusesAnythingItDoesNotList() throws {
        func refused(_ change: (inout NewCustomer) -> Void, preset p: ProfilePreset? = nil, _ expected: PresetRefusal, line: UInt = #line) {
            var book = try! SalesBook(); var c = newCustomer; change(&c)
            XCTAssertThrowsError(try signUp(&book, c, preset: p), line: line) { XCTAssertEqual($0 as? PresetRefusal, expected, line: line) }
            XCTAssertTrue(book.ledger.entries.isEmpty, line: line)
        }
        refused({ $0.selection.settings["refrigerationUnits"] = .string("bar,K,g") }, .valueNotOffered("refrigerationUnits"))
        refused({ $0.selection.settings["agentModeEnabled"] = .bool(false) }, .settingNotOffered("agentModeEnabled"))
        refused({ $0.selection.vaultPack = "fixture.other" }, .packNotInGrant("other"))
        refused({ $0.selection.vaultPack = "unlisted" }, .packNotOffered("unlisted"))
        refused({ $0.selection.aiModel = .init(provider: "openai", model: "gpt-6") }, .aiModelNotOffered)
        refused({ $0.selection.aiModel = .init(provider: "anthropic", model: "claude-sonnet-5-5", name: "sk-ant-fixture") }, .aiModelCarriesKey)
        refused({ $0.selection.aiModel = .init(provider: "openrouter", model: "x", baseURL: "https://fixture.invalid/v1?key=abc") }, .aiModelCarriesKey)
        var p = preset; p.choices.aiModels.append(.init(provider: "custom", model: "m", baseURL: "https://fixture.invalid", name: "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7"))
        refused({ _ in }, preset: p, .aiModelCarriesKey)
        p = preset; p.leaseDays = 59
        refused({ _ in }, preset: p, .invalidPreset("leaseDays must be 60–365 (got 59)"))
        p = preset; p.choices.settings["privacyFilterEnabled"] = .init(disposition: "ceiling", values: [.bool(true)])
        refused({ _ in }, preset: p, .invalidPreset("privacyFilterEnabled is both fixed and a choice"))
        p = preset; p.choices.settings["agentModeEnabled"] = .init(disposition: "ceiling", values: [.bool(true)])
        refused({ _ in }, preset: p, .invalidPreset("agentModeEnabled may only be pinned to false"))
        p = preset; p.settings["notASetting"] = .init(value: .bool(true), disposition: "default")
        refused({ _ in }, preset: p, .invalidPreset("notASetting is not a setting a profile may set (see SettingKey)"))
        XCTAssertFalse(ProfilePreset.carriesKey(.init(provider: "openrouter", model: "meta-llama/llama-3.1-405b-instruct", baseURL: "https://openrouter.ai/api/v1")))
    }

    func testPasscodeVerifierIsCheckedAndOnlyItsHashReachesTheProfile() throws {
        var book = try SalesBook(); _ = try signUp(&book)
        let full = try XCTUnwrap(pay(&book))
        let salt = Data(repeating: 7, count: 16).base64EncodedString(), hash = Data(repeating: 9, count: 32).base64EncodedString()
        func set(_ v: ProfileContract.PasscodeVerifier, _ p: ProfilePreset? = nil) throws {
            try book.setAdminPasscode(customerId: "c1", verifier: v, preset: p ?? preset, grant: grant, operatorId: "fixture", now: date(2))
        }
        for bad in [ProfileContract.PasscodeVerifier(salt: salt, iterations: 9_999, hash: hash),
                    .init(salt: salt, iterations: 5_000_001, hash: hash),
                    .init(salt: Data(repeating: 7, count: 15).base64EncodedString(), iterations: 210_000, hash: hash),
                    .init(salt: salt, iterations: 210_000, hash: Data(repeating: 9, count: 31).base64EncodedString())] {
            XCTAssertThrowsError(try set(bad)) { XCTAssertEqual($0 as? PresetRefusal, .invalidVerifier) }
        }
        let doc = { try self.payload(ofProfile: book.profileDocument(customerId: "c1", code: full.code, preset: self.preset, grant: self.grant, keyID: "fixture", issued: self.date(2), signer: self.profileKey.signature(for:))) }
        XCTAssertNil(try doc()["adminPasscode"])
        let good = ProfileContract.PasscodeVerifier(salt: salt, iterations: 210_000, hash: hash)
        try set(good)
        let signed = try book.profileDocument(customerId: "c1", code: full.code, preset: preset, grant: grant, keyID: "fixture", issued: date(2), signer: profileKey.signature(for:))
        XCTAssertEqual(try profile(signed).adminPasscode, good)
        var edited = preset; edited.leaseDays = 200
        XCTAssertThrowsError(try set(good, edited)) { XCTAssertEqual($0 as? PresetRefusal, .presetChanged) }
    }

    func testProfileFromPresetCarriesTheCurrentCodeAndChoices() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        func doc(_ code: String, _ p: ProfilePreset? = nil) throws -> String {
            try book.profileDocument(customerId: "c1", code: code, preset: p ?? preset, grant: grant, keyID: "fixture-profile", issued: date(1), signer: profileKey.signature(for:))
        }
        let first = try payload(ofProfile: doc(s.code.code))
        XCTAssertEqual(first["licenceCode"] as? String, s.code.code); XCTAssertEqual(first["organizationName"] as? String, "Fixture Ltd")
        XCTAssertEqual(first["profileId"] as? String, "fixture-profile"); XCTAssertEqual(first["leaseDays"] as? Int, 365)
        XCTAssertEqual(first["edition"] as? String, "fieldAssist"); XCTAssertNil(first["eraseAfterLapseDays"]); XCTAssertNil(first["policyExpiry"])
        XCTAssertEqual((first["vaultPack"] as? [String: Any])?["packId"] as? String, "fixture.hvac")
        let settings = try profile(doc(s.code.code)).settings
        XCTAssertEqual(settings["refrigerationUnits"], .init(value: .string("kPa,C,kg"), disposition: "default"))
        XCTAssertEqual(settings["privacyFilterEnabled"], .init(value: .bool(true), disposition: "ceiling"))
        let full = try XCTUnwrap(pay(&book))
        XCTAssertThrowsError(try doc(s.code.code)) { XCTAssertEqual($0 as? CustomerRefusal, .notCurrentCode) }
        XCTAssertEqual(try payload(ofProfile: doc(full.code))["licenceCode"] as? String, full.code)
        var edited = preset; edited.settings["agentModeEnabled"] = .init(value: .bool(false), disposition: "ceiling")
        XCTAssertThrowsError(try doc(full.code, edited)) { XCTAssertEqual($0 as? PresetRefusal, .presetChanged) }
        let next = ProfilePreset(id: edited.id, version: 2, edition: edited.edition, leaseDays: edited.leaseDays, settings: edited.settings, choices: edited.choices)
        XCTAssertThrowsError(try doc(full.code, next)) { XCTAssertEqual($0 as? PresetRefusal, .unknownPreset) }
        try book.changePreset(customerId: "c1", to: next, selection: newCustomer.selection, grant: grant, operatorId: "fixture", now: date(2))
        XCTAssertEqual(try profile(doc(full.code, next)).settings["agentModeEnabled"], .init(value: .bool(false), disposition: "ceiling"))
    }

    func testRotatedKeyOpensToTheCurrentCodeAndListsTheOldFile() throws {
        var book = try SalesBook(); let s = try signUp(&book)
        let full = try XCTUnwrap(pay(&book))
        XCTAssertThrowsError(try book.rotateActivationKey(customerId: "c1", currentCode: s.code.code, operatorId: "fixture", now: date(2))) {
            XCTAssertEqual($0 as? CustomerRefusal, .notCurrentCode)
        }
        XCTAssertThrowsError(try book.rotateActivationKey(customerId: "c1", currentCode: full.code, operatorId: "fixture", now: date(2))) {
            XCTAssertEqual($0 as? CustomerRefusal, .companySecretMismatch, "a customer with a secret keeps it")
        }
        let rotated = try book.rotateActivationKey(customerId: "c1", currentCode: full.code, companySecret: s.companySecret,
                                                   operatorId: "fixture", now: date(2))
        XCTAssertEqual(ActivationKeyMint.open(rotated.sealedFile, canonical: rotated.activationKey.replacingOccurrences(of: "-", with: "")),
                       .init(licenceCode: full.code, companySecret: s.companySecret))
        XCTAssertEqual(rotated.customer.companySecretId, s.customer.companySecretId)
        XCTAssertFalse(rotated.newCompanySecret)
        XCTAssertEqual(rotated.retiredFile, s.customer.activationFile); XCTAssertNotEqual(rotated.customer.activationFile, s.customer.activationFile)
        XCTAssertEqual(book.ledger.customers["c1"]?.activationFile, rotated.customer.activationFile)
        XCTAssertEqual(book.ledger.retiredActivationFiles(for: "c1"), [s.customer.activationFile])
        XCTAssertThrowsError(try open(rotated.sealedFile, key: s.activationKey))
        let json = String(decoding: try IssuanceWire.encoder().encode(book.ledger), as: UTF8.self)
        XCTAssertFalse(json.contains(rotated.activationKey.replacingOccurrences(of: "-", with: ""))); XCTAssertFalse(json.contains(rotated.sealedFile))
    }

    func testVendorMoveKeepsTheCustomerAndHandsOrdersToTheNewPartner() throws {
        var book = try SalesBook(); _ = try signUp(&book); try pay(&book)
        try book.moveCustomer(customerId: "c1", toPartner: "fixture-partner-2", operatorId: "fixture-vendor", now: date(2))
        XCTAssertThrowsError(try book.increaseSeats(id: "inc", customerId: "c1", additionalSeats: 1, grant: grant, catalog: catalog, bankDetails: "B", operatorId: "o", now: date(3))) {
            XCTAssertEqual($0 as? CustomerRefusal, .wrongPartner)
        }
        var g = grant; g.partnerId = "fixture-partner-2"
        XCTAssertNoThrow(try book.increaseSeats(id: "inc", customerId: "c1", additionalSeats: 1, grant: g, catalog: catalog, bankDetails: "B", operatorId: "o", now: date(3)))
        XCTAssertEqual(book.ledger.customers["c1"]?.licensee, "Fixture Ltd")
    }
}
