import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The check-in, renewal and removal messages as the phone reads them, against the Go golden
/// fixtures and the contract's negative cases (Contracts/office-check-in.md §11).
final class OfficeCheckInTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private let now = OfficeCheckInFixtures.now + 60

    private func assertRefused<T>(_ expected: OfficeCheckIn.Refusal, _ name: String, line: UInt = #line,
                                  _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), name, line: line) {
            XCTAssertEqual($0 as? OfficeCheckIn.Refusal, expected, name, line: line)
        }
    }

    private func readResult(_ data: Data, waiting: OfficeCheckIn.Waiting? = nil,
                            enrolmentID: String? = nil, phoneTransportID: String? = nil,
                            administratorKey: Data? = nil) throws -> OfficeCheckIn.VerifiedResult {
        let held = try F.held()
        return try OfficeCheckIn.result(
            data, administratorKey: administratorKey ?? held.administratorKey,
            organizationID: held.organizationID, enrolmentID: enrolmentID ?? held.enrolmentID,
            officeID: held.officeID, phoneTransportID: phoneTransportID ?? held.phoneTransportID,
            waiting: try waiting ?? F.waiting())
    }

    private func readRemoval(_ data: Data, profileID: String? = nil,
                             enrolmentID: String? = nil) throws -> OfficeCheckIn.VerifiedRemoval {
        let held = try F.held()
        return try OfficeCheckIn.removal(
            data, administratorKey: held.administratorKey, organizationID: held.organizationID,
            profileID: profileID ?? held.profileID, enrolmentID: enrolmentID ?? held.enrolmentID,
            phoneTransportID: held.phoneTransportID)
    }

    // MARK: - The golden fixtures

    func testTheGoldenExchangeReadsAsThePhoneReadsIt() throws {
        let held = try F.held()
        let keys = try F.fields(F.data("office-check-in-fixture-keys"))
        XCTAssertEqual(held.bindingSHA256, keys["bindingSHA256"] as? String)

        let challenge = try OfficeCheckIn.challenge(F.data("office-check-in-challenge-v1"), held: held, now: now)
        XCTAssertEqual(challenge.messageSHA256, keys["challengeSHA256"] as? String)
        XCTAssertEqual(challenge.payload.generation, 1)

        // The golden check-in is one this phone would sign, and it answers that challenge.
        let payload = try F.payload("office-check-in-v1")
        let checkIn = try XCTUnwrap(OfficeCheckIn.checkInPayload(payload))
        XCTAssertTrue(OfficeCheckIn.answers(checkIn, challenge: challenge, held: held))
        XCTAssertEqual(try OfficeCheckIn.checkIn(F.data("office-check-in-v1"),
                                                 phoneApplicationKey: held.phoneApplicationKey), checkIn)
        XCTAssertEqual(OfficeCheckIn.digest(try F.data("office-check-in-v1")), keys["checkInSHA256"] as? String)

        let result = try readResult(F.data("office-check-in-result-v1"))
        XCTAssertEqual(result.payload.outcome, "renewed")
        // The renewed binding travels unchanged: its envelope is a closed binding envelope.
        let binding = try F.fields(XCTUnwrap(Data(base64Encoded: F.envelope(result.peerBinding).payload)))
        XCTAssertEqual(binding["generation"] as? Int, 2)
        XCTAssertEqual(binding["enrolmentID"] as? String, held.enrolmentID)
    }

    func testTheGoldenRemovalAndItsReceiptReadBack() throws {
        let held = try F.held()
        let keys = try F.fields(F.data("office-check-in-fixture-keys"))
        let removal = try readRemoval(F.data("office-removal-v1"))
        XCTAssertEqual(removal.payload.reason, "removed")
        XCTAssertEqual(removal.messageSHA256, keys["removalSHA256"] as? String)
        let payload = try F.payload("office-removal-receipt-v1")
        let receipt = try XCTUnwrap(OfficeCheckIn.removalReceiptPayload(payload))
        XCTAssertTrue(OfficeCheckIn.receipt(receipt, isFor: removal))
        XCTAssertEqual(try OfficeCheckIn.removalReceipt(F.data("office-removal-receipt-v1"),
                                                        phoneApplicationKey: held.phoneApplicationKey,
                                                        removal: removal), receipt)
        // A receipt under the office application key is not the phone's.
        assertRefused(.badSignature, "receipt by another key") {
            try OfficeCheckIn.removalReceipt(
                F.signed(payload, domain: OfficeCheckIn.removalReceiptDomain, by: F.office()),
                phoneApplicationKey: held.phoneApplicationKey, removal: removal)
        }
    }

    // MARK: - A challenge the phone does not answer

    func testAChallengeIsAnsweredOnlyWhileLiveAndUnderExactlyTheBindingHeld() throws {
        let held = try F.held()
        let challenge = try F.data("office-check-in-challenge-v1")
        assertRefused(.notCurrentlyValid, "before issuedAt") {
            try OfficeCheckIn.challenge(challenge, held: held, now: F.now - 1)
        }
        assertRefused(.notCurrentlyValid, "at expiresAt") {
            try OfficeCheckIn.challenge(challenge, held: held, now: F.now + OfficeCheckIn.maximumChallengeLifetime)
        }
        func resigned(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try F.changed("office-check-in-challenge-v1", domain: OfficeCheckIn.challengeDomain, by: F.office(), change)
        }
        for (name, change) in [
            ("another organisation", { $0["organizationID"] = "another-organisation" }),
            ("another enrolment", { $0["enrolmentID"] = "another-enrolment" }),
            ("another office", { $0["officeID"] = "office-000000000000000000000000" }),
            ("another phone", { $0["phoneTransportID"] = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ" }),
            ("another generation", { $0["generation"] = 2 }),
            ("another binding digest", { $0["bindingSHA256"] = String(repeating: "0", count: 64) }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            assertRefused(.wrongBinding, name) { try OfficeCheckIn.challenge(resigned(change), held: held, now: now) }
        }
        // The phone holding generation 2 does not answer a challenge set under generation 1.
        let renewed = OfficeCheckIn.Held(
            organizationID: held.organizationID, profileID: held.profileID, enrolmentID: held.enrolmentID,
            officeID: held.officeID, phoneTransportID: held.phoneTransportID, generation: 2,
            bindingSHA256: held.bindingSHA256, officeApplicationKey: held.officeApplicationKey,
            phoneApplicationKey: held.phoneApplicationKey, administratorKey: held.administratorKey)
        assertRefused(.wrongBinding, "the generation before") {
            try OfficeCheckIn.challenge(challenge, held: renewed, now: now)
        }
        for (name, change) in [
            ("a lifetime over seven days", { $0["expiresAt"] = F.now + OfficeCheckIn.maximumChallengeLifetime + 1 }),
            ("a short nonce", { $0["nonce"] = "AAAA" }),
            ("an identifier that is not hex", { $0["challengeID"] = String(repeating: "G", count: 32) }),
            ("another kind", { $0["kind"] = "avenkin.office-check-in" }),
            ("another version", { $0["version"] = 2 }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            assertRefused(.invalidFields, name) { try OfficeCheckIn.challenge(resigned(change), held: held, now: now) }
        }
        // Signed by anyone but the office application key the binding names.
        for signer in [try F.administrator(), try F.phone()] {
            assertRefused(.badSignature, "another signer") {
                try OfficeCheckIn.challenge(
                    F.signed(F.payload("office-check-in-challenge-v1"), domain: OfficeCheckIn.challengeDomain, by: signer),
                    held: held, now: now)
            }
        }
    }

    // MARK: - A result that renews nothing

    func testAResultIsTheAdministratorsAndForExactlyTheCheckInWaitedOn() throws {
        let held = try F.held()
        let result = try F.data("office-check-in-result-v1")
        let payload = try F.payload("office-check-in-result-v1")
        // Signed by the office application key instead of the administrator key.
        assertRefused(.badSignature, "office application key") {
            try self.readResult(F.signed(payload, domain: OfficeCheckIn.resultDomain, by: F.office()))
        }
        // The administrator's own signature, under a key the profile does not name.
        assertRefused(.badSignature, "another administrator") {
            try self.readResult(result, administratorKey: held.officeApplicationKey)
        }
        // For another check-in: an earlier one, or one this phone never made.
        let waiting = try F.waiting()
        for (name, other) in [
            ("another check-in's bytes", OfficeCheckIn.Waiting(
                challengeID: waiting.challengeID, checkInSHA256: String(repeating: "0", count: 64),
                generation: 1, bindingSHA256: held.bindingSHA256)),
            ("another challenge", OfficeCheckIn.Waiting(
                challengeID: String(repeating: "0", count: 32), checkInSHA256: waiting.checkInSHA256,
                generation: 1, bindingSHA256: held.bindingSHA256)),
        ] {
            assertRefused(.wrongBinding, name) { try self.readResult(result, waiting: other) }
        }
        // For another phone or enrolment.
        assertRefused(.wrongBinding, "another enrolment") { try self.readResult(result, enrolmentID: "another-enrolment") }
        assertRefused(.wrongBinding, "another phone") {
            try self.readResult(result, phoneTransportID: "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ")
        }
        func resigned(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try F.changed("office-check-in-result-v1", domain: OfficeCheckIn.resultDomain, by: F.administrator(), change)
        }
        assertRefused(.invalidFields, "an outcome v1 does not have") { try self.readResult(resigned { $0["outcome"] = "refused" }) }
        assertRefused(.invalidFields, "no binding") { try self.readResult(resigned { $0["peerBinding"] = "" }) }
        assertRefused(.malformed, "over the size cap") {
            try self.readResult(resigned { $0["peerBinding"] = String(repeating: "a", count: OfficeCheckIn.maximumResultBytes) })
        }
    }

    // MARK: - A removal that removes nothing

    func testARemovalIsTheAdministratorsAndForThisEnrolmentOnly() throws {
        let removal = try F.data("office-removal-v1")
        let payload = try F.payload("office-removal-v1")
        assertRefused(.badSignature, "office application key") {
            try self.readRemoval(F.signed(payload, domain: OfficeCheckIn.removalDomain, by: F.office()))
        }
        assertRefused(.wrongBinding, "another enrolment") { try self.readRemoval(removal, enrolmentID: "another-enrolment") }
        assertRefused(.wrongBinding, "another profile") { try self.readRemoval(removal, profileID: "another-profile") }
        func resigned(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain, by: F.administrator(), change)
        }
        assertRefused(.invalidFields, "a reason v1 does not have") { try self.readRemoval(resigned { $0["reason"] = "expired" }) }
        // `revoked` is the other reason, and changes nothing but the sentence.
        XCTAssertEqual(try readRemoval(resigned { $0["reason"] = "revoked" }).payload.reason, "revoked")
        // A removal names no generation and has no expiry: it reads the same years later.
        XCTAssertEqual(try readRemoval(removal).payload.enrolmentID, "fixture-enrolment")
    }

    // MARK: - Domains and closed objects

    /// Each message is accepted under its own domain only: the same payload and key under any
    /// other message's domain does not verify.
    func testNoMessageIsAcceptedUnderAnotherMessagesDomain() throws {
        let held = try F.held()
        let domains = [OfficeCheckIn.challengeDomain, OfficeCheckIn.checkInDomain, OfficeCheckIn.resultDomain,
                       OfficeCheckIn.removalDomain, OfficeCheckIn.removalReceiptDomain, OfficePeerBindingDomain.value]
        let removal = try readRemoval(F.data("office-removal-v1"))
        for domain in domains {
            if domain != OfficeCheckIn.challengeDomain {
                assertRefused(.badSignature, "challenge") {
                    try OfficeCheckIn.challenge(
                        F.signed(F.payload("office-check-in-challenge-v1"), domain: domain, by: F.office()),
                        held: held, now: self.now)
                }
            }
            if domain != OfficeCheckIn.checkInDomain {
                assertRefused(.badSignature, "check-in") {
                    try OfficeCheckIn.checkIn(F.signed(F.payload("office-check-in-v1"), domain: domain, by: F.phone()),
                                              phoneApplicationKey: held.phoneApplicationKey)
                }
            }
            if domain != OfficeCheckIn.resultDomain {
                assertRefused(.badSignature, "result") {
                    try self.readResult(F.signed(F.payload("office-check-in-result-v1"), domain: domain, by: F.administrator()))
                }
            }
            if domain != OfficeCheckIn.removalDomain {
                assertRefused(.badSignature, "removal") {
                    try self.readRemoval(F.signed(F.payload("office-removal-v1"), domain: domain, by: F.administrator()))
                }
            }
            if domain != OfficeCheckIn.removalReceiptDomain {
                assertRefused(.badSignature, "removal receipt") {
                    try OfficeCheckIn.removalReceipt(
                        F.signed(F.payload("office-removal-receipt-v1"), domain: domain, by: F.phone()),
                        phoneApplicationKey: held.phoneApplicationKey, removal: removal)
                }
            }
        }
        // And one message's payload is not another's, whatever signs it: a result signed as a
        // removal, a challenge signed as a result.
        assertRefused(.malformed, "a result as a removal") {
            try self.readRemoval(F.signed(F.payload("office-check-in-result-v1"), domain: OfficeCheckIn.removalDomain, by: F.administrator()))
        }
        assertRefused(.malformed, "a removal as a result") {
            try self.readResult(F.signed(F.payload("office-removal-v1"), domain: OfficeCheckIn.resultDomain, by: F.administrator()))
        }
    }

    /// Extra, missing, duplicate, nested and fractional fields, and trailing data, in a payload
    /// the right key signed and in the envelope around it.
    func testEnvelopeAndPayloadAreClosedFlatObjects() throws {
        let held = try F.held()
        let text = String(decoding: try F.payload("office-check-in-challenge-v1"), as: UTF8.self)
        let cases: [(String, String)] = [
            ("an extra field", text.replacingOccurrences(of: "{\"version\":1,", with: "{\"version\":1,\"extra\":1,")),
            ("a missing field", text.replacingOccurrences(of: "\"generation\":1,", with: "")),
            ("a duplicate field", text.replacingOccurrences(of: "{\"version\":1,", with: "{\"version\":1,\"version\":1,")),
            ("a nested value", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":{\"value\":1},")),
            ("an array", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":[1],")),
            ("a fractional number", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":1.0,")),
            ("an exponent", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":1e0,")),
            ("a boolean", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":true,")),
            ("a null", text.replacingOccurrences(of: "\"generation\":1,", with: "\"generation\":null,")),
            ("trailing data", text + "{}"),
        ]
        for (name, changed) in cases {
            XCTAssertNotEqual(changed, text, name)
            assertRefused(.malformed, name) {
                try OfficeCheckIn.challenge(
                    F.signed(Data(changed.utf8), domain: OfficeCheckIn.challengeDomain, by: F.office()),
                    held: held, now: self.now)
            }
        }
        // The envelope itself.
        let envelope = String(decoding: try F.data("office-check-in-challenge-v1"), as: UTF8.self)
        for (name, changed) in [
            ("an extra envelope field", envelope.replacingOccurrences(of: "{\"payload\"", with: "{\"key\":\"x\",\"payload\"")),
            ("trailing data", envelope + " {}"),
            ("an unpadded signature", envelope.replacingOccurrences(of: "==\"}", with: "\"}")),
            ("nothing", ""),
        ] {
            XCTAssertNotEqual(changed, envelope, name)
            assertRefused(.malformed, name) { try OfficeCheckIn.challenge(Data(changed.utf8), held: held, now: self.now) }
        }
    }

    // MARK: - What the phone application key signs

    func testOnlyAClosedCheckInOrRemovalReceiptPayloadIsOneThePhoneSigns() throws {
        let checkIn = try F.payload("office-check-in-v1")
        let receipt = try F.payload("office-removal-receipt-v1")
        XCTAssertNotNil(OfficeCheckIn.checkInPayload(checkIn))
        XCTAssertNotNil(OfficeCheckIn.removalReceiptPayload(receipt))
        // Neither is the other, and no other message is either.
        XCTAssertNil(OfficeCheckIn.checkInPayload(receipt))
        XCTAssertNil(OfficeCheckIn.removalReceiptPayload(checkIn))
        for name in ["office-check-in-challenge-v1", "office-check-in-result-v1", "office-removal-v1",
                     "office-check-in-binding-v1"] {
            XCTAssertNil(OfficeCheckIn.checkInPayload(try F.payload(name)), name)
            XCTAssertNil(OfficeCheckIn.removalReceiptPayload(try F.payload(name)), name)
        }
        var fields = try F.fields(checkIn)
        fields["appVersion"] = "1.0\n0"
        XCTAssertNil(OfficeCheckIn.checkInPayload(try JSONSerialization.data(withJSONObject: fields)))
        fields["appVersion"] = String(repeating: "1", count: 65)
        XCTAssertNil(OfficeCheckIn.checkInPayload(try JSONSerialization.data(withJSONObject: fields)))
        XCTAssertNil(OfficeCheckIn.checkInPayload(Data()))
        XCTAssertNil(OfficeCheckIn.checkInPayload(checkIn + Data("{}".utf8)))
    }
}

/// The peer binding's own domain, spelled out here so this file needs nothing but the check-in
/// messages: a check-in message signed under it is no check-in message.
private enum OfficePeerBindingDomain {
    static let value = Data("Avenkin.OfficePeerBinding.v1\0".utf8)
}
