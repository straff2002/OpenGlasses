import XCTest
@testable import OpenGlasses

/// Plan HW P1. The size and rate of the pictures a stream delivered in its first thirty
/// seconds: measurements to put beside the link level. They are not a way to work the level
/// out, because nothing ties a size or a rate to a radio, so all this type does is count.
final class StreamDeliveryMeterTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func meter(firstPictureAfter warmup: TimeInterval, framesPerSecond: Double,
                       until end: TimeInterval = 40, width: Int = 504,
                       height: Int = 896) -> StreamDeliveryMeter {
        var meter = StreamDeliveryMeter()
        meter.restart(at: start)
        var time = warmup
        while time <= end {
            meter.pictureDelivered(width: width, height: height, at: start + time)
            time += 1 / framesPerSecond
        }
        return meter
    }

    func testNothingIsReportedBeforeTheWindowHasPassed() {
        let meter = meter(firstPictureAfter: 1, framesPerSecond: 30)
        XCTAssertNil(meter.facts(now: start + 10))
        XCTAssertNil(meter.facts(now: start + 29.9))
        XCTAssertNotNil(meter.facts(now: start + 30))
    }

    func testTheSizeAndTheRateAreWhatWasDelivered() throws {
        let facts = try XCTUnwrap(meter(firstPictureAfter: 0, framesPerSecond: 30)
            .facts(now: start + 31))
        XCTAssertEqual(facts.width, 504)
        XCTAssertEqual(facts.height, 896)
        XCTAssertEqual(facts.framesPerSecond, 30, accuracy: 0.5)
    }

    /// The wait for the first picture is a warmup, not a slow stream: 30 fps that took four
    /// seconds to begin is still 30 fps.
    func testTheWarmupBeforeTheFirstPictureDoesNotLowerTheRate() throws {
        let facts = try XCTUnwrap(meter(firstPictureAfter: 4, framesPerSecond: 30)
            .facts(now: start + 31))
        XCTAssertEqual(facts.framesPerSecond, 30, accuracy: 0.5)
    }

    /// A stall after the first picture is part of what was delivered.
    func testAStallAfterTheFirstPictureDoesLowerTheRate() throws {
        let facts = try XCTUnwrap(meter(firstPictureAfter: 0, framesPerSecond: 30, until: 15)
            .facts(now: start + 31))
        XCTAssertEqual(facts.framesPerSecond, 15, accuracy: 0.5)
    }

    func testPicturesAfterTheWindowAreNotCounted() throws {
        // Both run past the window, one by a second and one by a minute and a half. Where the
        // window closes is the meter's decision, so it is the same decision for both.
        let stoppedJustAfter = meter(firstPictureAfter: 0, framesPerSecond: 30, until: 31)
        let ranOn = meter(firstPictureAfter: 0, framesPerSecond: 30, until: 120)
        XCTAssertEqual(stoppedJustAfter.facts(now: start + 200), ranOn.facts(now: start + 200))
        XCTAssertEqual(try XCTUnwrap(ranOn.facts(now: start + 200)).framesPerSecond, 30,
                       accuracy: 0.5, "ninety more seconds of pictures did not raise the rate")
    }

    /// The SDK's ladder can step the source down mid-stream. The size it settled on inside the
    /// window is the one reported.
    func testTheSizeIsTheLastOneInsideTheWindow() throws {
        var meter = StreamDeliveryMeter()
        meter.restart(at: start)
        meter.pictureDelivered(width: 720, height: 1280, at: start + 1)
        meter.pictureDelivered(width: 504, height: 896, at: start + 2)
        meter.pictureDelivered(width: 360, height: 640, at: start + 45)
        let facts = try XCTUnwrap(meter.facts(now: start + 46))
        XCTAssertEqual(facts.width, 504)
        XCTAssertEqual(facts.height, 896)
    }

    func testAStreamThatDeliveredNothingHasNoFacts() {
        var meter = StreamDeliveryMeter()
        meter.restart(at: start)
        XCTAssertNil(meter.facts(now: start + 60))
    }

    func testAMeterThatWasNeverStartedCountsNothing() {
        var meter = StreamDeliveryMeter()
        meter.pictureDelivered(width: 504, height: 896, at: start)
        XCTAssertNil(meter.facts(now: start + 60))
    }

    func testARestartForgetsTheStreamBefore() {
        var meter = meter(firstPictureAfter: 0, framesPerSecond: 30)
        meter.restart(at: start + 100)
        XCTAssertNil(meter.facts(now: start + 140), "the new stream has delivered nothing yet")
    }

    /// The meter has no notion of a link at all. There is nothing in its answer but a size and
    /// a rate, so there is nothing a caller could mistake for a level.
    func testTheFactsAreASizeAndARateAndNothingElse() throws {
        let facts = try XCTUnwrap(meter(firstPictureAfter: 0, framesPerSecond: 30)
            .facts(now: start + 31))
        XCTAssertEqual(Mirror(reflecting: facts).children.compactMap(\.label),
                       ["width", "height", "framesPerSecond"])
    }
}
