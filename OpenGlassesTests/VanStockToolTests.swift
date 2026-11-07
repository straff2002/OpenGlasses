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

    private func onHand(_ description: String) -> Int? {
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
        XCTAssertEqual(onHand("Igniter"), 2)
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
        XCTAssertEqual(onHand("45/5 capacitor"), 8)
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
        XCTAssertEqual(onHand("Capacitor, dual run, 45/5"), 3)
        XCTAssertEqual(onHand("Capacitor, run, 5"), 3)
    }

    func testARepeatedIdenticalWriteInsideTheWindowIsOneWrite() async throws {
        let args: [String: Any] = ["action": "load", "description": "Igniter", "quantity": 4]
        _ = try await run(args)
        clock.addTimeInterval(3)
        let retry = try await run(args)
        XCTAssertTrue(retry.hasPrefix("Already recorded a moment ago"), retry)
        XCTAssertEqual(onHand("Igniter"), 4)

        clock.addTimeInterval(VanStockService.duplicateWindow + 1)
        _ = try await run(args)
        XCTAssertEqual(onHand("Igniter"), 8, "said again later, it is a second load")
    }

    func testAUnitIsKeptAndAMismatchChangesNothing() async throws {
        _ = try await run(["action": "load", "description": "Thermostat cable", "quantity": 30, "unit": "m"])
        XCTAssertEqual(store.log.items.first?.unit, .m)
        clock.addTimeInterval(60)
        let mismatch = try await run(["action": "load", "description": "thermostat cable", "quantity": 5, "unit": "ft"])
        XCTAssertTrue(mismatch.contains("is counted in m, not ft"), mismatch)
        XCTAssertEqual(onHand("Thermostat cable"), 30)
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
        XCTAssertEqual(store.log.level(of: store.log.items[0].id).onOrder, 0)
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
        XCTAssertEqual(counted, "Counted: 5 × Igniter on the van.\nSay: Igniter counted: 5 on the van. Put this in the reply, whatever else the technician asked this turn.")
        clock.addTimeInterval(3_600)
        let check = try await run(["action": "check", "description": "igniter"])
        XCTAssertTrue(check.hasPrefix("5 × Igniter on the van — counted today at"), check)
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
        XCTAssertEqual(lines, [VanStockService.Line(part: "4455", quantity: 3)])
        XCTAssertEqual(VanStockTool.lines(["description": "Igniter", "quantity": 2.0]),
                       [VanStockService.Line(description: "Igniter", quantity: 2)])
    }
}
