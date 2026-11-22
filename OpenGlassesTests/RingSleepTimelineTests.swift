import XCTest
@testable import OpenGlasses

/// Plan MZ P0 — the ring's sleep packets become merged runs in the app's `SleepStage`.
final class RingSleepTimelineTests: XCTestCase {

    private typealias F = RingFixture
    private let driver = SmartRingDriver()
    private let utc = RingClock(offsetSeconds: 0)

    private func packets(_ raw: [[UInt8]]) -> [RingSleepPacket] {
        raw.flatMap { driver.decode($0) }.compactMap {
            if case .sleep(let packet) = $0 { return packet }
            return nil
        }
    }

    private func total(_ runs: [RingSleepRun], _ stage: SleepStage) -> TimeInterval {
        runs.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }

    /// The morning capture the notes matched against the vendor's app: 20 packets, 18 light and 2
    /// deep, five hours from 01:30.
    private func fiveHourNight() -> [[UInt8]] {
        (0..<20).map { index in
            F.sleepPacket(at: F.sleepLight0130 + UInt32(index) * 900, all: (3...4).contains(index) ? F.deep : F.light)
        }
    }

    func testAFiveHourNightIsFourAndAHalfHoursLightAndHalfAnHourDeep() {
        let runs = RingSleepTimeline.runs(from: packets(fiveHourNight()), clock: utc)
        XCTAssertEqual(total(runs, .asleepCore), 4.5 * 3600)
        XCTAssertEqual(total(runs, .asleepDeep), 30 * 60)
        XCTAssertEqual(runs.map(\.stage), [.asleepCore, .asleepDeep, .asleepCore], "runs of a stage are merged")
        XCTAssertEqual(runs.first?.start, Date(timeIntervalSince1970: TimeInterval(F.sleepLight0130)))
        XCTAssertEqual(runs.last?.end, Date(timeIntervalSince1970: TimeInterval(F.sleepLight0130) + 5 * 3600))
    }

    func testThePublishedExamplesStartAtOneThirtyAndTwoFifteen() {
        let runs = RingSleepTimeline.runs(from: packets([
            F.hex("11989a176a282828282828282828282828282828"),
            F.hex("1124a5176a636363636363636363636363636363"),
        ]), clock: utc)
        XCTAssertEqual(runs.count, 2, "45 minutes apart with nothing between: two runs, not one")
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utcCalendar.dateComponents([.hour, .minute], from: runs[0].start), DateComponents(hour: 1, minute: 30))
        XCTAssertEqual(utcCalendar.dateComponents([.hour, .minute], from: runs[1].start), DateComponents(hour: 2, minute: 15))
        XCTAssertEqual(runs[1].stage, .asleepDeep)
    }

    func testAZeroMinuteIsAGapNotAwake() {
        let values = Array(repeating: F.light, count: 5) + Array(repeating: 0x00, count: 5)
            + Array(repeating: F.light, count: 5)
        let runs = RingSleepTimeline.runs(from: packets([F.sleepPacket(at: 0, values)]), clock: utc)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(total(runs, .asleepCore), 10 * 60)
        XCTAssertFalse(runs.contains { $0.stage == .awake })
        XCTAssertEqual(runs[1].start.timeIntervalSince(runs[0].end), 5 * 60)
    }

    func testAnUnknownValueIsAGapToo() {
        let values = Array(repeating: F.deep, count: 7) + [0x50] + Array(repeating: F.deep, count: 7)
        let runs = RingSleepTimeline.runs(from: packets([F.sleepPacket(at: 0, values)]), clock: utc)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(total(runs, .asleepDeep), 14 * 60)
    }

    func testPacketsOutOfOrderGiveTheSameRuns() {
        var shuffled = fiveHourNight()
        shuffled.reverse()
        shuffled.swapAt(2, 11)
        XCTAssertEqual(RingSleepTimeline.runs(from: packets(shuffled), clock: utc),
                       RingSleepTimeline.runs(from: packets(fiveHourNight()), clock: utc))
    }

    func testAPacketSeenTwiceCountsOnce() {
        let night = fiveHourNight()
        let runs = RingSleepTimeline.runs(from: packets(night + [night[0], night[7]]), clock: utc)
        XCTAssertEqual(total(runs, .asleepCore) + total(runs, .asleepDeep), 5 * 3600)
    }

    func testRunsAreDecodedWithTheGivenClock() {
        let clock = RingClock(offsetSeconds: 2 * 3600)
        let runs = RingSleepTimeline.runs(from: packets([F.sleepPacket(at: 10_800, all: F.light)]), clock: clock)
        XCTAssertEqual(runs.first?.start, Date(timeIntervalSince1970: 3600))
    }

    func testATimestampAtTheEndOfTheRangeIsDroppedNotACrash() {
        let runs = RingSleepTimeline.runs(from: packets([F.sleepPacket(at: UInt32.max - 120, all: F.light)]), clock: utc)
        XCTAssertEqual(runs.reduce(0) { $0 + $1.duration }, 2 * 60, "only the minutes that fit")
    }

    func testNoPacketsNoRuns() {
        XCTAssertEqual(RingSleepTimeline.runs(from: [], clock: utc), [])
        XCTAssertEqual(RingSleepTimeline.runs(from: packets([F.sleepPacket(at: 0, all: 0)]), clock: utc), [])
    }
}
