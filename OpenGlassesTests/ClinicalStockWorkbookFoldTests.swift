import XCTest
@testable import OpenGlasses

/// Plan NK §1–§2 — the workbook's rows fold to the same figures as the phone's own ledger over a
/// fixture; rows from several phones add up; a day's last count stands; and the comparison says
/// "matches" or "differs by N", per line and lot, without changing either. Invented lines and lots.
final class ClinicalStockWorkbookFoldTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    // 2026-11-23 09:00 UTC, a Monday.
    private let monday = Date(timeIntervalSince1970: 1_795_424_400)
    private func at(_ hours: Double, days: Int = 0) -> Date { monday.addingTimeInterval(Double(days) * 86_400 + hours * 3_600) }
    private func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }
    private func day(_ d: Int) -> StockDay { StockDay(year: 2026, month: 11, day: d)! }

    /// Flu with two lots, hepatitis B with none, MMR with one: three days of a clinic's week, each
    /// day's count (where there is one) the last thing done that day.
    private func fixture() -> VanStockLog {
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        _ = log.addItem(id: "hep", number: nil, description: "Hepatitis B vaccine", batch: "b0")
        _ = log.addItem(id: "mmr", number: "8170", description: "MMR vaccine", batch: "b0")
        _ = log.addLot(id: "A", itemID: "flu", code: "ZZ1001", expiry: StockDay(year: 2027, month: 3, day: 31), receivedAt: monday, batch: "b1")
        _ = log.addLot(id: "B", itemID: "flu", code: "ZZ1002", expiry: nil, receivedAt: monday, batch: "b1")
        _ = log.addLot(id: "M", itemID: "mmr", code: "MM77", expiry: nil, receivedAt: monday, batch: "b1")
        // Monday: deliveries, doses, a waste.
        log.record(.loaded, itemID: "flu", quantity: whole(30), at: at(0), batch: "b1", source: .scanned, id: "m1", lotID: "A")
        log.record(.loaded, itemID: "flu", quantity: whole(10), at: at(0), batch: "b1", source: .scanned, id: "m2", lotID: "B")
        log.record(.loaded, itemID: "hep", quantity: whole(12), at: at(0), batch: "b1", source: .typed, id: "m3")
        log.record(.loaded, itemID: "mmr", quantity: whole(8), at: at(0), batch: "b1", source: .scanned, id: "m4", lotID: "M")
        log.record(.used, itemID: "flu", quantity: whole(4), at: at(1), batch: "b2", source: .spoken, id: "m5", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(2), at: at(2), batch: "b3", source: .spoken, id: "m6", lotID: "A")
        log.record(.wasted, itemID: "mmr", quantity: whole(1), at: at(3), batch: "b4", source: .typed, id: "m7", lotID: "M",
                   wasteReason: .coldChain)
        log.record(.used, itemID: "hep", quantity: whole(3), at: at(4), batch: "b5", source: .spoken, id: "m8")
        // Tuesday: more doses, then the evening count finds one flu dose fewer in lot A.
        log.record(.used, itemID: "flu", quantity: whole(5), at: at(1, days: 1), batch: "b6", source: .spoken, id: "m9", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(2, days: 1), batch: "b7", source: .spoken, id: "m10", lotID: "B")
        log.record(.removed, itemID: "hep", quantity: whole(2), at: at(3, days: 1), batch: "b8", source: .typed, id: "m11",
                   reason: .returned)
        log.record(.counted, itemID: "flu", quantity: whole(18), at: at(8, days: 1), batch: "b9", source: .typed, id: "m12", lotID: "A")
        // Wednesday: a dose taken back by undo, a count of the line with no lots, a delivery.
        log.record(.used, itemID: "mmr", quantity: whole(2), at: at(1, days: 2), batch: "b10", source: .spoken, id: "m13", lotID: "M")
        _ = log.undoLastBatch(at: at(1.1, days: 2), batch: "b11", source: .typed, makeID: { "u1" })
        log.record(.used, itemID: "mmr", quantity: whole(1), at: at(2, days: 2), batch: "b12", source: .spoken, id: "m14", lotID: "M")
        log.record(.loaded, itemID: "flu", quantity: whole(6), at: at(3, days: 2), batch: "b13", source: .scanned, id: "m15", lotID: "B")
        log.record(.counted, itemID: "hep", quantity: whole(6), at: at(8, days: 2), batch: "b14", source: .typed, id: "m16")
        return log
    }

    /// What a phone sends for `log`, read back as Graph would hand it.
    private func workbookEntries(_ log: VanStockLog, seat: String = "seat-one") throws -> [ClinicalStockWorkbookEntry] {
        let rows = ClinicalStockShare.rows(log, calendar: calendar)
        let keyed = ClinicalStockSendPlan.plan(current: rows, ledger: .init(), seat: seat, range: nil).rows
        return try read(keyed)
    }

    private func read(_ keyed: [KeyedShareRow]) throws -> [ClinicalStockWorkbookEntry] {
        var entries: [ClinicalStockWorkbookEntry] = []
        for table in ClinicalStockWorkbookTable.allCases {
            let mine = keyed.filter { ClinicalStockWorkbookTable.of($0.row) == table }
            let data = try JSONSerialization.data(withJSONObject: mine.map { ClinicalStockWorkbookSchema.cells($0).map(\.json) })
            let cells = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[Any]])
            entries += try ClinicalStockWorkbookSchema.read(table, headers: table.headers, rows: cells).get().entries
        }
        return entries
    }

    private func sample(_ kind: ClinicalStockShareRow.Kind, _ quantity: Int, table: ClinicalStockWorkbookTable = .movements,
                       day d: Int = 23, lot: String? = "ZZ1001", position: Int = 0) -> ClinicalStockWorkbookEntry {
        ClinicalStockWorkbookEntry(table: table, day: day(d), span: .day, lineNumber: "8161", lineName: "Flu vaccine",
                                   lotCode: lot, kind: kind, quantity: whole(quantity), wasteReason: nil, key: nil,
                                   position: position)
    }

    private let flu = ClinicalStockLineIdentity(number: "8161", name: "Flu vaccine")

    // MARK: - The same figures as the phone

    func testTheWorkbookFoldsToThePhonesOwnFiguresOverTheFixture() throws {
        let log = fixture()
        let shared = ClinicalStockWorkbookFold.fold(try workbookEntries(log))
        let own = ClinicalStockWorkbookFold.own(log)
        XCTAssertEqual(Set(shared.keys), Set(own.keys))
        for (line, figure) in own {
            XCTAssertEqual(shared[line]?.onHand, figure.onHand, line.value)
            XCTAssertEqual(shared[line]?.lots, figure.lots, line.value)
        }
        // And the figures are the ones the week makes.
        XCTAssertEqual(own[flu]?.onHand, whole(18 + 9 + 6))
        XCTAssertEqual(own[flu]?.lots, ["ZZ1001": whole(18), "ZZ1002": whole(15)])
        XCTAssertEqual(own[ClinicalStockLineIdentity(number: nil, name: "Hepatitis B vaccine")]?.onHand, whole(6))
        XCTAssertEqual(own[ClinicalStockLineIdentity(number: "8170", name: "MMR vaccine")]?.lots, ["MM77": whole(6)])
        let comparison = ClinicalStockComparison.compare(shared: shared, own: own)
        XCTAssertEqual(comparison.differing, 0)
        XCTAssertTrue(comparison.lines.allSatisfy { $0.verdict == .matches })
    }

    func testTopUpsAndCorrectionsFoldToTheSameFigures() throws {
        // Monday sent "so far" at lunch, then the rest of the week in a later send.
        let log = fixture()
        var partial = VanStockLog()
        _ = partial.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        _ = partial.addLot(id: "A", itemID: "flu", code: "ZZ1001", expiry: nil, receivedAt: monday, batch: "b1")
        partial.record(.loaded, itemID: "flu", quantity: whole(30), at: at(0), batch: "b1", source: .scanned, id: "m1", lotID: "A")
        partial.record(.used, itemID: "flu", quantity: whole(7), at: at(1), batch: "b2", source: .spoken, id: "x")
        let first = ClinicalStockSendPlan.plan(current: ClinicalStockShare.rows(partial, calendar: calendar), ledger: .init(),
                                               seat: "seat-one", range: nil)
        let second = ClinicalStockSendPlan.plan(current: ClinicalStockShare.rows(log, calendar: calendar), ledger: first.ledger,
                                                seat: "seat-one", range: nil)
        let shared = ClinicalStockWorkbookFold.fold(try read(first.rows + second.rows))
        let own = ClinicalStockWorkbookFold.own(log)
        for (line, figure) in own {
            XCTAssertEqual(shared[line]?.onHand, figure.onHand, line.value)
            XCTAssertEqual(shared[line]?.lots, figure.lots, line.value)
        }
    }

    // MARK: - Several phones, one fridge

    func testRowsFromSeveralPhonesAddUp() {
        let figures = ClinicalStockWorkbookFold.fold([
            sample(.received, 20, position: 0), sample(.given, 3, position: 1),   // one phone
            sample(.given, 2, position: 2), sample(.wasted, 1, position: 3),      // another
        ])
        XCTAssertEqual(figures[flu]?.onHand, whole(14))
        XCTAssertEqual(figures[flu]?.lots["ZZ1001"], whole(14))
    }

    func testADaysLastCountStandsAndClosesTheDay() {
        let figures = ClinicalStockWorkbookFold.fold([
            sample(.received, 20, position: 0),
            sample(.counted, 15, table: .counts, position: 0), sample(.counted, 16, table: .counts, position: 1),
            sample(.given, 2, day: 24, position: 1),
        ])
        XCTAssertEqual(figures[flu]?.lots["ZZ1001"], whole(14), "the last count, 16, then the next day's doses")
        XCTAssertEqual(figures[flu]?.onHand, whole(14))
    }

    /// The workbook has the day, not the minute: a dose given after the day's count is in the
    /// record, but the day closes at the figure counted. The comparison says so; nothing is changed.
    func testADoseAfterTheDaysCountIsADifferenceTheComparisonShows() throws {
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        _ = log.addLot(id: "A", itemID: "flu", code: "ZZ1001", expiry: nil, receivedAt: monday, batch: "b1")
        log.record(.loaded, itemID: "flu", quantity: whole(20), at: at(0), batch: "b1", source: .scanned, id: "m1", lotID: "A")
        log.record(.counted, itemID: "flu", quantity: whole(20), at: at(1), batch: "b2", source: .typed, id: "m2", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(2), batch: "b3", source: .spoken, id: "m3", lotID: "A")
        let comparison = ClinicalStockComparison.compare(shared: ClinicalStockWorkbookFold.fold(try workbookEntries(log)),
                                                         own: ClinicalStockWorkbookFold.own(log))
        XCTAssertEqual(comparison.lines.first?.verdict, .differs(by: whole(1)))
        XCTAssertEqual(comparison.differing, 1)
    }

    func testNothingGoesBelowZero() {
        let figures = ClinicalStockWorkbookFold.fold([sample(.received, 2), sample(.given, 5, position: 1)])
        XCTAssertEqual(figures[flu]?.onHand, .zero)
    }

    /// Rows sit in the table in the order they were added, not the order things happened: a day's
    /// doses listed before its delivery still take from it, and a correction after them still counts.
    func testTheOrderOfADaysRowsInTheTableDoesNotMatter() {
        let figures = ClinicalStockWorkbookFold.fold([
            sample(.given, 7, lot: nil, position: 0), sample(.received, 30, position: 1),
            sample(.given, 6, position: 2),
            ClinicalStockWorkbookEntry(table: .movements, day: day(23), span: .day, lineNumber: "8161", lineName: "Flu vaccine",
                                       lotCode: nil, kind: .given, quantity: StockQuantity(scaled: -7000), wasteReason: nil,
                                       key: nil, position: 3),
        ])
        XCTAssertEqual(figures[flu]?.onHand, whole(24))
        XCTAssertEqual(figures[flu]?.lots["ZZ1001"], whole(24))
    }

    func testLinesAreMatchedByNumberThenByName() {
        XCTAssertEqual(ClinicalStockLineIdentity(number: "8161", name: "Flu"), ClinicalStockLineIdentity(number: " 8161", name: "Influenza"))
        XCTAssertEqual(ClinicalStockLineIdentity(number: nil, name: "Hep B "), ClinicalStockLineIdentity(number: "", name: "hep b"))
        XCTAssertNotEqual(ClinicalStockLineIdentity(number: "8161", name: "Flu"), ClinicalStockLineIdentity(number: nil, name: "Flu"))
    }

    // MARK: - The comparison

    func testTheComparisonSaysMatchesOrDiffersByNPerLineAndLot() throws {
        let own: [ClinicalStockLineIdentity: ClinicalStockFigure] = [
            flu: ClinicalStockFigure(name: "Flu vaccine", onHand: whole(10), lots: ["ZZ1001": whole(6), "ZZ1002": whole(4)]),
            ClinicalStockLineIdentity(number: nil, name: "Hep B"): ClinicalStockFigure(name: "Hep B", onHand: whole(3)),
        ]
        let shared: [ClinicalStockLineIdentity: ClinicalStockFigure] = [
            flu: ClinicalStockFigure(name: "Flu vaccine", onHand: whole(8), lots: ["ZZ1001": whole(6), "ZZ1002": whole(2)]),
            ClinicalStockLineIdentity(number: nil, name: "Polio"): ClinicalStockFigure(name: "Polio", onHand: whole(5)),
        ]
        let comparison = ClinicalStockComparison.compare(shared: shared, own: own)
        let line = try XCTUnwrap(comparison.lines.first { $0.identity == flu })
        XCTAssertEqual(line.verdict, .differs(by: StockQuantity(scaled: -2000)))
        XCTAssertEqual(line.lots.map(\.verdict), [.matches, .differs(by: StockQuantity(scaled: -2000))])
        XCTAssertEqual(comparison.lines.first { $0.name == "Hep B" }?.verdict, .notShared)
        XCTAssertEqual(comparison.lines.first { $0.name == "Polio" }?.verdict, .differs(by: whole(5)))
        XCTAssertEqual(comparison.differing, 2)

        XCTAssertNil(ClinicalStockComparison.sentence(.matches))
        XCTAssertEqual(ClinicalStockComparison.sentence(.differs(by: StockQuantity(scaled: -2000))), "The clinic's workbook shows 2 fewer.")
        XCTAssertEqual(ClinicalStockComparison.sentence(.differs(by: whole(5))), "The clinic's workbook shows 5 more.")
        XCTAssertEqual(ClinicalStockComparison.sentence(.notShared), "Not in the clinic's workbook yet.")
    }

    func testTheComparisonChangesNeitherFigure() {
        let own = ClinicalStockWorkbookFold.own(fixture())
        let shared = ClinicalStockWorkbookFold.fold([sample(.received, 1)])
        let before = (own, shared)
        _ = ClinicalStockComparison.compare(shared: shared, own: own)
        XCTAssertEqual(before.0, own)
        XCTAssertEqual(before.1, shared)
    }
}
