import XCTest
@testable import OpenGlasses

/// Plan KP P3 — the band check's pure core: the lessons, the moving target, the press order, what a
/// run records, the card's screens and the support report's **Band check** section.
final class BandPracticeTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The id of the button the run asks for now.
    private func target(_ practice: BandPractice) -> String {
        BandPractice.itemID(lesson: practice.lessonIndex, step: practice.step, slot: practice.targetSlot ?? 0)
    }

    /// Press the right button, `gap` seconds after the last.
    private func pressRight(_ practice: inout BandPractice, at time: inout Date, gap: TimeInterval = 0.5)
        -> BandPractice.Outcome {
        time = time.addingTimeInterval(gap)
        return practice.press(target(practice), at: time)
    }

    // MARK: - Lessons

    func testTheThreeLessonsAreOfferedInOrderAndLessonFourIsNot() {
        XCTAssertEqual(BandLesson.offered, [.select, .move, .list])
        XCTAssertFalse(BandLesson.offered.contains(.back))
        // Whatever a caller passes, a run never holds lesson 4.
        XCTAssertEqual(BandPractice(lessons: BandLesson.allCases).lessons, [.select, .move, .list])
        XCTAssertEqual(BandPractice(lessons: [.back]).lessons, BandLesson.offered)
    }

    func testLessonFourIsNeverShownOnTheCardThroughAWholeRun() {
        var practice = BandPractice()
        var time = start
        var titles: [String?] = []
        var lines: [String] = []
        while !practice.isFinished {
            let screen = BandPracticeCardBuilder.screen(for: practice) { _ in }
            titles.append(screen.title)
            lines += screen.lines.map(\.text)
            _ = pressRight(&practice, at: &time)
        }
        lines += BandPracticeCardBuilder.screen(for: practice) { _ in }.lines.map(\.text)
        XCTAssertFalse(lines.contains { $0.contains(BandLesson.back.title) || $0.contains(BandLesson.back.instruction) })
        XCTAssertFalse(lines.contains { $0.contains("of 4") })
    }

    func testLessonOneAdvancesOnThreePressesThenLessonTwo() {
        var practice = BandPractice()
        var time = start
        XCTAssertEqual(practice.currentLesson, .select)
        XCTAssertEqual(pressRight(&practice, at: &time), .advanced)
        XCTAssertEqual(practice.step, 1)
        XCTAssertEqual(pressRight(&practice, at: &time), .advanced)
        XCTAssertEqual(pressRight(&practice, at: &time), .lessonPassed(.select))
        XCTAssertEqual(practice.currentLesson, .move)
        XCTAssertEqual(practice.step, 0)
        XCTAssertEqual(practice.lessonsPassed, 1)
    }

    func testLessonTwosMarkedButtonMovesOnEveryPress() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<3 { _ = pressRight(&practice, at: &time) }
        XCTAssertEqual(practice.currentLesson, .move)
        var slots: [Int] = []
        for _ in 0..<3 {
            slots.append(practice.targetSlot ?? -1)
            _ = pressRight(&practice, at: &time)
        }
        XCTAssertEqual(slots, [1, 0, 1], "starts on the right, then swaps sides each press")
        XCTAssertEqual(practice.currentLesson, .list)
    }

    func testAWrongPressIsRecordedAndDoesNotAdvance() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<3 { _ = pressRight(&practice, at: &time) }
        // Lesson 2, step 0: the marked one is slot 1, so slot 0 is wrong.
        let wrong = BandPractice.itemID(lesson: 1, step: 0, slot: 0)
        XCTAssertEqual(practice.press(wrong, at: time.addingTimeInterval(1)), .wrong)
        XCTAssertEqual(practice.step, 0)
        XCTAssertEqual(practice.currentLesson, .move)
        XCTAssertEqual(practice.wrong, [0, 1, 0])
        XCTAssertEqual(practice.arrived, [3, 0, 0])
    }

    func testLessonThreeTakesTheButtonsInTheOrderShownNotTheirPlaces() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<6 { _ = pressRight(&practice, at: &time) }
        XCTAssertEqual(practice.currentLesson, .list)
        // The first place holds 3, so pressing it first is wrong.
        XCTAssertEqual(practice.press(BandPractice.itemID(lesson: 2, step: 0, slot: 0), at: time), .wrong)
        // The order is 1…6, wherever each sits.
        var places: [Int] = []
        for number in 1...6 {
            places.append(practice.targetSlot ?? -1)
            XCTAssertEqual(BandPractice.listOrder[practice.targetSlot ?? 0], number)
            let outcome = pressRight(&practice, at: &time)
            XCTAssertEqual(outcome, number == 6 ? .finished : .advanced)
        }
        XCTAssertEqual(places, [1, 4, 0, 5, 2, 3])
        XCTAssertTrue(practice.isFinished)
        XCTAssertEqual(practice.lessonsPassed, 3)
        XCTAssertEqual(practice.wrong, [0, 0, 1])
    }

    func testAPressFromAnOlderFrameIsStaleNotWrong() {
        var practice = BandPractice()
        var time = start
        let first = target(practice)
        _ = pressRight(&practice, at: &time)
        // The same button again, as drawn for step 0: the card has moved on.
        XCTAssertEqual(practice.press(first, at: time), .stale)
        XCTAssertEqual(practice.press("kp.next", at: time), .stale, "not one of ours")
        XCTAssertEqual(practice.press(BandPractice.itemID(lesson: 0, step: 1, slot: 4), at: time), .stale,
                       "no such button on this frame")
        XCTAssertEqual(practice.step, 1)
        XCTAssertEqual(practice.wrong, [0, 0, 0])
        XCTAssertEqual(practice.stalePresses, 3)
        XCTAssertEqual(practice.pressTimes.count, 1, "stale presses are not timed")
    }

    // MARK: - Screens

    func testLessonOneScreenIsOneButtonAndDotsThatFill() {
        var practice = BandPractice()
        var time = start
        var screen = BandPracticeCardBuilder.screen(for: practice) { _ in }
        XCTAssertEqual(screen.title, BandPracticeCardBuilder.title)
        XCTAssertEqual(screen.items.map(\.label), ["Press me"])
        XCTAssertEqual(screen.items.map(\.id), ["band.0.0.0"])
        XCTAssertEqual(screen.lines.last?.text, "○○○")
        _ = pressRight(&practice, at: &time)
        screen = BandPracticeCardBuilder.screen(for: practice) { _ in }
        XCTAssertEqual(screen.lines.last?.text, "●○○")
        XCTAssertEqual(screen.items.map(\.id), ["band.0.1.0"], "the id names the new frame")
        XCTAssertTrue(screen.lines.contains { $0.text == "1 of 3 · Select" })
    }

    func testLessonTwoScreenMarksTheTargetAndShowsLessonOnePassed() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<3 { _ = pressRight(&practice, at: &time) }
        let screen = BandPracticeCardBuilder.screen(for: practice) { _ in }
        XCTAssertEqual(screen.items.map(\.label), ["○", "●"])
        XCTAssertEqual(screen.items.map(\.style), [.secondary, .primary])
        XCTAssertEqual(screen.lines.first?.text, "✓ Select")
        XCTAssertTrue(screen.lines.contains { $0.text == "2 of 3 · Move" })
    }

    func testLessonThreeScreenIsSixNumberedButtonsAndTicksTheOnesPressed() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<8 { _ = pressRight(&practice, at: &time) }   // two of lesson 3
        let screen = BandPracticeCardBuilder.screen(for: practice) { _ in }
        XCTAssertEqual(screen.items.count, HUDMenuBuilder.pageSize, "the launcher's six")
        XCTAssertEqual(screen.items.map(\.label), ["3", "✓", "5", "6", "✓", "4"])
        XCTAssertEqual(screen.lines.last?.text, "●●○○○○")
    }

    func testFinishedScreenHasOnlyDone() {
        var practice = BandPractice()
        var time = start
        while !practice.isFinished { _ = pressRight(&practice, at: &time) }
        var pressed: String?
        let screen = BandPracticeCardBuilder.screen(for: practice) { pressed = $0 }
        XCTAssertEqual(screen.items.map(\.id), [BandPractice.doneID])
        XCTAssertEqual(screen.lines.first?.text, "✓ Select ✓ Move ✓ A list")
        screen.items.first?.action()
        XCTAssertEqual(pressed, BandPractice.doneID)
        XCTAssertEqual(practice.press(BandPractice.doneID, at: time), .stale, "Done is not a lesson press")
    }

    // MARK: - Result and report

    func testResultCountsWhatArrivedAndWhatDidNot() {
        var practice = BandPractice()
        var time = start
        _ = pressRight(&practice, at: &time, gap: 0)
        _ = pressRight(&practice, at: &time, gap: 0.42)
        _ = practice.press("band.0.2.0", at: time.addingTimeInterval(1.2))   // the third: right
        time = time.addingTimeInterval(1.2)
        _ = practice.press(BandPractice.itemID(lesson: 1, step: 0, slot: 0), at: time.addingTimeInterval(0.8))
        let result = practice.result(ending: .stopped, backend: "metaRayBan", at: start.addingTimeInterval(30))
        XCTAssertEqual(result.lessonsPassed, 1)
        XCTAssertEqual(result.pressesNotArrived, 9, "three of Move, six of A list")
        XCTAssertEqual(result.wrongPresses, 1)
        XCTAssertEqual(result.intervalsMs, [420, 1200, 800])
        XCTAssertEqual(result.lessons.map(\.lesson), [.select, .move, .list])
    }

    func testTheReportSection() {
        var practice = BandPractice()
        var time = start
        while !practice.isFinished { _ = pressRight(&practice, at: &time, gap: 0.6) }
        _ = practice.press("band.9.9.9", at: time)
        let result = practice.result(ending: .finished, backend: "metaRayBan", at: start)
        let lines = BandCheckReport.lines(for: result, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines, [
            "Band check (last run 2027-01-15 08:00:00, backend metaRayBan, finished):",
            "  Lessons passed: 3 of 3 (select, move, list)",
            "  Presses asked for that didn't arrive: 0",
            "  Wrong presses: 0",
            "  Stale presses dropped: 1",
            "  Time between presses: 11 gaps, median 600 ms, fastest 600 ms, slowest 600 ms",
        ])
    }

    func testTheReportSectionForAShortRunNamesTheLessons() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<4 { _ = pressRight(&practice, at: &time, gap: 1) }
        _ = practice.press(BandPractice.itemID(lesson: 1, step: 1, slot: 1), at: time.addingTimeInterval(2))
        let result = practice.result(ending: .timedOut, backend: "evenG2", at: start)
        let lines = BandCheckReport.lines(for: result, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines[0], "Band check (last run 2027-01-15 08:00:00, backend evenG2, timedOut):")
        XCTAssertEqual(lines[1], "  Lessons passed: 1 of 3 (select)")
        XCTAssertEqual(lines[2], "  Presses asked for that didn't arrive: 8 (move 2, list 6)")
        XCTAssertEqual(lines[3], "  Wrong presses: 1 (move 1)")
        XCTAssertEqual(lines[5], "  Time between presses: 4 gaps, median 1000 ms, fastest 1000 ms, slowest 2000 ms")
    }

    func testTheReportSaysWhenNoCheckHasRun() {
        XCTAssertEqual(BandCheckReport.lines(for: nil), ["Band check: not run on this phone"])
        XCTAssertEqual(BandCheckReport.intervalSummary([]), "none")
    }

    func testIntervalsAreBounded() {
        var practice = BandPractice()
        var time = start
        for _ in 0..<3 { _ = pressRight(&practice, at: &time) }
        for _ in 0..<60 {
            time = time.addingTimeInterval(0.3)
            // Lesson 2, step 0 marks slot 1: slot 0 is wrong every time.
            XCTAssertEqual(practice.press(BandPractice.itemID(lesson: 1, step: 0, slot: 0), at: time), .wrong)
        }
        XCTAssertEqual(practice.result(ending: .stopped, backend: "x", at: time).intervalsMs.count,
                       BandCheckResult.maxIntervals)
    }

    func testTheStoreKeepsTheLastRunOnly() throws {
        let suite = "BandPracticeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BandCheckStore(defaults: defaults)
        XCTAssertNil(store.load())
        let first = BandPractice().result(ending: .stopped, backend: "metaRayBan", at: start)
        store.save(first)
        XCTAssertEqual(store.load(), first)
        var practice = BandPractice()
        var time = start
        _ = pressRight(&practice, at: &time)
        let second = practice.result(ending: .timedOut, backend: "metaRayBan", at: time)
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }
}
