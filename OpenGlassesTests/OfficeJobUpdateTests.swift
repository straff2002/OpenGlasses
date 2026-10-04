import CryptoKit
import XCTest
@testable import OpenGlasses

/// The job-update messages (Contracts/job-updates.md) as the phone reads them, against the Go
/// golden fixtures and messages signed here with the fixture keys.
final class OfficeJobUpdateTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias U = OfficeJobUpdate

    static func trust() throws -> OfficeJobUpdate.Trust {
        let held = try OfficeCheckInFixtures.held()
        let binding = try OfficeCheckInFixtures.fields(OfficeCheckInFixtures.payload("office-check-in-binding-v1"))
        return OfficeJobUpdate.Trust(
            organizationID: held.organizationID, enrolmentID: held.enrolmentID, officeID: held.officeID,
            generation: held.generation, officeTransportID: try XCTUnwrap(binding["officeTransportID"] as? String),
            phoneTransportID: held.phoneTransportID, officeApplicationKey: held.officeApplicationKey)
    }

    private func changed(_ name: String = "job-update-note-v1", by key: Curve25519.Signing.PrivateKey? = nil,
                         _ change: (inout [String: Any]) -> Void) throws -> Data {
        try F.changed(name, domain: U.domain, by: key ?? F.office(), change)
    }

    private func refusal(_ data: Data, trust: U.Trust? = nil, now: Int64 = F.now) throws -> U.Refusal? {
        do {
            _ = try U.read(data, trust: trust ?? Self.trust(), now: now)
            return nil
        } catch let refusal as U.Refusal {
            return refusal
        }
    }

    // MARK: - The golden fixtures

    func testTheGoldenUpdatesReadUnderTheFixtureBinding() throws {
        let trust = try Self.trust()
        let parts = try U.read(F.data("job-update-parts-v1"), trust: trust, now: F.now)
        XCTAssertEqual(parts.payload.jobID, "job-2031")
        XCTAssertEqual(parts.payload.sequence, 1)
        XCTAssertEqual(parts.payload.updateKind, "parts")
        XCTAssertEqual(parts.payload.part, "Fan motor FX-90-M")
        XCTAssertEqual(parts.payload.quantity, 1)
        XCTAssertEqual(parts.payload.partState, "dispatched")
        XCTAssertEqual(parts.payload.expectedOn, "2027-01-18")
        XCTAssertEqual(parts.payloadSHA256, U.digest(try F.payload("job-update-parts-v1")))

        let schedule = try U.read(F.data("job-update-schedule-v1"), trust: trust, now: F.now)
        XCTAssertEqual(schedule.payload.sequence, 2)
        XCTAssertEqual(schedule.payload.scheduledFor, F.now + 3 * 86_400)
        XCTAssertEqual(schedule.payload.scheduledUntil, F.now + 3 * 86_400 + 7_200)

        let note = try U.read(F.data("job-update-note-v1"), trust: trust, now: F.now)
        XCTAssertEqual(note.payload.sequence, 3)
        XCTAssertEqual(note.payload.body, "Gate code is now 4412.\nAsk for the duty manager.")
    }

    func testTheGoldenReceiptIsThePhonesAndNamesTheUpdate() throws {
        let parts = try U.read(F.data("job-update-parts-v1"), trust: Self.trust(), now: F.now)
        let receipt = try U.receipt(F.data("job-update-receipt-v1"),
                                    phoneApplicationKey: F.phone().publicKey.rawRepresentation)
        XCTAssertEqual(receipt.updateID, parts.payload.updateID)
        XCTAssertEqual(receipt.updateSHA256, parts.payloadSHA256)
        XCTAssertEqual(receipt.jobID, "job-2031")
        XCTAssertEqual(receipt.sequence, 1)
        XCTAssertEqual(receipt.outcome, "received")
        XCTAssertEqual(receipt.jobState, "held")
        XCTAssertEqual(receipt.receivedAt, F.now + 60)
        XCTAssertThrowsError(try U.receipt(F.data("job-update-receipt-v1"),
                                           phoneApplicationKey: F.office().publicKey.rawRepresentation))

        // The signer signs only a closed receipt of this kind.
        XCTAssertEqual(U.receiptPayload(try F.payload("job-update-receipt-v1")), receipt)
        XCTAssertNil(U.receiptPayload(try F.payload("job-update-parts-v1")), "an update is not a receipt")
        XCTAssertNil(U.receiptPayload(try F.payload("office-bulk-assignment-receipt-received-v1")))
        for (member, value) in [("outcome", "read"), ("jobState", "opened"), ("updateSHA256", "abc"), ("kind", U.kind)] {
            var object = try F.fields(F.payload("job-update-receipt-v1"))
            object[member] = value
            XCTAssertNil(U.receiptPayload(try JSONSerialization.data(withJSONObject: object)), member)
        }
        var extra = try F.fields(F.payload("job-update-receipt-v1"))
        extra["openedAt"] = 1
        XCTAssertNil(U.receiptPayload(try JSONSerialization.data(withJSONObject: extra)))
    }

    // MARK: - Who it is from, and for

    func testAnUpdateIsTheOfficesForThisBindingAndInsideItsWindow() throws {
        let note = try F.data("job-update-note-v1")
        let trust = try Self.trust()
        func other(_ change: (inout [String: Any]) -> Void) throws -> U.Refusal? {
            try refusal(try changed("job-update-note-v1", change))
        }
        XCTAssertEqual(try refusal(try changed(by: F.phone()) { _ in }), .badSignature)
        let stranger = U.Trust(organizationID: trust.organizationID, enrolmentID: trust.enrolmentID,
                               officeID: trust.officeID, generation: trust.generation,
                               officeTransportID: trust.officeTransportID, phoneTransportID: trust.phoneTransportID,
                               officeApplicationKey: try F.administrator().publicKey.rawRepresentation)
        XCTAssertEqual(try refusal(note, trust: stranger), .badSignature)

        XCTAssertEqual(try other { $0["organizationID"] = "another-organisation" }, .wrongBinding)
        XCTAssertEqual(try other { $0["enrolmentID"] = "another-enrolment" }, .wrongBinding)
        XCTAssertEqual(try other { $0["officeID"] = "office-000000000000000000000000" }, .wrongBinding)
        XCTAssertEqual(try other { $0["generation"] = 2 }, .wrongBinding)
        XCTAssertEqual(try other { $0["phoneTransportID"] = trust.officeTransportID }, .wrongBinding)
        XCTAssertEqual(try other { $0["officeTransportID"] = trust.phoneTransportID }, .wrongBinding)

        let issued = try XCTUnwrap(try F.fields(F.payload("job-update-note-v1"))["issuedAt"] as? Int64)
        XCTAssertEqual(try refusal(note, now: issued - 1), .notCurrentlyValid)
        XCTAssertNil(try refusal(note, now: issued))
        XCTAssertEqual(try refusal(note, now: F.now + 7 * 86_400), .notCurrentlyValid)

        XCTAssertEqual(try refusal(Data()), .malformed)
        XCTAssertEqual(try refusal(Data(#"{"payload":"e30=","signature":"AA==","extra":1}"#.utf8)), .malformed)
        XCTAssertEqual(try refusal(Data(repeating: 0x20, count: U.maximumMessageBytes + 1)), .malformed)
        // Closed: a member the contract does not list, or one left out, is refused whoever signed.
        XCTAssertEqual(try other { $0["apply"] = 1 }, .malformed)
        XCTAssertEqual(try other { $0["scheduledUntil"] = nil }, .malformed)
        XCTAssertEqual(try other { $0["quantity"] = "0" }, .malformed)
        XCTAssertEqual(try other { $0["quantity"] = 1.5 }, .malformed)
    }

    func testEachKindCarriesOnlyItsOwnMembers() throws {
        func note(_ change: (inout [String: Any]) -> Void) throws -> U.Refusal? { try refusal(try changed("job-update-note-v1", change)) }
        func parts(_ change: (inout [String: Any]) -> Void) throws -> U.Refusal? {
            try refusal(try changed("job-update-parts-v1", change))
        }
        func schedule(_ change: (inout [String: Any]) -> Void) throws -> U.Refusal? {
            try refusal(try changed("job-update-schedule-v1", change))
        }
        let bad: [(String, U.Refusal?)] = [
            ("a version that is not 1", try note { $0["version"] = 2 }),
            ("another kind of message", try note { $0["kind"] = "avenkin.managed-job" }),
            ("an identifier that is not hex", try note { $0["updateID"] = String(repeating: "G", count: 32) }),
            ("a job that is a path", try note { $0["jobID"] = "../job" }),
            ("no job", try note { $0["jobID"] = "" }),
            ("sequence zero", try note { $0["sequence"] = 0 }),
            ("a window over thirty days", try note { $0["expiresAt"] = F.now + 31 * 86_400 }),
            ("a kind that is not a word", try note { $0["updateKind"] = "Parts!" }),
            ("a note with nothing in it", try note { $0["body"] = "" }),
            ("a note with a part", try note { $0["part"] = "Valve" }),
            ("a note with a time", try note { $0["scheduledFor"] = F.now }),
            ("a body with a control character", try note { $0["body"] = "a\u{07}b" }),
            ("a body with a carriage return", try note { $0["body"] = "a\r\nb" }),
            ("a body over the limit", try note { $0["body"] = String(repeating: "a", count: U.maximumBodyBytes + 1) }),
            ("parts with no part", try parts { $0["part"] = "" }),
            ("parts with no state", try parts { $0["partState"] = "" }),
            ("a state the contract does not name", try parts { $0["partState"] = "lost" }),
            ("a part over two lines", try parts { $0["part"] = "Fan\nmotor" }),
            ("a negative quantity", try parts { $0["quantity"] = -1 }),
            ("a quantity over the limit", try parts { $0["quantity"] = U.maximumQuantity + 1 }),
            ("a date that is not a date", try parts { $0["expectedOn"] = "2027-02-30" }),
            ("a date with a time", try parts { $0["expectedOn"] = "2027-01-18T09:00:00Z" }),
            ("parts with a time", try parts { $0["scheduledFor"] = F.now }),
            ("a schedule with no time", try schedule { $0["scheduledFor"] = 0; $0["scheduledUntil"] = 0 }),
            ("a window that ends before it starts", try schedule { $0["scheduledUntil"] = F.now }),
            ("a schedule with a part", try schedule { $0["part"] = "Valve" }),
            ("an end with no start", try note { $0["updateKind"] = "survey"; $0["scheduledUntil"] = F.now }),
        ]
        for (what, refusal) in bad {
            XCTAssertEqual(refusal, .invalidFields, what)
        }

        // Optional members may be empty, and a kind this version does not define verifies.
        XCTAssertNil(try parts { $0["body"] = ""; $0["quantity"] = 0; $0["expectedOn"] = "" })
        XCTAssertNil(try schedule { $0["scheduledUntil"] = 0; $0["body"] = "Morning." })
        XCTAssertNil(try note { $0["updateKind"] = "site-access" })
        XCTAssertNil(try parts { $0["expectedOn"] = "2028-02-29" }, "a leap day is a date")
    }

    func testASequenceIsTakenOnceAndOrderMeansNothing() throws {
        let trust = try Self.trust()
        let parts = try U.read(F.data("job-update-parts-v1"), trust: trust, now: F.now)
        XCTAssertEqual(U.standing(heldSHA256: nil, arriving: parts), .new)
        XCTAssertEqual(U.standing(heldSHA256: parts.payloadSHA256, arriving: parts), .same)
        let other = try U.read(try changed("job-update-parts-v1") { $0["body"] = "Courier to the depot." },
                               trust: trust, now: F.now)
        XCTAssertEqual(other.payload.sequence, parts.payload.sequence)
        XCTAssertEqual(U.standing(heldSHA256: parts.payloadSHA256, arriving: other), .conflict)
    }

    func testFieldRules() {
        XCTAssertTrue(U.kindWord("site-access2"))
        for word in ["", "2go", "-a", "Parts", "a_b", String(repeating: "a", count: 33)] {
            XCTAssertFalse(U.kindWord(word), word)
        }
        XCTAssertTrue(U.text("", maximum: 10, lines: false))
        XCTAssertTrue(U.text("Größe 5 mm ✓", maximum: 40, lines: false))
        XCTAssertTrue(U.text("a\nb", maximum: 10, lines: true))
        XCTAssertFalse(U.text("a\nb", maximum: 10, lines: false))
        XCTAssertFalse(U.text("a\u{2028}b", maximum: 10, lines: true))
        XCTAssertFalse(U.text("a\u{85}b", maximum: 10, lines: true))
        XCTAssertFalse(U.text("éé", maximum: 3, lines: true), "the limit is in bytes")
        for date in ["2027-01-18", "2028-02-29", "2000-02-29"] { XCTAssertTrue(U.day(date), date) }
        for date in ["2027-02-29", "1900-02-29", "2027-13-01", "2027-00-10", "2027-1-18", "2027-01-32", "18-01-2027", ""] {
            XCTAssertFalse(U.day(date), date)
        }
    }
}
