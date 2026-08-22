import XCTest
@testable import OpenGlasses

/// Plan CW P2. The mirror of what the player node still owes — the thing that lets a graph rebuild
/// carry queued reply audio across instead of destroying it, and lets an unavoidable loss be
/// reported instead of sounding like the assistant never spoke.
final class PendingPlaybackMirrorTests: XCTestCase {

    /// 24 kHz mono Int16: 48 bytes per millisecond.
    private func pcm(milliseconds: Int) -> (Data, UInt32) {
        let frames = 24 * milliseconds
        return (Data(count: frames * 2), UInt32(frames))
    }

    private func mirror(byteLimitMilliseconds: Int = 10_000) -> PendingPlaybackMirror {
        PendingPlaybackMirror(byteLimit: 24 * 2 * byteLimitMilliseconds)
    }

    private func schedule(
        _ mirror: inout PendingPlaybackMirror,
        milliseconds: Int,
        generation: UInt64 = 0
    ) -> Bool {
        let (data, frames) = pcm(milliseconds: milliseconds)
        return mirror.scheduled(pcm: data, frames: frames, generation: generation)
    }

    // MARK: - Scheduling and retirement

    func testStartsEmpty() {
        let m = mirror()
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.outstandingFrames, 0)
        XCTAssertEqual(m.byteCount, 0)
    }

    func testScheduledBufferBecomesOutstanding() {
        var m = mirror()
        XCTAssertTrue(schedule(&m, milliseconds: 100))
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.outstandingFrames, 2400)
    }

    func testEmptyOrZeroFrameBufferIsNotMirrored() {
        var m = mirror()
        XCTAssertFalse(m.scheduled(pcm: Data(), frames: 0, generation: 0))
        XCTAssertFalse(m.scheduled(pcm: Data(count: 10), frames: 0, generation: 0))
        XCTAssertTrue(m.isEmpty)
    }

    /// A completion callback retires exactly one buffer — the oldest of its generation, because
    /// the node plays them in the order they were scheduled.
    func testRetireDropsTheOldestBufferOfThatGeneration() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100)
        _ = schedule(&m, milliseconds: 250)
        m.retire(generation: 0)
        XCTAssertEqual(m.outstandingFrames, 24 * 250)
        XCTAssertEqual(m.byteCount, 24 * 250 * 2)
    }

    /// A callback from a superseded generation is a buffer `stop()` discarded, not one that was
    /// heard — it retires nothing, exactly as the ledger ignores it.
    func testRetireIgnoresASupersededGeneration() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100, generation: 3)
        m.retire(generation: 2)
        XCTAssertEqual(m.outstandingFrames, 2400)
    }

    func testRetireOnAnEmptyMirrorIsHarmless() {
        var m = mirror()
        m.retire(generation: 0)
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.byteCount, 0)
    }

    func testFullyRetiredMirrorReturnsToEmpty() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100)
        _ = schedule(&m, milliseconds: 100)
        m.retire(generation: 0)
        m.retire(generation: 0)
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.byteCount, 0)
        XCTAssertEqual(m.outstandingFrames, 0)
    }

    // MARK: - Carry-over

    func testDrainHandsBackTheSurvivorsInOrderAndEmpties() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100, generation: 7)
        _ = schedule(&m, milliseconds: 200, generation: 7)
        let survivors = m.drain()
        XCTAssertEqual(survivors.map(\.frames), [2400, 4800])
        XCTAssertEqual(survivors.map(\.generation), [7, 7])
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.byteCount, 0)
    }

    /// The generation rides along: re-scheduling under it is what keeps the ledger's played-count
    /// continuous across a rebuild rather than restarting at zero.
    func testDrainPreservesTheOriginalGeneration() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 50, generation: 42)
        XCTAssertEqual(m.drain().first?.generation, 42)
    }

    // MARK: - Loss accounting

    func testDiscardAllReportsEverythingOutstanding() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100)
        _ = schedule(&m, milliseconds: 400)
        XCTAssertEqual(m.discardAll(), UInt64(24 * 500))
        XCTAssertTrue(m.isEmpty)
    }

    func testDiscardAllOnAnEmptyMirrorReportsNothing() {
        var m = mirror()
        XCTAssertEqual(m.discardAll(), 0)
    }

    func testDiscardAllIsNotDoubleCounted() {
        var m = mirror()
        _ = schedule(&m, milliseconds: 100)
        XCTAssertEqual(m.discardAll(), 2400)
        XCTAssertEqual(m.discardAll(), 0)
    }

    // MARK: - The bound

    /// Refusing the newest keeps what is about to play contiguous; evicting the oldest would punch
    /// a gap into it and re-order what follows.
    func testTheBoundRefusesTheNewestNotTheOldest() {
        var m = mirror(byteLimitMilliseconds: 300)
        XCTAssertTrue(schedule(&m, milliseconds: 200))
        XCTAssertFalse(schedule(&m, milliseconds: 200))
        XCTAssertEqual(m.outstandingFrames, 24 * 200, "the first buffer must survive")
    }

    func testABufferThatExactlyFillsTheBoundIsAccepted() {
        var m = mirror(byteLimitMilliseconds: 200)
        XCTAssertTrue(schedule(&m, milliseconds: 200))
    }

    /// Refused frames were scheduled and unheard just the same; leaving them out would make the
    /// loss report flatter than the truth.
    func testRefusedFramesStillCountAsLost() {
        var m = mirror(byteLimitMilliseconds: 300)
        _ = schedule(&m, milliseconds: 200)
        _ = schedule(&m, milliseconds: 500)
        XCTAssertEqual(m.discardAll(), UInt64(24 * 700))
    }

    /// Carry-over is the good case: what could be mirrored comes across, and the refused tail is
    /// not left behind as a phantom loss on the next discard.
    func testDrainClearsTheRefusedTally() {
        var m = mirror(byteLimitMilliseconds: 300)
        _ = schedule(&m, milliseconds: 200)
        _ = schedule(&m, milliseconds: 500)
        _ = m.drain()
        XCTAssertEqual(m.discardAll(), 0)
    }

    /// Retiring frees room, so a long session of ordinary playback never wedges the mirror shut.
    func testRetiringMakesRoomForNewBuffers() {
        var m = mirror(byteLimitMilliseconds: 300)
        _ = schedule(&m, milliseconds: 200)
        XCTAssertFalse(schedule(&m, milliseconds: 200))
        m.retire(generation: 0)
        XCTAssertTrue(schedule(&m, milliseconds: 200))
    }

    // MARK: - Duration

    func testMillisecondsMatchesTheLedgerConvention() {
        XCTAssertEqual(PendingPlaybackMirror.milliseconds(frames: 24000, sampleRate: 24000), 1000)
        XCTAssertEqual(PendingPlaybackMirror.milliseconds(frames: 2400, sampleRate: 24000), 100)
    }

    func testMillisecondsIsZeroForAnInvalidSampleRate() {
        XCTAssertEqual(PendingPlaybackMirror.milliseconds(frames: 24000, sampleRate: 0), 0)
    }

    /// The two numbers a loss report compares are computed the same way, so they are commensurable.
    func testMillisecondsAgreesWithThePlaybackLedger() {
        var ledger = PlaybackProgressLedger()
        let generation = ledger.scheduled(frames: 12000)
        ledger.played(frames: 12000, generation: generation)
        XCTAssertEqual(
            ledger.playedMilliseconds(sampleRate: 24000),
            PendingPlaybackMirror.milliseconds(frames: 12000, sampleRate: 24000)
        )
    }
}
