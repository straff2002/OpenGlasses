import XCTest
@testable import OpenGlasses

/// Plan NK §2 — once each: the same day sent twice adds nothing, a day sent "so far" and topped up
/// adds only the difference as a new row with its own key, and a correction is a new row with the
/// opposite quantity. Invented lines and lots only.
final class ClinicalStockRowKeyTests: XCTestCase {

    private let seat = "seat-one"
    private func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }
    private func day(_ d: Int) -> StockDay { StockDay(year: 2026, month: 11, day: d)! }

    private func row(_ kind: ClinicalStockShareRow.Kind = .given, _ quantity: Int, day d: Int = 25, lot: String? = "ZZ1001",
                     reason: VanStockMovement.WasteReason? = nil) -> ClinicalStockShareRow {
        ClinicalStockShareRow(day: day(d), span: .day, lineID: "flu", lineNumber: "8161", lineName: "Flu vaccine",
                              lotCode: lot, lotExpiry: nil, kind: kind, quantity: whole(quantity), wasteReason: reason)
    }

    private func plan(_ rows: [ClinicalStockShareRow], _ ledger: ClinicalStockSendLedger = .init(),
                      range: StockReportRange? = nil) -> ClinicalStockSendPlan.Plan {
        ClinicalStockSendPlan.plan(current: rows, ledger: ledger, seat: seat, range: range)
    }

    // MARK: - The key

    func testAKeyIsSeatBaseAndSequenceAndSaysNothingAboutTheRow() throws {
        let base = ClinicalStockRowKey.base(row(.given, 3), seat: seat)
        let key = ClinicalStockRowKey.key(base: base, sequence: 2)
        let parsed = try XCTUnwrap(ClinicalStockRowKey.parse(key))
        XCTAssertEqual(parsed.base, base)
        XCTAssertEqual(parsed.sequence, 2)
        XCTAssertTrue(key.hasPrefix(ClinicalStockRowKey.seatTag(seat) + "."))
        for said in ["8161", "flu", "Flu", "ZZ1001", "2026", "given", seat] {
            XCTAssertFalse(key.contains(said), "the key gives away \(said)")
        }
        for bad in ["", "abc", "abcdef01.0123456789ab", "abcdef01.0123456789ab.0", "xyzxyzxy.0123456789ab.1"] {
            XCTAssertNil(ClinicalStockRowKey.parse(bad), bad)
        }
    }

    func testTheBaseIsTheSameForTheSameRowAndDiffersForAnythingItIsAbout() {
        let base = ClinicalStockRowKey.base(row(.given, 3), seat: seat)
        XCTAssertEqual(base, ClinicalStockRowKey.base(row(.given, 9), seat: seat), "the quantity is not in the base")
        let others = [row(.given, 3, day: 26), row(.given, 3, lot: "ZZ1002"), row(.wasted, 3, reason: .expired),
                      row(.wasted, 3, reason: .broken), row(.received, 3)]
        for other in others { XCTAssertNotEqual(base, ClinicalStockRowKey.base(other, seat: seat)) }
        XCTAssertNotEqual(base, ClinicalStockRowKey.base(row(.given, 3), seat: "seat-two"), "two phones never share a key")
    }

    // MARK: - Once each

    func testTheSameDaySentTwiceAddsNothing() {
        let rows = [row(.received, 20), row(.given, 3), row(.counted, 17)]
        let first = plan(rows)
        XCTAssertEqual(first.rows.count, 3)
        XCTAssertEqual(first.rows.map(\.row), rows)
        XCTAssertTrue(first.rows.allSatisfy { ClinicalStockRowKey.parse($0.key)?.sequence == 1 })
        XCTAssertTrue(plan(rows, first.ledger).rows.isEmpty)
    }

    func testADaySentSoFarAndToppedUpAddsOnlyTheDifference() throws {
        let first = plan([row(.given, 3)])
        let second = plan([row(.given, 5)], first.ledger)
        let topUp = try XCTUnwrap(second.rows.first)
        XCTAssertEqual(second.rows.count, 1)
        XCTAssertEqual(topUp.row.quantity, whole(2))
        XCTAssertNotEqual(topUp.key, first.rows[0].key, "a top-up is a new row with its own key")
        XCTAssertEqual(ClinicalStockRowKey.parse(topUp.key)?.sequence, 2)
        XCTAssertEqual(ClinicalStockRowKey.parse(topUp.key)?.base, ClinicalStockRowKey.parse(first.rows[0].key)?.base)
        XCTAssertEqual(second.ledger.entries.values.first?.sent, whole(5))
    }

    func testACorrectionIsANewRowWithTheOppositeQuantity() throws {
        let first = plan([row(.given, 5), row(.wasted, 2, reason: .coldChain)])
        // One dose taken back, and the waste reversed altogether.
        let second = plan([row(.given, 4)], first.ledger)
        XCTAssertEqual(second.rows.count, 2)
        let given = try XCTUnwrap(second.rows.first { $0.row.kind == .given })
        XCTAssertEqual(given.row.quantity, StockQuantity(scaled: -1000))
        let wasted = try XCTUnwrap(second.rows.first { $0.row.kind == .wasted })
        XCTAssertEqual(wasted.row.quantity, StockQuantity(scaled: -2000))
        XCTAssertEqual(wasted.row.wasteReason, .coldChain, "the correction repeats what it corrects")
        XCTAssertTrue(plan([row(.given, 4)], second.ledger).rows.isEmpty, "and then nothing more")
    }

    func testACountIsSentAgainOnlyWhenTheDaysLastCountChanged() throws {
        let first = plan([row(.counted, 10)])
        XCTAssertTrue(plan([row(.counted, 10)], first.ledger).rows.isEmpty)
        let recount = plan([row(.counted, 12)], first.ledger)
        XCTAssertEqual(recount.rows.map(\.row.quantity), [whole(12)], "a count says the level, not a difference")
        XCTAssertEqual(recount.ledger.entries.values.first?.sent, whole(12))
        // A count taken back is not undone in the workbook: the next count replaces it.
        XCTAssertTrue(plan([], recount.ledger).rows.isEmpty)
    }

    func testRowsThatNeverReachedTheWorkbookAreMadeAgainUnderANewKey() throws {
        let first = plan([row(.given, 3)])
        var ledger = first.ledger
        ledger.rollBack(first.rows.map(\.key))
        let again = plan([row(.given, 3)], ledger)
        let row = try XCTUnwrap(again.rows.first)
        XCTAssertEqual(row.row.quantity, whole(3))
        XCTAssertEqual(ClinicalStockRowKey.parse(row.key)?.sequence, 2, "a sequence is never used twice")
    }

    // MARK: - The window

    func testTheFirstSendCoversTheHistoryAndLaterOnesTheWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 9)))
        XCTAssertNil(ClinicalStockSendPlan.range(ledger: .init(), now: now, calendar: calendar))
        let sent = plan([row(.given, 3, day: 1)])
        XCTAssertTrue(sent.ledger.historySent)
        let range = try XCTUnwrap(ClinicalStockSendPlan.range(ledger: sent.ledger, now: now, calendar: calendar))
        XCTAssertEqual(range.last, day(27))
        // From the Monday of the week 62 days back, so a weekly row is never cut in two.
        XCTAssertEqual(range.first, StockDay(year: 2026, month: 9, day: 21))
        XCTAssertLessThanOrEqual(range.first, day(27).adding(days: -(ClinicalStockSendPlan.windowDays - 1), calendar: calendar))
    }

    func testNothingOutsideTheWindowIsTakenBack() {
        let old = plan([row(.given, 3, day: 1)])
        let range = StockReportRange(first: day(20), last: day(27))
        XCTAssertTrue(plan([], old.ledger, range: range).rows.isEmpty, "a day the window no longer covers is left alone")
        var pruned = old.ledger
        pruned.prune(before: day(20))
        XCTAssertTrue(pruned.entries.isEmpty)
    }

    // MARK: - A new install

    func testANewInstallRebuildsItsLedgerFromItsOwnRowsInTheWorkbook() {
        let sent = plan([row(.given, 3), row(.counted, 9)])
        let entries = sent.rows.enumerated().map { index, keyed in
            ClinicalStockWorkbookEntry(table: ClinicalStockWorkbookTable.of(keyed.row), day: keyed.row.day, span: .day,
                                       lineNumber: keyed.row.lineNumber, lineName: keyed.row.lineName,
                                       lotCode: keyed.row.lotCode, kind: keyed.row.kind, quantity: keyed.row.quantity,
                                       wasteReason: nil, key: keyed.key, position: index)
        }
        // Another phone's row, and one staff typed, are not this phone's.
        let others = [ClinicalStockWorkbookEntry(table: .movements, day: day(25), span: .day, lineNumber: "8161",
                                                 lineName: "Flu vaccine", lotCode: "ZZ1001", kind: .given,
                                                 quantity: whole(1), wasteReason: nil,
                                                 key: ClinicalStockRowKey.key(base: ClinicalStockRowKey.base(row(.given, 1), seat: "seat-two"), sequence: 1),
                                                 position: 5),
                      ClinicalStockWorkbookEntry(table: .movements, day: day(25), span: .day, lineNumber: nil,
                                                 lineName: "Flu vaccine", lotCode: nil, kind: .given, quantity: whole(1),
                                                 wasteReason: nil, key: nil, position: 6)]
        let byKey = Dictionary(uniqueKeysWithValues: sent.rows.map { ($0.key, $0.row) })
        let rebuilt = ClinicalStockSendLedger.rebuilt(from: entries + others, rowsByKey: byKey, seat: seat)
        XCTAssertEqual(rebuilt.entries.count, 2)
        XCTAssertTrue(plan([row(.given, 3), row(.counted, 9)], rebuilt).rows.isEmpty, "nothing is added twice")
        XCTAssertEqual(plan([row(.given, 4), row(.counted, 9)], rebuilt).rows.map(\.row.quantity), [whole(1)])
    }

    func testTheLedgerSurvivesTheKeychainAsJSON() throws {
        let sent = plan([row(.given, 3), row(.counted, 9)])
        let data = try JSONEncoder().encode(sent.ledger)
        XCTAssertEqual(try JSONDecoder().decode(ClinicalStockSendLedger.self, from: data), sent.ledger)
    }
}
