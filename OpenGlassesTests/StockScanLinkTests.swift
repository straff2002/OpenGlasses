import XCTest
@testable import OpenGlasses

/// Plan MY §5 — link on first scan: a line imported from a clinic's list has its tariff and short
/// forms but no product number, so its carton's first scan matches nothing. The person says which
/// line it is; recording the scan keeps the code on that line, one Undo takes both back, and the
/// next scan finds the line. Invented lines, tariffs, product numbers and lots only.
@MainActor
final class StockScanLinkTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    // 2026-11-22 10:00 UTC.
    private var clock = Date(timeIntervalSince1970: 1_795_341_600)
    private var counter = 0
    private var previousEntitlement: FieldAssistEntitlementProvider!

    /// Made-up GTIN-14s with good check digits, in the restricted-circulation range.
    private let gtin = "02000000000022"
    private let otherGTIN = "02000000000039"

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stock-scan-link-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        counter = 0
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        // Two lines as the clinic's list brings them in: a tariff as the number, short forms and
        // brands as codes, and no product number.
        _ = store.update { log in
            _ = log.addItem(id: "flu", number: "9001", description: "Examplevax quadrivalent",
                        codes: ["EXQ", "Examplevax"], batch: "import")
            _ = log.addItem(id: "mmr", number: "9002", description: "Samplemune triple", codes: ["SMT"], batch: "import")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private lazy var service = VanStockService(
        store: store,
        place: { .stock },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { nil },
        now: { [unowned self] in self.clock },
        calendar: calendar,
        makeID: { [unowned self] in
            self.counter += 1
            return "id-\(self.counter)"
        },
        clinical: { true })

    private func carton(_ gtin: String, lot: String = "ZZ2001", expiry: String = "280331") throws -> StockScan {
        try StockScan.read("01\(gtin)17\(expiry)10\(lot)", referenceYear: 2026).get()
    }

    // MARK: - The sheet's choice

    func testACodeNoLineCarriesOffersTheListsLines() throws {
        let scan = try carton(gtin)
        let resolved = StockScanFlow.resolve(scan, in: store.log)
        XCTAssertEqual(resolved, .newProduct, "the barcode carries no name, so nothing is matched by itself")
        XCTAssertTrue(StockScanFlow.offersLink(resolved, in: store.log))
        XCTAssertFalse(StockScanFlow.offersLink(resolved, in: VanStockLog()), "an empty list has nothing to choose")
        let flu = try XCTUnwrap(store.log.item(id: "flu"))
        XCTAssertFalse(StockScanFlow.offersLink(.known(item: flu, lot: nil, newLot: nil), in: store.log))
    }

    func testAChosenLineReadsTheLotAsAScanOfItWould() throws {
        let scan = try carton(gtin)
        let flu = try XCTUnwrap(store.log.item(id: "flu"))
        XCTAssertEqual(StockScanFlow.chosen(scan, itemID: "flu", in: store.log),
                       .known(item: flu, lot: nil, newLot: "ZZ2001"))
        let today = StockDay(clock, calendar: calendar)
        XCTAssertEqual(StockScanFlow.allowed(.known(item: flu, lot: nil, newLot: "ZZ2001"), expiry: scan.expiry, today: today),
                       [.received, .counted], "a new lot still comes in only on Received or Count")
        XCTAssertNil(StockScanFlow.chosen(scan, itemID: "gone", in: store.log))
    }

    // MARK: - Recording links the code

    func testRecordingOnTheChosenLineKeepsTheCodeAndTheNextScanFindsIt() throws {
        let scan = try carton(gtin)
        let result = service.recordScan(.received, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 10))
        XCTAssertTrue(result.recorded, result.answer)
        let flu = try XCTUnwrap(store.log.item(id: "flu"))
        XCTAssertEqual(flu.codes, ["EXQ", "Examplevax", gtin], "kept as the GTIN-14 the lookup matches")
        XCTAssertEqual(store.log.level(of: "flu").onHand, StockQuantity(whole: 10), "the movement is on that line")
        XCTAssertNil(store.log.item(id: "mmr")?.codes.first { $0 == gtin })
        XCTAssertEqual(store.log.items.count, 2, "no separate new line")

        guard case .known(let item, let lot?, nil) = StockScanFlow.resolve(scan, in: store.log) else {
            return XCTFail("\(StockScanFlow.resolve(scan, in: store.log))")
        }
        XCTAssertEqual(item.id, "flu")
        XCTAssertEqual(lot.code, "ZZ2001")

        // A plain 13-digit barcode on the same box, and a later carton of another lot, both find it.
        let plain = try StockScan.read("2000000000022", referenceYear: 2026).get()
        XCTAssertEqual(StockScanFlow.resolve(plain, in: store.log), .known(item: item, lot: nil, newLot: nil))
        let later = try carton(gtin, lot: "ZZ2002")
        XCTAssertEqual(StockScanFlow.resolve(later, in: store.log), .known(item: item, lot: nil, newLot: "ZZ2002"))
    }

    func testOneUndoTakesTheMovementAndTheCodeBack() throws {
        let scan = try carton(gtin)
        XCTAssertTrue(service.recordScan(.received, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 10)).recorded)
        _ = service.undo(source: .typed)
        XCTAssertEqual(store.log.item(id: "flu")?.codes, ["EXQ", "Examplevax"])
        XCTAssertEqual(store.log.level(of: "flu").onHand, .zero)
        XCTAssertEqual(StockScanFlow.resolve(scan, in: store.log), .newProduct, "after the undo the carton is unknown again")
    }

    func testTheCodeIsKeptOnceHoweverOftenTheCartonIsScanned() throws {
        let scan = try carton(gtin)
        XCTAssertTrue(service.recordScan(.received, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 10)).recorded)
        clock = clock.addingTimeInterval(60)
        XCTAssertTrue(service.recordScan(.given, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 1)).recorded)
        XCTAssertEqual(store.log.item(id: "flu")?.codes.filter { $0 == gtin }.count, 1)
        XCTAssertEqual(store.log.level(of: "flu").onHand, StockQuantity(whole: 9))
    }

    func testACodeAlreadyOnAnotherLineIsRefusedAndNothingChanges() throws {
        let scan = try carton(gtin)
        XCTAssertTrue(service.recordScan(.received, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 10)).recorded)
        let before = store.log
        XCTAssertEqual(StockScanFlow.linkConflict(scan, itemID: "mmr", in: store.log)?.id, "flu")
        XCTAssertNil(StockScanFlow.chosen(scan, itemID: "mmr", in: store.log))
        clock = clock.addingTimeInterval(60)
        let refused = service.recordScan(.counted, scan: scan, itemID: "mmr", quantity: StockQuantity(whole: 3))
        XCTAssertFalse(refused.recorded)
        XCTAssertTrue(refused.answer.contains("already on Examplevax quadrivalent"), refused.answer)
        XCTAssertEqual(store.log, before, "nothing recorded, no code moved")
    }

    func testLinesSharingAProductNumberAreNotAConflict() throws {
        _ = store.update { log in
            _ = log.edit(itemID: "flu", .addCode(otherGTIN), at: clock, batch: "b", source: .typed, id: "e1")
            _ = log.edit(itemID: "mmr", .addCode(otherGTIN), at: clock, batch: "b", source: .typed, id: "e2")
        }
        let scan = try carton(otherGTIN)
        XCTAssertNil(StockScanFlow.linkConflict(scan, itemID: "mmr", in: store.log),
                     "funded and private stock of one vaccine share a product number")
        XCTAssertNil(StockScanFlow.linkConflict(scan, itemID: "flu", in: store.log))
    }

    func testARefusedLinkKeepsNoCode() throws {
        // Given is never how a new lot comes in, so the write is refused, and the code with it.
        let scan = try carton(gtin)
        let refused = service.recordScan(.given, scan: scan, itemID: "flu", quantity: StockQuantity(whole: 1))
        XCTAssertFalse(refused.recorded, refused.answer)
        XCTAssertEqual(store.log.item(id: "flu")?.codes, ["EXQ", "Examplevax"])
    }
}
