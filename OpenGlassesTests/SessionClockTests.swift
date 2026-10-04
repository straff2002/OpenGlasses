import XCTest
@testable import OpenGlasses

/// The recorded job's clock: times as whole milliseconds, and wall-stamped moments placed on it.
final class SessionClockTests: XCTestCase {
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    func testATimeIsWholeMillisecondsRoundedHalfAwayFromZero() {
        XCTAssertEqual(t(12.345).milliseconds, 12_345)
        XCTAssertEqual(t(0.1 + 0.2).milliseconds, 300, "binary fractions do not leak into a time")
        XCTAssertEqual(t(45.0004).milliseconds, 45_000)
        XCTAssertEqual(t(57.9996).milliseconds, 58_000)
        XCTAssertEqual(t(1.0625).milliseconds, 1_063, "a half goes away from zero")
        XCTAssertEqual(t(-1.0625).milliseconds, -1_063)
        XCTAssertEqual(t(139.888).seconds, 139.888)
    }

    func testAReadingThatIsNotANumberIsZeroAndOnePastTheLimitStopsAtIt() {
        XCTAssertEqual(t(.nan), .zero)
        XCTAssertEqual(t(.infinity), .zero)
        XCTAssertEqual(t(1e300).milliseconds, SessionTime.limit)
        XCTAssertEqual(t(-1e300).milliseconds, -SessionTime.limit)
    }

    func testTimesCompareAddAndSubtractAsIntegers() {
        XCTAssertLessThan(t(1.999), t(2))
        XCTAssertEqual(t(12.5) + t(0.25), t(12.75))
        XCTAssertEqual(t(12) - t(17.001), SessionTime(milliseconds: -5_001))
        XCTAssertEqual([t(3), t(1), t(2)].sorted(), [t(1), t(2), t(3)])
    }

    func testATimeIsWrittenAsAnExactDecimalWithAtMostThreePlaces() throws {
        func written(_ time: SessionTime) throws -> String {
            String(decoding: try JSONEncoder().encode([time]), as: UTF8.self)
        }
        XCTAssertEqual(try written(t(39.6)), "[39.6]")
        XCTAssertEqual(try written(t(0.1 + 0.2)), "[0.3]")
        XCTAssertEqual(try written(t(139.888)), "[139.888]")
        XCTAssertEqual(try written(t(120)), "[120]")
        XCTAssertEqual(try written(t(0.25)), "[0.25]")
        XCTAssertEqual(try written(t(-2.5)), "[-2.5]")
    }

    func testATimeReadWithMorePlacesIsRoundedAndOneOutOfRangeIsRefused() throws {
        func read(_ json: String) throws -> [SessionTime] {
            try JSONDecoder().decode([SessionTime].self, from: Data(json.utf8))
        }
        XCTAssertEqual(try read("[46.0006, 12, 0.3000000000000004, 1e2]"), [t(46.001), t(12), t(0.3), t(100)])
        XCTAssertThrowsError(try read("[1e300]"))
        XCTAssertThrowsError(try read(#"["12"]"#))
        XCTAssertThrowsError(try read("[true]"))
    }

    func testAMonotonicReadingIsCountedFromTheStart() {
        let clock = SessionClock(wallStart: Date(timeIntervalSince1970: 1_800_000_000), monotonicStart: 5_000.25)
        XCTAssertEqual(clock.time(monotonic: 5_000.25), .zero)
        XCTAssertEqual(clock.time(monotonic: 5_012.75), t(12.5))
        XCTAssertEqual(clock.time(monotonic: 4_999.25), t(-1), "before the start is negative, not clamped")
        XCTAssertEqual(clock.wallStartMilliseconds, 1_800_000_000_000)
    }

    func testAWallStampedMomentIsPlacedThroughTheStartPair() {
        let start = Date(timeIntervalSince1970: 1_800_000_000.5)
        let clock = SessionClock(wallStart: start, monotonicStart: 77)
        XCTAssertEqual(clock.wallStartMilliseconds, 1_800_000_000_500)
        XCTAssertEqual(clock.time(wall: start.addingTimeInterval(131.25)), t(131.25))
        XCTAssertEqual(clock.time(wall: start.addingTimeInterval(-3)), t(-3))
        XCTAssertEqual(clock.wallDate(at: t(131.25)), start.addingTimeInterval(131.25))
        // The monotonic start plays no part in placing a wall time.
        XCTAssertEqual(SessionClock(wallStart: start, monotonicStart: 9_000).time(wall: start), .zero)
    }
}
