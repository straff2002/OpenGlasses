import XCTest
@testable import OpenGlasses

/// Plan NJ §6, Decision 5 — in a clinic's reports and exports a figure from 1 to 4 prints as
/// "fewer than 5" and a sensitive line is shown by the week; a van's report and export are as
/// they were; and the phone's own Stock screen still shows the exact count. Invented lines only.
@MainActor
final class StockSmallCellTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    // 2026-11-25 09:00 UTC, a Wednesday.
    private let morning = Date(timeIntervalSince1970: 1_795_597_200)
    private func whole(_ n: Int) -> StockQuantity { StockQuantity(whole: n) }
    private var today: StockReportRange { .today(now: morning.addingTimeInterval(3_600 * 8), calendar: calendar) }
    private var week: StockReportRange { .thisWeek(now: morning, calendar: calendar) }

    private func log(sensitiveRabies: Bool = true) -> VanStockLog {
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
        _ = log.addItem(id: "rab", number: "8190", description: "Rabies vaccine", batch: "b0")
        if sensitiveRabies { log.edit(itemID: "rab", .sensitive(true), at: morning, batch: "s", source: .typed, id: "s") }
        log.record(.loaded, itemID: "flu", quantity: whole(30), at: morning, batch: "l1", source: .typed, id: "l1")
        log.record(.loaded, itemID: "rab", quantity: whole(5), at: morning, batch: "l2", source: .typed, id: "l2")
        log.record(.used, itemID: "flu", quantity: whole(12), at: morning.addingTimeInterval(3_600), batch: "g1",
                   source: .spoken, id: "g1")
        log.record(.used, itemID: "rab", quantity: whole(1), at: morning.addingTimeInterval(7_200), batch: "g2",
                   source: .spoken, id: "g2")
        log.record(.wasted, itemID: "flu", quantity: whole(2), at: morning.addingTimeInterval(9_000), batch: "w1",
                   source: .spoken, id: "w1", wasteReason: .coldChain)
        return log
    }

    private func report(_ log: VanStockLog, _ range: StockReportRange, clinical: Bool) -> StockPeriodReport {
        StockPeriodReport.make(log, range: range, now: morning.addingTimeInterval(3_600 * 8), calendar: calendar,
                               clinical: clinical)
    }

    private func sheet(_ workbook: XLSX.Workbook, _ name: String) -> XLSX.Sheet? { workbook.sheets.first { $0.name == name } }
    private func row(_ sheet: XLSX.Sheet?, _ label: String) -> [XLSX.Cell]? { sheet?.rows.first { $0.first == .text(label) } }

    // MARK: - The rule

    func testOneToFourIsASmallCellAndZeroAndFiveAreNot() {
        XCTAssertFalse(StockSmallCell.isSmall(.zero))
        for n in 1...4 { XCTAssertTrue(StockSmallCell.isSmall(whole(n)), "\(n)") }
        XCTAssertFalse(StockSmallCell.isSmall(whole(5)))
        XCTAssertEqual(VaccineStockPolicy.smallCellThreshold, 5)
        XCTAssertEqual(StockSmallCell.text(whole(3)), "fewer than 5")
        XCTAssertEqual(StockSmallCell.text(whole(12)), "12")
        XCTAssertEqual(StockSmallCell.cell(whole(1)), .text("fewer than 5"))
        XCTAssertEqual(StockSmallCell.cell(.zero), .decimal(.zero))
        XCTAssertEqual(StockSmallCell.fewerThan(10), "fewer than 10", "the threshold is interpolated")
    }

    // MARK: - The period report

    func testAClinicsReportPrintsSmallFiguresAsFewerThanFive() {
        let workbook = report(log(sensitiveRabies: false), week, clinical: true).workbook()
        let summary = sheet(workbook, "Summary")
        XCTAssertEqual(row(summary, "Given")?.last, .decimal(whole(13)))
        XCTAssertEqual(row(summary, "Wasted: cold chain")?.last, .text("fewer than 5"))
        XCTAssertEqual(row(summary, "Wasted: expired")?.last, .decimal(.zero), "zero identifies nobody")
        let given = sheet(workbook, "Given and wasted")
        XCTAssertEqual(row(given, "Rabies vaccine (8190)")?[3], .text("fewer than 5"))
        XCTAssertEqual(row(given, "Flu vaccine (8161)")?[3], .decimal(whole(12)))
        let onHand = sheet(workbook, "On hand")
        XCTAssertEqual(row(onHand, "Rabies vaccine (8190)")?.last, .decimal(whole(4)), "a level prints exactly")
    }

    func testAVansReportIsExactAsBefore() {
        let workbook = report(log(sensitiveRabies: false), week, clinical: false).workbook()
        XCTAssertEqual(row(sheet(workbook, "Summary"), "Wasted: cold chain")?.last, .decimal(whole(2)))
        XCTAssertNil(sheet(workbook, "By day"))
        XCTAssertEqual(workbook.sheets.map(\.name), ["Summary", "Given and wasted", "On hand", "Count differences"])
    }

    func testASensitiveLineReportsWeeklyNotDaily() {
        let daily = report(log(), today, clinical: true)
        XCTAssertTrue(daily.showsLessThanAWeek)
        let given = sheet(daily.workbook(), "Given and wasted")
        XCTAssertEqual(row(given, "Rabies vaccine (8190)")?[3], .text(StockPeriodReport.reportedWeekly))
        XCTAssertEqual(row(given, "Flu vaccine (8161)")?[3], .decimal(whole(12)), "an ordinary line still reports by day")
        let byDay = sheet(daily.workbook(), "By day")
        let rabies = byDay?.rows.first { $0.contains(.text("Rabies vaccine")) && $0.contains(.text("given")) }
        XCTAssertEqual(rabies?[1], .text("Week"))
        XCTAssertEqual(rabies?[0], .text("2026-11-23"), "the week's first day, never the day it was given")

        let weekly = report(log(), week, clinical: true)
        XCTAssertFalse(weekly.showsLessThanAWeek)
        XCTAssertEqual(row(sheet(weekly.workbook(), "Given and wasted"), "Rabies vaccine (8190)")?[3], .text("fewer than 5"))
    }

    func testThePhonesOwnScreenShowsTheExactCount() {
        let log = log()
        XCTAssertEqual(log.level(of: "rab").onHand, whole(4))
        let rows = VanStockRows.rows(log)
        XCTAssertEqual(rows.first { $0.item.id == "rab" }?.level.onHand, whole(4))
        // The report's own lines, which the Stock screen's report reads, are exact; only the
        // spreadsheet goes through the rule.
        let daily = report(log, today, clinical: true)
        XCTAssertEqual(daily.lines.first { $0.item.id == "rab" }?.given, whole(1))
        XCTAssertTrue(daily.spokenSummary().contains("13 doses given"))
    }

    // MARK: - The stock export

    func testAClinicsExportIsByDayWithNoTimesOrJobs() throws {
        var log = log()
        log.record(.used, itemID: "flu", quantity: whole(1), at: morning.addingTimeInterval(10_000), batch: "g9",
                   source: .spoken, id: "g9", jobReference: "JOB-7731")
        let workbook = VanStockSheet.workbook(log, exportedAt: morning, calendar: calendar, kind: .stock, clinical: true)
        XCTAssertEqual(workbook.sheets.map(\.name), [VanStockSheet.stockSheetName(.stock), VanStockSheet.clinicalHistorySheetName,
                                                     VanStockSheet.metaSheetName])
        XCTAssertNil(sheet(workbook, VanStockSheet.historySheetName), "no per-movement history leaves the phone")
        let byDay = try XCTUnwrap(sheet(workbook, VanStockSheet.clinicalHistorySheetName))
        let text = byDay.rows.flatMap { $0 }.compactMap { cell -> String? in
            if case .text(let value) = cell { return value }
            return nil
        }
        XCTAssertFalse(text.contains("JOB-7731"))
        XCTAssertFalse(text.contains { $0.range(of: #"\d{2}:\d{2}"#, options: .regularExpression) != nil }, "\(text)")
        let stock = try XCTUnwrap(workbook.sheets.first)
        let lastChanged = try XCTUnwrap(stock.rows.first?.firstIndex(of: .text(VanStockSheet.Column.lastChanged.rawValue)))
        let description = try XCTUnwrap(VanStockSheet.Column.allCases.firstIndex(of: .description))
        let onHand = try XCTUnwrap(VanStockSheet.Column.allCases.firstIndex(of: .onHand))
        let rabies = try XCTUnwrap(stock.rows.first { $0[description] == .text("Rabies vaccine") })
        XCTAssertEqual(rabies[lastChanged], .text("2026-11-25"), "a day, not a minute")
        XCTAssertEqual(rabies[onHand], .decimal(whole(4)), "the levels stay exact, so a takeover reads them back")
    }

    func testAVansExportIsUnchanged() {
        let workbook = VanStockSheet.workbook(log(), exportedAt: morning, calendar: calendar, kind: .van)
        XCTAssertEqual(workbook.sheets.map(\.name), [VanStockSheet.stockSheetName(.van), VanStockSheet.historySheetName,
                                                     VanStockSheet.metaSheetName])
        XCTAssertEqual(workbook, VanStockSheet.workbook(log(), exportedAt: morning, calendar: calendar, kind: .van, clinical: false))
    }

    func testAClinicsExportStillTakesOver() throws {
        let data = VanStockSheet.data(log(), van: VanIdentity(id: "fridge", name: "Main fridge", clinical: true),
                                      exportedAt: morning, calendar: calendar, kind: .stock, clinical: true)
        let sheets = try XCTUnwrap(try? XLSXReader.read(data).get())
        guard case .success(let takeover) = VanStockHandover.takeover(from: sheets, at: morning, batch: "t") else {
            return XCTFail("a clinic's export must still be a workbook another phone can take over")
        }
        XCTAssertEqual(takeover.lineCount, 2)
        XCTAssertEqual(takeover.log.level(of: takeover.log.items.first { $0.description == "Rabies vaccine" }?.id ?? "").onHand,
                       whole(4))
    }
}
