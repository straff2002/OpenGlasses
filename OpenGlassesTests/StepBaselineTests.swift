import XCTest
@testable import OpenGlasses

/// Plan GI P1 — "usual by now" is the median of earlier days at the same clock time, ignoring days
/// the phone stayed home, and says nothing until it has five days to go on.
final class StepBaselineTests: XCTestCase {

    private func day(_ byNow: Double, total: Double = 8000) -> DayStepSample {
        DayStepSample(byNow: byNow, dayTotal: total)
    }

    func testUsualIsTheMedianOfUsableDays() {
        let history = [3000, 5000, 4000, 9000, 4500, 4200].map { day($0) }
        let result = StepBaseline.compare(today: 6200, history: history, asOf: HealthFixture.now)
        XCTAssertEqual(result.usualByNow, 4350)   // median of 3000,4000,4200,4500,5000,9000
        XCTAssertEqual(result.usableDays, 6)
        XCTAssertEqual(result.today, 6200)
    }

    func testDaysUnderFiveHundredStepsAreIgnored() {
        let history = [day(4000), day(4100), day(4200), day(4300), day(4400),
                       day(10, total: 120), day(0, total: 0)]
        let result = StepBaseline.compare(today: 5000, history: history, asOf: HealthFixture.now)
        XCTAssertEqual(result.usableDays, 5)
        XCTAssertEqual(result.usualByNow, 4200)
    }

    func testFewerThanFiveUsableDaysGivesNoComparison() {
        let history = [day(4000), day(4100), day(4200), day(4300), day(0, total: 300)]
        let result = StepBaseline.compare(today: 5000, history: history, asOf: HealthFixture.now)
        XCTAssertNil(result.usualByNow)
        XCTAssertEqual(result.usableDays, 4)
    }

    func testHistoryRangesCoverFourteenEarlierDaysAtTheSameClockTime() {
        let calendar = HealthFixture.calendar
        let now = HealthFixture.at(15, 13, 25)
        let ranges = StepBaseline.historyRanges(now: now, calendar: calendar)
        XCTAssertEqual(ranges.count, 14)
        XCTAssertEqual(ranges.first?.dayStart, HealthFixture.at(14, 0))
        XCTAssertEqual(ranges.first?.sameTime, HealthFixture.at(14, 13, 25))
        XCTAssertEqual(ranges.first?.dayEnd, HealthFixture.at(15, 0))
        XCTAssertEqual(ranges.last?.dayStart, HealthFixture.at(1, 0))
    }

    func testMedianOfAnEvenCountAveragesTheMiddlePair() {
        XCTAssertEqual(StepBaseline.median([1, 2, 3, 10]), 2.5)
        XCTAssertEqual(StepBaseline.median([7]), 7)
        XCTAssertEqual(StepBaseline.median([]), 0)
    }
}
