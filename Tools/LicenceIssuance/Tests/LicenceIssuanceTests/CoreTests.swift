import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = Curve25519.Signing.PrivateKey()
    let catalog = VerifiedPackCatalog(verifiedKeys: ["hvac", "electrical", "other"])
    var grant: PartnerGrant {
        PartnerGrant(partnerId: "fixture-partner", packs: ["hvac", "electrical"], maxTermDays: 365,
                     maxSeatsPerCode: 10, seatQuota: 30, pilotsAllowed: true, maxPilotDays: 14,
                     validFrom: now.addingTimeInterval(-86_400), validUntil: now.addingTimeInterval(500 * 86_400),
                     prices: PriceTable(currency: "XXX", taxTreatment: "fixture only", perSeatByTermDays: [365: 100]),
                     maxUnpaidSeats: 10)
    }
    var request: IssuanceRequest {
        IssuanceRequest(licensee: "Fixture Ltd", seats: 2, termDays: 365, packs: ["electrical", "hvac"],
                        reference: "o1", profile: "https://fixture.invalid/p/customer")
    }
    func date(_ day: Int) -> Date { now.addingTimeInterval(Double(day) * 86_400) }
    func validate(_ r: IssuanceRequest, _ g: PartnerGrant? = nil, ledger: Ledger = Ledger(), at: Date? = nil) -> Result<IssuedLicensePayload, IssuanceRefusal> {
        IssuancePolicy.validate(r, grant: g ?? grant, ledger: ledger, catalog: catalog, now: at ?? now)
    }
    func refusal(_ result: Result<IssuedLicensePayload, IssuanceRefusal>, _ expected: IssuanceRefusal, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("expected refusal", file: file, line: line) }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    /// Plan JS P2: a seat-checked code is minted with the signed claim, and only with a profile,
    /// whose origin is the seat service.
    func testASeatCheckedRequestCarriesTheClaimAndNeedsAProfile() throws {
        var r = request
        r.seatCheck = true
        guard case .success(let payload) = validate(r) else { return XCTFail("expected a payload") }
        XCTAssertEqual(payload.seatCheck, true)
        r.profile = nil
        refusal(validate(r), .invalidRequest)
        guard case .success(let plain) = validate(request) else { return XCTFail("expected a payload") }
        XCTAssertNil(plain.seatCheck)
    }
    func testEnterpriseNeverDelegatesEvenWithMalformedGrant() { var r = request; r.tier = "enterprise"; var g = grant; g.tiers.insert("enterprise"); refusal(validate(r, g), .tierNotDelegated) }
    func testSoloRefused() { var r = request; r.tier = "solo"; refusal(validate(r), .tierNotDelegated) }
    func testEnterprisePlanRefused() { var r = request; r.plan = "enterprise"; refusal(validate(r), .tierNotDelegated) }
    func testUnknownPackRefused() { var r = request; r.packs = ["typo"]; refusal(validate(r), .unknownPack("typo")) }
    func testPackOutsideResaleSetRefused() { var r = request; r.packs = ["other"]; refusal(validate(r), .packNotResellable("other")) }
    func testTermTooLongRefused() { var r = request; r.termDays = 366; refusal(validate(r), .termTooLong(365)) }
    func testTooManySeatsRefused() { var r = request; r.seats = 11; refusal(validate(r), .seatsPerCodeExceeded(10)) }
    func testPilotDisallowedRefused() { var r = request; r.plan = "pilot"; var g = grant; g.pilotsAllowed = false; refusal(validate(r, g), .pilotNotAllowed) }
    func testPilotWithoutExpiryRefused() { var r = request; r.plan = "pilot"; r.termDays = nil; refusal(validate(r), .pilotWithoutExpiry) }
    func testPilotTooLongRefused() { var r = request; r.plan = "pilot"; r.termDays = 15; refusal(validate(r), .termTooLong(14)) }
    func testExpiredAndFutureGrantRefused() { refusal(validate(request, at: date(500)), .grantExpired); refusal(validate(request, at: date(-2)), .grantExpired) }
    func testUnknownReplacementRefused() { var r = request; r.replaces = "absent"; refusal(validate(r), .replacesUnknown) }
    func testInvalidInputsRefusedBeforeSigning() {
        var r = request; r.seats = 0; refusal(validate(r), .invalidRequest)
        r = request; r.expiry = date(4); refusal(validate(r), .invalidRequest)
        r = request; r.profile = "http://fixture.invalid"; refusal(validate(r), .invalidRequest)
        r = request; r.packs = ["hvac", "hvac"]; refusal(validate(r), .invalidRequest)
        var g = grant; g.seatQuota = -1; refusal(validate(request, g), .invalidGrant)
    }
    func issue(_ book: inout SalesBook, id: String = "i1", r: IssuanceRequest? = nil, at: Date? = nil) throws -> IssuedCode {
        try book.issue(id: id, request: r ?? request, grant: grant, catalog: catalog, operatorId: "fixture-operator", now: at ?? now, signer: key.signature(for:))
    }
    @discardableResult func order(_ book: inout SalesBook, id: String = "o1", at: Date? = nil, renewal: String? = nil, g: PartnerGrant? = nil) throws -> IssuedCode? {
        var r = request; r.reference = id
        return try book.order(id: id, request: r, grant: g ?? grant, catalog: catalog, profileId: "customer", bankDetails: "FIXTURE BANK", renewalOf: renewal, operatorId: "fixture-operator", now: at ?? now, signer: key.signature(for:))
    }
    @discardableResult func pay(_ book: inout SalesBook, amount: Int64 = 200, day: Int = 1, id: String = "p1", invoice: String = "INV-000001", confirmed: Bool = true) throws -> IssuedCode? {
        try book.recordPayment(Payment(id: id, invoiceNumber: invoice, amountMinor: amount, receivedAt: date(day), bankReference: "fixture-bank-ref"),
                               confirmed: confirmed, operatorId: "fixture-vendor", now: date(day), signer: key.signature(for:))
    }
    func testQuotaExactLimitReissueAndNoExpiryRefund() throws {
        var book = try SalesBook(); let first = try issue(&book)
        var g = grant; g.seatQuota = 4
        XCTAssertNoThrow(try validate(request, g, ledger: book.ledger).get())
        var r = request; r.seats = 3; refusal(validate(r, g, ledger: book.ledger), .quotaExceeded(2))
        r = request; r.termDays = nil; r.expiry = first.payload.expires; r.replaces = first.record.issuanceId
        let second = try issue(&book, id: "i2", r: r, at: date(1))
        XCTAssertEqual(second.record.replaces, "i1")
        XCTAssertEqual(book.ledger.billableIssuances(from: date(-1), until: date(400)).count, 1)
        r.replaces = "i1"; refusal(validate(r, ledger: book.ledger, at: date(2)), .replacesUnknown)
        g.seatQuota = 2; refusal(validate(request, g, ledger: book.ledger, at: date(366)), .quotaExceeded(0))
    }
    func testReplacementCannotChangeSeatsPacksOrExpiry() throws {
        var book = try SalesBook(); let old = try issue(&book)
        for mutation in 0..<3 {
            var r = request; r.termDays = nil; r.expiry = old.payload.expires; r.replaces = old.record.issuanceId
            if mutation == 0 { r.seats = 3 }; if mutation == 1 { r.packs = ["hvac"] }; if mutation == 2 { r.expiry = date(364) }
            refusal(validate(r, ledger: book.ledger), .replacementMismatch)
        }
        var g = grant; g.partnerId = "another"; var r = request; r.replaces = "i1"
        refusal(validate(r, g, ledger: book.ledger), .replacesUnknown)
    }
    func testLedgerIntegrityAndSupportJoinWithoutBearerMaterial() throws {
        var book = try SalesBook()
        var secrets: [String] = []
        for n in 0..<60 {
            var r = request; r.seats = 1
            // A fresh grant quota for this property fixture, still exercising the real policy.
            var g = grant; g.seatQuota = 100
            let result = try book.issue(id: "i\(n)", request: r, grant: g, catalog: catalog, operatorId: "fixture", now: date(n), signer: key.signature(for:))
            secrets += [result.code, String(result.code.split(separator: ".")[0]), String(decoding: try IssuanceWire.encoder().encode(result.payload), as: UTF8.self)]
            XCTAssertEqual(result.record.licenseIDHash, String(IssuanceWire.digest(Data(result.code.utf8)).prefix(16)))
        }
        try book.ledger.verify()
        let encoded = try IssuanceWire.encoder().encode(book.ledger)
        let json = String(decoding: encoded, as: UTF8.self)
        for secret in secrets { XCTAssertFalse(json.contains(secret)) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
        rows[1]["prevRowHash"] = "tampered"; object["entries"] = rows
        let corrupt = try IssuanceWire.decoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try corrupt.verify()) { XCTAssertEqual($0 as? Ledger.IntegrityError, .brokenChain(2)) }
        XCTAssertThrowsError(try SalesBook(ledger: corrupt))
    }
    func testBillingHalfOpenPeriodsRenewalAndReissue() throws {
        var book = try SalesBook(); let first = try issue(&book, at: date(0))
        var r = request; r.termDays = nil; r.expiry = first.payload.expires; r.replaces = "i1"
        _ = try issue(&book, id: "replacement", r: r, at: date(2))
        _ = try issue(&book, id: "renewal", at: date(15))
        _ = try issue(&book, id: "last-day", at: date(29))
        _ = try issue(&book, id: "next-month", at: date(30))
        XCTAssertEqual(book.ledger.billableIssuances(from: date(0), until: date(30)).map(\.issuanceId), ["i1", "renewal", "last-day"])
    }
    func testProvisionalPartialFullAndLatePaymentExpiry() throws {
        for day in [1, 34, 40, 400] {
            var book = try SalesBook(); let initial = try XCTUnwrap(order(&book))
            XCTAssertEqual(initial.payload.expires, date(35)); XCTAssertEqual(initial.payload.profile, request.profile)
            XCTAssertNil(try pay(&book, amount: 50, day: day))
            let invoice = try XCTUnwrap(book.ledger.invoices.first)
            XCTAssertFalse(book.ledger.isPaid(invoice)); XCTAssertEqual(book.ledger.balance(invoice), 150)
            XCTAssertEqual(book.ledger.state(of: book.ledger.orders[0], now: date(36)), .lapsed)
            let full = try XCTUnwrap(pay(&book, amount: 150, day: day, id: "p2"))
            XCTAssertEqual(full.payload.expires, date(365)); XCTAssertEqual(full.record.replaces, initial.record.issuanceId)
            XCTAssertTrue(book.ledger.isPaid(invoice)); XCTAssertEqual(book.ledger.balance(invoice), 0)
            XCTAssertEqual(book.ledger.billableIssuances(from: date(0), until: date(500)).count, 1)
            XCTAssertThrowsError(try pay(&book, day: day, id: "p2"))
        }
    }
    func testInvoicesSequentialImmutableAndCreditsDoNotIssueCodes() throws {
        var book = try SalesBook(); try order(&book)
        let original = book.ledger.invoices[0]
        XCTAssertEqual(original.dueAt, date(30)); XCTAssertEqual(original.paymentReference, original.number)
        XCTAssertEqual(original.totalMinor, 200); XCTAssertEqual(original.currency, "XXX")
        var g = grant; g.prices.perSeatByTermDays = [:]
        XCTAssertThrowsError(try order(&book, id: "bad-price", g: g))
        try book.credit(CreditNote(id: "c1", invoiceNumber: original.number, amountMinor: 200, issuedAt: date(1), reason: "fixture correction"), now: date(1))
        XCTAssertEqual(book.ledger.invoices[0], original); XCTAssertEqual(book.ledger.balance(original), 0)
        XCTAssertFalse(book.ledger.isPaid(original)); XCTAssertEqual(book.ledger.issuances.count, 1)
        XCTAssertThrowsError(try pay(&book))
        try order(&book, id: "o2", at: date(1))
        XCTAssertEqual(book.ledger.invoices.map(\.number), ["INV-000001", "INV-000002"])
        XCTAssertEqual(book.ledger.invoices(from: date(0), until: date(1)).count, 1)
    }
    func testOverdueAndUnpaidSeatCreditCaps() throws {
        var book = try SalesBook(); var g = grant; g.maxUnpaidSeats = 2
        try order(&book, g: g)
        XCTAssertThrowsError(try order(&book, id: "o2", g: g)) { XCTAssertEqual($0 as? IssuanceRefusal, .unpaidSeatLimit(0)) }
        XCTAssertThrowsError(try order(&book, id: "o2", at: date(30))) { XCTAssertEqual($0 as? IssuanceRefusal, .overdueInvoice("INV-000001")) }
        try pay(&book, day: 40)
        XCTAssertNoThrow(try order(&book, id: "o2", at: date(40)))
    }
    func testRenewalPaidBeforeExpiryAnchorsAtOldExpiryAndReservesQuota() throws {
        var book = try SalesBook(); try order(&book); try pay(&book)
        XCTAssertNil(try order(&book, id: "o2", at: date(300), renewal: "o1"))
        XCTAssertEqual(book.ledger.orders[1].fullExpiry, date(730))
        var g = grant; g.seatQuota = 4
        refusal(validate(request, g, ledger: book.ledger, at: date(301)), .quotaExceeded(0))
        let renewal = try XCTUnwrap(pay(&book, day: 301, id: "p2", invoice: "INV-000002"))
        XCTAssertEqual(renewal.payload.expires, date(730)); XCTAssertNil(renewal.record.replaces)
        XCTAssertEqual(book.ledger.state(of: book.ledger.orders[0], now: date(301)), .replaced)
        XCTAssertThrowsError(try order(&book, id: "o3", at: date(302), renewal: "o1"))
    }
    func testPilotNoInvoiceAndNoProvisionalExtension() throws {
        var book = try SalesBook(); var r = request; r.plan = "pilot"; r.termDays = 14
        let code = try XCTUnwrap(book.order(id: "o1", request: r, grant: grant, catalog: catalog, profileId: "customer", bankDetails: "", operatorId: "fixture", now: now, signer: key.signature(for:)))
        XCTAssertEqual(code.payload.expires, date(14)); XCTAssertTrue(book.ledger.invoices.isEmpty)
    }
    func testFailedSignerAndUnconfirmedPaymentLeaveJournalUnchanged() throws {
        var book = try SalesBook(); let original = book.ledger
        XCTAssertThrowsError(try book.order(id: "o1", request: request, grant: grant, catalog: catalog, profileId: "customer", bankDetails: "fixture", operatorId: "fixture", now: now, signer: { _ in throw SalesError.invalidOrder }))
        XCTAssertEqual(book.ledger, original)
        try order(&book); let before = book.ledger
        XCTAssertThrowsError(try pay(&book, confirmed: false)) { XCTAssertEqual($0 as? SalesError, .confirmationRequired) }
        XCTAssertEqual(book.ledger, before)
        let payment = Payment(id: "failed", invoiceNumber: "INV-000001", amountMinor: 200, receivedAt: date(1), bankReference: "fixture")
        XCTAssertThrowsError(try book.recordPayment(payment, confirmed: true, operatorId: "fixture", now: date(1), signer: { _ in throw SalesError.invalidOrder }))
        XCTAssertEqual(book.ledger, before)
    }
    func testWireAndActivationContractsWithSyntheticKey() throws {
        let payload = try validate(request).get()
        let bytes = try IssuanceWire.encoder().encode(payload)
        let signed = try IssuanceWire.code(payload, signer: key.signature(for:))
        let parts = signed.split(separator: "."); XCTAssertEqual(Data(base64Encoded: String(parts[0])), bytes)
        XCTAssertTrue(key.publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded: String(parts[1]))), for: bytes))
        let canonical = ActivationKeyMint.generate()
        let sealed = try ActivationKeyMint.seal(signed, canonical: canonical)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)), info: Data("openglasses.activation-key.v1".utf8), outputByteCount: 32)
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: sealed))), using: derived)
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), signed)
        XCTAssertThrowsError(try ActivationKeyMint.seal(signed, canonical: "bad"))
        let profileKey = Curve25519.Signing.PrivateKey()
        let profile = try IssuanceWire.minimalProfile(id: "customer", licensee: payload.licensee, issued: now, code: signed, keyID: "fixture", signer: profileKey.signature(for:))
        let pp = profile.split(separator: "."); let data = try XCTUnwrap(Data(base64Encoded: String(pp[0])))
        let sig = try XCTUnwrap(Data(base64Encoded: String(pp[1])))
        XCTAssertTrue(profileKey.publicKey.isValidSignature(sig, for: Data("openglasses.org-profile.v1\n".utf8) + data))
        XCTAssertFalse(profileKey.publicKey.isValidSignature(sig, for: data))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["eraseAfterLapseDays"]); XCTAssertNil(json["policyExpiry"]); XCTAssertEqual(json["leaseDays"] as? Int, 365)
    }
    func testCatalogUsesVendorSignedEffectivePackKeysAndRejectsTampering() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let manifest = Data(#"{"id":"fixture.pack","vaultId":"vault","version":"1","licensePack":"wholesale_key"}"#.utf8)
        let files = ["manifest.json": Data(#"{"id":"vault"}"#.utf8)]
        let message = manifest + Data("\nsha256(manifest.json)=\(IssuanceWire.digest(files["manifest.json"]!))".utf8)
        let index = try JSONSerialization.data(withJSONObject: ["version": 1, "packs": [["id": "fixture.pack", "vaultId": "vault", "version": "1", "packSignature": signer.signature(for: message).base64EncodedString()]]])
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": index.base64EncodedString(), "signature": signer.signature(for: index).base64EncodedString()])
        let proof = VerifiedPackCatalog.Proof(envelope: envelope, packsById: ["fixture.pack": .init(manifest: manifest, files: files)])
        let publicKey = signer.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(try VerifiedPackCatalog.verify(proof, publicKeyBase64: publicKey).keys, ["wholesale_key"])
        let tampered = VerifiedPackCatalog.Proof(envelope: envelope, packsById: ["fixture.pack": .init(manifest: Data(String(decoding: manifest, as: UTF8.self).replacingOccurrences(of: "wholesale_key", with: "forged").utf8), files: files)])
        XCTAssertThrowsError(try VerifiedPackCatalog.verify(tampered, publicKeyBase64: publicKey))
        XCTAssertThrowsError(try VerifiedPackCatalog.verify(.init(envelope: envelope, packsById: [:]), publicKeyBase64: publicKey))
        XCTAssertThrowsError(try VerifiedPackCatalog.verify(proof, publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
    }
    func testManualReissueOfAProvisionalKeepsQuotaAndPaidReplacementChain() throws {
        var book = try SalesBook(); let provisional = try XCTUnwrap(order(&book))
        var r = request; r.termDays = nil; r.expiry = provisional.payload.expires; r.replaces = provisional.record.issuanceId
        let replacement = try issue(&book, id: "lost-key", r: r, at: date(1))
        XCTAssertEqual(replacement.record.phase, .provisional)
        let full = try XCTUnwrap(pay(&book, day: 2))
        XCTAssertEqual(full.record.replaces, "lost-key")
        XCTAssertEqual(book.ledger.billableIssuances(from: now, until: date(400)).count, 1)
    }
    func testCreditAndPaymentBoundsAndMissingPriceRefusals() throws {
        var book = try SalesBook(); var g = grant; g.prices.perSeatByTermDays = [:]
        XCTAssertThrowsError(try order(&book, g: g)) { XCTAssertEqual($0 as? IssuanceRefusal, .missingPrice) }
        XCTAssertEqual(book.ledger.entries.count, 0)
        try order(&book)
        XCTAssertThrowsError(try pay(&book, amount: -1)) { XCTAssertEqual($0 as? SalesError, .invalidPayment) }
        XCTAssertThrowsError(try pay(&book, invoice: "missing")) { XCTAssertEqual($0 as? SalesError, .unknownInvoice) }
        XCTAssertThrowsError(try book.credit(CreditNote(id: "c", invoiceNumber: "INV-000001", amountMinor: 201, issuedAt: date(1), reason: "too much"), now: date(1)))
        XCTAssertEqual(book.ledger.entries.count, 1)
    }
    func testRenewalMustBePaidAndRaisedThirtyFiveDaysBeforeExpiry() throws {
        var book = try SalesBook(); try order(&book)
        XCTAssertThrowsError(try order(&book, id: "unpaid", at: date(1), renewal: "o1")) { XCTAssertEqual($0 as? SalesError, .invalidRenewal) }
        try pay(&book)
        XCTAssertThrowsError(try order(&book, id: "too-late", at: date(331), renewal: "o1")) { XCTAssertEqual($0 as? SalesError, .invalidRenewal) }
        XCTAssertNil(try order(&book, id: "on-boundary", at: date(330), renewal: "o1"))
    }
    func testTrustedHeadDetectsTruncationAndPaidTermEventuallyLapses() throws {
        var book = try SalesBook(); try order(&book)
        let oldLedger = book.ledger
        try pay(&book, day: 1)
        let head = try XCTUnwrap(book.ledger.entries.last?.rowHash)
        XCTAssertThrowsError(try oldLedger.verify(expectedHead: head))
        XCTAssertNoThrow(try book.ledger.verify(expectedHead: head))
        XCTAssertEqual(book.ledger.state(of: book.ledger.orders[0], now: date(365)), .lapsed)
    }

    func testPaidInvoiceCanBeCorrectedWithoutRevokingItsCodeAndAccountingUsesPeriodBoundaries() throws {
        var book = try SalesBook(); try order(&book); try pay(&book, day: 1)
        let count = book.ledger.issuances.count
        try book.credit(CreditNote(id: "refund", invoiceNumber: "INV-000001", amountMinor: 100, issuedAt: date(2), reason: "fixture correction after payment"), now: date(2))
        XCTAssertEqual(book.ledger.issuances.count, count)
        XCTAssertEqual(book.ledger.state(of: book.ledger.orders[0], now: date(2)), .active)
        let first = book.ledger.accounting(from: date(0), until: date(2))
        XCTAssertEqual(first.invoices.count, 1); XCTAssertEqual(first.payments.count, 1); XCTAssertTrue(first.creditNotes.isEmpty)
        XCTAssertEqual(book.ledger.accounting(from: date(2), until: date(3)).creditNotes.count, 1)
        XCTAssertThrowsError(try book.credit(CreditNote(id: "excess", invoiceNumber: "INV-000001", amountMinor: 101, issuedAt: date(2), reason: "too much"), now: date(2)))
    }
    func testCreditedUnissuedRenewalReleasesItsReservation() throws {
        var book = try SalesBook(); try order(&book); try pay(&book)
        try order(&book, id: "renewal", at: date(300), renewal: "o1")
        var g = grant; g.seatQuota = 4
        refusal(validate(request, g, ledger: book.ledger, at: date(300)), .quotaExceeded(0))
        try book.credit(CreditNote(id: "cancel-renewal", invoiceNumber: "INV-000002", amountMinor: 200, issuedAt: date(300), reason: "cancel before issuance"), now: date(300))
        XCTAssertNoThrow(try validate(request, g, ledger: book.ledger, at: date(300)).get())
    }


    /// Plan KQ P2b: an organisation may pin the manual-search model, and only to one the app knows.
    func testAProfileMayPinTheManualSearchModelToAModelTheAppKnows() throws {
        XCTAssertEqual(ProfileContract.allowList["organizationManualSearchModel"], "owned:string")
        for model in ["standard", "smarter", "searchTrained"] {
            XCTAssertNoThrow(try ProfileContract.checkSetting("organizationManualSearchModel",
                                                              .init(value: .string(model), disposition: "locked")))
        }
        XCTAssertThrowsError(try ProfileContract.checkSetting("organizationManualSearchModel",
                                                              .init(value: .string("fastest"), disposition: "locked")))
        XCTAssertThrowsError(try ProfileContract.checkSetting("organizationManualSearchModel",
                                                              .init(value: .bool(true), disposition: "locked")))
    }
}
