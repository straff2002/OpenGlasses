import XCTest
@testable import OpenGlasses

/// Plan NJ §4 — the EMR's billing export read in memory: the date and the tariff, the lot when the
/// export has one, and nothing else; compared with the doses given by day × line; a tariff several
/// lines carry reported as billed under a shared code and never assigned; and nothing kept. Every
/// name and number here is invented.
@MainActor
final class BillingExportReaderTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var medical = true
    // 2026-11-22 10:00 UTC.
    private let clock = Date(timeIntervalSince1970: 1_795_341_600)

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let day22 = StockDay(year: 2026, month: 11, day: 22)!
    private let day23 = StockDay(year: 2026, month: 11, day: 23)!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-check-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock, profileClinical: .some(nil))
        medical = true
        store.update { log in
            _ = log.addItem(id: "flu", number: "8161", description: "Flu vaccine", batch: "b0")
            _ = log.addItem(id: "mmr", number: "8170", description: "MMR vaccine", batch: "b0")
            // One catch-all tariff over two products.
            _ = log.addItem(id: "zos", number: "G538", description: "Shingles vaccine", batch: "b0")
            _ = log.addItem(id: "rsv", number: "G538", description: "RSV vaccine", batch: "b0")
            _ = log.addLot(id: "A", itemID: "flu", code: "ZZ1001", expiry: nil, receivedAt: clock, batch: "b1")
            for id in ["flu", "mmr", "zos", "rsv"] {
                log.record(.loaded, itemID: id, quantity: StockQuantity(whole: 10), at: clock, batch: "b1", source: .scanned,
                           id: "load-\(id)", lotID: id == "flu" ? "A" : nil)
            }
            log.record(.used, itemID: "flu", quantity: StockQuantity(whole: 2), at: clock, batch: "g1", source: .spoken,
                       id: "g1", lotID: "A")
            log.record(.used, itemID: "mmr", quantity: StockQuantity(whole: 1), at: clock, batch: "g2", source: .spoken, id: "g2")
            log.record(.used, itemID: "zos", quantity: StockQuantity(whole: 1), at: clock, batch: "g3", source: .spoken, id: "g3")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private lazy var checker = BillingCheckService(store: store, medicalMode: { [unowned self] in self.medical },
                                                   calendar: calendar)

    private var csv: Data {
        Data("""
            Claim,Patient name,Health card,Service date,Fee code,Amount
            C1,Test Person One,ZZZ0001,2026-11-22,8161,12.00
            C2,Test Person Two,ZZZ0002,2026-11-22,8161,12.00
            C3,Test Person One,ZZZ0001,2026-11-22,G538,20.00
            C4,Test Person Two,ZZZ0002,2026-11-22,9999,5.00
            """.utf8)
    }

    private let mapping = BillingColumnMapping(date: "Service date", tariff: "Fee code", lot: nil)

    // MARK: - Reading

    func testTheRecordHoldsTheDayTheTariffAndTheLotOnly() {
        let record = BillingRecord(day: day22, tariff: "8161", lot: "")
        XCTAssertEqual(Set(Mirror(reflecting: record).children.compactMap(\.label)), ["day", "tariff", "lot"])
    }

    func testTheDateAndTariffAreReadAndTheLotIsOptional() throws {
        let list = try XCTUnwrap(try? BillingExportReader.read(csv, format: .csv, mapping: mapping).get())
        XCTAssertEqual(list.records.map(\.tariff), ["8161", "8161", "G538", "9999"])
        XCTAssertTrue(list.records.allSatisfy { $0.day == day22 && $0.lot.isEmpty })
        let withLot = Data("Date,Tariff,Lot,Name\n22/11/2026,8161,ZZ1001,Test Person One\n".utf8)
        let lotted = try XCTUnwrap(try? BillingExportReader.read(
            withLot, format: .csv, mapping: BillingColumnMapping(date: "Date", tariff: "Tariff", lot: "Lot")).get())
        XCTAssertEqual(lotted.records, [BillingRecord(day: day22, tariff: "8161", lot: "ZZ1001")])
    }

    func testEveryOtherColumnIsDroppedAsTheFileIsRead() throws {
        let list = try XCTUnwrap(try? BillingExportReader.read(csv, format: .csv, mapping: mapping).get())
        let described = String(describing: list)
        for detail in ["Test Person One", "Test Person Two", "ZZZ0001", "ZZZ0002", "C1", "12.00"] {
            XCTAssertFalse(described.contains(detail), detail)
        }
    }

    func testAMissingColumnNamesTheColumnChosen() {
        let wrong = BillingColumnMapping(date: "Service date", tariff: "Billing code", lot: nil)
        XCTAssertEqual(BillingExportReader.read(csv, format: .csv, mapping: wrong), .failure(.missingColumn("Billing code")))
    }

    func testRowsWithNoDateOrTariffAreCountedNotShown() {
        let rows = [["2026-11-22", "8161"], ["not a date", "8161"], ["2026-11-22", ""], ["", ""]]
        let list = BillingExportReader.records(fromKept: rows, hasLot: false, dateOrder: .dayMonthYear)
        XCTAssertEqual(list.records.count, 1)
        XCTAssertEqual(list.skippedRows, 2, "a wholly empty row is not a skipped one")
    }

    // MARK: - Tariff to line

    func testATariffFindsItsLineByNumber() {
        let items = store.log.items
        XCTAssertEqual(TariffLineLookup.match("8161", in: items), .line(items[0]))
        XCTAssertEqual(TariffLineLookup.match("g538", in: items), .shared([items[2], items[3]]))
        XCTAssertEqual(TariffLineLookup.match("9999", in: items), .none)
        XCTAssertEqual(TariffLineLookup.match("  ", in: items), .none)
    }

    // MARK: - The comparison

    func testASharedTariffIsReportedAndNeverAssigned() throws {
        guard case .done(let result, _) = checker.check(csv, format: .csv, mapping: mapping) else { return XCTFail() }
        XCTAssertEqual(result.sharedCodes, [.init(tariff: "G538", itemIDs: ["zos", "rsv"], rows: 1)])
        let findings = result.reconciliation.findings
        XCTAssertFalse(findings.contains { $0.itemID == "zos" || $0.itemID == "rsv" },
                       "neither line under the shared code is matched, missing or billed")
        XCTAssertEqual(result.reconciliation.unmatchedVaccines, [.init(vaccine: "9999", rows: 1)])
    }

    func testDosesAreComparedByDayAndLineWhenTheExportHasNoLot() throws {
        guard case .done(let result, let skipped) = checker.check(csv, format: .csv, mapping: mapping) else { return XCTFail() }
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(result.reconciliation.matched, 2, "two flu doses from lot ZZ1001 match two billed 8161s with no lot")
        XCTAssertEqual(result.reconciliation.findings,
                       [.givenNotInEMR(itemID: "mmr", day: day22, lot: "", count: 1)],
                       "the MMR dose was given and not billed: the likely missed claim")
    }

    func testABillOnTheNextDayIsNearbyNotMissing() {
        let doses = [ImmunisationReconciliation.Dose(itemID: "flu", day: day22, lot: "ZZ1001", count: 1)]
        let records = [BillingRecord(day: day23, tariff: "8161", lot: "")]
        let result = BillingReconciliation.compare(doses: doses, records: records, hasLot: false, items: store.log.items,
                                                   first: day22, last: day23, calendar: calendar)
        XCTAssertEqual(result.reconciliation.findings, [.nearby(itemID: "flu", here: day22, emr: day23, lot: "", count: 1)])
    }

    func testWithALotColumnADifferentLotIsItsOwnFinding() {
        let doses = [ImmunisationReconciliation.Dose(itemID: "flu", day: day22, lot: "ZZ1001", count: 1)]
        let records = [BillingRecord(day: day22, tariff: "8161", lot: "ZZ1009")]
        let result = BillingReconciliation.compare(doses: doses, records: records, hasLot: true, items: store.log.items,
                                                   first: day22, last: day22, calendar: calendar)
        XCTAssertEqual(result.reconciliation.findings,
                       [.differentLot(itemID: "flu", day: day22, here: "ZZ1001", emr: "ZZ1009", count: 1)])
    }

    // MARK: - Gated, and nothing kept

    func testTheCheckIsRefusedOutsideMedicalModeAndReadsNothing() {
        medical = false
        XCTAssertEqual(checker.check(csv, format: .csv, mapping: mapping), .refused(BillingCheckService.medicalModeRefusal))
        guard case .failure(let refusal) = checker.header(csv, format: .csv) else { return XCTFail() }
        XCTAssertEqual(refusal.sentence, BillingCheckService.medicalModeRefusal)
    }

    func testNothingIsStoredAndNoTariffJoinsAMovement() throws {
        let before = store.log
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.lowercased().contains("billing") }
        guard case .done = checker.check(csv, format: .csv, mapping: mapping) else { return XCTFail() }
        XCTAssertEqual(store.log, before, "the check writes nothing to the list")
        let defaultsAfter = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.lowercased().contains("billing") }
        XCTAssertEqual(Set(defaultsBefore), Set(defaultsAfter), "no mapping and no summary are kept")
        let fields = Set(Mirror(reflecting: store.log.movements[0]).children.compactMap(\.label))
        XCTAssertFalse(fields.contains { $0.lowercased().contains("tariff") || $0.lowercased().contains("bill") })
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("van-stock.json"), encoding: .utf8)
            .contains("Test Person"))
    }
}
