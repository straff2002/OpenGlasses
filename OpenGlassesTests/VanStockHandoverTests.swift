import XCTest
@testable import OpenGlasses

/// Plan IH P5 — the end of a shift and the start of the next.
@MainActor
final class VanStockHandoverTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-09-21 14:13 UTC.
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func time(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }

    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var store: VanStockStore!
    private var unrecorded: [TaskPart] = []
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-handover-tests-\(UUID().uuidString)", isDirectory: true)
        clock = start
        store = VanStockStore(directory: directory, now: clock)
        unrecorded = []
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
        verify: { TaskPart(number: VaultPartsIndex.normalise($0), verified: false) },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { nil },
        now: { [unowned self] in self.clock },
        calendar: calendar,
        jobUses: .init(record: { _ in }, remove: { _ in }, notFromVan: { _ in false },
                       unrecorded: { [unowned self] in self.unrecorded }))

    /// A van at the end of a shift: one line short, one at standard, one with no standard, one run out.
    private var van: VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "sensor", number: "00123", description: "Flame sensor", standard: 6, standardSetBy: .base, batch: "b0")
        log.addItem(id: "igniter", number: "22B22", description: "Igniter", standard: 2, standardSetBy: .van, batch: "b0")
        log.addItem(id: "motor", description: "Inducer motor", batch: "b0")
        log.addItem(id: "fuse", description: "Fuse", minimum: 5, batch: "b0")
        log.record(.counted, itemID: "sensor", quantity: 2, at: time(0), batch: "b0", source: .handover)
        log.record(.counted, itemID: "igniter", quantity: 2, at: time(0), batch: "b0", source: .handover)
        log.record(.counted, itemID: "fuse", quantity: 3, at: time(0), batch: "b0", source: .handover)
        return log
    }

    // MARK: Top-up

    func testTheTopUpIsStandardMinusOnHandAndNeverNegative() {
        var log = van
        log.record(.loaded, itemID: "igniter", quantity: 5, at: time(1), batch: "b1", source: .spoken)
        XCTAssertEqual(VanStockHandover.topUp(log).map(\.item.id), ["sensor"])
        XCTAssertEqual(VanStockHandover.topUp(log).first?.short, 4)
    }

    func testWithNoStandardAnywhereTheListIsWhatHasRunOut() {
        var log = VanStockLog()
        log.addItem(id: "fuse", description: "Fuse", minimum: 5, batch: "b0")
        log.addItem(id: "nuts", description: "Wire nuts", batch: "b0")
        log.record(.counted, itemID: "fuse", quantity: 3, at: time(0), batch: "b0", source: .typed)
        log.record(.counted, itemID: "nuts", quantity: 40, at: time(0), batch: "b0", source: .typed)
        XCTAssertFalse(VanStockHandover.hasStandards(log))
        XCTAssertEqual(VanStockHandover.topUp(log).map(\.item.id), ["fuse"])
        XCTAssertNil(VanStockHandover.topUp(log).first?.short, "with nothing to measure against there is no figure to fill to")
    }

    // MARK: The day's extras

    func testALineLoadedThisShiftAboveItsStandardIsAnExtra() {
        var log = van
        log.record(.loaded, itemID: "motor", quantity: 1, at: time(5), batch: "b1", source: .spoken)
        log.record(.loaded, itemID: "igniter", quantity: 3, at: time(5), batch: "b1", source: .spoken)
        log.record(.loaded, itemID: "sensor", quantity: 4, at: time(5), batch: "b1", source: .spoken)
        log.record(.used, itemID: "igniter", quantity: 2, at: time(60), batch: "b2", source: .spoken)
        let shiftStart = VanStockHandover.shiftStart(log, now: time(400), calendar: calendar)
        XCTAssertEqual(shiftStart, time(0), "the shift began at the takeover")
        let extras = VanStockHandover.surplus(log, since: shiftStart)
        XCTAssertEqual(extras.map(\.item.id), ["igniter", "motor"])
        XCTAssertEqual(extras.map(\.extra), [1, 1], "the igniters: loaded three, used two, one beyond the standard two")
    }

    func testOneLoadedAndUsedIsNotAnExtraAndStockFromAnEarlierShiftIsNotAskedAboutAgain() {
        var log = van
        log.record(.loaded, itemID: "motor", quantity: 1, at: time(-600), batch: "b-1", source: .spoken)
        log.record(.loaded, itemID: "igniter", quantity: 1, at: time(5), batch: "b1", source: .spoken)
        log.record(.used, itemID: "igniter", quantity: 1, at: time(60), batch: "b2", source: .spoken)
        XCTAssertEqual(VanStockHandover.surplus(log, since: time(0)), [])
    }

    func testWithNoTakeoverTheShiftBeganThisMorning() {
        var log = VanStockLog()
        log.addItem(id: "fuse", description: "Fuse", batch: "b0")
        log.record(.loaded, itemID: "fuse", quantity: 3, at: time(0), batch: "b0", source: .spoken)
        XCTAssertEqual(VanStockHandover.shiftStart(log, now: time(30), calendar: calendar),
                       calendar.startOfDay(for: time(30)))
    }

    // MARK: The message

    func testTheMessageSaysWhatToTopUpWhatIsComingWhatNeedsCountingAndWhatCameBack() {
        var log = van
        log.record(.ordered, itemID: "sensor", quantity: 1, at: time(10), batch: "b1", source: .spoken)
        log.record(.used, itemID: "motor", quantity: 1, at: time(20), batch: "b2", source: .spoken)
        log.record(.loaded, itemID: "igniter", quantity: 2, at: time(30), batch: "b3", source: .spoken)
        log.record(.removed, itemID: "igniter", quantity: 2, at: time(300), batch: "b4", source: .spoken, reason: .returned)
        let message = VanStockHandover.message(log, van: VanIdentity(id: "v4", name: "Truck 4"), now: time(400), calendar: calendar)
        XCTAssertEqual(message, """
        Truck 4 stock, 2026-09-21 20:53.
        To top up (1):
          4 × Flame sensor (00123) — 2 on board
        Asked for, not yet loaded:
          1 × Flame sensor (00123)
        Needs counting:
          Inducer motor
        Returned this shift:
          2 × Igniter (22B22)
        The full list is in the attached spreadsheet.
        """)
    }

    func testAVanWithNoStandardLoadSaysSo() {
        var log = VanStockLog()
        log.addItem(id: "fuse", description: "Fuse", batch: "b0")
        log.record(.counted, itemID: "fuse", quantity: 0, at: time(0), batch: "b0", source: .typed)
        let message = VanStockHandover.message(log, van: nil, now: time(1), calendar: calendar)
        XCTAssertTrue(message.hasPrefix("Van stock, "), message)
        XCTAssertTrue(message.contains("No standard load is set for this van"), message)
        XCTAssertTrue(message.contains("  Fuse — 0 on board"), message)
    }

    // MARK: Taking a van over

    private func handover(of log: VanStockLog, van: VanIdentity?, at date: Date) throws -> [XLSXReader.Sheet] {
        try XLSXReader.read(VanStockSheet.data(log, van: van, exportedAt: date, calendar: calendar)).get()
    }

    func testATakeoverIsTheWholeTruthAboutTheVan() throws {
        var left = van
        log(&left)
        let sheets = try handover(of: left, van: VanIdentity(id: "v4", name: "Truck 4"), at: time(400))
        let takeover = try VanStockHandover.takeover(from: sheets, at: time(900), batch: "takeover").get()

        XCTAssertEqual(takeover.van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertEqual(takeover.exportedAt, time(400))
        XCTAssertEqual(takeover.lineCount, 4)
        XCTAssertEqual(takeover.needCounting, 1)
        XCTAssertEqual(takeover.refusals, [])
        XCTAssertEqual(Set(takeover.log.items.map(\.id)), ["sensor", "igniter", "motor", "fuse"], "the lines keep their identity")

        let levels = takeover.log.levels
        XCTAssertEqual(levels["sensor"]?.onHand, 2)
        XCTAssertEqual(levels["sensor"]?.handedOver, true)
        XCTAssertEqual(levels["sensor"]?.onOrder, 1, "what was on order comes across")
        XCTAssertNil(takeover.log.movements.first { $0.kind == .ordered }?.requestID, "with no request attached")
        XCTAssertEqual(levels["motor"]?.unreliable, true, "a line that needed counting still does")
        XCTAssertEqual(takeover.log.item(id: "sensor")?.standardSetBy, .base)
        XCTAssertEqual(takeover.log.item(id: "igniter")?.standardSetBy, .van)
        XCTAssertEqual(takeover.log.item(id: "fuse")?.minimum, 5)
        XCTAssertEqual(takeover.shortfalls, 1)
    }

    /// The state the van is left in for the takeover test: an order open and one line unreliable.
    private func log(_ log: inout VanStockLog) {
        log.record(.ordered, itemID: "sensor", quantity: 1, at: time(10), batch: "b1", source: .spoken)
        log.record(.used, itemID: "motor", quantity: 1, at: time(20), batch: "b2", source: .spoken)
    }

    func testTakingOverReplacesThePhonesListAndKeepsTheOldOneOnce() throws {
        // This phone had Truck 2 on it.
        store.nameVan("Truck 2")
        _ = service.load([.init(description: "Contactor", quantity: 3)])
        let truck2 = store.log
        XCTAssertFalse(store.hasPrevious)

        let sheets = try handover(of: van, van: VanIdentity(id: "v4", name: "Truck 4"), at: time(400))
        clock = time(900)
        service.takeOver(try service.takeover(from: sheets).get())

        XCTAssertEqual(store.van?.name, "Truck 4")
        XCTAssertNil(store.log.items.first { $0.description == "Contactor" }, "two vehicles are never merged")
        XCTAssertEqual(store.log.level(of: "sensor").onHand, 2)
        XCTAssertTrue(store.hasPrevious)
        let check = service.check(.init(part: "00123"))
        XCTAssertTrue(check.contains("as handed over today at 05:13"), check)

        // And it survives a relaunch.
        let reopened = VanStockStore(directory: directory, now: clock)
        XCTAssertEqual(reopened.van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertEqual(reopened.log.level(of: "sensor").onHand, 2)

        XCTAssertTrue(store.restorePrevious())
        XCTAssertEqual(store.van?.name, "Truck 2")
        XCTAssertEqual(store.log.items, truck2.items)
        XCTAssertFalse(store.hasPrevious)
    }

    func testAVanKeepsItsIdentifierWhenItIsRenamed() {
        store.nameVan("Truck 4", makeID: { "v4" })
        store.nameVan("  Truck 4 (spare)  ")
        XCTAssertEqual(store.van, VanIdentity(id: "v4", name: "Truck 4 (spare)"))
        store.nameVan("   ")
        XCTAssertEqual(store.van?.name, "Truck 4 (spare)")
        XCTAssertEqual(VanStockStore(directory: directory, now: clock).van?.id, "v4")
    }

    // MARK: Base's baseline

    private let baselineSheet = [XLSXReader.Sheet(name: "Standard load", isHidden: false, rows: [
        ["Part number", "Description", "Standard"],
        ["00123", "Flame sensor", "8"],
        ["22B22", "Igniter", "1"],
        ["77-100", "Contactor", "2"],
        ["", "Wire nuts", ""],
    ])]

    func testABaselineTouchesStandardsAndNeverALevel() throws {
        let changes = try VanStockHandover.baseline(from: baselineSheet, log: van).get()
        XCTAssertEqual(changes.map(\.kind), [.set, .keptOwn(current: 2), .newLine])
        XCTAssertEqual(changes.map(\.standard), [8, 1, 2])

        var applied = van
        VanStockHandover.apply(changes, to: &applied, at: time(10), batch: "baseline")
        XCTAssertEqual(applied.item(id: "sensor")?.standard, 8)
        XCTAssertEqual(applied.item(id: "sensor")?.standardSetBy, .base)
        XCTAssertEqual(applied.item(id: "igniter")?.standard, 2, "what this truck set itself is kept by default")
        XCTAssertEqual(applied.item(id: "igniter")?.standardSetBy, .van)
        let contactor = try XCTUnwrap(applied.items.first { $0.number == "77-100" })
        XCTAssertEqual(contactor.standard, 2)
        XCTAssertFalse(applied.level(of: contactor.id).isRecorded, "a new line is at nothing recorded, not zero")
        XCTAssertEqual(applied.item(id: "fuse"), van.item(id: "fuse"), "a line the baseline does not name is left alone")
        for id in ["sensor", "igniter", "motor", "fuse"] {
            XCTAssertEqual(applied.level(of: id), van.level(of: id), id)
        }

        // One undo takes the whole baseline back, new line included.
        applied.undoLastBatch(at: time(11), batch: "undo", source: .typed)
        XCTAssertEqual(applied.items, van.items)
    }

    func testTheTechnicianMayTakeBasesFigureAndASecondBaselineLeavesTheTrucksAdditionsAlone() throws {
        let changes = try VanStockHandover.baseline(from: baselineSheet, log: van).get()
        var applied = van
        VanStockHandover.apply(changes, to: &applied, takingBaseFigure: ["igniter"], at: time(10), batch: "baseline")
        XCTAssertEqual(applied.item(id: "igniter")?.standard, 1)
        XCTAssertEqual(applied.item(id: "igniter")?.standardSetBy, .base)

        // The truck grows a line of its own, then base reissues the same baseline.
        applied.edit(itemID: "motor", .standard(1, setBy: .van), at: time(20), batch: "b9", source: .spoken)
        let again = try VanStockHandover.baseline(from: baselineSheet, log: applied).get()
        XCTAssertEqual(again, [], "nothing it names has changed, and what it does not name is not its business")
        XCTAssertEqual(applied.item(id: "motor")?.standard, 1)
    }

    func testAnExportOfAVansOwnStockIsNotABaselineAndQuantitiesAreOnlyReadAsStandardsInAForeignSheet() throws {
        // Our own workbook: it has a Standard column, so its quantities are never read as standards,
        // and a figure the truck already has is no change whoever set it.
        let own = try handover(of: van, van: nil, at: time(400))
        XCTAssertEqual(try VanStockHandover.baseline(from: own, log: van).get(), [])

        // A sheet from somebody else with only quantities: those are the standard load.
        let quantitiesOnly = [XLSXReader.Sheet(name: "Truck load", isHidden: false, rows: [
            ["Part", "Description", "Qty"], ["00123", "Flame sensor", "9"],
        ])]
        XCTAssertEqual(try VanStockHandover.baseline(from: quantitiesOnly, log: van).get().map(\.standard), [9])
    }

    // MARK: By voice

    func testToppingUpEverythingExceptWhatCouldNotBeFilled() {
        service.takeOver(.init(van: nil, log: van, exportedAt: nil, lineCount: 4, shortfalls: 1, needCounting: 0, refusals: []))
        _ = service.setStandard(.init(description: "fuse", quantity: 10))
        clock = time(5)
        XCTAssertTrue(service.topUp().hasPrefix("2 to top up: "), service.topUp())

        let answer = service.loadToStandard(except: [.init(description: "flame sensor"), .init(description: "thermostat")])
        XCTAssertTrue(answer.hasPrefix("1 line brought to the standard load."), answer)
        XCTAssertTrue(answer.contains("Left as they were: Flame sensor (00123)."), answer)
        XCTAssertTrue(answer.contains("Not on the van list, so not treated as an exception: thermostat."), answer)
        XCTAssertEqual(store.log.level(of: "fuse").onHand, 10)
        XCTAssertEqual(store.log.level(of: "sensor").onHand, 2, "a line nobody filled stays short")

        clock = time(6)
        _ = service.undo()
        XCTAssertEqual(store.log.level(of: "fuse").onHand, 3, "one undo takes the whole top-up back")
    }

    func testAStandardSetByVoiceIsThisTrucksOwnAndZeroClearsIt() {
        service.takeOver(.init(van: nil, log: van, exportedAt: nil, lineCount: 4, shortfalls: 1, needCounting: 0, refusals: []))
        // Plan KR P7: the change ends with what the reply must say.
        XCTAssertEqual(service.setStandard(.init(description: "inducer motor", quantity: 1)),
                       "The standard load for this truck is now 1 × Inducer motor.\n"
                       + "Say: the standard load set to 1 × Inducer motor. Put this in the reply, whatever else the technician asked this turn.")
        XCTAssertEqual(store.log.item(id: "motor")?.standardSetBy, .van)
        clock = time(1)
        XCTAssertEqual(service.setStandard(.init(description: "inducer motor", quantity: 0)),
                       "Inducer motor has no standard load now.\nSay: no standard load for Inducer motor now. Put this in the reply, whatever else the technician asked this turn.")
        XCTAssertNil(store.log.item(id: "motor")?.standard)
        XCTAssertTrue(service.setStandard(.init(description: "inducer motor")).contains("Say how many"))
    }

    func testSendingToBaseAsksFirstThenStagesAndSendsNothing() async throws {
        service.takeOver(.init(van: VanIdentity(id: "v4", name: "Truck 4"), log: van, exportedAt: nil,
                               lineCount: 4, shortfalls: 1, needCounting: 0, refusals: []))
        clock = time(5)
        _ = service.load([.init(description: "inducer motor", quantity: 1)])
        unrecorded = [TaskPart(number: "14T65", partDescription: "Pressure switch", verified: true)]
        let handover = VanStockHandoverService(service: service)
        let tool = VanStockTool(service: service, handover: handover)

        clock = time(400)
        let asked = try await tool.execute(args: ["action": "send_to_base"])
        XCTAssertTrue(asked.contains("Pressure switch (14T65)"), asked)
        XCTAssertTrue(asked.contains("1 × Inducer motor"), asked)
        XCTAssertTrue(asked.contains("'answered' true"), asked)
        XCTAssertNil(handover.staged, "nothing is staged until the questions are answered")

        let staged = try await tool.execute(args: ["action": "send_to_base", "answered": true])
        XCTAssertTrue(staged.hasPrefix("Staged on the phone for the technician to look at and send. Nothing has been sent."), staged)
        let waiting = try XCTUnwrap(handover.staged)
        XCTAssertTrue(waiting.message.hasPrefix("Truck 4 stock, "), waiting.message)
        XCTAssertEqual(waiting.fileURL.lastPathComponent, "Van stock 2026-09-21.xlsx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.fileURL.path))

        // What was staged is a workbook the next phone can take over.
        let read = try XLSXReader.read(Data(contentsOf: waiting.fileURL)).get()
        XCTAssertEqual(try VanStockHandover.takeover(from: read, at: clock, batch: "t").get().van?.name, "Truck 4")

        handover.discard()
        XCTAssertNil(handover.staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: waiting.fileURL.path), "the temporary workbook goes with it")
    }

    func testWithNothingToAskTheHandoverIsStagedAtOnce() async throws {
        service.takeOver(.init(van: nil, log: van, exportedAt: nil, lineCount: 4, shortfalls: 1, needCounting: 0, refusals: []))
        let handover = VanStockHandoverService(service: service)
        defer { handover.discard() }
        let answer = try await VanStockTool(service: service, handover: handover).execute(args: ["action": "send_to_base"])
        XCTAssertTrue(answer.hasPrefix("Staged on the phone"), answer)
        XCTAssertNotNil(handover.staged)
    }

    // MARK: The review offers the right way to apply a workbook

    func testAWorkbookFromAnotherVanIsOfferedAsATakeoverAndOneOfOurOwnAsCorrections() throws {
        let imports = VanStockImportService(store: store, service: service, isAllowed: { nil })
        let truck4 = VanStockSheet.data(van, van: VanIdentity(id: "v4", name: "Truck 4"), exportedAt: time(400), calendar: calendar)

        // An empty phone: taking the van over is what it is for.
        imports.handle(data: truck4, fileName: "Van stock.xlsx")
        guard case .reviewing = imports.stage else { return XCTFail("\(imports.stage)") }
        XCTAssertEqual(imports.suggestedMode, .takeover)
        XCTAssertNotNil(imports.takeover)
        clock = time(900)
        XCTAssertTrue(imports.applyTakeover())
        XCTAssertEqual(imports.stage, .idle)
        XCTAssertEqual(store.van?.id, "v4")

        // The same van's own workbook, later: corrections, and not stale.
        clock = time(1_000)
        let own = try XCTUnwrap(service.exportFile())
        defer { try? FileManager.default.removeItem(at: own.deletingLastPathComponent()) }
        clock = time(1_010)
        _ = service.use([.init(description: "igniter", quantity: 1)])
        imports.handle(data: try Data(contentsOf: own), fileName: own.lastPathComponent)
        XCTAssertEqual(imports.suggestedMode, .corrections)
        XCTAssertTrue(imports.takeoverIsStale, "the phone has a later entry for this van than the workbook does")
        imports.dismiss()
        XCTAssertNil(imports.takeover)
    }

    func testAWorkbookWithStandardsIsOfferedAsBasesBaseline() {
        service.takeOver(.init(van: nil, log: van, exportedAt: nil, lineCount: 4, shortfalls: 1, needCounting: 0, refusals: []))
        let imports = VanStockImportService(store: store, service: service, isAllowed: { nil })
        let cells = baselineSheet[0].rows.map { $0.map { XLSX.Cell.text($0) } }
        let data = XLSXWriter.data(for: XLSX.Workbook(sheets: [XLSX.Sheet(name: "Standard load", columns: [], rows: cells)]),
                                   modified: clock)
        imports.handle(data: data, fileName: "baseline.xlsx")
        XCTAssertNil(imports.takeover, "a baseline does not say which van it is, so it cannot be taken over")
        XCTAssertEqual(imports.baseline?.count, 3)
        clock = time(10)
        XCTAssertTrue(imports.applyBaseline())
        XCTAssertEqual(store.log.item(id: "sensor")?.standard, 8)
        XCTAssertEqual(store.log.level(of: "sensor").onHand, 2, "no level moved")
    }
}
