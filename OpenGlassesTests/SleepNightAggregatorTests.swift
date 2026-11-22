import XCTest
@testable import OpenGlasses

/// Plan GI P1 — "last night" from the shapes Health actually holds: a phone's in-bed schedule, a
/// watch's staged night, both at once, a split night and a nap.
final class SleepNightAggregatorTests: XCTestCase {

    private typealias F = HealthFixture
    private let calendar = HealthFixture.calendar

    private func aggregate(_ samples: [SleepSample], now: Date = HealthFixture.now) -> SleepNight? {
        SleepNightAggregator.aggregate(samples, now: now, calendar: calendar)
    }

    func testTheWindowRunsFromSixYesterdayEveningToTwoThisAfternoon() {
        let window = SleepNightAggregator.window(endingOn: F.now, calendar: calendar)
        XCTAssertEqual(window.start, F.at(14, 18))
        XCTAssertEqual(window.end, F.at(15, 14))
    }

    func testASplitNightIsOneNightWithOneAwakening() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 23), F.at(15, 2), .asleepUnspecified, source: "phone"),
            F.sleep(F.at(15, 3), F.at(15, 7), .asleepUnspecified, source: "phone"),
        ]))
        XCTAssertEqual(night.asleep, F.hours(7))
        XCTAssertEqual(night.awakenings, 1)
        XCTAssertEqual(night.morning, calendar.startOfDay(for: F.now))
    }

    func testANapIsNotPartOfTheNight() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 15), F.at(14, 16), .asleepUnspecified),   // yesterday afternoon: outside
            F.sleep(F.at(14, 23), F.at(15, 7), .asleepUnspecified),
            F.sleep(F.at(15, 12), F.at(15, 13), .asleepUnspecified),   // today's nap: its own session
        ], now: F.at(15, 13, 30)))
        XCTAssertEqual(night.asleep, F.hours(8))
        XCTAssertEqual(night.awakenings, 0)
    }

    func testAWatchsStagedNightIsPreferredOverThePhonesCoarseBlock() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 22, 30), F.at(15, 7, 30), .inBed, source: "phone"),
            F.sleep(F.at(14, 23), F.at(15, 7), .asleepUnspecified, source: "phone"),
            F.sleep(F.at(14, 23, 30), F.at(15, 1, 30), .asleepCore, source: "watch"),
            F.sleep(F.at(15, 1, 30), F.at(15, 2, 30), .asleepDeep, source: "watch"),
            F.sleep(F.at(15, 2, 30), F.at(15, 2, 40), .awake, source: "watch"),
            F.sleep(F.at(15, 2, 40), F.at(15, 4), .asleepREM, source: "watch"),
            F.sleep(F.at(15, 4), F.at(15, 6, 30), .asleepCore, source: "watch"),
        ]))
        // 2h + 1h + 1h20 + 2h30 from the watch alone; the phone's 8h block does not pad it.
        XCTAssertEqual(night.asleep, F.hours(6) + 50 * 60)
        XCTAssertEqual(night.inBed, F.hours(9))
        XCTAssertEqual(night.stages?.deep, F.hours(1))
        XCTAssertEqual(night.stages?.rem, F.hours(1) + 20 * 60)
        XCTAssertEqual(night.stages?.core, F.hours(4) + 30 * 60)
        XCTAssertEqual(night.awakenings, 1, "the ten-minute awake gap counts; nothing else does")
    }

    func testStagesAreAbsentWhenNoSourceRecordsThem() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 23), F.at(15, 6, 40), .asleepUnspecified, source: "phone"),
        ]))
        XCTAssertNil(night.stages)
        XCTAssertEqual(night.asleep, F.hours(7) + 40 * 60)
    }

    func testInBedOnlyReportsTimeInBedAndNoSleep() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 22, 30), F.at(15, 7), .inBed, source: "phone"),
        ]))
        XCTAssertNil(night.asleep)
        XCTAssertEqual(night.inBed, F.hours(8.5))
    }

    func testAShortBreakIsNotAnAwakening() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 23), F.at(15, 3), .asleepCore),
            F.sleep(F.at(15, 3, 4), F.at(15, 7), .asleepCore),
        ]))
        XCTAssertEqual(night.awakenings, 0)
    }

    func testTwoStageTrackersAreNotDoubleCounted() throws {
        let night = try XCTUnwrap(aggregate([
            F.sleep(F.at(14, 23), F.at(15, 1), .asleepDeep, source: "watch"),
            F.sleep(F.at(15, 1), F.at(15, 7), .asleepCore, source: "watch"),
            F.sleep(F.at(14, 23), F.at(15, 0), .asleepDeep, source: "ring"),
            F.sleep(F.at(15, 0), F.at(15, 6), .asleepCore, source: "ring"),
        ]))
        XCTAssertEqual(night.asleep, F.hours(8), "asleep time is the union, not the sum")
        XCTAssertEqual(night.stages?.deep, F.hours(2), "stages come from the busier tracker alone")
    }

    /// Plan MZ P1: a smart ring writes light and deep runs and no REM. Worn beside a watch, the
    /// night is the union of the two, never their sum, and the stages come from whichever recorded
    /// more staged time.
    func testARingBesideAWatchIsNotAddedAndTheBusierSourceGivesTheStages() throws {
        let clock = RingClock(offsetSeconds: 0)
        let ringStart = clock.ringSeconds(for: F.at(14, 23, 30))
        // 6 h 30 from the ring: 23:30 → 06:00, the second hour deep.
        let packets = (0..<26).map { index in
            RingSleepPacket(ringSeconds: ringStart + UInt32(index) * 900,
                            minutes: Array(repeating: (4..<8).contains(index) ? .deep : .light, count: 15))
        }
        let ring = RingSleepTimeline.runs(from: packets, clock: clock)
            .map { F.sleep($0.start, $0.end, $0.stage, source: "ring") }
        let watch = [
            F.sleep(F.at(14, 23), F.at(15, 1), .asleepCore, source: "watch"),
            F.sleep(F.at(15, 1), F.at(15, 2), .asleepDeep, source: "watch"),
            F.sleep(F.at(15, 2), F.at(15, 3, 30), .asleepREM, source: "watch"),
            F.sleep(F.at(15, 3, 30), F.at(15, 7), .asleepCore, source: "watch"),
        ]

        let both = try XCTUnwrap(aggregate(ring + watch))
        XCTAssertEqual(both.asleep, F.hours(8), "23:00 → 07:00 once, not the ring's 6 h 30 added on")
        XCTAssertEqual(both.stages?.rem, F.hours(1.5), "the watch recorded more staged time")
        XCTAssertEqual(both.stages?.deep, F.hours(1))

        let ringAlone = try XCTUnwrap(aggregate(ring))
        XCTAssertEqual(ringAlone.asleep, F.hours(6.5))
        XCTAssertEqual(ringAlone.stages?.deep, F.hours(1))
        XCTAssertEqual(ringAlone.stages?.core, F.hours(5.5))
        XCTAssertEqual(ringAlone.stages?.rem, 0)
    }

    func testNothingInTheWindowIsNoNight() {
        XCTAssertNil(aggregate([F.sleep(F.at(13, 23), F.at(14, 7), .asleepCore)]))
        XCTAssertNil(aggregate([]))
    }
}
