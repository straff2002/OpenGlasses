import XCTest
@testable import OpenGlasses

/// Plan MY P0 — the expiry rules, the day an expiry is, and which of a line's own lots a spoken
/// lot means.
final class StockExpiryTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let received = Date(timeIntervalSince1970: 1_795_000_000)

    private func lot(_ id: String, _ code: String, _ expiry: StockDay?, receivedAfter seconds: Double = 0) -> StockLot {
        StockLot(id: id, itemID: "flu", code: code, expiry: expiry, firstReceived: received.addingTimeInterval(seconds),
                 createdBatch: "b")
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> StockDay { StockDay(year: y, month: m, day: d)! }

    func testALotIsUsableThroughItsExpiryDay() {
        let ending = lot("a", "ZZ1001", day(2026, 11, 22))
        XCTAssertFalse(StockExpiry.isExpired(ending, today: day(2026, 11, 22)))
        XCTAssertTrue(StockExpiry.isExpired(ending, today: day(2026, 11, 23)))
        XCTAssertFalse(StockExpiry.isExpired(lot("b", "ZZ1002", nil), today: day(2030, 1, 1)), "no expiry, never expired")
    }

    func testExpiringSoonIsWithinThirtyDaysByDefault() {
        let today = day(2026, 11, 22)
        XCTAssertEqual(VaccineStockPolicy.expiringSoonDays, 30)
        XCTAssertTrue(StockExpiry.expiresSoon(lot("a", "A", day(2026, 12, 22)), today: today, calendar: calendar))
        XCTAssertFalse(StockExpiry.expiresSoon(lot("b", "B", day(2026, 12, 23)), today: today, calendar: calendar))
        XCTAssertFalse(StockExpiry.expiresSoon(lot("c", "C", day(2026, 11, 21)), today: today, calendar: calendar),
                       "an expired lot is expired, not expiring")
        XCTAssertTrue(StockExpiry.expiresSoon(lot("d", "D", day(2027, 1, 10)), today: today, within: 60, calendar: calendar))
    }

    func testOldestExpiryFirstWithNoExpiryLast() {
        let lots = [lot("n", "N", nil), lot("late", "L", day(2027, 9, 30)), lot("early", "E", day(2027, 3, 31)),
                    lot("tie2", "T2", day(2027, 3, 31), receivedAfter: 60)]
        XCTAssertEqual(StockExpiry.oldestFirst(lots).map(\.id), ["early", "tie2", "late", "n"])
    }

    func testTheExpiringAndExpiredListsHoldOnlyLotsInStock() {
        let today = day(2026, 11, 22)
        let lots = [lot("gone", "G", day(2026, 11, 1)), lot("soon", "S", day(2026, 12, 1)),
                    lot("empty", "E", day(2026, 12, 2)), lot("fine", "F", day(2027, 6, 30))]
        var levels: [String: StockLotLevel] = [:]
        for (id, held) in [("gone", 2), ("soon", 5), ("empty", 0), ("fine", 9)] {
            levels[id] = StockLotLevel(lotID: id, onHand: StockQuantity(whole: held))
        }
        XCTAssertEqual(StockExpiry.expiringSoon(lots, levels: levels, today: today, calendar: calendar).map(\.id), ["soon"])
        XCTAssertEqual(StockExpiry.expiredInStock(lots, levels: levels, today: today).map(\.id), ["gone"])
        XCTAssertEqual(StockExpiry.older(than: lots[3], among: lots, levels: levels)?.id, "gone")
        XCTAssertNil(StockExpiry.older(than: lots[0], among: lots, levels: levels), "the oldest has none older")
    }

    func testADayIsStoredAsItsDateAndRefusesAnImpossibleOne() throws {
        XCTAssertNil(StockDay(year: 2027, month: 13, day: 1))
        XCTAssertNil(StockDay(year: 2027, month: 2, day: 29))
        XCTAssertNotNil(StockDay(year: 2028, month: 2, day: 29))
        XCTAssertEqual(StockDay.lastDay(ofMonth: 4, year: 2027), day(2027, 4, 30))
        let data = try JSONEncoder().encode([day(2027, 3, 1)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"2027-03-01\"]")
        XCTAssertEqual(try JSONDecoder().decode([StockDay].self, from: data), [day(2027, 3, 1)])
        XCTAssertThrowsError(try JSONDecoder().decode([StockDay].self, from: Data("[\"2027-02-30\"]".utf8)))
        XCTAssertEqual(day(2026, 12, 25).adding(days: 10, calendar: calendar), day(2027, 1, 4))
        XCTAssertEqual(day(2027, 3, 31).spoken, "31 March 2027")
    }

    // MARK: - A spoken lot

    func testASpokenLotMatchesOnlyTheLinesOwnLots() {
        let lots = [lot("a", "ZZ1001", day(2027, 3, 31)), lot("b", "zz-1002", day(2027, 9, 30))]
        XCTAssertEqual(StockLotMatch.match("ZZ1001", in: lots), .one(lots[0]))
        XCTAssertEqual(StockLotMatch.match("zz1001", in: lots), .one(lots[0]), "case forgiven")
        XCTAssertEqual(StockLotMatch.match("ZZ 1002", in: lots), .one(lots[1]), "spaces and dashes forgiven")
        XCTAssertEqual(StockLotMatch.match("ZZ1003", in: lots), .none)
        XCTAssertEqual(StockLotMatch.match("", in: lots), .none)
        let alike = [lot("x", "AB-1", nil), lot("y", "ab1", nil)]
        XCTAssertEqual(StockLotMatch.match("AB1", in: alike), .several(StockExpiry.oldestFirst(alike)))
        XCTAssertEqual(StockLotMatch.match("ab1", in: alike), .one(alike[1]), "exactly as printed wins")
    }
}
