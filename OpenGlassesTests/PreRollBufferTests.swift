import XCTest
@testable import OpenGlasses

/// Plan GU §5 — the pre-roll ring and the hand-over to live recognition.
final class PreRollBufferTests: XCTestCase {

    /// Samples whose value is their own sequence number, so loss and duplication are visible.
    private func sequence(_ range: Range<Int>) -> [Float] { range.map(Float.init) }

    func testHoldsEverythingUntilFull() {
        var ring = PreRollBuffer(capacity: 8)
        ring.write(sequence(0..<5))
        let held = ring.contents()
        XCTAssertEqual(held.samples, sequence(0..<5))
        XCTAssertEqual(held.firstSequence, 0)
    }

    func testWrapAroundKeepsTheNewestOldestFirst() {
        var ring = PreRollBuffer(capacity: 8)
        ring.write(sequence(0..<5))
        ring.write(sequence(5..<11))
        let held = ring.contents()
        XCTAssertEqual(held.samples, sequence(3..<11), "the newest 8, oldest first")
        XCTAssertEqual(held.firstSequence, 3)
        XCTAssertEqual(ring.framesWritten, 11)
    }

    func testAChunkLargerThanTheRingKeepsItsTail() {
        var ring = PreRollBuffer(capacity: 4)
        ring.write(sequence(0..<3))
        ring.write(sequence(3..<13))
        XCTAssertEqual(ring.contents().samples, sequence(9..<13))
        XCTAssertEqual(ring.contents().firstSequence, 9)
    }

    func testSizedInSeconds() {
        XCTAssertEqual(PreRollBuffer(seconds: WakeSpeechGate.preRollSeconds, sampleRate: 16_000).capacity, 16_000)
        XCTAssertEqual(WakeSpeechGate.preRollSeconds, 1.0)
    }

    func testClearForgetsButKeepsCounting() {
        var ring = PreRollBuffer(capacity: 8)
        ring.write(sequence(0..<6))
        ring.clear()
        XCTAssertTrue(ring.contents().samples.isEmpty)
        ring.write(sequence(6..<8))
        XCTAssertEqual(ring.contents().samples, sequence(6..<8))
        XCTAssertEqual(ring.contents().firstSequence, 6)
    }

    // MARK: - Attach

    /// The recognizer must receive a contiguous run — the pre-roll, then live — with no gap and no
    /// sample twice, wherever the attach lands between chunks.
    func testAttachHandsOverWithNoLossOrDuplicate() {
        for attachAfter in 0...6 {
            var router = GatedTapRouter(preRoll: PreRollBuffer(capacity: 10))
            var delivered: [Float] = []
            var next = 0
            for chunkIndex in 0..<12 {
                if chunkIndex == attachAfter { delivered += router.attach().samples }
                let chunk = sequence(next..<(next + 3))
                next += 3
                if router.route(chunk) == .live { delivered += chunk }
            }
            XCTAssertFalse(delivered.isEmpty)
            let first = Int(delivered[0])
            XCTAssertEqual(delivered, sequence(first..<next),
                           "contiguous from the oldest pre-roll sample (attach after \(attachAfter))")
            let buffered = attachAfter * 3
            XCTAssertEqual(first, buffered - min(buffered, 10),
                           "the whole pre-roll window (up to its capacity) plus everything live")
        }
    }

    func testAttachReportsTheFirstSequence() {
        var router = GatedTapRouter(preRoll: PreRollBuffer(capacity: 4))
        _ = router.route(sequence(0..<6))
        let held = router.attach()
        XCTAssertEqual(held.samples, sequence(2..<6))
        XCTAssertEqual(held.firstSequence, 2)
        XCTAssertEqual(router.route(sequence(6..<8)), .live)
    }

    func testDetachGoesBackToBufferingAFreshWindow() {
        var router = GatedTapRouter(preRoll: PreRollBuffer(capacity: 4))
        _ = router.route(sequence(0..<4))
        _ = router.attach()
        _ = router.route(sequence(4..<6))
        router.detach()
        XCTAssertFalse(router.attached)
        XCTAssertEqual(router.route(sequence(6..<8)), .buffered)
        XCTAssertEqual(router.attach().samples, sequence(6..<8), "nothing from before the detach is replayed")
    }
}
