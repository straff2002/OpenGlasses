import XCTest
@testable import OpenGlasses

/// Plan MK §8 — `list`: what is there, all of it or one bin, said with `check`'s honesty rules.
@MainActor
final class VanStockListTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday 14 October 2026, 15:00 UTC.
    private var now: Date { date(2026, 10, 14, 15, 0) }
    private var counted: Date { date(2026, 10, 14, 10, 40) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func composer(_ kind: StockPlace.Kind = .store) -> VanStockAnswerComposer {
        VanStockAnswerComposer(now: now, calendar: calendar, wording: StockPlaceWording(kind))
    }

    /// A shop: two fridges, a shelf, and a line with no bin. Everything counted at the same time.
    private var shop: VanStockLog {
        var log = VanStockLog()
        log.addItem(id: "gin", description: "Gin", unit: .pack, bin: "Main fridge", batch: "b0")
        log.addItem(id: "soda", description: "Soda water", bin: "main FRIDGE", batch: "b0")
        log.addItem(id: "tonic", description: "Tonic", bin: "Door fridge", batch: "b0")
        log.addItem(id: "lemons", description: "Lemons", bin: "Back shelf", batch: "b0")
        log.addItem(id: "ice", description: "Ice", batch: "b0")
        for (id, quantity) in [("gin", 22), ("soda", 0), ("tonic", 6), ("lemons", 12), ("ice", 3)] {
            log.record(.counted, itemID: id, quantity: quantity, at: counted, batch: "b0", source: .typed)
        }
        return log
    }

    private func lines(_ answer: String) -> [String] { answer.components(separatedBy: "\n") }

    // MARK: Order

    func testTheWholeListIsByBinThenNameWithBinlessLinesLast() {
        let answer = composer().list(shop, bin: nil)
        XCTAssertEqual(lines(answer), [
            "Everything in the store: 5 lines, by bin, all counted today at 10:40:",
            "Back shelf — 12 × Lemons.",
            "Door fridge — 6 × Tonic.",
            "Main fridge — 22 packs of Gin.",
            "main FRIDGE — Soda water: none.",
            "No bin — 3 × Ice.",
        ])
    }

    // MARK: Matching a bin

    func testABinMatchesEveryWordSaidIgnoringCase() {
        let answer = composer().list(shop, bin: "FRIDGE main")
        XCTAssertEqual(lines(answer), [
            "In Main fridge: 2 lines, all counted today at 10:40:",
            "22 packs of Gin.",
            "Soda water: none.",
        ], "the bin's two spellings are one bin")
        XCTAssertEqual(lines(composer().list(shop, bin: "the back shelf")).first, "In Back shelf: 1 line, all counted today at 10:40:")
        XCTAssertTrue(composer().list(shop, bin: "main cellar").hasPrefix("No bin called main cellar."), "every word must be there")
    }

    func testSeveralMatchingBinsAreListedTogetherEachNamed() {
        let answer = composer().list(shop, bin: "fridge")
        XCTAssertEqual(lines(answer), [
            "In Door fridge and Main fridge: 3 lines, by bin, all counted today at 10:40:",
            "Door fridge — 6 × Tonic.",
            "Main fridge — 22 packs of Gin.",
            "main FRIDGE — Soda water: none.",
        ])
    }

    func testAnUnknownBinNamesTheBinsThereAre() {
        XCTAssertEqual(composer().list(shop, bin: "cellar"),
                       "No bin called cellar. The bins are: Back shelf, Door fridge, Main fridge. Ask which one they mean.")
        var bare = VanStockLog()
        bare.addItem(id: "x", description: "Fuse", batch: "b0")
        XCTAssertEqual(composer().list(bare, bin: "cellar"),
                       "No bin called cellar: no line on the stock list has a bin. Leave 'bin' out to read the whole list.")
    }

    // MARK: Honesty

    func testAnUnreliableLineIsSaidUnreliableBeforeItsFigure() {
        var log = shop
        log.record(.used, itemID: "soda", quantity: 1, at: counted.addingTimeInterval(60), batch: "b1", source: .spoken)
        let text = lines(composer().list(log, bin: "main fridge")).first { $0.contains("Soda water") } ?? ""
        let unreliable = text.range(of: "unreliable")
        let figure = text.range(of: "the log shows")
        XCTAssertNotNil(unreliable, text)
        XCTAssertNotNil(figure, text)
        if let unreliable, let figure { XCTAssertLessThan(unreliable.lowerBound, figure.lowerBound, text) }
    }

    func testALineAtZeroSaysNoneAndANewLineGivesNoNumber() {
        var log = shop
        log.addItem(id: "limes", description: "Limes", bin: "Back shelf", batch: "b2")
        let answer = composer().list(log, bin: "back shelf")
        XCTAssertTrue(answer.contains("Limes: nothing recorded yet, no count."), answer)
        XCTAssertFalse(answer.contains("all counted"), "a line with no figure shares no provenance")
        XCTAssertTrue(composer().list(shop, bin: nil).contains("Soda water: none."))
    }

    func testASharedProvenanceIsSaidOnceAndAMixedOnePerLine() {
        let shared = composer().list(shop, bin: nil)
        XCTAssertEqual(shared.components(separatedBy: "counted today at 10:40").count - 1, 1, shared)

        var mixed = shop
        mixed.record(.loaded, itemID: "gin", quantity: 2, at: date(2026, 10, 14, 12, 0), batch: "b1", source: .spoken)
        let answer = composer().list(mixed, bin: nil)
        XCTAssertFalse(answer.contains("all counted"), answer)
        XCTAssertTrue(answer.contains("Back shelf — 12 × Lemons (counted today at 10:40)."), answer)
        XCTAssertTrue(answer.contains("24 packs of Gin (worked out from what was received and sold or used, not counted"), answer)
    }

    // MARK: Length

    func testAtMostEightLinesAreSpokenThenTheStockScreen() {
        var log = VanStockLog()
        for index in 1...22 {
            let id = String(format: "line-%02d", index)
            log.addItem(id: id, description: "Bottle \(String(format: "%02d", index))", bin: "Shelf", batch: "b0")
            log.record(.counted, itemID: id, quantity: index, at: counted, batch: "b0", source: .typed)
        }
        let answer = composer(.stock).list(log, bin: nil)
        let spoken = lines(answer)
        XCTAssertEqual(spoken.count, 1 + VanStockAnswerComposer.listLimit + 1)
        XCTAssertEqual(spoken.last, "And 14 more: the full list is on the Stock screen.")
        XCTAssertTrue(spoken[1].contains("Bottle 01"), spoken[1])
        XCTAssertTrue(composer(.van).list(log, bin: nil).hasSuffix("And 14 more: the full list is on the Van stock screen."))
    }

    // MARK: Empty, nothing written, and the words

    func testAnEmptyListGivesTheEmptyListSentence() {
        for kind in StockPlace.Kind.allCases {
            XCTAssertEqual(composer(kind).list(VanStockLog(), bin: nil), composer(kind).emptyVan())
            XCTAssertEqual(composer(kind).list(VanStockLog(), bin: "fridge"), composer(kind).emptyVan())
        }
    }

    func testListingWritesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-list-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VanStockStore(directory: directory, now: now)
        store.replace(with: shop, van: nil)
        store.setPlace(.store)
        let expected = store.log
        let file = directory.appendingPathComponent("van-stock.json")
        let before = try Data(contentsOf: file)
        let service = VanStockService(store: store, partsIndex: { VaultPartsIndex(files: []) }, activeJob: { nil },
                                      now: { self.now }, calendar: calendar)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let previousEntitlement = EntitlementTestScope.grant()
        defer {
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
            EntitlementTestScope.restore(previousEntitlement)
        }
        let answer = try await VanStockTool(service: service).execute(args: ["action": "list", "bin": "fridge"])
        XCTAssertTrue(answer.hasPrefix("In Door fridge and Main fridge: 3 lines"), answer)
        XCTAssertFalse(answer.contains(VanStockService.sayPrefix), "nothing changed, so nothing to say was done")
        XCTAssertEqual(store.log, expected)
        XCTAssertEqual(try Data(contentsOf: file), before, "the file is not even rewritten")
    }

    func testEveryPlaceListsInItsOwnWords() {
        for kind in StockPlace.Kind.allCases {
            for bin in [nil, "fridge", "main fridge", "cellar"] {
                let answer = composer(kind).list(shop, bin: bin)
                XCTAssertEqual(StockPlaceWordCheck.violations(answer, kind: kind), [], "\(kind): \(answer)")
            }
            XCTAssertTrue(composer(kind).list(shop, bin: nil).hasPrefix("Everything \(StockPlaceWording(kind).location):"))
        }
    }
}
