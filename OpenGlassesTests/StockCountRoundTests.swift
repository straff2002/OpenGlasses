import XCTest
@testable import OpenGlasses

/// Plan MY P2 — the weekly count lot by lot, oldest expiry first; an empty lot counted at zero
/// stays listed until hidden; the count is one entry that one undo takes back; and the weekly
/// reminder, off until chosen and content-free. Invented lines and lots only.
@MainActor
final class StockCountRoundTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_795_341_600)
    private var counter = 0

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stock-count-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        counter = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
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

    private func q(_ whole: Int) -> StockQuantity { StockQuantity(whole: whole) }

    /// The flu vaccine with lots received out of expiry order (September first, then March), and a
    /// line with no lots.
    private func seed() {
        store.update { log in
            let flu = log.addItem(id: "flu", description: "the flu vaccine", batch: "b0")
            log.addItem(id: "swabs", description: "Swabs", batch: "b0")
            log.addLot(id: "late", itemID: flu.id, code: "ZZ1002", expiry: StockDay(year: 2027, month: 9, day: 30),
                       receivedAt: clock, batch: "b1")
            log.addLot(id: "early", itemID: flu.id, code: "ZZ1001", expiry: StockDay(year: 2027, month: 3, day: 31),
                       receivedAt: clock, batch: "b1")
            log.record(.loaded, itemID: flu.id, quantity: q(10), at: clock, batch: "b1", source: .scanned, id: "m1", lotID: "late")
            log.record(.loaded, itemID: flu.id, quantity: q(4), at: clock, batch: "b1", source: .scanned, id: "m2", lotID: "early")
            log.record(.loaded, itemID: "swabs", quantity: q(50), at: clock, batch: "b1", source: .typed, id: "m3")
        }
        clock = clock.addingTimeInterval(60)
    }

    func testTheRoundGoesLotByLotOldestExpiryFirst() {
        seed()
        let round = service.countRound()
        XCTAssertEqual(round.map(\.id), ["lot-early", "lot-late", "line-swabs"])
        XCTAssertEqual(round.map(\.expected), [q(4), q(10), q(50)])
        XCTAssertTrue(round.allSatisfy(\.isKnown))
    }

    func testACountIsOneEntryWithAChecksPerLot() {
        seed()
        let results = service.recordCounts([("lot-early", q(3)), ("lot-late", q(10)), ("line-swabs", q(52))])
        XCTAssertEqual(results?.map(\.check), [.short(expected: q(4), by: q(1)), .matches(expected: q(10)),
                                              .over(expected: q(50), by: q(2))])
        let level = store.log.level(of: "flu")
        XCTAssertEqual(level.lots["early"]?.onHand, q(3))
        XCTAssertEqual(level.onHand, q(13))
        XCTAssertEqual(Set(store.log.movements.filter { $0.kind == .counted }.map(\.batch)).count, 1, "one batch")

        _ = service.undo(source: .typed)
        XCTAssertEqual(store.log.level(of: "flu").lots["early"]?.onHand, q(4), "one undo takes the whole count back")
        XCTAssertEqual(store.log.level(of: "swabs").onHand, q(50))
    }

    func testAFigureTheLineCannotHoldRecordsNothing() {
        seed()
        let before = store.log
        XCTAssertNil(service.recordCounts([("lot-early", q(3)), ("lot-late", StockQuantity(scaled: 2_500))]))
        XCTAssertNil(service.recordCounts([("lot-nothing", q(3))]))
        XCTAssertEqual(store.log, before)
    }

    func testAnEmptyLotCountedAtZeroStaysListedUntilHidden() {
        seed()
        _ = service.recordCounts([("lot-early", .zero)])
        XCTAssertTrue(service.countRound().contains { $0.id == "lot-early" && $0.expected == .zero && $0.mayHide })

        XCTAssertFalse(service.hideLot("late"), "a lot with stock in it is not hidden")
        XCTAssertTrue(service.hideLot("early"))
        XCTAssertEqual(service.countRound().map(\.id), ["lot-late", "line-swabs"])

        // Something in it again brings it back.
        store.update { log in
            log.record(.loaded, itemID: "flu", quantity: q(2), at: clock, batch: "b9", source: .scanned, id: "m9", lotID: "early")
        }
        XCTAssertEqual(service.countRound().map(\.id), ["lot-early", "lot-late", "line-swabs"])
    }

    func testAHiddenLotIsWrittenOnlyWhenHidden() throws {
        let lot = StockLot(id: "l", itemID: "i", code: "ZZ1001", expiry: nil, firstReceived: clock, createdBatch: "b")
        let encoder = JSONEncoder()
        XCTAssertFalse(String(decoding: try encoder.encode(lot), as: UTF8.self).contains("hidden"))
        var hidden = lot
        hidden.hidden = true
        XCTAssertTrue(String(decoding: try encoder.encode(hidden), as: UTF8.self).contains("\"hidden\":true"))
    }

    // MARK: - The spoken report

    func testTheReportActionSaysOneSentenceAndSendsNothing() async throws {
        seed()
        store.update { log in
            log.record(.used, itemID: "flu", quantity: q(2), at: clock, batch: "b5", source: .spoken, id: "m5", lotID: "early")
        }
        let tool = VanStockTool(service: service)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let previous = EntitlementTestScope.grant()
        defer {
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
            EntitlementTestScope.restore(previous)
        }
        let answer = try await tool.execute(args: ["action": "report", "period": "today"])
        XCTAssertTrue(answer.hasPrefix("On 22 November 2026: 2 doses given, 0 wasted, 64 received;"), answer)
        XCTAssertTrue(answer.contains("nothing is sent from here"), answer)
    }

    // MARK: - The reminder

    func testTheReminderIsOffUntilChosen() {
        XCTAssertNil(StockCountReminderPolicy.wanted(StockCountReminderSettings()))
        let defaults = UserDefaults(suiteName: "stock-count-reminder-\(UUID().uuidString)")!
        XCTAssertFalse(StockCountReminderSettings.stored(defaults).enabled)
    }

    func testTheReminderFiresWeeklyOnTheChosenDayAndTime() {
        let request = StockCountReminderPolicy.wanted(StockCountReminderSettings(enabled: true, weekday: 6, minute: 16 * 60 + 30))
        XCTAssertEqual(request?.identifier, "stock.weekly-count")
        XCTAssertEqual(request?.fireAt.weekday, 6)
        XCTAssertEqual(request?.fireAt.hour, 16)
        XCTAssertEqual(request?.fireAt.minute, 30)
        XCTAssertNil(request?.fireAt.day, "weekly, never one date")
        XCTAssertEqual(StockCountReminderPolicy.describe(StockCountReminderSettings(enabled: true, weekday: 6, minute: 990)),
                       "Fridays at 16:30")
    }

    func testTheReminderNamesNothingOnTheList() {
        XCTAssertEqual(StockCountReminderPolicy.body, "The weekly stock count is due.")
        XCTAssertEqual(StockCountReminderPolicy.title, "Stock")
    }

    func testTheSchedulerKeepsOneRequestInStepWithTheChoice() async {
        let center = FakeReminderCenter()
        let defaults = UserDefaults(suiteName: "stock-count-reminder-\(UUID().uuidString)")!
        let scheduler = StockCountReminderScheduler(center: center, defaults: defaults)

        let on = await scheduler.apply(StockCountReminderSettings(enabled: true, weekday: 2, minute: 540))
        XCTAssertTrue(on)
        XCTAssertEqual(center.pending.map(\.identifier), ["stock.weekly-count"])
        XCTAssertEqual(center.pending.first?.fireAt.weekday, 2)

        await scheduler.apply(StockCountReminderSettings(enabled: true, weekday: 4, minute: 540))
        XCTAssertEqual(center.pending.map(\.fireAt.weekday), [4], "a changed day replaces the old one")

        await scheduler.apply(StockCountReminderSettings(enabled: false, weekday: 4, minute: 540))
        XCTAssertTrue(center.pending.isEmpty)

        center.allowed = false
        let refused = await scheduler.apply(StockCountReminderSettings(enabled: true, weekday: 4, minute: 540))
        XCTAssertFalse(refused)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(scheduler.settings.enabled, "the choice is kept")
    }
}

@MainActor
private final class FakeReminderCenter: StockCountReminderCentering {
    var pending: [StockCountReminderRequest] = []
    var allowed = true

    func pendingIdentifiers() async -> [String] { pending.map(\.identifier) }
    func add(_ request: StockCountReminderRequest) async { pending.append(request) }
    func remove(_ identifiers: [String]) { pending.removeAll { identifiers.contains($0.identifier) } }
    func mayNotify(askIfNeeded: Bool) async -> Bool { allowed }
}
