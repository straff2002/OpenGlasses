import XCTest
@testable import OpenGlasses

/// Plan IH P0 — how a level is known is always said, and an unknown is never a number.
final class VanStockAnswerComposerTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday 14 October 2026, 15:00 UTC.
    private var now: Date { date(2026, 10, 14, 15, 0) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var composer: VanStockAnswerComposer { VanStockAnswerComposer(now: now, calendar: calendar) }

    private func item(number: String? = "62-23543-01", verified: Bool = true, minimum: StockQuantity? = nil,
                      unit: VanStockUnit = .each) -> VanStockItem {
        VanStockItem(id: "i", number: number, description: "Flame sensor", unit: unit, minimum: minimum,
                     verified: verified, createdBatch: "b0")
    }

    /// `onHand` in whole units.
    private func level(_ onHand: Int, _ provenance: VanStockLevel.Provenance = .counted,
                       asOf: Date? = nil, onOrder: StockQuantity = .zero, orderedAt: Date? = nil,
                       unreliable: Bool = false, handedOver: Bool = false) -> VanStockLevel {
        VanStockLevel(itemID: "i", onHand: .whole(onHand), onOrder: onOrder, oldestOrderAt: orderedAt,
                      provenance: provenance, asOf: asOf ?? date(2026, 10, 14, 10, 40),
                      unreliable: unreliable, handedOver: handedOver)
    }

    // MARK: Age

    func testAgeWording() {
        XCTAssertEqual(composer.age(date(2026, 10, 14, 10, 40)), "today at 10:40")
        XCTAssertEqual(composer.age(date(2026, 10, 13, 17, 10)), "yesterday at 17:10")
        XCTAssertEqual(composer.age(date(2026, 10, 12, 9, 0)), "on Monday")
        XCTAssertEqual(composer.age(date(2026, 10, 8, 9, 0)), "on Thursday")
        XCTAssertEqual(composer.age(date(2026, 10, 3, 9, 0)), "on 3 October")
        XCTAssertEqual(composer.age(date(2025, 12, 31, 9, 0)), "on 31 December 2025")
    }

    // MARK: Check

    func testACountedLevelSaysCountedAndWhen() {
        XCTAssertEqual(composer.check(item(), level: level(2)),
                       "2 × Flame sensor (62-23543-01) on the van — counted today at 10:40.")
    }

    func testAnInferredLevelSaysItWasWorkedOut() {
        let answer = composer.check(item(), level: level(2, .inferred, asOf: date(2026, 10, 13, 17, 10)))
        XCTAssertEqual(answer, "2 × Flame sensor (62-23543-01) on the van — worked out from what was loaded "
            + "and used, not counted; last changed yesterday at 17:10.")
    }

    func testAHandedOverLevelSaysSo() {
        let answer = composer.check(item(), level: level(2, asOf: date(2026, 10, 13, 17, 10), handedOver: true))
        XCTAssertTrue(answer.contains("as handed over yesterday at 17:10"), answer)
    }

    func testTheAgeIsAlwaysPresentForARecordedLine() {
        for provenance in [VanStockLevel.Provenance.counted, .inferred] {
            for onHand in [0, 1, 9] {
                let answer = composer.check(item(), level: level(onHand, provenance))
                XCTAssertTrue(answer.contains("today at 10:40"), answer)
            }
        }
    }

    func testZeroIsSaidAsNone() {
        XCTAssertEqual(composer.check(item(), level: level(0)),
                       "No Flame sensor (62-23543-01) on the van — counted today at 10:40.")
    }

    func testUnreliableIsSaidBeforeAnyFigure() {
        let answer = composer.check(item(), level: level(0, .inferred, unreliable: true))
        XCTAssertTrue(answer.hasPrefix("The count for Flame sensor (62-23543-01) cannot be trusted"), answer)
        XCTAssertTrue(answer.contains("count them"), answer)
        XCTAssertFalse(answer.contains("on the van —"), answer)
    }

    func testALineWithNothingRecordedIsNeverANumber() {
        let nothing = VanStockLevel(itemID: "i")
        let answer = composer.check(item(), level: nothing)
        XCTAssertEqual(answer, "Flame sensor (62-23543-01) is on the van list with nothing recorded against it — no count yet.")
        XCTAssertNil(answer.rangeOfCharacter(from: .decimalDigits, options: [],
                                             range: answer.range(of: "is on the van list")!.lowerBound..<answer.endIndex))
    }

    func testOnOrderMinimumAndNotFoundAreAdded() {
        // Plan MK §4: the sentence names the book that was searched, and only a number that book
        // did not hold gets one. A number nothing was searched for says nothing about it.
        var notFound = item(verified: false, minimum: .whole(2))
        notFound.verification = .notFound(in: "Furnace manual")
        let answer = composer.check(notFound, level: level(1, onOrder: .whole(1), orderedAt: date(2026, 10, 12, 9, 0)))
        XCTAssertTrue(answer.contains("1 asked for on Monday and not yet loaded."), answer)
        XCTAssertTrue(answer.contains("That is at or below the minimum of 2."), answer)
        XCTAssertTrue(answer.contains("The part number is not found in Furnace manual."), answer)
        let unchecked = composer.check(item(verified: false, minimum: .whole(2)), level: level(1))
        XCTAssertFalse(unchecked.contains("not found"), unchecked)
        XCTAssertFalse(unchecked.contains("manuals"), unchecked)
    }

    func testALineWithNoNumberIsNotCalledUnverified() {
        let answer = composer.check(item(number: nil, verified: false), level: level(2))
        XCTAssertEqual(answer, "2 × Flame sensor on the van — counted today at 10:40.")
    }

    func testUnitsAreSaid() {
        XCTAssertTrue(composer.check(item(number: nil, unit: .m), level: level(10)).hasPrefix("10 metres of Flame sensor"))
        XCTAssertTrue(composer.check(item(number: nil, unit: .pack), level: level(1)).hasPrefix("1 pack of Flame sensor"))
    }

    // MARK: Read-backs

    func testALoadReadsBackTheLineAndTheLevel() {
        let answer = composer.loaded(item(), quantity: .whole(4), before: level(2), after: level(6, .inferred), created: false)
        XCTAssertEqual(answer, "Loaded 4 × Flame sensor (62-23543-01). 6 × Flame sensor (62-23543-01) on the van now.")
    }

    func testANewLineWithAnUnknownNumberIsSpelledOut() {
        let answer = composer.loaded(item(verified: false), quantity: .whole(4), before: VanStockLevel(itemID: "i"),
                                     after: level(4, .inferred), created: true)
        XCTAssertTrue(answer.contains("That is a new line on the van list."), answer)
        XCTAssertTrue(answer.contains("six two, dash, two three five four three, dash, zero one"), answer)
        XCTAssertTrue(answer.contains("undo that"), answer)
    }

    func testANewLineWithAVerifiedNumberIsNotSpelledOut() {
        let answer = composer.loaded(item(), quantity: .whole(4), before: VanStockLevel(itemID: "i"),
                                     after: level(4, .inferred), created: true)
        XCTAssertTrue(answer.contains("That is a new line on the van list."), answer)
        XCTAssertFalse(answer.contains("dash"), answer)
    }

    func testALoadSaysWhatItCovered() {
        let ordered = date(2026, 10, 12, 9, 0)
        let all = composer.loaded(item(), quantity: .whole(1), before: level(0, onOrder: .whole(1), orderedAt: ordered),
                                  after: level(1, .inferred), created: false)
        XCTAssertTrue(all.contains("That covers the 1 asked for on Monday."), all)
        let some = composer.loaded(item(), quantity: .whole(1), before: level(0, onOrder: .whole(3), orderedAt: ordered),
                                   after: level(1, .inferred, onOrder: .whole(2), orderedAt: ordered), created: false)
        XCTAssertTrue(some.contains("That covers 1 of the 3 asked for on Monday."), some)
    }

    func testAUseSaysWhatIsLeft() {
        let answer = composer.used(item(), quantity: .whole(1), before: level(3), after: level(2, .inferred),
                                   jobReference: "job-2031")
        XCTAssertEqual(answer, "Used 1 × Flame sensor (62-23543-01) on job job-2031. 2 left.")
    }

    func testTheLastOneOffersARequestAndStops() {
        let answer = composer.used(item(), quantity: .whole(1), before: level(1), after: level(0, .inferred), jobReference: nil)
        XCTAssertTrue(answer.contains("That was the last on the van."), answer)
        XCTAssertTrue(answer.contains("request one only if the technician says yes"), answer)
    }

    func testAtTheMinimumOffersARequest() {
        let answer = composer.used(item(minimum: .whole(2)), quantity: .whole(1), before: level(3), after: level(2, .inferred),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("2 left, at or below the minimum of 2."), answer)
        XCTAssertTrue(answer.contains("Offer to ask the office"), answer)
    }

    func testWithOneAlreadyAskedForNoSecondOfferIsMade() {
        let answer = composer.used(item(), quantity: .whole(1), before: level(1, onOrder: .whole(1), orderedAt: date(2026, 10, 12, 9, 0)),
                                   after: level(0, .inferred, onOrder: .whole(1), orderedAt: date(2026, 10, 12, 9, 0)),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("1 asked for on Monday and not yet loaded."), answer)
        XCTAssertFalse(answer.contains("Offer"), answer)
    }

    func testAUseTheLogCannotCoverSaysTheCountIsGone() {
        let answer = composer.used(item(), quantity: .whole(1), before: level(0), after: level(0, .inferred, unreliable: true),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("The log showed 0, so it cannot say how many are left."), answer)
        XCTAssertFalse(answer.contains("Offer"), answer)
    }

    func testARemovalNamesTheReasonAndMakesNoOffer() {
        let answer = composer.removed(item(), quantity: .whole(1), reason: .returned, before: level(1), after: level(0, .inferred))
        XCTAssertEqual(answer, "Removed 1 × Flame sensor (62-23543-01) (returned). That was the last on the van.")
    }

    func testACountOfALineWithNothingRecordedReadsBackAlone() {
        XCTAssertEqual(composer.counted(item(), before: VanStockLevel(itemID: "i"), after: level(5), created: false),
                       "Counted: 5 × Flame sensor (62-23543-01) on the van.")
    }

    func testACountSaysHowItComparesWithTheLog() {
        XCTAssertEqual(composer.counted(item(), before: level(7, .inferred), after: level(5), created: false),
                       "Counted: 5 × Flame sensor (62-23543-01) on the van. The log expected 7, so that is 2 short.")
        XCTAssertEqual(composer.counted(item(), before: level(4), after: level(5), created: false),
                       "Counted: 5 × Flame sensor (62-23543-01) on the van. The log expected 4, so that is 1 over.")
        XCTAssertEqual(composer.counted(item(), before: level(5), after: level(5), created: false),
                       "Counted: 5 × Flame sensor (62-23543-01) on the van. That matches the 5 the log expected.")
    }

    func testACountAgainstAnUnreliableFigureComparesNothing() {
        let answer = composer.counted(item(), before: level(0, .inferred, unreliable: true), after: level(3), created: false)
        XCTAssertTrue(answer.contains("nothing to check this against"), answer)
        XCTAssertFalse(answer.contains("short"), answer)
        XCTAssertFalse(answer.contains("over"), answer)
    }

    func testACountComparisonKeepsTheUnit() {
        let cable = VanStockItem(id: "i", description: "Thermostat cable", unit: .m, createdBatch: "b0")
        XCTAssertEqual(composer.counted(cable, before: level(30), after: level(25), created: false),
                       "Counted: 25 metres of Thermostat cable on the van. The log expected 30 metres, so that is 5 metres short.")
        XCTAssertEqual(VanStockCountCheck(before: level(30), counted: .whole(25))?.said(.m), ", 5 metres short of the 30 metres expected")
        XCTAssertEqual(VanStockCountCheck(before: level(1), counted: .whole(2))?.said(.pack), ", 1 pack over the 1 pack expected")
    }

    // MARK: Measured amounts in words (Plan ML P2)

    private func measured(_ description: String, _ unit: VanStockUnit, minimum: StockQuantity? = nil) -> VanStockItem {
        VanStockItem(id: "i", description: description, unit: unit, minimum: minimum, createdBatch: "b0")
    }

    private func level(scaled: Int, onOrder: StockQuantity = .zero) -> VanStockLevel {
        VanStockLevel(itemID: "i", onHand: StockQuantity(scaled: scaled), onOrder: onOrder, oldestOrderAt: nil,
                      provenance: .counted, asOf: date(2026, 10, 14, 10, 40), unreliable: false, handedOver: false)
    }

    /// No result carries the stored thousandths, a padded decimal or a bare unit symbol.
    private func assertSpokenPlainly(_ answer: String, file: StaticString = #filePath, line: UInt = #line) {
        for leak in ["4250", "4.250", " l ", " l.", " l,", " kg ", " m ", " ft ", " lb "] {
            XCTAssertFalse(answer.contains(leak), "\(leak) in: \(answer)", file: file, line: line)
        }
    }

    func testMeasuredAmountsAreSaidInWords() {
        let oil = measured("Engine oil", .l)
        let checked = composer.check(oil, level: level(scaled: 4250))
        XCTAssertEqual(checked, "4.25 litres of Engine oil on the van — counted today at 10:40.")
        XCTAssertTrue(composer.check(oil, level: level(scaled: 1000)).hasPrefix("1 litre of Engine oil"))
        XCTAssertTrue(composer.check(measured("Resin", .kg), level: level(scaled: 500)).hasPrefix("0.5 kilograms of Resin"))
        XCTAssertTrue(composer.check(measured("Cable", .m), level: level(scaled: 12_000)).hasPrefix("12 metres of Cable"))
        XCTAssertTrue(composer.check(measured("Grease", .lb), level: level(scaled: 750)).hasPrefix("0.75 pounds of Grease"))
        XCTAssertTrue(composer.check(measured("Duct", .ft), level: level(scaled: 3000)).hasPrefix("3 feet of Duct"))
        assertSpokenPlainly(checked)
    }

    func testEachAndPackReadExactlyAsTheyDid() {
        XCTAssertEqual(composer.check(item(), level: level(2)), "2 × Flame sensor (62-23543-01) on the van — counted today at 10:40.")
        XCTAssertTrue(composer.check(measured("Wire nuts", .pack), level: level(1)).hasPrefix("1 pack of Wire nuts"))
        XCTAssertTrue(composer.check(measured("Wire nuts", .pack), level: level(3)).hasPrefix("3 packs of Wire nuts"))
        XCTAssertEqual(VanStockCountCheck(before: level(18), counted: .whole(16))?.said(.each), ", 2 short of the 18 expected")
        let low = composer.low([(item: measured("Wire nuts", .pack, minimum: .whole(2)), level: level(1))])
        XCTAssertEqual(low, "1 line is low: Wire nuts — 1 left, minimum 2.")
    }

    func testTheCountCheckSaysTheShortfallInWords() {
        XCTAssertEqual(VanStockCountCheck(before: level(scaled: 4500), counted: StockQuantity(scaled: 4250))?.said(.l),
                       ", 0.25 litres short of the 4.5 litres expected")
        let answer = composer.counted(measured("Engine oil", .l), before: level(scaled: 4500), after: level(scaled: 4250), created: false)
        XCTAssertEqual(answer, "Counted: 4.25 litres of Engine oil on the van. The log expected 4.5 litres, so that is "
            + "0.25 litres short.")
        assertSpokenPlainly(answer)
    }

    func testAMeasuredLinesBareFiguresCarryTheirUnit() {
        let oil = measured("Engine oil", .l, minimum: .whole(2))
        let used = composer.used(oil, quantity: StockQuantity(scaled: 2750), before: level(scaled: 4250),
                                 after: level(scaled: 1500), jobReference: nil)
        XCTAssertEqual(used, "Used 2.75 litres of Engine oil. 1.5 litres left, at or below the minimum of 2 litres. "
            + "Offer to ask the office for a replacement, and request one only if the technician says yes.")
        let low = composer.low([(item: oil, level: level(scaled: 1500, onOrder: .whole(5)))])
        XCTAssertEqual(low, "1 line is low: Engine oil — 1.5 litres left, minimum 2 litres (5 litres asked for).")
        assertSpokenPlainly(used + low)
    }

    // MARK: Lists and misses

    func testCandidatesAreListedAndNotChosen() {
        let other = VanStockItem(id: "j", description: "Flame rod", createdBatch: "b0")
        let answer = composer.candidates([item(), other], levels: ["i": level(2)])
        XCTAssertTrue(answer.contains("1. Flame sensor (62-23543-01) — 2 on the van; 2. Flame rod — 0 on the van"), answer)
        XCTAssertTrue(answer.contains("do not choose for them"), answer)
    }

    func testTheClosestLineIsGivenToBeAskedAbout() {
        let answer = composer.closest([item()], to: "frame sensor", levels: ["i": level(2)])
        XCTAssertEqual(answer, "No line on the van list matches 'frame sensor' word for word. The closest on the van: "
            + "2 × Flame sensor (62-23543-01) on the van — counted today at 10:40. It may have been misheard: "
            + "ask the technician whether that is the part; if it is, give them this figure. Do not say there is "
            + "none on the van unless they say it is none of these. Nothing was changed.")
        let other = VanStockItem(id: "j", description: "Flame rod", createdBatch: "b0")
        let both = composer.closest([item(), other], to: "frame sensor", levels: ["i": level(2)])
        XCTAssertTrue(both.contains("1. 2 × Flame sensor (62-23543-01) on the van"), both)
        XCTAssertTrue(both.contains("2. Flame rod is on the van list with nothing recorded against it"), both)
        XCTAssertTrue(both.contains("which, if any, is the part"), both)
        XCTAssertFalse(both.contains("do not look it up again"), both)
    }

    func testAMisheardWriteAsksAndChangesNothing() {
        let use = composer.misheard([item()], reference: "frame sensor", levels: ["i": level(2)], mayCreate: false)
        XCTAssertEqual(use, "Nothing on the van list matches 'frame sensor' word for word, but a word may have been "
            + "misheard. Did they mean Flame sensor (62-23543-01) — 2 on the van? Ask the technician; do not choose "
            + "for them. Nothing was changed.")
        let other = VanStockItem(id: "j", description: "Flame rod", createdBatch: "b0")
        let load = composer.misheard([item(), other], reference: "frame sensor", levels: ["i": level(2)], mayCreate: true)
        XCTAssertTrue(load.contains("Did they mean 1. Flame sensor (62-23543-01) — 2 on the van; 2. Flame rod — 0 on the van?"), load)
        XCTAssertTrue(load.contains("record it again with 'new_line' true"), load)
        XCTAssertTrue(load.hasSuffix("Nothing was changed."), load)
    }

    func testLowWording() {
        XCTAssertEqual(composer.low([]), "Nothing on the van is at or below its minimum.")
        let answer = composer.low([(item(minimum: .whole(2)), level(1, onOrder: .whole(1))), (item(number: nil), level(0))])
        XCTAssertEqual(answer, "2 lines are low: Flame sensor (62-23543-01) — 1 left, minimum 2 (1 asked for); "
            + "Flame sensor — none left.")
    }

    func testAnEmptyVanGivesNoRouteToAGuess() {
        XCTAssertTrue(composer.emptyVan().contains("Do not guess"))
        XCTAssertEqual(composer.notOnVan("14T65"), "Nothing on the van list matches 14T65. Nothing was changed.")
    }

    func testUndoSaysWhatWasTakenBack() {
        var log = VanStockLog()
        let kept = log.addItem(id: "i", number: "62-23543-01", description: "Flame sensor", batch: "b0")
        log.record(.counted, itemID: kept.id, quantity: .whole(1), at: now, batch: "b0", source: .typed)
        let added = log.addItem(id: "j", description: "Flame rod", batch: "b1")
        log.record(.loaded, itemID: kept.id, quantity: .whole(4), at: now, batch: "b1", source: .spoken)
        log.record(.loaded, itemID: added.id, quantity: .whole(2), at: now, batch: "b1", source: .spoken)
        let undone = log.undoLastBatch(at: now, batch: "u1", source: .spoken)!
        XCTAssertEqual(composer.undone(undone, items: log.items),
                       "Undone: the load of 4 × Flame sensor (62-23543-01); the load of 2 × Flame rod. "
                       + "Taken off the van list again: Flame rod.")
        XCTAssertTrue(composer.nothingToUndo().contains("nothing to undo"))
    }

    // MARK: Every place in its own words (Plan MK P1)

    private func composer(_ kind: StockPlace.Kind) -> VanStockAnswerComposer {
        VanStockAnswerComposer(now: now, calendar: calendar, wording: StockPlaceWording(kind))
    }

    /// Everything the composer says, for one place.
    private func everything(_ kind: StockPlace.Kind) -> [String] {
        let c = composer(kind)
        let levels = ["i": level(2)]
        var log = VanStockLog()
        log.addItem(id: "i", number: "62-23543-01", description: "Flame sensor", bin: "Shelf 1", batch: "b0")
        log.record(.counted, itemID: "i", quantity: .whole(2), at: date(2026, 10, 14, 10, 40), batch: "b0", source: .typed)
        log.record(.loaded, itemID: "i", quantity: .whole(1), at: date(2026, 10, 14, 11, 40), batch: "b1", source: .spoken)
        return [
            c.check(item(), level: level(2)),
            c.check(item(), level: level(0)),
            c.check(item(), level: level(2, .inferred, unreliable: true)),
            c.check(item(), level: VanStockLevel(itemID: "i")),
            c.check(item(), level: level(3, .inferred, onOrder: .whole(1), orderedAt: date(2026, 10, 12, 9, 0))),
            c.candidates([item(), item()], levels: levels),
            c.closest([item()], to: "flame", levels: levels),
            c.closest([item(), item()], to: "flame", levels: levels),
            c.misheard([item()], reference: "flame", levels: levels, mayCreate: true),
            c.notOnVan("flame"),
            c.notCarried("flame"),
            c.emptyVan(),
            c.low([]),
            c.low([(item: item(minimum: .whole(2)), level: level(0))]),
            c.loaded(item(verified: false), quantity: .whole(4), before: VanStockLevel(itemID: "i"), after: level(4, .inferred), created: true),
            c.loaded(item(), quantity: .whole(1), before: level(0, onOrder: .whole(1)), after: level(1, .inferred), created: false),
            c.used(item(minimum: .whole(2)), quantity: .whole(1), before: level(2), after: level(1, .inferred), jobReference: "job-7"),
            c.used(item(), quantity: .whole(2), before: level(2), after: level(0, .inferred), jobReference: nil),
            c.removed(item(), quantity: .whole(1), reason: .returned, before: level(2), after: level(1, .inferred)),
            c.counted(item(), before: level(2), after: level(3), created: true),
            c.nothingToUndo(),
            c.list(log, bin: nil),
            c.list(log, bin: "cellar"),
        ]
    }

    func testEveryPlaceIsSpokenOfInItsOwnWords() {
        for kind in StockPlace.Kind.allCases {
            for answer in everything(kind) {
                XCTAssertEqual(StockPlaceWordCheck.violations(answer, kind: kind), [], "\(kind): \(answer)")
            }
            let wording = StockPlaceWording(kind)
            XCTAssertTrue(composer(kind).check(item(), level: level(2)).contains(wording.location), "\(kind)")
            XCTAssertTrue(composer(kind).emptyVan().hasPrefix(StockPlaceWording.capitalised(wording.list)), "\(kind)")
        }
    }

    func testAVanSaysExactlyWhatItAlwaysHas() {
        let van = composer(.van)
        XCTAssertEqual(van.emptyVan(),
                       "The van list is empty: nothing has been loaded or counted yet. The technician can say what "
                       + "they have loaded, count what is on the shelves, or import a spreadsheet from the Van stock "
                       + "screen, to start it. Do not guess what is on the van.")
        XCTAssertEqual(van.notCarried("igniter"),
                       "Nothing on the van list matches igniter, by part number or by name: as far as the van "
                       + "log knows, there is none on the van. Say so — do not look it up again under another "
                       + "name unless the technician gives one. Offer to ask the office for one, and request it "
                       + "only if the technician says yes. Nothing was changed.")
        XCTAssertEqual(van.low([]), "Nothing on the van is at or below its minimum.")
        XCTAssertEqual(van.nothingToUndo(),
                       "There is nothing to undo: the last van stock entry has already been taken back, or there is none.")
        XCTAssertEqual(van.check(item(), level: level(2, .inferred)),
                       "2 × Flame sensor (62-23543-01) on the van — worked out from what was loaded and used, not "
                       + "counted; last changed today at 10:40.")
        XCTAssertEqual(composer.emptyVan(), van.emptyVan(), "a composer given no place is a van")
    }

    func testAStoreSaysItsOwnWords() {
        let store = composer(.store)
        XCTAssertEqual(store.check(item(), level: level(2)), "2 × Flame sensor (62-23543-01) in the store — counted today at 10:40.")
        XCTAssertEqual(store.check(item(), level: level(2, .inferred)),
                       "2 × Flame sensor (62-23543-01) in the store — worked out from what was received and sold or "
                       + "used, not counted; last changed today at 10:40.")
        XCTAssertTrue(store.loaded(item(), quantity: .whole(4), before: level(2), after: level(6, .inferred), created: false)
            .hasPrefix("Received 4 × Flame sensor (62-23543-01). 6 × Flame sensor (62-23543-01) in the store now."))
        XCTAssertTrue(store.used(item(), quantity: .whole(1), before: level(2), after: level(1, .inferred), jobReference: nil)
            .hasPrefix("Sold or used 1 × Flame sensor"))
        XCTAssertTrue(store.emptyVan().contains("the Store stock screen"))
        XCTAssertTrue(composer(.stock).check(item(), level: level(0)).hasPrefix("No Flame sensor (62-23543-01) in stock"))
    }

    // MARK: The first-load read-back gives the reason the lookup supports (Plan MK §4)

    func testTheReadBackSaysWhyTheNumberIsSpelledOut() {
        let unchecked = composer.loaded(item(verified: false), quantity: .whole(1), before: VanStockLevel(itemID: "i"),
                                        after: level(1, .inferred), created: true)
        XCTAssertTrue(unchecked.contains("Part number 62-23543-01 has not been on this list before. Read it back as:"), unchecked)
        XCTAssertFalse(unchecked.contains("manuals"), unchecked)

        var missing = item(verified: false)
        missing.verification = .notFound(in: "Supplier catalogue")
        let notFound = composer.loaded(missing, quantity: .whole(1), before: VanStockLevel(itemID: "i"),
                                       after: level(1, .inferred), created: true)
        XCTAssertTrue(notFound.contains("Part number 62-23543-01 is not in Supplier catalogue and has not been on this list."),
                      notFound)
        XCTAssertTrue(notFound.contains("six two, dash"), notFound)
        XCTAssertTrue(composer.check(missing, level: level(1)).hasSuffix("The part number is not found in Supplier catalogue."))
    }
}
