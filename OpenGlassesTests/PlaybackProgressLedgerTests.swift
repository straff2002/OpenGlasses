import XCTest
@testable import OpenGlasses

/// Tests for confirmed-played playback accounting (Plan CJ item 6): frames count only when the
/// hardware confirms them, discarded-buffer callbacks are invalidated by generation, and the
/// millisecond conversion is conservative.
final class PlaybackProgressLedgerTests: XCTestCase {

    func testPlayedAccumulatesConfirmedFrames() {
        var ledger = PlaybackProgressLedger()
        let gen = ledger.scheduled(frames: 2400)
        ledger.scheduled(frames: 2400)
        ledger.played(frames: 2400, generation: gen)
        XCTAssertEqual(ledger.playedFrames, 2400)
        XCTAssertEqual(ledger.playedMilliseconds(sampleRate: 24_000), 100)
    }

    func testStaleGenerationCallbackIgnored() {
        var ledger = PlaybackProgressLedger()
        let gen = ledger.scheduled(frames: 2400)
        ledger.reset()   // playerNode.stop() — the buffer was discarded, not heard
        ledger.played(frames: 2400, generation: gen)
        XCTAssertEqual(ledger.playedFrames, 0)
        XCTAssertEqual(ledger.playedMilliseconds(sampleRate: 24_000), 0)
    }

    func testPlayedNeverExceedsScheduled() {
        var ledger = PlaybackProgressLedger()
        let gen = ledger.scheduled(frames: 1000)
        ledger.played(frames: 1000, generation: gen)
        ledger.played(frames: 1000, generation: gen)   // double-fire must not overshoot
        XCTAssertEqual(ledger.playedFrames, 1000)
    }

    func testResetStartsFreshWindow() {
        var ledger = PlaybackProgressLedger()
        let gen1 = ledger.scheduled(frames: 2400)
        ledger.played(frames: 2400, generation: gen1)
        ledger.reset()
        XCTAssertEqual(ledger.playedFrames, 0)
        let gen2 = ledger.scheduled(frames: 4800)
        ledger.played(frames: 4800, generation: gen2)
        XCTAssertEqual(ledger.playedMilliseconds(sampleRate: 24_000), 200)
    }

    func testZeroSampleRateIsSafe() {
        let ledger = PlaybackProgressLedger()
        XCTAssertEqual(ledger.playedMilliseconds(sampleRate: 0), 0)
    }

    func testMillisecondsTruncateDownward() {
        // Conservative direction: partial milliseconds round down, never up.
        var ledger = PlaybackProgressLedger()
        let gen = ledger.scheduled(frames: 100)
        ledger.played(frames: 100, generation: gen)
        XCTAssertEqual(ledger.playedMilliseconds(sampleRate: 24_000), 4)   // 4.1666… → 4
    }
}
