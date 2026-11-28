import XCTest
@testable import OpenGlasses

/// Plan MY P3 — the EMR's list read through its three mapped columns, the line aliases, and the
/// comparison per day × line × lot: given here and not in the EMR, in the EMR and not given here,
/// same day with a different lot, and a nearby day. Invented lines, codes and lots only.
final class ImmunisationReconciliationTests: XCTestCase {

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ d: Int) -> StockDay { StockDay(year: 2026, month: 11, day: d)! }

    private let items: [VanStockItem] = {
        var log = VanStockLog()
        log.addItem(id: "flu", description: "the flu vaccine", codes: ["02000000000015", "FLU-EMR"], batch: "b0")
        log.addItem(id: "tet", description: "the tetanus vaccine", codes: ["TET"], batch: "b0")
        return log.items
    }()

    private func compare(_ doses: [ImmunisationReconciliation.Dose], _ records: [ImmunisationRecord],
                         first: Int = 20, last: Int = 30) -> ImmunisationReconciliation {
        ImmunisationReconciliation.compare(doses: doses, records: records, items: items, first: day(first), last: day(last),
                                           calendar: calendar)
    }

    private func dose(_ item: String, _ d: Int, _ lot: String, _ n: Int = 1) -> ImmunisationReconciliation.Dose {
        .init(itemID: item, day: day(d), lot: lot, count: n)
    }

    private func record(_ vaccine: String, _ d: Int, _ lot: String) -> ImmunisationRecord {
        ImmunisationRecord(day: day(d), vaccine: vaccine, lot: lot)
    }

    // MARK: - The comparison

    func testTheSameDayAndLotMatches() {
        let result = compare([dose("flu", 24, "ZZ1001", 2)], [record("FLU-EMR", 24, "ZZ1001"), record("flu emr", 24, "zz1001")])
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.matched, 2, "case, spaces and dashes forgiven in the name and the lot")
    }

    func testGivenHereNotInTheEMR() {
        let result = compare([dose("flu", 24, "ZZ1001", 3)], [record("FLU-EMR", 24, "ZZ1001")])
        XCTAssertEqual(result.findings, [.givenNotInEMR(itemID: "flu", day: day(24), lot: "ZZ1001", count: 2)])
        XCTAssertEqual(ImmunisationFindingWording(items: items).sentence(result.findings[0]),
                       "2 doses of the flu vaccine from lot ZZ1001 given here on \(StockScanText.day(day(24))) are not in the EMR on that day.")
    }

    func testInTheEMRNotGivenHere() {
        let result = compare([], [record("TET", 25, "ZZ2001")])
        XCTAssertEqual(result.findings, [.inEMRNotGiven(itemID: "tet", day: day(25), lot: "ZZ2001", count: 1)])
        XCTAssertTrue(ImmunisationFindingWording(items: items).sentence(result.findings[0])
            .hasSuffix("was not recorded as given here, so the stock figure may be high."))
    }

    func testTheSameDayWithADifferentLotIsListedOnItsOwn() {
        let result = compare([dose("tet", 24, "ZZ2001")], [record("TET", 24, "ZZ2009")])
        XCTAssertEqual(result.findings, [.differentLot(itemID: "tet", day: day(24), here: "ZZ2001", emr: "ZZ2009", count: 1)])
    }

    func testARecordOneDayEitherSideIsNearbyNotMissing() {
        let result = compare([dose("flu", 25, "ZZ1001"), dose("flu", 27, "ZZ1001")],
                             [record("FLU-EMR", 26, "ZZ1001"), record("FLU-EMR", 26, "ZZ1001")])
        XCTAssertEqual(result.findings, [
            .nearby(itemID: "flu", here: day(25), emr: day(26), lot: "ZZ1001", count: 1),
            .nearby(itemID: "flu", here: day(27), emr: day(26), lot: "ZZ1001", count: 1),
        ])
        XCTAssertFalse(result.findings.contains { if case .givenNotInEMR = $0 { return true } else { return false } })
        XCTAssertTrue(ImmunisationFindingWording(items: items).sentence(result.findings[0]).hasSuffix("nearby, not missing."))
    }

    // MARK: - The words on the screen

    func testOneDoseAndSeveralEachReadRight() {
        let wording = ImmunisationFindingWording(items: items)
        let on = StockScanText.day(day(24)), next = StockScanText.day(day(25))
        XCTAssertEqual(wording.sentence(.givenNotInEMR(itemID: "flu", day: day(24), lot: "", count: 1)),
                       "1 dose of the flu vaccine with no lot given here on \(on) is not in the EMR on that day.")
        XCTAssertEqual(wording.sentence(.inEMRNotGiven(itemID: "tet", day: day(24), lot: "ZZ2001", count: 3)),
                       "3 doses of the tetanus vaccine from lot ZZ2001 in the EMR on \(on) were not recorded as given here, "
                       + "so the stock figure may be high.")
        XCTAssertEqual(wording.sentence(.differentLot(itemID: "tet", day: day(24), here: "ZZ2001", emr: "", count: 2)),
                       "2 doses of the tetanus vaccine on \(on) were recorded here from lot ZZ2001 and in the EMR from "
                       + "lot (none). One of the two records likely has a typo.")
        XCTAssertEqual(wording.sentence(.nearby(itemID: "gone", here: day(24), emr: day(25), lot: "ZZ9", count: 1)),
                       "1 dose of a line no longer on the list from lot ZZ9 given here on \(on) is in the EMR on \(next): "
                       + "nearby, not missing.")
    }

    func testTheSummaryCountsEachKindOfDifference() {
        let wording = ImmunisationFindingWording(items: items)
        let first = StockScanText.day(day(20)), last = StockScanText.day(day(30)), on = StockScanText.day(day(24))
        let same = compare([dose("flu", 24, "ZZ1001")], [record("FLU-EMR", 24, "ZZ1001")])
        XCTAssertEqual(wording.summary(same), "From \(first) to \(last), every dose given here matches the EMR (1 dose).")
        let oneDay = compare([dose("flu", 24, "ZZ1001", 2)], [], first: 24, last: 24)
        XCTAssertEqual(wording.summary(oneDay), "On \(on): 2 doses given here but not in the EMR that day.")
        let parts = ["2 doses given here but not in the EMR that day", "1 dose in the EMR but not recorded as given here"]
            .formatted(.list(type: .and))
        XCTAssertEqual(wording.summary(compare([dose("flu", 22, "ZZ1001", 2)], [record("TET", 27, "ZZ2001")])),
                       "From \(first) to \(last): \(parts).")
    }

    func testTwoDaysApartIsMissingOnBothSides() {
        let result = compare([dose("flu", 24, "ZZ1001")], [record("FLU-EMR", 26, "ZZ1001")])
        XCTAssertEqual(result.findings, [
            .givenNotInEMR(itemID: "flu", day: day(24), lot: "ZZ1001", count: 1),
            .inEMRNotGiven(itemID: "flu", day: day(26), lot: "ZZ1001", count: 1),
        ])
    }

    func testADoseWithNoLotMatchesThatDaysDoseOfAnyLot() {
        let result = compare([dose("flu", 24, "")], [record("FLU-EMR", 24, "ZZ1001")])
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.matched, 1)
    }

    func testAVaccineTheListHasNoLineForIsCountedForMatching() {
        let result = compare([], [record("Something else", 24, "ZZ9"), record("Something else", 25, "ZZ9")])
        XCTAssertEqual(result.unmatchedVaccines, [.init(vaccine: "Something else", rows: 2)])
        XCTAssertEqual(result.findings, [])
    }

    func testOutsideTheDaysNothingIsCompared() {
        let result = compare([dose("flu", 19, "ZZ1001")], [record("FLU-EMR", 30, "ZZ1001")], first: 20, last: 28)
        XCTAssertEqual(result.findings, [])
    }

    func testTheSummaryKeepsCountsOnly() throws {
        let result = compare([dose("flu", 24, "ZZ1001", 3), dose("tet", 24, "ZZ2001")],
                             [record("FLU-EMR", 24, "ZZ1001"), record("TET", 24, "ZZ2009"), record("TET", 26, "ZZ2001")])
        let summary = result.summary(ranAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual([summary.givenNotInEMR, summary.inEMRNotGiven, summary.differentLot, summary.nearby], [2, 1, 1, 0])
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        for value in ["ZZ1001", "ZZ2001", "flu", "tet", "FLU-EMR"] {
            XCTAssertFalse(json.contains(value), "\(value) in \(json)")
        }
    }

    // MARK: - From the log

    func testTheDosesGivenComeFromTheLogByDayAndLotAndAReversedOneCountsNowhere() {
        var log = VanStockLog()
        let flu = log.addItem(id: "flu", description: "the flu vaccine", batch: "b0")
        log.addLot(id: "A", itemID: flu.id, code: "ZZ1001", expiry: nil, receivedAt: Date(timeIntervalSince1970: 0), batch: "b1")
        let at = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9))!
        log.record(.loaded, itemID: flu.id, quantity: StockQuantity(whole: 10), at: at, batch: "b1", source: .scanned, id: "m0", lotID: "A")
        log.record(.used, itemID: flu.id, quantity: StockQuantity(whole: 2), at: at, batch: "b2", source: .spoken, id: "m1", lotID: "A")
        log.record(.used, itemID: flu.id, quantity: StockQuantity(whole: 1), at: at, batch: "b3", source: .spoken, id: "m2", lotID: "A")
        log.record(.wasted, itemID: flu.id, quantity: StockQuantity(whole: 1), at: at, batch: "b4", source: .spoken, id: "m3",
                   lotID: "A", wasteReason: .broken)
        log.record(.used, itemID: flu.id, quantity: StockQuantity(whole: 5), at: at, batch: "b5", source: .spoken, id: "m4", lotID: "A")
        _ = log.undoLastBatch(at: at, batch: "u", source: .spoken, makeID: { "r" })
        let doses = ImmunisationReconciliation.doses(in: log, first: day(24), last: day(24), calendar: calendar)
        XCTAssertEqual(doses, [.init(itemID: "flu", day: day(24), lot: "ZZ1001", count: 3)], "waste is not a dose given")
    }

    // MARK: - Reading the list

    private let mapping = ImmunisationColumnMapping(date: "Date given", vaccine: "Vaccine", lot: "Batch")

    func testACSVIsReadThroughItsMappedColumns() throws {
        let csv = "Date given,Vaccine,Batch\r\n24/11/2026,FLU-EMR,ZZ1001\r\n\"25/11/2026\",\"TET, adult\",ZZ2001\r\n,,\r\nnot a date,FLU-EMR,ZZ1\r\n"
        let list = try XCTUnwrap(try? ImmunisationListReader.read(Data(csv.utf8), format: .csv, mapping: mapping).get())
        XCTAssertEqual(list.records, [record("FLU-EMR", 24, "ZZ1001"), record("TET, adult", 25, "ZZ2001")])
        XCTAssertEqual(list.skippedRows, 1, "the blank row is not counted; the unreadable date is")
    }

    func testDatesInEachForm() {
        XCTAssertEqual(ImmunisationListReader.day("2026-11-24", order: .dayMonthYear), day(24))
        XCTAssertEqual(ImmunisationListReader.day("2026-11-24T08:30:00", order: .dayMonthYear), day(24))
        XCTAssertEqual(ImmunisationListReader.day("24/11/2026 08:30", order: .dayMonthYear), day(24))
        XCTAssertEqual(ImmunisationListReader.day("11/24/2026", order: .monthDayYear), day(24))
        XCTAssertEqual(ImmunisationListReader.day("24.11.26", order: .dayMonthYear), day(24))
        XCTAssertEqual(ImmunisationListReader.day("46350", order: .dayMonthYear), day(24), "a spreadsheet's date number")
        XCTAssertNil(ImmunisationListReader.day("31/02/2026", order: .dayMonthYear))
        XCTAssertNil(ImmunisationListReader.day("11/24/2026", order: .dayMonthYear))
    }

    func testAMissingColumnIsNamedAsChosen() {
        let csv = "When,Vaccine,Batch\n24/11/2026,FLU-EMR,ZZ1001\n"
        XCTAssertEqual(ImmunisationListReader.read(Data(csv.utf8), format: .csv, mapping: mapping),
                       .failure(.missingColumn("Date given")))
    }

    func testTheMappingRemembersColumnNamesOnly() throws {
        let json = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        XCTAssertEqual(json.contains("Date given"), true)
        XCTAssertTrue(mapping.fits(["batch", "VACCINE", "date-given", "Other"]))
        XCTAssertFalse(mapping.fits(["Vaccine", "Batch"]))
    }

    func testTheLineAliasesMatchOneLineOnly() {
        XCTAssertEqual(ImmunisationLineAliases.line(for: "flu-emr", in: items)?.id, "flu")
        XCTAssertEqual(ImmunisationLineAliases.line(for: "The Tetanus Vaccine", in: items)?.id, "tet", "by its description")
        XCTAssertNil(ImmunisationLineAliases.line(for: "Something else", in: items))
        var shared = items
        shared[1].codes.append("FLU-EMR")
        XCTAssertNil(ImmunisationLineAliases.line(for: "FLU-EMR", in: shared), "two lines carry it: not guessed")
    }

    // MARK: - CSV

    func testCSVQuotesAndSeparators() {
        XCTAssertEqual(try CSVReader.read("a,\"b,c\",\"d \"\"e\"\"\"\n1,2,3").get(), [["a", "b,c", "d \"e\""], ["1", "2", "3"]])
        XCTAssertEqual(try CSVReader.read("a;b;c\n1;2;3").get(), [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertEqual(try CSVReader.read("a\tb\n1\t2").get(), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(try CSVReader.read("\"line\nbreak\",x").get(), [["line\nbreak", "x"]])
        XCTAssertEqual(CSVReader.read("\"open"), .failure(.unterminatedQuote))
        XCTAssertEqual(try CSVReader.read("a,b,c,d\n1,2,3,4", keeping: [3, 1]).get(), [["d", "b"], ["4", "2"]])
    }
}
