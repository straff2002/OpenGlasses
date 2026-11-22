import XCTest
@testable import OpenGlasses

/// Plan MZ §3 — the ring counts local wall-clock seconds; the latched offset converts both ways,
/// half-hour zones included, and a night keeps the offset it was recorded under.
final class RingClockTests: XCTestCase {

    /// 2026-05-26 21:47:10 UTC: the moment the protocol's time-sync example stands for at −4 h.
    private let exampleMoment = Date(timeIntervalSince1970: 1_779_832_030)

    func testTheExampleTimeSync() {
        let sync = RingClock(offsetSeconds: -4 * 3600).timeSync(at: exampleMoment)
        XCTAssertEqual(sync.ringSeconds, 0x6a15_dc9e)
        XCTAssertEqual(sync.wholeHourOffset, -4)
        XCTAssertEqual(SmartRingDriver().encode(.timeSync(sync)),
                       RingFixture.hex("019edc156afc0000000000000000000000000000"))
    }

    func testRoundTripAcrossOffsets() {
        for offset in [-12 * 3600, -4 * 3600, -12_600, 0, 3600, 19_800, 45_900, 14 * 3600] {
            let clock = RingClock(offsetSeconds: offset)
            let seconds = clock.ringSeconds(for: exampleMoment)
            XCTAssertEqual(Int64(seconds), 1_779_832_030 + Int64(offset), "offset \(offset)")
            XCTAssertEqual(clock.date(fromRingSeconds: seconds), exampleMoment, "offset \(offset)")
        }
    }

    /// +5:30: the hour field truncates to 5, but the seconds carry the full offset and decoding
    /// uses those, so a reading lands at the right minute rather than half an hour out.
    func testAHalfHourZoneDecodesFromTheLatchedSeconds() throws {
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let clock = RingClock.latching(kolkata, at: exampleMoment)
        XCTAssertEqual(clock.offsetSeconds, 19_800)
        let sync = clock.timeSync(at: exampleMoment)
        XCTAssertEqual(sync.wholeHourOffset, 5)
        XCTAssertEqual(SmartRingDriver().encode(.timeSync(sync))[5], 0x05)
        XCTAssertEqual(clock.date(fromRingSeconds: sync.ringSeconds), exampleMoment)
    }

    func testANegativeHalfHourZoneTruncatesTowardZero() {
        let sync = RingClock(offsetSeconds: -12_600).timeSync(at: exampleMoment)
        XCTAssertEqual(sync.wholeHourOffset, -3)
        XCTAssertEqual(SmartRingDriver().encode(.timeSync(sync))[5], 0xfd)
    }

    func testLatchingIncludesDaylightSaving() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(RingClock.latching(london, at: exampleMoment).offsetSeconds, 3600, "May is summer time")
        let january = Date(timeIntervalSince1970: 1_767_225_600)
        XCTAssertEqual(RingClock.latching(london, at: january).offsetSeconds, 0)
    }

    /// A night recorded at +1 h and fetched after the phone moved to +3 h decodes right only with
    /// the clock it was recorded under; the new clock would put it two hours early.
    func testANightRecordedUnderAnOlderOffset() {
        let old = RingClock(offsetSeconds: 3600)
        let new = RingClock(offsetSeconds: 3 * 3600)
        let asleepAt = Date(timeIntervalSince1970: 1_779_926_400)  // 00:00 UTC
        let stamped = old.ringSeconds(for: asleepAt)
        XCTAssertEqual(old.date(fromRingSeconds: stamped), asleepAt)
        XCTAssertEqual(new.date(fromRingSeconds: stamped), asleepAt.addingTimeInterval(-2 * 3600))
    }

    func testTheClockIsCodableForThePairingRecord() throws {
        let clock = RingClock(offsetSeconds: 19_800)
        let data = try JSONEncoder().encode(clock)
        XCTAssertEqual(try JSONDecoder().decode(RingClock.self, from: data), clock)
    }
}
