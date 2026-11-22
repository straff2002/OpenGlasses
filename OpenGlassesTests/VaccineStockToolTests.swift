import XCTest
@testable import OpenGlasses

/// Plan MY P1 — a clinic's list by voice and by scan: doses given, wasted, received and counted by
/// lot, the which-lot question, the expired refusal, the oldest-first line, and a scanned carton.
/// Invented lines, product numbers and lots only.
@MainActor
final class VaccineStockToolTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    // 2026-11-22 10:00 UTC.
    private var clock = Date(timeIntervalSince1970: 1_795_341_600)
    private var counter = 0
    private var clinical = true
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private let gtin = "02000000000015"
    private let gs = "\u{1D}"

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaccine-stock-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        counter = 0
        clinical = true
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
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
        clinical: { [unowned self] in self.clinical })

    private lazy var tool = VanStockTool(service: service)

    private func run(_ args: [String: Any]) async throws -> String {
        clock = clock.addingTimeInterval(30)   // past the retry window between calls
        return try await tool.execute(args: args)
    }

    private func code(lot: String, expiry: String) -> String { "01\(gtin)17\(expiry)10\(lot)" }

    private var flu: VanStockItem? { store.log.items.first { $0.description == "the flu vaccine" } }
    private func lot(_ code: String) -> StockLot? { store.log.lots.first { $0.code == code } }
    private func held(_ code: String) -> StockQuantity? {
        guard let flu, let lot = lot(code) else { return nil }
        return store.log.level(of: flu.id).lots[lot.id]?.onHand
    }

    /// Two lots of the flu vaccine received by scanning their cartons: ZZ1001 expiring in March,
    /// ZZ1002 in September.
    private func receiveTwoLots() async throws {
        _ = try await run(["action": "receive", "description": "the flu vaccine", "code": code(lot: "ZZ1001", expiry: "270331"),
                           "quantity": 10, "doses_per_carton": 10])
        _ = try await run(["action": "receive", "description": "the flu vaccine", "code": code(lot: "ZZ1002", expiry: "270930"),
                           "quantity": 20])
    }

    // MARK: - Receiving

    func testAScannedDeliveryAddsTheLineTheLotAndItsExpiry() async throws {
        let answer = try await run(["action": "receive", "description": "the flu vaccine",
                                    "code": code(lot: "ZZ1001", expiry: "270331"), "cartons": 2, "doses_per_carton": 10])
        XCTAssertTrue(answer.contains("Received 20 doses of the flu vaccine, lot ZZ1001"), answer)
        XCTAssertEqual(flu?.dosesPerCarton, 10)
        XCTAssertEqual(flu?.codes, [gtin], "the product number, never the whole code")
        XCTAssertEqual(lot("ZZ1001")?.expiry, StockDay(year: 2027, month: 3, day: 31))
        XCTAssertEqual(held("ZZ1001"), StockQuantity(whole: 20))
    }

    func testCartonsNeedADosesPerCarton() async throws {
        _ = try await run(["action": "receive", "description": "the flu vaccine", "quantity": 5])
        let answer = try await run(["action": "receive", "description": "the flu vaccine", "cartons": 2])
        XCTAssertTrue(answer.contains("no carton size"), answer)
        XCTAssertEqual(store.log.level(of: flu!.id).onHand, StockQuantity(whole: 5), "nothing recorded")
    }

    func testASpokenLotNeverCreatesALot() async throws {
        try await receiveTwoLots()
        let lots = store.log.lots.count
        let answer = try await run(["action": "receive", "description": "the flu vaccine", "lot": "ZZ9999", "quantity": 5])
        XCTAssertTrue(answer.contains("ZZ9999 is not one of the lots"), answer)
        XCTAssertEqual(store.log.lots.count, lots)
        let given = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ9999"])
        XCTAssertTrue(given.contains("Nothing was recorded"), given)
        XCTAssertEqual(store.log.lots.count, lots)
        XCTAssertEqual(store.log.level(of: flu!.id).onHand, StockQuantity(whole: 30))
    }

    // MARK: - Given

    func testWithTwoLotsTheAppAsksWhichOldestExpiryFirst() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "give", "description": "the flu vaccine"])
        XCTAssertTrue(answer.contains("2 lots in the fridge, oldest expiry first: 1. lot ZZ1001, expires 31 March 2027, 10 doses; 2. lot ZZ1002"), answer)
        XCTAssertTrue(answer.contains("Nothing was recorded"), answer)
        XCTAssertEqual(store.log.level(of: flu!.id).onHand, StockQuantity(whole: 30))
    }

    func testAGivenDoseNamesItsLotAndIsSaid() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "give", "description": "the flu vaccine", "lot": "zz1001"])
        XCTAssertTrue(answer.contains("Given 1 dose of the flu vaccine, lot ZZ1001"), answer)
        XCTAssertTrue(answer.contains("Say: 1 dose of the flu vaccine given, lot ZZ1001"), answer)
        XCTAssertEqual(held("ZZ1001"), StockQuantity(whole: 9))
        XCTAssertEqual(held("ZZ1002"), StockQuantity(whole: 20))
    }

    func testOneLotInStockIsUsedWithoutAsking() async throws {
        _ = try await run(["action": "receive", "description": "the flu vaccine", "code": code(lot: "ZZ1001", expiry: "270331"),
                           "quantity": 3])
        let answer = try await run(["action": "give", "description": "the flu vaccine", "quantity": 2])
        XCTAssertTrue(answer.contains("Given 2 doses of the flu vaccine, lot ZZ1001"), answer)
        XCTAssertEqual(held("ZZ1001"), StockQuantity(whole: 1))
    }

    func testTheOlderLotIsPointedOutOnceADayPerLine() async throws {
        try await receiveTwoLots()
        let first = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ1002"])
        XCTAssertTrue(first.contains("The flu vaccine also has the older lot ZZ1001 (expires 31 March 2027) in the fridge; use that one first"), first)
        let second = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ1002"])
        XCTAssertFalse(second.contains("older"), second)
        XCTAssertEqual(held("ZZ1002"), StockQuantity(whole: 18), "both recorded")
        clock = clock.addingTimeInterval(86_400)
        let tomorrow = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ1002"])
        XCTAssertTrue(tomorrow.contains("older"), tomorrow)
    }

    func testAnExpiredLotIsNotGivenAndTheOfferRecordsItAsWasted() async throws {
        _ = try await run(["action": "receive", "description": "the flu vaccine", "code": code(lot: "ZZ0900", expiry: "261103"),
                           "quantity": 4])
        let refused = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ0900"])
        XCTAssertTrue(refused.contains("Lot ZZ0900 of the flu vaccine expired on 3 November 2026"), refused)
        XCTAssertTrue(refused.contains("It has not been recorded as given"), refused)
        XCTAssertTrue(refused.contains("'waste_reason' 'expired'"), refused)
        XCTAssertFalse(store.log.movements.contains { $0.kind == .used })
        XCTAssertEqual(held("ZZ0900"), StockQuantity(whole: 4))

        let wasted = try await run(["action": "waste", "description": "the flu vaccine", "lot": "ZZ0900",
                                    "waste_reason": "expired", "quantity": 4])
        XCTAssertTrue(wasted.contains("Wasted 4 doses of the flu vaccine, lot ZZ0900"), wasted)
        XCTAssertTrue(wasted.contains("expired"), wasted)
        let movement = store.log.movements.last { $0.kind == .wasted }
        XCTAssertEqual(movement?.wasteReason, .expired)
        XCTAssertEqual(movement?.lotID, lot("ZZ0900")?.id)
        XCTAssertEqual(held("ZZ0900"), .zero)
    }

    func testAScannedLotNotOnTheLineIsNotGiven() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "give", "code": code(lot: "ZZ2000", expiry: "280131")])
        XCTAssertTrue(answer.contains("not on the stock list yet"), answer)
        XCTAssertNil(lot("ZZ2000"))
        XCTAssertFalse(store.log.movements.contains { $0.kind == .used })
    }

    func testAMisreadCartonIsRefused() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "give", "code": "0102000000000016" + "10ZZ1001"])
        XCTAssertTrue(answer.contains("could not be read safely"), answer)
        XCTAssertFalse(store.log.movements.contains { $0.kind == .used })
    }

    // MARK: - Waste and count

    func testWasteIsKeptApartFromGivenWithItsReason() async throws {
        try await receiveTwoLots()
        _ = try await run(["action": "waste", "description": "the flu vaccine", "lot": "ZZ1001", "waste_reason": "drawn_up_not_given"])
        _ = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ1001"])
        XCTAssertEqual(store.log.movements.filter { $0.kind == .wasted }.map(\.wasteReason), [.drawnUpNotGiven])
        XCTAssertEqual(store.log.movements.filter { $0.kind == .used }.count, 1)
        XCTAssertFalse(store.log.movements.contains { $0.kind == .removed })
        XCTAssertEqual(held("ZZ1001"), StockQuantity(whole: 8))
    }

    func testACountOfALotSaysShortAndMovesTheTotal() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "count", "description": "the flu vaccine", "lot": "ZZ1002", "quantity": 18])
        XCTAssertTrue(answer.contains("Counted 18 doses of the flu vaccine in lot ZZ1002"), answer)
        XCTAssertTrue(answer.contains("so it is 2 doses short"), answer)
        XCTAssertEqual(store.log.level(of: flu!.id).onHand, StockQuantity(whole: 28))
        let unnamed = try await run(["action": "count", "description": "the flu vaccine", "quantity": 5])
        XCTAssertTrue(unnamed.contains("Ask the person which lot"), unnamed)
    }

    func testAScannedCountMayAddALot() async throws {
        try await receiveTwoLots()
        let answer = try await run(["action": "count", "description": "the flu vaccine",
                                    "code": code(lot: "ZZ3000", expiry: "280229"), "quantity": 6])
        XCTAssertTrue(answer.contains("Lot ZZ3000 is new on the stock list"), answer)
        XCTAssertEqual(held("ZZ3000"), StockQuantity(whole: 6))
        XCTAssertEqual(store.log.level(of: flu!.id).onHand, StockQuantity(whole: 36))
    }

    func testUndoTakesBackADoseGivenAndItsLotFigure() async throws {
        try await receiveTwoLots()
        _ = try await run(["action": "give", "description": "the flu vaccine", "lot": "ZZ1001"])
        let answer = try await run(["action": "undo"])
        XCTAssertTrue(answer.contains("the dose given of"), answer)
        XCTAssertEqual(held("ZZ1001"), StockQuantity(whole: 10))
    }

    // MARK: - Funded and private stock (Decision 6)

    func testTwoLinesSharingAProductNumberAreAskedAboutUnlessTheLotSays() async throws {
        try await receiveTwoLots()
        // A second line of the same vaccine (funded stock), with its own lot, sharing the code.
        let funded = store.update { log -> VanStockItem in
            let item = log.addItem(id: "funded", description: "the flu vaccine funded", codes: [gtin], batch: "f")
            let lot = log.addLot(id: "lot-f", itemID: item.id, code: "ZZ5000", expiry: StockDay(year: 2027, month: 5, day: 31),
                                 receivedAt: clock, batch: "f")
            log.record(.loaded, itemID: item.id, quantity: StockQuantity(whole: 5), at: clock, batch: "f",
                       source: .typed, lotID: lot?.id)
            return item
        }!
        let byLot = try await run(["action": "give", "code": code(lot: "ZZ5000", expiry: "270531")])
        XCTAssertTrue(byLot.contains("Given 1 dose of the flu vaccine funded, lot ZZ5000"), byLot)
        XCTAssertEqual(store.log.level(of: funded.id).onHand, StockQuantity(whole: 4))

        let plain = try await run(["action": "give", "code": "2000000000015"])
        XCTAssertTrue(plain.contains("More than one line"), plain)
        XCTAssertTrue(plain.contains("They share that code"), plain)
    }

    // MARK: - The scan sheet

    func testTheScanSheetResolvesALineALotAndANewLot() throws {
        let gs1 = code(lot: "ZZ1001", expiry: "270331")
        let scan = try StockScan.read(gs1, referenceYear: 2026).get()
        XCTAssertEqual(StockScanFlow.resolve(scan, in: store.log), .newProduct)
        let today = StockDay(clock, calendar: calendar)
        XCTAssertEqual(StockScanFlow.allowed(.newProduct, expiry: scan.expiry, today: today), [.received, .counted],
                       "a new product comes in only on Received or Count")

        let first = service.recordScan(.received, scan: scan, itemID: nil,
                                       newLine: .init(name: "the flu vaccine", dosesPerCarton: 10),
                                       quantity: StockQuantity(whole: 10))
        XCTAssertTrue(first.recorded, first.answer)
        guard case .known(let item, let lot?, nil) = StockScanFlow.resolve(scan, in: store.log) else {
            return XCTFail("\(StockScanFlow.resolve(scan, in: store.log))")
        }
        XCTAssertEqual(item.dosesPerCarton, 10)
        XCTAssertEqual(lot.code, "ZZ1001")
        XCTAssertEqual(StockScanFlow.allowed(.known(item: item, lot: lot, newLot: nil), expiry: lot.expiry, today: today).first,
                       .given, "Given is the default")

        let other = try StockScan.read(code(lot: "ZZ1002", expiry: "270930"), referenceYear: 2026).get()
        let resolved = StockScanFlow.resolve(other, in: store.log)
        XCTAssertEqual(resolved, .known(item: item, lot: nil, newLot: "ZZ1002"))
        XCTAssertFalse(StockScanFlow.allowed(resolved, expiry: other.expiry, today: today).contains(.given),
                       "a new lot is never added on Given")
        let given = service.recordScan(.given, scan: other, itemID: item.id, quantity: StockQuantity(whole: 1))
        XCTAssertFalse(given.recorded, given.answer)
        XCTAssertEqual(store.log.lots.count, 1)

        let dose = service.recordScan(.given, scan: scan, itemID: item.id, quantity: StockQuantity(whole: 1))
        XCTAssertTrue(dose.recorded, dose.answer)
        let again = service.recordScan(.given, scan: scan, itemID: item.id, quantity: StockQuantity(whole: 1))
        XCTAssertTrue(again.recorded, "a tap the person confirmed is never taken for a retry")
        XCTAssertEqual(store.log.level(of: item.id).onHand, StockQuantity(whole: 8))
    }

    func testAnExpiredScanOffersWastedNotGiven() throws {
        let scan = try StockScan.read(code(lot: "ZZ0900", expiry: "261103"), referenceYear: 2026).get()
        let today = StockDay(clock, calendar: calendar)
        var log = VanStockLog()
        let item = log.addItem(id: "flu", description: "the flu vaccine", codes: [gtin], batch: "b")
        let lot = log.addLot(id: "l", itemID: item.id, code: "ZZ0900", expiry: scan.expiry, receivedAt: clock, batch: "b")
        let allowed = StockScanFlow.allowed(.known(item: item, lot: lot, newLot: nil), expiry: scan.expiry, today: today)
        XCTAssertEqual(allowed.first, .wasted(.expired))
        XCTAssertFalse(allowed.contains(.given))
        XCTAssertEqual(StockScanFlow.defaultAction(allowed), .wasted(.expired))
    }

    func testTheSameCodeWithinTenSecondsAsksAnotherOne() {
        var guardrail = StockScanRepeatGuard()
        let start = clock
        XCTAssertFalse(guardrail.asksAgain("A", at: start), "nothing recorded yet")
        guardrail.recorded("A", at: start)
        XCTAssertTrue(guardrail.asksAgain("A", at: start.addingTimeInterval(9.9)))
        XCTAssertFalse(guardrail.asksAgain("A", at: start.addingTimeInterval(10)))
        XCTAssertFalse(guardrail.asksAgain("B", at: start.addingTimeInterval(1)), "another carton's code")
        XCTAssertEqual(VaccineStockPolicy.repeatScanWindow, 10)
    }

    func testTheOldestFirstReminderIsOncePerLinePerDay() {
        var reminder = OldestFirstReminder()
        let today = StockDay(year: 2026, month: 11, day: 22)!
        XCTAssertTrue(reminder.shouldSay(itemID: "a", today: today))
        XCTAssertFalse(reminder.shouldSay(itemID: "a", today: today))
        XCTAssertTrue(reminder.shouldSay(itemID: "b", today: today))
        XCTAssertTrue(reminder.shouldSay(itemID: "a", today: StockDay(year: 2026, month: 11, day: 23)!))
    }

    // MARK: - A list that is not a clinic's

    func testAVanListIsUntouchedByLots() async throws {
        clinical = false
        _ = try await run(["action": "load", "description": "45/5 capacitor", "quantity": 4])
        let answer = try await run(["action": "use", "description": "45/5 capacitor"])
        XCTAssertTrue(answer.contains("1 × 45/5 capacitor"), answer)
        XCTAssertFalse(answer.contains("lot"), answer)
        XCTAssertTrue(store.log.lots.isEmpty)
        XCTAssertTrue(store.log.movements.allSatisfy { $0.lotID == nil })
    }
}
