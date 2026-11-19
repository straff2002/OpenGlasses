import XCTest
@testable import OpenGlasses

/// Plan MK P0 — a line's number is found, not found, or not checked, and says which book answered
/// (§4). Everything stored before keeps reading as it did.
final class VanStockVerificationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func item(json: String) throws -> VanStockItem {
        try JSONDecoder().decode(VanStockItem.self, from: Data(json.utf8))
    }

    private let olderLine = #"{"id":"i1","number":"00123","description":"Flame sensor","unit":"each","codes":[],"created_batch":"b0""#

    // MARK: The three states

    func testTheStatesAndTheirBooks() {
        XCTAssertEqual(VanStockVerification.found(in: "Supplier catalogue").vault, "Supplier catalogue")
        XCTAssertEqual(VanStockVerification.notFound(in: "Supplier catalogue").state, .notFound)
        XCTAssertNil(VanStockVerification(state: .notChecked, vault: "Supplier catalogue").vault,
                     "nothing was asked, so no book answered")
        XCTAssertNil(VanStockVerification.found(in: "  ").vault)
        XCTAssertTrue(VanStockVerification.found(in: nil).isFound)
        XCTAssertFalse(VanStockVerification.notFound(in: "Furnace manual").isFound)
        XCTAssertFalse(VanStockVerification.notChecked.isFound)
    }

    func testAVerificationRoundTrips() throws {
        for value in [VanStockVerification.found(in: "Supplier catalogue"), .found(in: nil),
                      .notFound(in: "Furnace manual"), .notChecked] {
            XCTAssertEqual(try JSONDecoder().decode(VanStockVerification.self, from: JSONEncoder().encode(value)), value)
            XCTAssertEqual(VanStockVerification(storedValue: value.storedValue), value)
        }
        XCTAssertEqual(VanStockVerification.notFound(in: "Book: volume 2").storedValue, "not_found:Book: volume 2")
        XCTAssertEqual(VanStockVerification(storedValue: "not_found:Book: volume 2").vault, "Book: volume 2")
    }

    func testAStateFromANewerBuildReadsAsNotChecked() throws {
        let newer = Data(#"{"state":"superseded","vault":"Furnace manual"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(VanStockVerification.self, from: newer).state, .notChecked)
        XCTAssertEqual(VanStockVerification(storedValue: "superseded:Furnace manual"), .notChecked)
    }

    // MARK: Lines stored before

    func testAStoredTrueIsFound() throws {
        let line = try item(json: olderLine + #","verified":true}"#)
        XCTAssertEqual(line.verification, .found(in: nil))
        XCTAssertTrue(line.verified)
    }

    func testAStoredFalseIsNotCheckedNeverNotFound() throws {
        let line = try item(json: olderLine + #","verified":false}"#)
        XCTAssertEqual(line.verification, .notChecked, "today's false cannot say whether anything was searched")
        XCTAssertFalse(line.verified)
    }

    func testALineWithNoVerificationAtAllIsNotChecked() throws {
        XCTAssertEqual(try item(json: olderLine + "}").verification, .notChecked)
    }

    func testTheNewKeyWinsAndBothAreWrittenForAnOlderBuild() throws {
        let line = VanStockItem(id: "i1", number: "00123", description: "Flame sensor",
                                verification: .notFound(in: "Supplier catalogue"), createdBatch: "b0")
        let data = try JSONEncoder().encode(line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["verified"] as? Bool, false, "an older build requires verified")
        XCTAssertNotNil(object["verification"])
        XCTAssertEqual(try JSONDecoder().decode(VanStockItem.self, from: data), line)

        let disagreeing = olderLine + #","verified":true,"verification":{"state":"not_found","vault":"Furnace manual"}}"#
        XCTAssertEqual(try item(json: disagreeing).verification, .notFound(in: "Furnace manual"))
    }

    func testTheOldInitialiserStillMeansWhatItDid() {
        XCTAssertEqual(VanStockItem(description: "Igniter", verified: true, createdBatch: "b0").verification, .found(in: nil))
        XCTAssertEqual(VanStockItem(description: "Igniter", createdBatch: "b0").verification, .notChecked)
        var log = VanStockLog()
        XCTAssertEqual(log.addItem(description: "Igniter", verified: true, batch: "b0").verification, .found(in: nil))
        XCTAssertEqual(log.addItem(number: "22B22", description: "Igniter", verification: .notFound(in: "Furnace manual"),
                                   batch: "b0").verification, .notFound(in: "Furnace manual"))
    }

    func testTheBoolOnlyChangesTheStateWhenTheAnswerChanges() {
        var line = VanStockItem(description: "Igniter", verification: .notFound(in: "Furnace manual"), createdBatch: "b0")
        line.verified = false
        XCTAssertEqual(line.verification, .notFound(in: "Furnace manual"), "already not found, so nothing changes")
        line.verified = true
        XCTAssertEqual(line.verification, .found(in: nil))
        line.verification = .found(in: "Furnace manual")
        line.verified = true
        XCTAssertEqual(line.verification, .found(in: "Furnace manual"), "a found line keeps its book")
        line.verified = false
        XCTAssertEqual(line.verification, .notChecked)
    }

    // MARK: The log

    func testAnOldLogWithAVerifiedEditStillDecodesAndUndoes() throws {
        let older = Data("""
        {"items":[{"id":"i1","number":"00123","description":"Flame sensor","unit":"each","codes":[],
                   "verified":true,"created_batch":"b0"}],
         "movements":[{"id":"m1","item_id":"i1","kind":"edited","quantity":0,"at":"2026-09-21T14:13:20Z",
                       "batch":"b1","source":"sheet","attribute":"verified","old_value":"false","new_value":"true"}]}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = try decoder.decode(VanStockLog.self, from: older)
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: nil))
        XCTAssertEqual(log.movements.first?.attribute, .verified)

        XCTAssertNotNil(log.undoLastBatch(at: start, batch: "u", source: .typed, makeID: { "r1" }))
        XCTAssertEqual(log.item(id: "i1")?.verification, .notChecked, "an old false comes back as not checked")
    }

    func testANewVerificationEditIsRecordedUnderTheSameAttributeAndUndoes() throws {
        var log = VanStockLog()
        log.addItem(id: "i1", number: "00123", description: "Flame sensor",
                    verification: .notFound(in: "Furnace manual"), batch: "b0")
        XCTAssertTrue(log.edit(itemID: "i1", .verification(.found(in: "Supplier catalogue")), at: start,
                               batch: "b1", source: .typed, id: "m1"))
        let edit = try XCTUnwrap(log.movements.last)
        XCTAssertEqual(edit.attribute, .verified, "an older build still reads the log")
        XCTAssertEqual(edit.oldValue, "not_found:Furnace manual")
        XCTAssertEqual(edit.newValue, "found:Supplier catalogue")
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: "Supplier catalogue"))

        XCTAssertFalse(log.edit(itemID: "i1", .verification(.found(in: "Supplier catalogue")), at: start,
                                batch: "b2", source: .typed), "the same answer is no change")

        log.undoLastBatch(at: start, batch: "u", source: .typed, makeID: { "r1" })
        XCTAssertEqual(log.item(id: "i1")?.verification, .notFound(in: "Furnace manual"), "the book comes back with the state")
    }

    func testTheOldBoolEditStillRecordsTrueAndFalse() {
        var log = VanStockLog()
        log.addItem(id: "i1", number: "00123", description: "Flame sensor", batch: "b0")
        XCTAssertTrue(log.edit(itemID: "i1", .verified(true), at: start, batch: "b1", source: .typed))
        XCTAssertEqual(log.movements.last?.oldValue, "false")
        XCTAssertEqual(log.movements.last?.newValue, "true")
        XCTAssertEqual(log.item(id: "i1")?.verification, .found(in: nil))
        log.undoLastBatch(at: start, batch: "u", source: .typed)
        XCTAssertEqual(log.item(id: "i1")?.verification, .notChecked)
    }
}
