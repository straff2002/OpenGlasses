import XCTest
@testable import OpenGlasses

/// Plan MY P2 — the report for a range of days: given, wasted by reason, received, on hand by line
/// and lot, expiring and expired lots, count differences, the latest EMR check, the spoken sentence
/// and the spreadsheet. A fixed log, a UTC calendar whose week starts on Monday, invented lines.
final class StockPeriodReportTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func day(_ d: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))!
    }
    private func q(_ whole: Int) -> StockQuantity { StockQuantity(whole: whole) }
    private func stockDay(_ y: Int, _ m: Int, _ d: Int) -> StockDay { StockDay(year: y, month: m, day: d)! }

    /// The week of 16–22 November 2026: lot A of the flu vaccine expires in December (soon), lot B
    /// next September; the one lot of the tetanus vaccine expired on 20 November.
    private func weekLog() -> VanStockLog {
        var log = VanStockLog()
        let flu = log.addItem(id: "flu", description: "the flu vaccine", dosesPerCarton: 10, batch: "b0")
        let tet = log.addItem(id: "tet", description: "the tetanus vaccine", batch: "b0")
        log.addLot(id: "A", itemID: flu.id, code: "ZZ1001", expiry: stockDay(2026, 12, 10), receivedAt: day(10), batch: "b1")
        log.addLot(id: "C", itemID: tet.id, code: "ZZ2001", expiry: stockDay(2026, 11, 20), receivedAt: day(10), batch: "b1")
        log.record(.loaded, itemID: flu.id, quantity: q(10), at: day(10), batch: "b1", source: .scanned, id: "m1", lotID: "A")
        log.record(.loaded, itemID: tet.id, quantity: q(4), at: day(10), batch: "b1", source: .scanned, id: "m2", lotID: "C")
        log.addLot(id: "B", itemID: flu.id, code: "ZZ1002", expiry: stockDay(2027, 9, 30), receivedAt: day(16), batch: "b2")
        log.record(.loaded, itemID: flu.id, quantity: q(20), at: day(16), batch: "b2", source: .scanned, id: "m3", lotID: "B")
        log.record(.used, itemID: flu.id, quantity: q(3), at: day(17), batch: "b3", source: .spoken, id: "m4", lotID: "A")
        log.record(.used, itemID: flu.id, quantity: q(1), at: day(17, 10), batch: "b4", source: .spoken, id: "m5", lotID: "B")
        log.record(.wasted, itemID: flu.id, quantity: q(1), at: day(18), batch: "b5", source: .spoken, id: "m6",
                   lotID: "A", wasteReason: .coldChain)
        log.record(.wasted, itemID: tet.id, quantity: q(2), at: day(18, 10), batch: "b6", source: .spoken, id: "m7",
                   lotID: "C", wasteReason: .expired)
        log.record(.used, itemID: flu.id, quantity: q(1), at: day(19), batch: "b7", source: .spoken, id: "m8", lotID: "A")
        _ = log.undoLastBatch(at: day(19, 10), batch: "u1", source: .spoken, makeID: { "r1" })
        log.record(.counted, itemID: flu.id, quantity: q(5), at: day(20), batch: "b8", source: .typed, id: "m9", lotID: "A")
        log.record(.counted, itemID: flu.id, quantity: q(19), at: day(20, 10), batch: "b9", source: .typed, id: "m10", lotID: "B")
        // After the week: not in it, and not in its on-hand figure.
        log.record(.used, itemID: flu.id, quantity: q(2), at: day(23), batch: "b10", source: .spoken, id: "m11", lotID: "B")
        return log
    }

    private var week: StockReportRange { StockReportRange(first: stockDay(2026, 11, 16), last: stockDay(2026, 11, 22)) }

    private func report(_ log: VanStockLog? = nil, range: StockReportRange? = nil,
                        emr: ImmunisationCheckSummary? = nil) -> StockPeriodReport {
        StockPeriodReport.make(log ?? weekLog(), range: range ?? week, now: day(24), calendar: calendar,
                               clinical: true, emrCheck: emr)
    }

    // MARK: - The golden week

    func testTheWeeksTotals() {
        let report = report()
        XCTAssertEqual(report.given, q(4), "3 from A and 1 from B; the reversed dose counts nowhere")
        XCTAssertEqual(report.received, q(20), "only B came in this week")
        XCTAssertEqual(report.wastedTotal, q(3))
        XCTAssertEqual(report.wastedByReason, [.init(reason: .expired, quantity: q(2)), .init(reason: .coldChain, quantity: q(1))])
        XCTAssertEqual(report.lines.map(\.item.id), ["flu", "tet"])
        XCTAssertEqual(report.lines[0].given, q(4))
        XCTAssertEqual(report.lines[0].wasted, [.coldChain: q(1)])
        XCTAssertEqual(report.lines[1].wasted, [.expired: q(2)])
    }

    func testOnHandIsAsTheLastDayEndedByLineAndLotOldestFirst() {
        let report = report()
        let flu = report.lines[0]
        XCTAssertEqual(flu.onHand, q(24), "the use on the 23rd is after the week")
        XCTAssertEqual(flu.lots.map(\.code), ["ZZ1001", "ZZ1002"])
        XCTAssertEqual(flu.lots.map(\.onHand), [q(5), q(19)])
        XCTAssertEqual(flu.lots.map(\.given), [q(3), q(1)])
        XCTAssertEqual(flu.lots.map(\.received), [.zero, q(20)])
        XCTAssertEqual(report.lines[1].onHand, q(2))
    }

    func testExpiringAndExpiredLots() {
        let report = report()
        XCTAssertEqual(report.expiringSoon.map(\.code), ["ZZ1001"])
        XCTAssertEqual(report.expiringSoon.first?.onHand, q(5))
        XCTAssertEqual(report.expired.map(\.code), ["ZZ2001"])
        XCTAssertEqual(report.expired.first?.expiry, stockDay(2026, 11, 20))
    }

    func testCountDifferencesComparedWithTheLogJustBefore() {
        let report = report()
        XCTAssertEqual(report.countsMade, 2)
        XCTAssertEqual(report.countDifferences.count, 1)
        XCTAssertEqual(report.countDifferences.first?.lotCode, "ZZ1001")
        XCTAssertEqual(report.countDifferences.first?.check, .short(expected: q(6), by: q(1)))
    }

    func testTheSpokenSentenceIsGolden() {
        XCTAssertEqual(report().spokenSummary(),
                       "From 16 November 2026 to 22 November 2026: 4 doses given, 3 wasted (2 expired, 1 cold chain), "
                       + "20 received; 1 lot in the fridge has expired; 1 lot expires within 30 days; "
                       + "1 of 2 counts differed from the log.")
    }

    func testTheSpokenSentenceRepeatsTheLatestEMRCheck() {
        let emr = ImmunisationCheckSummary(ranAt: day(22), first: stockDay(2026, 11, 16), last: stockDay(2026, 11, 22),
                                           givenNotInEMR: 2, inEMRNotGiven: 1, differentLot: 0, nearby: 1, unmatched: 0)
        let sentence = report(emr: emr).spokenSummary()
        XCTAssertTrue(sentence.hasSuffix("the last check against the EMR found 3 differences to look at."), sentence)
    }

    func testAClinicalSentenceSaysNoVanPartOrUsed() {
        let sentence = report().spokenSummary().lowercased()
        for word in ["van", "part", "used"] {
            XCTAssertFalse(sentence.contains(word), "'\(word)' in: \(sentence)")
        }
    }

    // MARK: - Ranges

    func testTodayAndThisWeekAreOneCallAway() {
        let wednesday = day(18, 15)
        XCTAssertEqual(StockReportRange.today(now: wednesday, calendar: calendar),
                       StockReportRange(first: stockDay(2026, 11, 18), last: stockDay(2026, 11, 18)))
        XCTAssertEqual(StockReportRange.thisWeek(now: wednesday, calendar: calendar), week)
    }

    func testOneDaysReport() {
        let report = report(range: StockReportRange(first: stockDay(2026, 11, 17), last: stockDay(2026, 11, 17)))
        XCTAssertEqual(report.given, q(4))
        XCTAssertEqual(report.received, .zero)
        XCTAssertEqual(report.wastedTotal, .zero)
        XCTAssertEqual(report.countsMade, 0)
        XCTAssertTrue(report.spokenSummary().hasPrefix("On 17 November 2026: 4 doses given, 0 wasted, 0 received;"),
                      report.spokenSummary())
    }

    func testAHiddenEmptyLotWithNothingInTheRangeIsLeftOut() {
        var log = weekLog()
        log.addLot(id: "D", itemID: "flu", code: "ZZ1000", expiry: stockDay(2026, 10, 1), receivedAt: day(1), batch: "b11")
        XCTAssertTrue(log.setLot("D", hidden: true))
        XCTAssertFalse(report(log).lines[0].lots.contains { $0.code == "ZZ1000" })
    }

    // MARK: - The spreadsheet

    func testTheSpreadsheetReadsBackAndIsTitledAsStock() throws {
        let report = report()
        XCTAssertEqual(report.fileName, "Stock report 2026-11-16 to 2026-11-22.xlsx")
        let data = report.spreadsheet(modified: day(24))
        let sheets = try XCTUnwrap(try? XLSXReader.read(data).get())
        XCTAssertEqual(sheets.map(\.name), ["Summary", "Given and wasted", "On hand", "Count differences"])
        let summary = sheets[0].rows
        XCTAssertEqual(summary[1].first, "This is a stock record, not the immunisation record.")
        XCTAssertTrue(summary.contains(["Given", "4"]))
        XCTAssertTrue(summary.contains(["Wasted: expired", "2"]))
        XCTAssertTrue(sheets[2].rows.contains(["the flu vaccine", "each", "ZZ1001", "2026-12-10", "5"]))
        XCTAssertTrue(sheets[3].rows.contains(["the flu vaccine", "ZZ1001", "5", "6", "-1"]))
    }

    func testTheSameReportGivesTheSameBytes() {
        XCTAssertEqual(report().spreadsheet(modified: day(24)), report().spreadsheet(modified: day(24)))
    }
}
