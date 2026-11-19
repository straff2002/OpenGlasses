import XCTest
@testable import OpenGlasses

/// Plan IH P1 — the `van_stock` tool: said, recorded, read back, and undone, with no job and no
/// network.
@MainActor
final class VanStockToolTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var job: VanStockService.Job?
    private var verified: Set<String> = []
    private var counter = 0
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-tool-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        job = nil
        verified = []
        counter = 0
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func makeService() -> VanStockService {
        VanStockService(
            store: store,
            verify: { [unowned self] number in
                let cleaned = VaultPartsIndex.normalise(number)
                return TaskPart(number: cleaned, partDescription: self.verified.contains(cleaned) ? "From the book" : nil,
                                verified: self.verified.contains(cleaned))
            },
            partsIndex: { VaultPartsIndex(files: []) },
            activeJob: { [unowned self] in self.job },
            now: { [unowned self] in self.clock },
            calendar: calendar,
            makeID: { [unowned self] in
                self.counter += 1
                return "id-\(self.counter)"
            })
    }

    private lazy var service = makeService()
    private lazy var tool = VanStockTool(service: service)

    private func run(_ args: [String: Any]) async throws -> String {
        try await tool.execute(args: args)
    }

    /// One entry of `items`, typed so a mixed literal needs no annotation at each use.
    private func entry(_ fields: [String: Any]) -> [String: Any] { fields }

    private func onHand(_ description: String) -> StockQuantity? {
        store.log.items.first { $0.description == description }.map { store.log.level(of: $0.id).onHand }
    }

    // MARK: Gates

    func testFieldAssistOffIsRefused() async throws {
        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        let answer = try await run(["action": "load", "description": "Igniter", "quantity": 2])
        XCTAssertTrue(answer.contains("Field Assist is disabled"), answer)
        XCTAssertTrue(store.log.isEmpty)
    }

    func testNoJobOpenIsFine() async throws {
        XCTAssertNil(job)
        let answer = try await run(["action": "load", "description": "Igniter", "quantity": 2])
        XCTAssertTrue(answer.hasPrefix("Loaded 2 × Igniter."), answer)
        XCTAssertEqual(onHand("Igniter"), .whole(2))
        XCTAssertNil(store.log.movements.last?.jobSessionID)
    }

    func testAnEmptyVanSaysSoAndGivesNoFigure() async throws {
        let check = try await run(["action": "check", "description": "igniter"])
        XCTAssertTrue(check.contains("The van list is empty"), check)
        let low = try await run(["action": "low"])
        XCTAssertTrue(low.contains("The van list is empty"), low)
    }

    func testAnUnknownActionChangesNothing() async throws {
        let answer = try await run(["action": "order", "description": "Igniter"])
        XCTAssertTrue(answer.contains("Pass 'action'"), answer)
        XCTAssertTrue(store.log.isEmpty)
    }

    // MARK: Load

    func testALoadOfSeveralLinesIsOneBatchAndIsReadBack() async throws {
        verified = ["62-23543-01"]
        let answer = try await run(["action": "load", "items": [
            entry(["part": "62-23543-01", "description": "flame sensor", "quantity": 4]),
            entry(["description": "45/5 capacitor", "quantity": 6]),
        ]])
        let lines = answer.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "two lines read back, then what the reply says (Plan KR P7)")
        XCTAssertTrue(lines[2].hasPrefix("Say: 4 × flame sensor (62-23543-01) put on the van; 6 × 45/5 capacitor put on the van."), lines[2])
        XCTAssertTrue(lines[0].hasPrefix("Loaded 4 × flame sensor (62-23543-01). 4 × flame sensor (62-23543-01) on the van now."), lines[0])
        XCTAssertTrue(lines[0].contains("new line"), lines[0])
        XCTAssertFalse(lines[0].contains("dash"), "a verified number is not spelled out")
        XCTAssertTrue(lines[1].hasPrefix("Loaded 6 × 45/5 capacitor."), lines[1])
        XCTAssertEqual(Set(store.log.movements.map(\.batch)).count, 1)
        XCTAssertEqual(store.log.items.first?.verified, true)
    }

    func testANumberNothingKnowsIsSpelledOutAndCanBeUndone() async throws {
        let answer = try await run(["action": "load", "part": "14T56", "quantity": 1])
        XCTAssertTrue(answer.contains("one four T five six"), answer)
        XCTAssertTrue(answer.contains("undo that"), answer)
        XCTAssertEqual(store.log.items.count, 1)

        let undone = try await run(["action": "undo"])
        XCTAssertTrue(undone.hasPrefix("Undone: the load of 1 × 14T56."), undone)
        XCTAssertTrue(undone.contains("Taken off the van list again: 14T56."), undone)
        XCTAssertTrue(store.log.items.isEmpty)

        let again = try await run(["action": "undo"])
        XCTAssertTrue(again.contains("nothing to undo"), again)
    }

    func testAVaultDescriptionNamesALineNobodyDescribed() async throws {
        verified = ["22B22"]
        _ = try await run(["action": "load", "part": "22B22", "quantity": 1])
        XCTAssertEqual(store.log.items.first?.description, "From the book")
    }

    func testWordsWhereANumberGoesAreADescription() async throws {
        _ = try await run(["action": "load", "part": "flame sensor", "quantity": 2])
        XCTAssertNil(store.log.items.first?.number)
        XCTAssertEqual(store.log.items.first?.description, "flame sensor")
    }

    func testASecondLoadGoesOnTheSameLine() async throws {
        _ = try await run(["action": "load", "description": "45/5 capacitor", "quantity": 6])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "load", "description": "45/5 capacitors", "quantity": 2])
        XCTAssertEqual(store.log.items.count, 1)
        XCTAssertEqual(onHand("45/5 capacitor"), .whole(8))
        XCTAssertFalse(answer.contains("new line"), answer)
    }

    func testAVaguerDescriptionJoinsTheLineItFitsUnlessItIsSaidToBeNew() async throws {
        _ = try await run(["action": "load", "description": "Capacitor, dual run, 45/5", "quantity": 2])
        clock.addTimeInterval(60)
        let joined = try await run(["action": "load", "description": "capacitor", "quantity": 1])
        XCTAssertTrue(joined.hasPrefix("Loaded 1 × Capacitor, dual run, 45/5."), "the read-back names the line it went on")
        XCTAssertEqual(store.log.items.count, 1)

        clock.addTimeInterval(60)
        let separate = try await run(["action": "load", "description": "Capacitor, run, 5", "quantity": 3, "new_line": true])
        XCTAssertTrue(separate.contains("new line"), separate)
        XCTAssertEqual(store.log.items.count, 2)
        XCTAssertEqual(onHand("Capacitor, dual run, 45/5"), .whole(3))
        XCTAssertEqual(onHand("Capacitor, run, 5"), .whole(3))
    }

    func testARepeatedIdenticalWriteInsideTheWindowIsOneWrite() async throws {
        let args: [String: Any] = ["action": "load", "description": "Igniter", "quantity": 4]
        _ = try await run(args)
        clock.addTimeInterval(3)
        let retry = try await run(args)
        XCTAssertTrue(retry.hasPrefix("Already recorded a moment ago"), retry)
        XCTAssertEqual(onHand("Igniter"), .whole(4))

        clock.addTimeInterval(VanStockService.duplicateWindow + 1)
        _ = try await run(args)
        XCTAssertEqual(onHand("Igniter"), .whole(8), "said again later, it is a second load")
    }

    func testAUnitIsKeptAndAMismatchChangesNothing() async throws {
        _ = try await run(["action": "load", "description": "Thermostat cable", "quantity": 30, "unit": "m"])
        XCTAssertEqual(store.log.items.first?.unit, .m)
        clock.addTimeInterval(60)
        let mismatch = try await run(["action": "load", "description": "thermostat cable", "quantity": 5, "unit": "ft"])
        XCTAssertTrue(mismatch.contains("is counted in metres, not feet"), mismatch)
        XCTAssertEqual(onHand("Thermostat cable"), .whole(30))
        let unknown = try await run(["action": "load", "description": "Solder", "quantity": 1, "unit": "reel"])
        XCTAssertTrue(unknown.contains("is not a unit the van list keeps"), unknown)
        XCTAssertEqual(store.log.items.count, 1)
    }

    func testAZeroLoadIsRefused() async throws {
        let answer = try await run(["action": "load", "description": "Igniter", "quantity": 0])
        XCTAssertTrue(answer.contains("at least 1"), answer)
        XCTAssertTrue(store.log.isEmpty)
    }

    // MARK: Use and remove

    func testAUseIsTaggedToTheOpenJobAndSaysWhatIsLeft() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 2])
        clock.addTimeInterval(60)
        job = .init(sessionID: "session-1", reference: "job-2031")
        let answer = try await run(["action": "use", "description": "igniter"])
        XCTAssertEqual(answer, "Used 1 × Igniter on job job-2031. 1 left.\n"
                       + "Say: 1 × Igniter taken off the van for job job-2031. Put this in the reply, whatever else the technician asked this turn.")
        XCTAssertEqual(store.log.movements.last?.jobSessionID, "session-1")
        XCTAssertEqual(store.log.movements.last?.kind, .used)
    }

    func testTheLastOneOffersARequestAndOrdersNothing() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 1])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "use", "description": "igniter"])
        XCTAssertTrue(answer.contains("That was the last on the van."), answer)
        XCTAssertTrue(answer.contains("request one only if the technician says yes"), answer)
        XCTAssertFalse(store.log.movements.contains { $0.kind == .ordered })
        XCTAssertEqual(store.log.level(of: store.log.items[0].id).onOrder, .whole(0))
    }

    func testAUseThatMatchesNothingChangesNothing() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 1])
        clock.addTimeInterval(60)
        let before = store.log
        let answer = try await run(["action": "use", "part": "14T56"])
        XCTAssertEqual(answer, "Nothing on the van list matches 14T56. Nothing was changed.")
        XCTAssertEqual(store.log, before, "a misheard number never becomes a line")
    }

    func testSeveralCandidatesAreAskedAboutNotChosen() async throws {
        _ = try await run(["action": "load", "items": [
            entry(["description": "Capacitor, dual run, 45/5", "quantity": 2]),
            entry(["description": "Capacitor, run, 5", "quantity": 3, "new_line": true]),
        ]])
        clock.addTimeInterval(60)
        let before = store.log
        let answer = try await run(["action": "use", "description": "capacitor"])
        XCTAssertTrue(answer.contains("More than one line on the van fits"), answer)
        XCTAssertEqual(store.log, before)
    }

    func testARemovalCarriesItsReason() async throws {
        _ = try await run(["action": "load", "description": "Inducer motor", "quantity": 1])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "remove", "description": "inducer motor", "reason": "returned"])
        XCTAssertTrue(answer.hasPrefix("Removed 1 × Inducer motor (returned)."), answer)
        XCTAssertEqual(store.log.movements.last?.reason, .returned)
        XCTAssertFalse(answer.contains("Offer"), answer)
    }

    // MARK: Count and check

    func testACountSetsTheFigureAndACheckSaysHowItIsKnown() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 9])
        clock.addTimeInterval(60)
        let counted = try await run(["action": "count", "description": "igniter", "quantity": 5])
        XCTAssertEqual(counted, "Counted: 5 × Igniter on the van. The log expected 9, so that is 4 short."
            + "\nSay: Igniter counted: 5 on the van, 4 short of the 9 expected. Put this in the reply, whatever else the technician asked this turn.")
        clock.addTimeInterval(3_600)
        let check = try await run(["action": "check", "description": "igniter"])
        XCTAssertTrue(check.hasPrefix("5 × Igniter on the van — counted today at"), check)
    }

    /// A shop keeping its shelf by voice: an opening figure, a delivery, then a stocktake checked
    /// against what the log expected.
    func testAStocktakeSaysHowFarItIsFromTheLog() async throws {
        let opening = try await run(["action": "count", "part": "1042", "quantity": 18])
        XCTAssertTrue(opening.hasPrefix("Counted: 18 × 1042 on the van. That is a new line"), opening)
        XCTAssertFalse(opening.contains("expected"), opening)
        clock.addTimeInterval(60)
        let delivery = try await run(["action": "load", "part": "1042", "quantity": 6])
        XCTAssertTrue(delivery.hasPrefix("Loaded 6 × 1042. 24 × 1042 on the van now."), delivery)
        clock.addTimeInterval(3_600)
        let short = try await run(["action": "count", "part": 1042, "quantity": 22])
        XCTAssertTrue(short.hasPrefix("Counted: 22 × 1042 on the van. The log expected 24, so that is 2 short."), short)
        XCTAssertTrue(short.contains("Say: 1042 counted: 22 on the van, 2 short of the 24 expected."), short)
        clock.addTimeInterval(3_600)
        let same = try await run(["action": "count", "part": "1042", "quantity": 22])
        XCTAssertTrue(same.contains("That matches the 22 the log expected."), same)
        XCTAssertTrue(same.contains("on the van, as expected."), same)
    }

    func testACountNeedsAFigure() async throws {
        let answer = try await run(["action": "count", "description": "Igniter"])
        XCTAssertTrue(answer.contains("Say how many"), answer)
        XCTAssertTrue(store.log.isEmpty)
    }

    func testACheckThatMatchesNothingSaysSo() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 1])
        let answer = try await run(["action": "check", "description": "thermostat"])
        XCTAssertTrue(answer.hasPrefix("Nothing on the van list matches thermostat, by part number or by name"), answer)
        XCTAssertTrue(answer.contains("do not look it up again"), answer)
        XCTAssertTrue(answer.hasSuffix("Nothing was changed."), answer)
    }

    // MARK: A tester's build-728 report — a brand heard as the word it sounds like

    /// Invented brand and number: a pack of couplings loaded as a test line.
    private func loadCouplings() async throws {
        _ = try await run(["action": "load", "part": "71234", "description": "Kwartz Coupling 6 x 250 mm",
                           "quantity": 22, "unit": "pack"])
        clock.addTimeInterval(60)
    }

    func testANumberHeardInPiecesStillFindsTheLine() async throws {
        try await loadCouplings()
        let answer = try await run(["action": "check", "description": "kwartz coupling 6 x 2 50"])
        XCTAssertTrue(answer.hasPrefix("22 packs of Kwartz Coupling 6 x 250 mm (71234) on the van — "), answer)
    }

    func testACheckThatOnlySoundsLikeALineGivesItsFigureToBeAsked() async throws {
        try await loadCouplings()
        let before = store.log
        let answer = try await run(["action": "check", "description": "quartz coupling 6 x 2 50"])
        XCTAssertTrue(answer.hasPrefix("No line on the van list matches 'quartz coupling 6 x 2 50' word for word. "
            + "The closest on the van: 22 packs of Kwartz Coupling 6 x 250 mm (71234) on the van — "), answer)
        XCTAssertTrue(answer.contains("It may have been misheard: ask the technician whether that is the part; "
            + "if it is, give them this figure."), answer)
        XCTAssertFalse(answer.contains("do not look it up again"), answer)
        XCTAssertFalse(answer.contains("there is none on the van."), answer)
        XCTAssertEqual(store.log, before)
    }

    func testAUseOrRemovalThatOnlySoundsLikeALineChangesNothingAndAsks() async throws {
        try await loadCouplings()
        let before = store.log
        let used = try await run(["action": "use", "description": "quartz coupling 6 x 250", "quantity": 2])
        XCTAssertTrue(used.contains("Did they mean Kwartz Coupling 6 x 250 mm (71234) — 22 on the van?"), used)
        XCTAssertTrue(used.hasSuffix("Nothing was changed."), used)
        XCTAssertFalse(used.contains("new_line"), "a use never starts a line")
        XCTAssertFalse(used.contains(VanStockService.sayPrefix), used)
        clock.addTimeInterval(60)
        let removed = try await run(["action": "remove", "description": "quartz coupling 6 x 250", "reason": "returned"])
        XCTAssertTrue(removed.contains("Did they mean"), removed)
        clock.addTimeInterval(60)
        let standard = try await run(["action": "set_standard", "description": "quartz coupling 6 x 250", "quantity": 30])
        XCTAssertTrue(standard.contains("Did they mean"), standard)
        clock.addTimeInterval(60)
        let topUp = try await run(["action": "load", "to_standard": true,
                                   "items": [entry(["description": "quartz coupling 6 x 250"])]])
        XCTAssertTrue(topUp.contains("Did they mean"), topUp)
        XCTAssertEqual(store.log, before)
    }

    func testALoadOrCountThatOnlySoundsLikeALineAsksBeforeStartingAnother() async throws {
        try await loadCouplings()
        let before = store.log
        let loaded = try await run(["action": "load", "description": "quartz coupling 6 x 250", "quantity": 4, "unit": "pack"])
        XCTAssertTrue(loaded.contains("Did they mean Kwartz Coupling 6 x 250 mm (71234) — 22 on the van?"), loaded)
        XCTAssertTrue(loaded.contains("record it again with 'new_line' true"), loaded)
        XCTAssertTrue(loaded.hasSuffix("Nothing was changed."), loaded)
        clock.addTimeInterval(60)
        let counted = try await run(["action": "count", "description": "quartz coupling 6 x 250", "quantity": 20])
        XCTAssertTrue(counted.contains("Did they mean"), counted)
        XCTAssertEqual(store.log, before, "no near-duplicate line beside the one it sounds like")

        clock.addTimeInterval(60)
        let separate = try await run(["action": "load", "description": "quartz coupling 6 x 250", "quantity": 4,
                                      "unit": "pack", "new_line": true])
        XCTAssertTrue(separate.contains("new line"), separate)
        XCTAssertEqual(store.log.items.count, 2)
        XCTAssertEqual(onHand("quartz coupling 6 x 250"), .whole(4))
        XCTAssertEqual(onHand("Kwartz Coupling 6 x 250 mm"), .whole(22))
    }

    func testWhatMatchesNothingAtAllIsStillNoneOnTheVan() async throws {
        try await loadCouplings()
        let check = try await run(["action": "check", "description": "thermostat cable 30 m"])
        XCTAssertTrue(check.hasPrefix("Nothing on the van list matches thermostat cable 30 m, by part number or by name"), check)
        XCTAssertTrue(check.contains("do not look it up again"), check)
        let used = try await run(["action": "use", "description": "kwartz coupling 8 x 250"])
        XCTAssertEqual(used, "Nothing on the van list matches kwartz coupling 8 x 250. Nothing was changed.",
                       "a different number is a different part, not a near miss")
    }

    func testLowListsWhatHasRunOut() async throws {
        _ = try await run(["action": "load", "items": [entry(["description": "Igniter", "quantity": 1]),
                                                       entry(["description": "Fuse", "quantity": 5])]])
        clock.addTimeInterval(60)
        _ = try await run(["action": "use", "description": "igniter"])
        let low = try await run(["action": "low"])
        XCTAssertEqual(low, "1 line is low: Igniter — none left.")
    }

    // MARK: Scanned codes

    func testAnUnknownCodeAsksWhatItIsThenIsRemembered() async throws {
        let unknown = try await run(["action": "load", "code": "0123456789012", "quantity": 2])
        XCTAssertTrue(unknown.contains("That code is not on the van list yet"), unknown)
        XCTAssertTrue(store.log.isEmpty)

        clock.addTimeInterval(60)
        _ = try await run(["action": "load", "code": "0123456789012", "description": "Flame sensor", "quantity": 2])
        XCTAssertEqual(store.log.items.first?.codes, ["0123456789012"])
        XCTAssertEqual(store.log.movements.last?.source, .scanned)

        clock.addTimeInterval(60)
        let second = try await run(["action": "load", "code": "0123456789012", "quantity": 1])
        XCTAssertTrue(second.hasPrefix("Loaded 1 × Flame sensor. 3 × Flame sensor on the van now."), second)
    }

    // MARK: Orders from a parts request

    func testAStockReplacementShowsAsAskedForUntilItIsLoaded() async throws {
        _ = try await run(["action": "load", "part": "62-23543-01", "description": "Flame sensor", "quantity": 1])
        clock.addTimeInterval(60)
        _ = try await run(["action": "use", "part": "62-23543-01"])
        let noted = service.noteOrdered(number: "62-23543-01", quantity: 1, requestID: "r1")
        XCTAssertEqual(noted, "The van list now shows 1 asked for and not yet loaded.")
        XCTAssertEqual(store.log.movements.last?.requestID, "r1")

        clock.addTimeInterval(86_400)
        let check = try await run(["action": "check", "part": "62-23543-01"])
        XCTAssertTrue(check.contains("1 asked for yesterday"), check)

        let loaded = try await run(["action": "load", "part": "62-23543-01", "quantity": 1])
        XCTAssertTrue(loaded.contains("That covers the 1 asked for yesterday"), loaded)
    }

    func testAnOrderNeverCreatesALine() {
        XCTAssertNil(service.noteOrdered(number: "62-23543-01", quantity: 1, requestID: "r1"))
        XCTAssertTrue(store.log.isEmpty)
    }

    // MARK: An unreadable file

    func testAnUnreadableListIsSaidAndNothingIsGuessed() async throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("van-stock.json"))
        store = VanStockStore(directory: directory, now: clock)
        let answer = try await run(["action": "check", "description": "igniter"])
        XCTAssertTrue(answer.contains("could not be read"), answer)
        let write = try await run(["action": "load", "description": "Igniter", "quantity": 1])
        XCTAssertTrue(write.contains("could not be read"), write)
    }

    // MARK: Argument shapes

    func testQuantitiesAndNumbersArriveInWhateverShapeTheModelSent() {
        let lines = VanStockTool.lines(["items": [entry(["part": 4455, "quantity": "3"]), entry(["description": " ", "quantity": 2])]])
        XCTAssertEqual(lines, [VanStockService.Line(part: "4455", quantity: .whole(3))])
        XCTAssertEqual(VanStockTool.lines(["description": "Igniter", "quantity": 2.0]),
                       [VanStockService.Line(description: "Igniter", quantity: .whole(2))])
    }

    // MARK: Measured quantities (Plan ML P2)

    private func standard(_ description: String) -> StockQuantity? {
        store.log.items.first { $0.description == description }?.standard
    }

    /// No model-facing result carries the stored thousandths, a padded decimal or a bare litre symbol.
    private func assertSpokenPlainly(_ answer: String, file: StaticString = #filePath, line: UInt = #line) {
        for leak in ["4250", "4.250", " l ", " l.", " kg ", " m "] {
            XCTAssertFalse(answer.contains(leak), "\(leak) in: \(answer)", file: file, line: line)
        }
    }

    func testAUseOfFourAndAQuarterLitresIsKeptExactly() async throws {
        _ = try await run(["action": "load", "description": "Engine oil", "quantity": 5, "unit": "l"])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "use", "description": "engine oil", "quantity": 4.25])
        XCTAssertTrue(answer.hasPrefix("Used 4.25 litres of Engine oil."), answer)
        XCTAssertTrue(answer.contains("0.75 litres left."), answer)
        XCTAssertEqual(store.log.movements.last?.quantity, StockQuantity(scaled: 4250))
        XCTAssertEqual(onHand("Engine oil"), StockQuantity(scaled: 750))
        assertSpokenPlainly(answer)
    }

    func testAFractionOnALineCountedWholeIsRefusedNotCut() async throws {
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 5])
        let movements = store.log.movements.count
        clock.addTimeInterval(60)
        let answer = try await run(["action": "use", "description": "igniter", "quantity": 4.25])
        XCTAssertTrue(answer.hasPrefix("Nothing recorded for Igniter: each is counted in whole numbers."), answer)
        XCTAssertEqual(store.log.movements.count, movements)
        XCTAssertEqual(onHand("Igniter"), .whole(5))

        let packs = try await run(["action": "load", "description": "Wire nuts", "quantity": 2.5, "unit": "pack"])
        XCTAssertTrue(packs.hasPrefix("Nothing loaded for Wire nuts: packs are counted whole."), packs)
        XCTAssertNil(onHand("Wire nuts"), "no line was started for it")
    }

    func testTheLinesOwnUnitDecidesNotTheUnitTheModelLeftOut() async throws {
        // The use names no unit: the line it matches is in litres, so 4.25 is taken.
        _ = try await run(["action": "count", "description": "Engine oil", "quantity": 6, "unit": "l"])
        clock.addTimeInterval(60)
        _ = try await run(["action": "use", "description": "engine oil", "quantity": "4.25"])
        XCTAssertEqual(onHand("Engine oil"), StockQuantity(scaled: 1750))
    }

    func testMoreThanThreeDecimalPlacesIsRefused() async throws {
        _ = try await run(["action": "load", "description": "Engine oil", "quantity": 5, "unit": "l"])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "use", "description": "engine oil", "quantity": 4.2513])
        XCTAssertTrue(answer.hasPrefix("Nothing recorded for Engine oil: litres are kept to 3 decimal places."), answer)
        XCTAssertEqual(onHand("Engine oil"), .whole(5))
    }

    func testACountByWeightIsKeptExactly() async throws {
        let answer = try await run(["action": "count", "description": "Refrigerant", "quantity": 3.5, "unit": "kg"])
        XCTAssertEqual(onHand("Refrigerant"), StockQuantity(scaled: 3500))
        XCTAssertTrue(answer.hasPrefix("Counted: 3.5 kilograms of Refrigerant on the van."), answer)
        clock.addTimeInterval(60)
        let short = try await run(["action": "count", "description": "refrigerant", "quantity": 3.25])
        XCTAssertTrue(short.contains("The log expected 3.5 kilograms, so that is 0.25 kilograms short."), short)
        XCTAssertTrue(short.contains("counted: 3.25 kilograms on the van, 0.25 kilograms short of the 3.5 kilograms expected"), short)
    }

    func testAHalfLitreStandardIsSetAndAHalfIgniterDoesNotClearOne() async throws {
        _ = try await run(["action": "load", "description": "Engine oil", "quantity": 5, "unit": "l"])
        _ = try await run(["action": "load", "description": "Igniter", "quantity": 4])
        clock.addTimeInterval(60)
        let oil = try await run(["action": "set_standard", "description": "engine oil", "quantity": 0.5])
        XCTAssertEqual(standard("Engine oil"), StockQuantity(scaled: 500), "0.5 used to be cut to 0, which cleared it")
        XCTAssertTrue(oil.contains("is now 0.5 litres of Engine oil"), oil)

        _ = try await run(["action": "set_standard", "description": "igniter", "quantity": 3])
        clock.addTimeInterval(60)
        let answer = try await run(["action": "set_standard", "description": "igniter", "quantity": 0.5])
        XCTAssertTrue(answer.hasPrefix("No standard load set for Igniter: each is counted in whole numbers."), answer)
        XCTAssertEqual(standard("Igniter"), .whole(3))
    }

    func testAWholeNumberSentAsADecimalIsKept() async throws {
        let answer = try await run(["action": "load", "description": "Igniter", "quantity": 2.0])
        XCTAssertTrue(answer.hasPrefix("Loaded 2 × Igniter."), answer)
        XCTAssertEqual(onHand("Igniter"), .whole(2))
    }

    func testAQuantityInWordsOrALocalSpellingIsRefusedNotTakenAsOne() async throws {
        let answer = try await run(["action": "load", "description": "Igniter", "quantity": "two"])
        XCTAssertTrue(answer.hasPrefix("Nothing loaded for Igniter: that is not a number."), answer)
        let comma = try await run(["action": "load", "description": "Engine oil", "quantity": "4,25", "unit": "l"])
        XCTAssertTrue(comma.hasPrefix("Nothing loaded for Engine oil: that is not a number."), comma)
        let negative = try await run(["action": "count", "description": "Igniter", "quantity": -1])
        XCTAssertTrue(negative.hasPrefix("Nothing counted for Igniter: a quantity cannot be below zero."), negative)
        XCTAssertTrue(store.log.isEmpty)
    }

    func testOneRefusedFigureInABatchStopsTheWholeBatchAndEachIsNamed() async throws {
        let answer = try await run(["action": "load", "items": [
            entry(["description": "Igniter", "quantity": 2]),
            entry(["description": "Thermostat cable", "quantity": 1.5, "unit": "m"]),
            entry(["description": "Wire nuts", "quantity": 1.5, "unit": "pack"]),
            entry(["part": "70W16", "quantity": "0.5"]),
        ]])
        XCTAssertEqual(answer, "Nothing loaded for Wire nuts: packs are counted whole. Nothing loaded for 70W16: "
            + "each is counted in whole numbers. Nothing else in this call was recorded either. Ask the technician "
            + "for the figure again.")
        XCTAssertTrue(store.log.isEmpty, "nothing in the batch is recorded, the 1.5 m that fitted included")

        let fitted = try await run(["action": "load", "items": [
            entry(["description": "Igniter", "quantity": 2]),
            entry(["description": "Thermostat cable", "quantity": 1.5, "unit": "m"]),
        ]])
        XCTAssertTrue(fitted.contains("Loaded 1.5 metres of Thermostat cable."), fitted)
        XCTAssertEqual(onHand("Thermostat cable"), StockQuantity(scaled: 1500))
    }

    func testTheRefusalIsSaidInThePlacesWords() async throws {
        for kind in StockPlace.Kind.allCases {
            store.setPlace(kind)
            for args in [["action": "use", "description": "Wire nuts", "quantity": 4.25, "unit": "pack"] as [String: Any],
                         ["action": "set_standard", "description": "Wire nuts", "quantity": 0.5, "unit": "pack"]] {
                let refusal = try await run(args)
                XCTAssertTrue(refusal.contains("packs are counted whole"), "\(kind): \(refusal)")
                XCTAssertEqual(StockPlaceWordCheck.violations(refusal, kind: kind), [], "\(kind): \(refusal)")
            }
        }
        store.setPlace(.store)
        let answer = try await run(["action": "use", "description": "Wire nuts", "quantity": 4.25, "unit": "pack"])
        XCTAssertTrue(answer.hasSuffix("Ask the person for the figure again."), answer)
    }

    func testTheQuantityIsANumberForStockAndAWholeNumberForAPartsRequest() throws {
        for kind in StockPlace.Kind.allCases {
            let properties = try XCTUnwrap(VanStockTool.parametersSchema(for: kind)["properties"] as? [String: Any])
            let quantity = try XCTUnwrap(properties["quantity"] as? [String: Any])
            XCTAssertEqual(quantity["type"] as? String, "number", "\(kind)")
            XCTAssertTrue((quantity["description"] as? String ?? "").contains("4.25 litres is 4.25"), "\(kind)")
            let items = try XCTUnwrap(properties["items"] as? [String: Any])
            let itemFields = try XCTUnwrap((items["items"] as? [String: Any])?["properties"] as? [String: Any])
            XCTAssertEqual((itemFields["quantity"] as? [String: Any])?["type"] as? String, "number", "\(kind)")
        }
        let parts = try XCTUnwrap(PartsRequestTool().parametersSchema["properties"] as? [String: Any])
        XCTAssertEqual((parts["quantity"] as? [String: Any])?["type"] as? String, "integer")
    }

    func testALoadWithNoQuantityStillDefaultsToOne() async throws {
        let answer = try await run(["action": "load", "description": "Igniter"])
        XCTAssertTrue(answer.hasPrefix("Loaded 1 × Igniter."), answer)
        XCTAssertEqual(onHand("Igniter"), .whole(1))
    }

    // MARK: Every place (Plan MK P1)

    func testTheDescriptionLeadsWithThePlaceInItsOwnWords() {
        for kind in StockPlace.Kind.allCases {
            let description = VanStockTool.description(for: kind)
            XCTAssertEqual(StockPlaceWordCheck.violations(description, kind: kind), [], "\(kind): \(description)")
            XCTAssertTrue(description.contains(StockPlaceWording(kind).location), "\(kind)")
            XCTAssertTrue(description.contains("'list' (what is there, all of it or one bin; pass 'bin')"), "\(kind)")
        }
        XCTAssertTrue(VanStockTool.description(for: .van).hasPrefix(
            "The technician's own van or truck stock, kept on the phone. Use it whenever they ask what is on the "
            + "van or truck, or say they loaded, used, returned or counted parts. Works without a job open"))
        XCTAssertTrue(VanStockTool.description(for: .store).hasPrefix(
            "The stock kept in the store, on the phone. Use it whenever they ask what is in the store, or say they "
            + "received, sold, used, returned or counted stock."))
        XCTAssertEqual(tool.name, "van_stock", "the name is a contract string and stays")
    }

    func testEveryKindsSchemaHasEveryActionIncludingTheJobOnesAndList() throws {
        for kind in StockPlace.Kind.allCases {
            let schema = VanStockTool.parametersSchema(for: kind)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let action = try XCTUnwrap(properties["action"] as? [String: Any])
            let actions = try XCTUnwrap(action["enum"] as? [String])
            for wanted in ["unrecorded", "not_from_van", "list", "send_to_base", "top_up", "set_standard", "use"] {
                XCTAssertTrue(actions.contains(wanted), "\(kind) lacks \(wanted)")
            }
            XCTAssertNotNil(properties["bin"], "\(kind)")
            let reason = try XCTUnwrap(properties["reason"] as? [String: Any])
            XCTAssertEqual(StockPlaceWordCheck.violations(reason["description"] as? String ?? "", kind: kind), [], "\(kind)")
        }
    }

    func testTheToolFollowsThePlaceSetOnTheList() {
        XCTAssertEqual(tool.description, VanStockTool.description(for: .van))
        store.setPlace(.store)
        XCTAssertEqual(tool.description, VanStockTool.description(for: .store))
        XCTAssertTrue((tool.parametersSchema["properties"] as? [String: Any])?["bin"] != nil)
    }

    /// A place changed on the screen reaches the next turn's tool definitions: the registry, the
    /// declarations a request carries, and the signature the on-device tool cache keys on.
    func testAChangedPlaceReachesTheNextToolDefinitions() {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let before = registry.toolDescriptions(for: ["van_stock"]).first?.description
        let signature = registry.definitionSignature(for: ["van_stock"])
        XCTAssertEqual(before, VanStockTool.description(for: .van))

        store.setPlace(.warehouse)
        XCTAssertEqual(registry.toolDescriptions(for: ["van_stock"]).first?.description,
                       VanStockTool.description(for: .warehouse))
        XCTAssertNotEqual(registry.definitionSignature(for: ["van_stock"]), signature,
                          "a cache keyed on the names alone would serve the van's description")
        let declared = ToolDeclarations.nativeToolDeclarations(registry: registry, fieldJobActive: false,
                                                               fieldProfileEnabled: false)
            .first { ($0["name"] as? String) == "van_stock" }
        XCTAssertEqual(declared?["description"] as? String, VanStockTool.description(for: .warehouse))
        XCTAssertEqual(registry.definitionSignature(for: ["van_stock"]), registry.definitionSignature(for: ["van_stock"]),
                       "the signature is stable while nothing changes")
    }

    func testAtAStoreWithNoJobOpenTheJobActionsRefuseInTheStoresWords() async throws {
        store.setPlace(.store)
        let unrecorded = try await run(["action": "unrecorded"])
        XCTAssertTrue(unrecorded.contains("There is no job open"), unrecorded)
        let notFrom = try await run(["action": "not_from_van", "part": "22B22"])
        XCTAssertTrue(notFrom.contains("There is no job open"), notFrom)
        let unnamed = try await run(["action": "not_from_van"])
        XCTAssertEqual(unnamed, "Say which part did not come from the store, by its part number.")
        for answer in [unrecorded, notFrom, unnamed] {
            XCTAssertEqual(StockPlaceWordCheck.violations(answer, kind: .store), [], answer)
        }
        XCTAssertTrue(store.log.isEmpty)
    }

    func testAtStockWithAJobOpenAUsedLineIsTaggedToTheJob() async throws {
        store.setPlace(.stock)
        var told: [VanStockUse] = []
        let service = VanStockService(
            store: store, partsIndex: { VaultPartsIndex(files: []) }, activeJob: { [unowned self] in self.job },
            now: { [unowned self] in self.clock }, calendar: calendar,
            makeID: { [unowned self] in self.counter += 1; return "id-\(self.counter)" },
            jobUses: .init(record: { told.append($0) }, remove: { _ in }, notFromVan: { _ in true }, unrecorded: { [] }))
        let tool = VanStockTool(service: service)
        _ = try await tool.execute(args: ["action": "load", "description": "Brake pads", "quantity": 4])
        job = .init(sessionID: "s1", reference: "job-7")
        clock.addTimeInterval(60)
        let answer = try await tool.execute(args: ["action": "use", "description": "brake pads", "quantity": 1])
        XCTAssertTrue(answer.hasPrefix("Used or sold 1 × Brake pads on job job-7."), answer)
        XCTAssertTrue(answer.contains("Say: 1 × Brake pads taken from stock for job job-7."), answer)
        XCTAssertEqual(store.log.movements.last?.jobSessionID, "s1")
        XCTAssertEqual(told.map(\.summary), ["1 × Brake pads"])
        let noted = try await tool.execute(args: ["action": "not_from_van", "part": "BP-9"])
        XCTAssertTrue(noted.hasPrefix("Noted: BP-9 did not come from stock on this job. The stock list is unchanged."), noted)
        for text in [answer, noted] {
            XCTAssertEqual(StockPlaceWordCheck.violations(text, kind: .stock), [], text)
        }
    }

    func testSendingAStoresListAsksNoExtrasQuestionAndStagesIt() async throws {
        store.setPlace(.store)
        store.nameVan("Main street store")
        _ = try await run(["action": "count", "description": "Gin", "quantity": 4])
        clock.addTimeInterval(60)
        // At a van this load, beyond any standard and made this shift, is asked about first.
        _ = try await run(["action": "load", "description": "gin", "quantity": 6])
        let handover = VanStockHandoverService(service: service)
        defer { handover.discard() }
        let answer = try await VanStockTool(service: service, handover: handover).execute(args: ["action": "send_to_base"])
        XCTAssertTrue(answer.hasPrefix("Staged on the phone for the person to look at and send. Nothing has been sent."), answer)
        XCTAssertFalse(answer.contains("returning it"), answer)
        XCTAssertEqual(StockPlaceWordCheck.violations(answer, kind: .store), [], answer)
        let staged = try XCTUnwrap(handover.staged)
        XCTAssertTrue(staged.message.hasPrefix("Main street store stock, "), staged.message)
        XCTAssertTrue(staged.fileURL.lastPathComponent.hasPrefix("Store stock "), staged.fileURL.lastPathComponent)
        XCTAssertEqual(StockPlaceWordCheck.violations(staged.message, kind: .store), [], staged.message)
    }

    func testAVanStillAsksAboutTheDaysExtras() async throws {
        _ = try await run(["action": "count", "description": "Gin", "quantity": 4])
        clock.addTimeInterval(60)
        _ = try await run(["action": "load", "description": "gin", "quantity": 6])
        let asked = try await VanStockTool(service: service, handover: VanStockHandoverService(service: service))
            .execute(args: ["action": "send_to_base"])
        XCTAssertTrue(asked.contains("Ask for each: returning it, or keeping it on the truck?"), asked)
    }

    func testAStoreWithNoNamedVaultMakesNoLookup() async throws {
        store.setPlace(.store)
        var looked = 0
        var named = 0
        let book = VanStockBook(name: "Supplier catalogue", verify: { looked += 1; return TaskPart(number: $0, verified: true) })
        let service = VanStockService(
            store: store, books: VanStockBooks(job: { nil }, named: { _ in named += 1; return book }),
            partsIndex: { VaultPartsIndex(files: []) }, activeJob: { nil },
            now: { [unowned self] in self.clock }, calendar: calendar)
        let answer = try await VanStockTool(service: service).execute(args: ["action": "load", "part": "62-23543-01",
                                                                             "description": "sensor", "quantity": 2])
        XCTAssertEqual(looked, 0, "nothing is searched until a book is named")
        XCTAssertEqual(named, 0)
        XCTAssertEqual(store.log.items.first?.verification, .notChecked)
        XCTAssertTrue(answer.contains("Part number 62-23543-01 has not been on this list before."), answer)
        XCTAssertFalse(answer.contains("manuals"), answer)
        XCTAssertFalse(answer.contains("not found"), answer)
    }

    func testEveryResultAtEveryPlaceIsInItsWords() async throws {
        for kind in StockPlace.Kind.allCases {
            try? FileManager.default.removeItem(at: directory)
            store = VanStockStore(directory: directory, now: clock)
            store.setPlace(kind)
            let service = makeService()
            let tool = VanStockTool(service: service)
            var answers: [String] = []
            answers.append(try await tool.execute(args: ["action": "check", "description": "igniter"]))
            answers.append(try await tool.execute(args: ["action": "list"]))
            answers.append(try await tool.execute(args: ["action": "load", "part": "22B22", "description": "Igniter", "quantity": 3]))
            clock.addTimeInterval(20)
            answers.append(try await tool.execute(args: ["action": "load", "description": "Fuse", "quantity": 1, "unit": "kg"]))
            answers.append(try await tool.execute(args: ["action": "use", "part": "22B22", "quantity": 1]))
            clock.addTimeInterval(20)
            answers.append(try await tool.execute(args: ["action": "remove", "part": "22B22", "quantity": 1, "reason": "returned"]))
            clock.addTimeInterval(20)
            answers.append(try await tool.execute(args: ["action": "count", "part": "22B22", "quantity": 5]))
            answers.append(try await tool.execute(args: ["action": "check", "part": "22B22"]))
            answers.append(try await tool.execute(args: ["action": "check", "description": "flamingo"]))
            answers.append(try await tool.execute(args: ["action": "use", "description": "flamingo"]))
            answers.append(try await tool.execute(args: ["action": "low"]))
            answers.append(try await tool.execute(args: ["action": "list", "bin": "cellar"]))
            answers.append(try await tool.execute(args: ["action": "top_up"]))
            answers.append(try await tool.execute(args: ["action": "set_standard", "part": "22B22", "quantity": 8]))
            answers.append(try await tool.execute(args: ["action": "set_standard", "part": "22B22"]))
            answers.append(try await tool.execute(args: ["action": "top_up"]))
            clock.addTimeInterval(20)
            answers.append(try await tool.execute(args: ["action": "load", "to_standard": true]))
            answers.append(try await tool.execute(args: ["action": "undo"]))
            answers.append(try await tool.execute(args: ["action": "undo"]))
            answers.append(try await tool.execute(args: ["action": "unrecorded"]))
            answers.append(try await tool.execute(args: ["action": "set_standard"]))
            answers.append(try await tool.execute(args: ["action": "load", "code": "0123456"]))
            for answer in answers {
                XCTAssertEqual(StockPlaceWordCheck.violations(answer, kind: kind), [], "\(kind): \(answer)")
            }
            XCTAssertTrue(answers[2].contains(StockPlaceWording(kind).location), "\(kind): \(answers[2])")
        }
    }
}
