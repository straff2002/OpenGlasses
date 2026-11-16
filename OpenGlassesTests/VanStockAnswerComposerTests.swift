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

    private func item(number: String? = "62-23543-01", verified: Bool = true, minimum: Int? = nil,
                      unit: VanStockUnit = .each) -> VanStockItem {
        VanStockItem(id: "i", number: number, description: "Flame sensor", unit: unit, minimum: minimum,
                     verified: verified, createdBatch: "b0")
    }

    private func level(_ onHand: Int, _ provenance: VanStockLevel.Provenance = .counted,
                       asOf: Date? = nil, onOrder: Int = 0, orderedAt: Date? = nil,
                       unreliable: Bool = false, handedOver: Bool = false) -> VanStockLevel {
        VanStockLevel(itemID: "i", onHand: onHand, onOrder: onOrder, oldestOrderAt: orderedAt,
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

    func testOnOrderMinimumAndUnverifiedAreAdded() {
        let answer = composer.check(item(verified: false, minimum: 2),
                                    level: level(1, onOrder: 1, orderedAt: date(2026, 10, 12, 9, 0)))
        XCTAssertTrue(answer.contains("1 asked for on Monday and not yet loaded."), answer)
        XCTAssertTrue(answer.contains("That is at or below the minimum of 2."), answer)
        XCTAssertTrue(answer.contains("The part number is not verified against the manuals."), answer)
    }

    func testALineWithNoNumberIsNotCalledUnverified() {
        let answer = composer.check(item(number: nil, verified: false), level: level(2))
        XCTAssertEqual(answer, "2 × Flame sensor on the van — counted today at 10:40.")
    }

    func testUnitsAreSaid() {
        XCTAssertTrue(composer.check(item(number: nil, unit: .m), level: level(10)).hasPrefix("10 m of Flame sensor"))
        XCTAssertTrue(composer.check(item(number: nil, unit: .pack), level: level(1)).hasPrefix("1 pack of Flame sensor"))
    }

    // MARK: Read-backs

    func testALoadReadsBackTheLineAndTheLevel() {
        let answer = composer.loaded(item(), quantity: 4, before: level(2), after: level(6, .inferred), created: false)
        XCTAssertEqual(answer, "Loaded 4 × Flame sensor (62-23543-01). 6 × Flame sensor (62-23543-01) on the van now.")
    }

    func testANewLineWithAnUnknownNumberIsSpelledOut() {
        let answer = composer.loaded(item(verified: false), quantity: 4, before: VanStockLevel(itemID: "i"),
                                     after: level(4, .inferred), created: true)
        XCTAssertTrue(answer.contains("That is a new line on the van list."), answer)
        XCTAssertTrue(answer.contains("six two, dash, two three five four three, dash, zero one"), answer)
        XCTAssertTrue(answer.contains("undo that"), answer)
    }

    func testANewLineWithAVerifiedNumberIsNotSpelledOut() {
        let answer = composer.loaded(item(), quantity: 4, before: VanStockLevel(itemID: "i"),
                                     after: level(4, .inferred), created: true)
        XCTAssertTrue(answer.contains("That is a new line on the van list."), answer)
        XCTAssertFalse(answer.contains("dash"), answer)
    }

    func testALoadSaysWhatItCovered() {
        let ordered = date(2026, 10, 12, 9, 0)
        let all = composer.loaded(item(), quantity: 1, before: level(0, onOrder: 1, orderedAt: ordered),
                                  after: level(1, .inferred), created: false)
        XCTAssertTrue(all.contains("That covers the 1 asked for on Monday."), all)
        let some = composer.loaded(item(), quantity: 1, before: level(0, onOrder: 3, orderedAt: ordered),
                                   after: level(1, .inferred, onOrder: 2, orderedAt: ordered), created: false)
        XCTAssertTrue(some.contains("That covers 1 of the 3 asked for on Monday."), some)
    }

    func testAUseSaysWhatIsLeft() {
        let answer = composer.used(item(), quantity: 1, before: level(3), after: level(2, .inferred),
                                   jobReference: "job-2031")
        XCTAssertEqual(answer, "Used 1 × Flame sensor (62-23543-01) on job job-2031. 2 left.")
    }

    func testTheLastOneOffersARequestAndStops() {
        let answer = composer.used(item(), quantity: 1, before: level(1), after: level(0, .inferred), jobReference: nil)
        XCTAssertTrue(answer.contains("That was the last on the van."), answer)
        XCTAssertTrue(answer.contains("request one only if the technician says yes"), answer)
    }

    func testAtTheMinimumOffersARequest() {
        let answer = composer.used(item(minimum: 2), quantity: 1, before: level(3), after: level(2, .inferred),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("2 left, at or below the minimum of 2."), answer)
        XCTAssertTrue(answer.contains("Offer to ask the office"), answer)
    }

    func testWithOneAlreadyAskedForNoSecondOfferIsMade() {
        let answer = composer.used(item(), quantity: 1, before: level(1, onOrder: 1, orderedAt: date(2026, 10, 12, 9, 0)),
                                   after: level(0, .inferred, onOrder: 1, orderedAt: date(2026, 10, 12, 9, 0)),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("1 asked for on Monday and not yet loaded."), answer)
        XCTAssertFalse(answer.contains("Offer"), answer)
    }

    func testAUseTheLogCannotCoverSaysTheCountIsGone() {
        let answer = composer.used(item(), quantity: 1, before: level(0), after: level(0, .inferred, unreliable: true),
                                   jobReference: nil)
        XCTAssertTrue(answer.contains("The log showed 0, so it cannot say how many are left."), answer)
        XCTAssertFalse(answer.contains("Offer"), answer)
    }

    func testARemovalNamesTheReasonAndMakesNoOffer() {
        let answer = composer.removed(item(), quantity: 1, reason: .returned, before: level(1), after: level(0, .inferred))
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
                       "Counted: 25 m of Thermostat cable on the van. The log expected 30 m, so that is 5 m short.")
        XCTAssertEqual(VanStockCountCheck(before: level(30), counted: 25)?.said(.m), ", 5 m short of the 30 m expected")
        XCTAssertEqual(VanStockCountCheck(before: level(1), counted: 2)?.said(.pack), ", 1 pack over the 1 pack expected")
    }

    // MARK: Lists and misses

    func testCandidatesAreListedAndNotChosen() {
        let other = VanStockItem(id: "j", description: "Flame rod", createdBatch: "b0")
        let answer = composer.candidates([item(), other], levels: ["i": level(2)])
        XCTAssertTrue(answer.contains("1. Flame sensor (62-23543-01) — 2 on the van; 2. Flame rod — 0 on the van"), answer)
        XCTAssertTrue(answer.contains("do not choose for them"), answer)
    }

    func testLowWording() {
        XCTAssertEqual(composer.low([]), "Nothing on the van is at or below its minimum.")
        let answer = composer.low([(item(minimum: 2), level(1, onOrder: 1)), (item(number: nil), level(0))])
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
        log.record(.counted, itemID: kept.id, quantity: 1, at: now, batch: "b0", source: .typed)
        let added = log.addItem(id: "j", description: "Flame rod", batch: "b1")
        log.record(.loaded, itemID: kept.id, quantity: 4, at: now, batch: "b1", source: .spoken)
        log.record(.loaded, itemID: added.id, quantity: 2, at: now, batch: "b1", source: .spoken)
        let undone = log.undoLastBatch(at: now, batch: "u1", source: .spoken)!
        XCTAssertEqual(composer.undone(undone, items: log.items),
                       "Undone: the load of 4 × Flame sensor (62-23543-01); the load of 2 × Flame rod. "
                       + "Taken off the van list again: Flame rod.")
        XCTAssertTrue(composer.nothingToUndo().contains("nothing to undo"))
    }
}
