import XCTest
@testable import OpenGlasses

/// Plan GI P1 — a heart rate is "current" for two hours; a resting rate is today's, else the most
/// recent from the last three days.
final class HeartRateSummaryTests: XCTestCase {

    private typealias F = HealthFixture
    private let calendar = HealthFixture.calendar

    private func reading(_ bpm: Double, _ date: Date) -> HeartRateReading {
        HeartRateReading(beatsPerMinute: bpm, date: date)
    }

    func testALatestReadingWithinTwoHoursIsKept() {
        let summary = HeartRateSummary.summarize(latest: reading(72, F.at(15, 8, 50)), resting: [],
                                                 now: F.now, calendar: calendar)
        XCTAssertEqual(summary.latest?.beatsPerMinute, 72)
        XCTAssertEqual(summary.asOf, F.now)
    }

    func testALatestReadingOlderThanTwoHoursIsDropped() {
        let summary = HeartRateSummary.summarize(latest: reading(72, F.at(15, 6, 59)), resting: [],
                                                 now: F.now, calendar: calendar)
        XCTAssertNil(summary.latest)
    }

    func testTodaysRestingRateWins() {
        let summary = HeartRateSummary.summarize(
            latest: nil,
            resting: [reading(61, F.at(13, 6)), reading(58, F.at(15, 7)), reading(60, F.at(14, 6))],
            now: F.now, calendar: calendar)
        XCTAssertEqual(summary.resting?.beatsPerMinute, 58)
    }

    func testTheMostRecentRestingRateWithinThreeDaysIsUsedWhenTodayHasNone() {
        let summary = HeartRateSummary.summarize(
            latest: nil, resting: [reading(61, F.at(12, 6)), reading(60, F.at(13, 6))],
            now: F.now, calendar: calendar)
        XCTAssertEqual(summary.resting?.beatsPerMinute, 60)
    }

    func testARestingRateOlderThanThreeDaysIsNotUsed() {
        let summary = HeartRateSummary.summarize(latest: nil, resting: [reading(61, F.at(11, 23))],
                                                 now: F.now, calendar: calendar)
        XCTAssertNil(summary.resting)
        XCTAssertEqual(HeartRateSummary.restingSearchStart(now: F.now, calendar: calendar), F.at(12, 0))
    }

    func testFutureReadingsAreIgnored() {
        let summary = HeartRateSummary.summarize(latest: reading(90, F.at(15, 9, 30)),
                                                 resting: [reading(55, F.at(15, 10))],
                                                 now: F.now, calendar: calendar)
        XCTAssertNil(summary.latest)
        XCTAssertNil(summary.resting)
    }
}
