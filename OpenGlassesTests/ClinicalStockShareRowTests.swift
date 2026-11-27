import XCTest
@testable import OpenGlasses

/// Plan NJ §1–§2 — what a clinical list shares is inventory-only by construction: one row per day,
/// line, lot, kind and reason; no time, job, staff code or free text can be represented, and the
/// row's fields are a closed allow-list. Invented lines and lots only.
final class ClinicalStockShareRowTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    // 2026-11-25 09:00 UTC, a Wednesday.
    private let morning = Date(timeIntervalSince1970: 1_795_597_200)
    private func at(_ hours: Double, days: Int = 0) -> Date {
        morning.addingTimeInterval(Double(days) * 86_400 + hours * 3_600)
    }
    private func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }

    /// A flu line with two lots and a rabies line with one.
    private func log() -> VanStockLog {
        var log = VanStockLog()
        let flu = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        let rabies = log.addItem(id: "rab", number: "8190", description: "Rabies vaccine", batch: "b0")
        _ = log.addLot(id: "A", itemID: flu.id, code: "ZZ1001", expiry: StockDay(year: 2027, month: 3, day: 31),
                       receivedAt: morning, batch: "b1")
        _ = log.addLot(id: "B", itemID: flu.id, code: "ZZ1002", expiry: nil, receivedAt: morning, batch: "b1")
        _ = log.addLot(id: "R", itemID: rabies.id, code: "RB01", expiry: nil, receivedAt: morning, batch: "b1")
        log.record(.loaded, itemID: "flu", quantity: whole(20), at: at(0), batch: "b1", source: .scanned, id: "m1", lotID: "A")
        log.record(.loaded, itemID: "flu", quantity: whole(10), at: at(0), batch: "b1", source: .scanned, id: "m2", lotID: "B")
        log.record(.loaded, itemID: "rab", quantity: whole(5), at: at(0), batch: "b1", source: .scanned, id: "m3", lotID: "R")
        return log
    }

    // MARK: - The allow-list

    /// Adding a field means editing this list, which makes it a decision rather than an accident.
    func testTheRowsStoredPropertiesAreTheAllowListAndNothingElse() {
        let row = ClinicalStockShareRow(day: StockDay(year: 2026, month: 11, day: 25)!, span: .day, lineID: "flu",
                                        lineNumber: "8161", lineName: "Flu vaccine", lotCode: "ZZ1001", lotExpiry: nil,
                                        kind: .wasted, quantity: whole(1), wasteReason: .coldChain)
        let fields = Mirror(reflecting: row).children.compactMap(\.label)
        let allowList: Set<String> = ["day", "span", "lineID", "lineNumber", "lineName", "lotCode", "lotExpiry",
                                      "kind", "quantity", "wasteReason"]
        for field in fields {
            XCTAssertTrue(allowList.contains(field), "'\(field)' is not on the allow-list of what may leave the phone")
        }
        XCTAssertEqual(Set(fields), allowList)
    }

    func testNoFieldCouldCarryATimeAPersonOrAJob() {
        let row = ClinicalStockShareRow(day: StockDay(year: 2026, month: 11, day: 25)!, span: .day, lineID: "flu",
                                        lineNumber: nil, lineName: "Flu vaccine", lotCode: nil, lotExpiry: nil,
                                        kind: .given, quantity: whole(1), wasteReason: nil)
        for child in Mirror(reflecting: row).children {
            let name = (child.label ?? "").lowercased()
            for word in ["time", "job", "staff", "patient", "person", "note", "reference", "who", "appointment", "comment"] {
                XCTAssertFalse(name.contains(word), "'\(name)' could carry a \(word)")
            }
            XCTAssertFalse(child.value is Date, "\(name) is a time")
        }
    }

    // MARK: - Aggregation

    func testRowsAddUpPerDayLineLotKindAndReason() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(0.5), batch: "g1", source: .spoken, id: "g1", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(2), at: at(3), batch: "g2", source: .spoken, id: "g2", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(4), batch: "g3", source: .spoken, id: "g3", lotID: "B")
        log.record(.used, itemID: "flu", quantity: whole(4), at: at(1, days: 1), batch: "g4", source: .spoken, id: "g4", lotID: "A")
        log.record(.wasted, itemID: "flu", quantity: whole(1), at: at(5), batch: "w1", source: .spoken, id: "w1", lotID: "A",
                   wasteReason: .coldChain)
        log.record(.wasted, itemID: "flu", quantity: whole(2), at: at(6), batch: "w2", source: .spoken, id: "w2", lotID: "A",
                   wasteReason: .expired)
        let rows = ClinicalStockShare.rows(log, calendar: calendar, sensitive: [])
        let given = rows.filter { $0.kind == .given }
        XCTAssertEqual(given.map(\.quantity), [whole(3), whole(1), whole(4)], "A, then B on the first day; A on the next")
        XCTAssertEqual(given.map(\.lotCode), ["ZZ1001", "ZZ1002", "ZZ1001"])
        XCTAssertEqual(given.map(\.day.description), ["2026-11-25", "2026-11-25", "2026-11-26"])
        let wasted = rows.filter { $0.kind == .wasted }
        XCTAssertEqual(Set(wasted.map(\.wasteReason)), [.coldChain, .expired], "one row per reason")
        XCTAssertEqual(rows.filter { $0.kind == .received }.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.span == .day })
    }

    func testNoTimeSurvivesTheDay() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(0.02), batch: "g1", source: .spoken, id: "g1", lotID: "A")
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(8.75), batch: "g2", source: .spoken, id: "g2", lotID: "A")
        let given = ClinicalStockShare.rows(log, calendar: calendar).filter { $0.kind == .given }
        XCTAssertEqual(given.count, 1, "09:01 and 17:45 on the same day are one row")
        XCTAssertEqual(given.first?.quantity, whole(2))
        XCTAssertEqual(given.first?.day, StockDay(year: 2026, month: 11, day: 25))
        let sheet = ClinicalStockShare.sheet(given)
        for cell in sheet.rows.flatMap({ $0 }) {
            if case .text(let text) = cell { XCTAssertNil(text.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), text) }
        }
    }

    func testAWasteReasonPassesThroughAndFreeTextCannotBeRepresented() {
        var log = log()
        log.record(.wasted, itemID: "flu", quantity: whole(1), at: at(1), batch: "w", source: .spoken, id: "w", lotID: "A",
                   wasteReason: .drawnUpNotGiven)
        let row = ClinicalStockShare.rows(log, calendar: calendar).first { $0.kind == .wasted }
        XCTAssertEqual(row?.wasteReason, .drawnUpNotGiven)
        // The reason is a closed list, and the only text fields are the line's and the lot's own.
        XCTAssertEqual(Set(VanStockMovement.WasteReason.allCases.map(\.rawValue)),
                       ["expired", "cold_chain", "drawn_up_not_given", "broken", "opened_vial_discarded", "other"])
        XCTAssertNil(ClinicalStockShare.rows(log, calendar: calendar).first { $0.kind == .given }?.wasteReason)
    }

    func testReturnsAdjustmentsAndCountsAreTheirOwnKinds() {
        var log = log()
        log.record(.removed, itemID: "flu", quantity: whole(2), at: at(1), batch: "r1", source: .spoken, id: "r1",
                   reason: .returned, lotID: "A")
        log.record(.removed, itemID: "flu", quantity: whole(1), at: at(2), batch: "r2", source: .spoken, id: "r2",
                   reason: .damaged, lotID: "A")
        log.record(.counted, itemID: "flu", quantity: whole(15), at: at(3), batch: "c1", source: .spoken, id: "c1", lotID: "A")
        log.record(.counted, itemID: "flu", quantity: whole(16), at: at(4), batch: "c2", source: .spoken, id: "c2", lotID: "A")
        let rows = ClinicalStockShare.rows(log, calendar: calendar)
        XCTAssertEqual(rows.first { $0.kind == .returned }?.quantity, whole(2))
        XCTAssertEqual(rows.first { $0.kind == .adjusted }?.quantity, whole(1))
        XCTAssertEqual(rows.filter { $0.kind == .counted }.map(\.quantity), [whole(16)], "a day's counts are not added: the last stands")
    }

    func testReversedEditedOrderedAndOpeningMovementsGiveNoRow() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(1), batch: "g", source: .spoken, id: "g", lotID: "A")
        _ = log.undoLastBatch(at: at(2), batch: "u", source: .spoken)
        log.record(.ordered, itemID: "flu", quantity: whole(10), at: at(3), batch: "o", source: .spoken, id: "o")
        log.edit(itemID: "flu", .bin("Fridge"), at: at(4), batch: "e", source: .typed, id: "e")
        let kinds = Set(ClinicalStockShare.rows(log, calendar: calendar).map(\.kind))
        XCTAssertEqual(kinds, [.received], "a dose taken back counts nowhere; an order and an edit are not stock moving")
    }

    func testASensitiveLineIsSharedByTheWeek() {
        var log = log()
        log.edit(itemID: "rab", .sensitive(true), at: at(0), batch: "s", source: .typed, id: "s")
        log.record(.used, itemID: "rab", quantity: whole(1), at: at(1), batch: "g1", source: .spoken, id: "g1", lotID: "R")
        log.record(.used, itemID: "rab", quantity: whole(1), at: at(2, days: 2), batch: "g2", source: .spoken, id: "g2", lotID: "R")
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(1), batch: "g3", source: .spoken, id: "g3", lotID: "A")
        let rows = ClinicalStockShare.rows(log, calendar: calendar)
        let rabies = rows.filter { $0.lineID == "rab" && $0.kind == .given }
        XCTAssertEqual(rabies.count, 1, "Wednesday and Friday are one week")
        XCTAssertEqual(rabies.first?.span, .week)
        XCTAssertEqual(rabies.first?.day, StockDay(year: 2026, month: 11, day: 23), "the week's first day, a Monday")
        XCTAssertEqual(rabies.first?.quantity, whole(2))
        XCTAssertEqual(rows.first { $0.lineID == "flu" && $0.kind == .given }?.span, .day)
    }

    func testAStaffCodeAndAJobReferenceNeverReachARow() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(1), batch: "g", source: .spoken, id: "g",
                   jobReference: "JOB-7731", lotID: "A")
        log.record(.wasted, itemID: "flu", quantity: whole(1), at: at(2), batch: "w", source: .spoken, id: "w", lotID: "A",
                   wasteReason: .broken, staffCode: "QX7")
        XCTAssertEqual(log.movements.last?.staffCode, "QX7", "kept on the phone")
        let described = String(describing: ClinicalStockShare.rows(log, calendar: calendar))
        XCTAssertFalse(described.contains("QX7"))
        XCTAssertFalse(described.contains("JOB-7731"))
        let sheet = String(describing: ClinicalStockShare.sheet(ClinicalStockShare.rows(log, calendar: calendar)).rows)
        XCTAssertFalse(sheet.contains("QX7") || sheet.contains("JOB-7731"))
    }

    func testARangeKeepsOnlyItsDays() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: at(1, days: 3), batch: "g", source: .spoken, id: "g", lotID: "A")
        let day = StockDay(year: 2026, month: 11, day: 28)!
        let rows = ClinicalStockShare.rows(log, calendar: calendar, range: StockReportRange(first: day, last: day))
        XCTAssertEqual(rows.map(\.kind), [.given])
    }

    func testTheSheetPrintsSmallFiguresAsFewerThanFiveAndCountsExactly() {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(3), at: at(1), batch: "g", source: .spoken, id: "g", lotID: "A")
        log.record(.counted, itemID: "flu", quantity: whole(2), at: at(2), batch: "c", source: .spoken, id: "c", lotID: "B")
        let sheet = ClinicalStockShare.sheet(ClinicalStockShare.rows(log, calendar: calendar))
        XCTAssertEqual(sheet.rows.first, ClinicalStockShare.headings.map { .text($0) })
        let given = sheet.rows.first { $0.contains(.text("given")) }
        XCTAssertEqual(given?.last, .text("fewer than 5"))
        let counted = sheet.rows.first { $0.contains(.text("counted")) }
        XCTAssertEqual(counted?.last, .decimal(whole(2)), "a count is a level, not a dose event")
        let received = sheet.rows.first { $0.contains(.text("received")) && $0.contains(.text("ZZ1001")) }
        XCTAssertEqual(received?.last, .decimal(whole(20)))
    }
}
