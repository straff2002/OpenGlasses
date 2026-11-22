import XCTest
@testable import OpenGlasses

/// Plan MZ §5 — the live heart rate in memory: fresh for 15 s, then gone; implausible and older
/// readings never replace a newer one.
@MainActor
final class RingLiveReadingsTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_795_000_000)

    private func readings() -> RingLiveReadings {
        RingLiveReadings(clock: { [unowned self] in self.now })
    }

    func testAReadingIsFreshForFifteenSeconds() {
        let live = readings()
        XCTAssertNil(live.fresh)
        live.record(beatsPerMinute: 88, at: now)
        XCTAssertEqual(live.freshBeatsPerMinute, 88)
        now = now.addingTimeInterval(15)
        XCTAssertEqual(live.freshBeatsPerMinute, 88, "fifteen seconds is still fresh")
        now = now.addingTimeInterval(0.5)
        XCTAssertNil(live.freshBeatsPerMinute, "stale after fifteen seconds")
        XCTAssertNotNil(live.latest, "the reading is kept, only no longer handed on as current")
    }

    func testANewReadingKeepsItFresh() {
        let live = readings()
        live.record(beatsPerMinute: 90, at: now)
        now = now.addingTimeInterval(10)
        live.record(beatsPerMinute: 95, at: now)
        now = now.addingTimeInterval(10)
        XCTAssertEqual(live.freshBeatsPerMinute, 95)
    }

    func testImplausibleAndOlderReadingsAreIgnored() {
        let live = readings()
        live.record(beatsPerMinute: 100, at: now)
        live.record(beatsPerMinute: 250, at: now.addingTimeInterval(1))
        live.record(beatsPerMinute: 12, at: now.addingTimeInterval(2))
        live.record(beatsPerMinute: 70, at: now.addingTimeInterval(-5))
        XCTAssertEqual(live.latest?.beatsPerMinute, 100)
    }

    func testAReadingFromTheFutureIsNotFresh() {
        XCTAssertNil(RingLiveReadings.fresh(.init(beatsPerMinute: 80, at: now.addingTimeInterval(60)), now: now))
    }

    func testClearForgetsIt() {
        let live = readings()
        live.record(beatsPerMinute: 80, at: now)
        live.clear()
        XCTAssertNil(live.latest)
    }
}
