import XCTest
@testable import OpenGlasses

/// Tests for the shared floor arbitration extracted in Plan CV P1. `ChatReadbackPolicyTests` is
/// the other half of the acceptance criterion for the extraction — those tests were not touched
/// and still pass, which is what proves the behaviour moved rather than changed. These cover the
/// arbiter directly, including with the narration-shaped payload that motivated pulling it out.
final class AmbientSpeechArbiterTests: XCTestCase {

    private func makeArbiter(_ tweak: (inout AmbientSpeechRules) -> Void = { _ in })
        -> AmbientSpeechArbiter<String> {
        var rules = AmbientSpeechRules()
        tweak(&rules)
        return AmbientSpeechArbiter<String>(rules: rules)
    }

    // MARK: - Queue and dedup

    func testEnqueueAndDrain() {
        var a = makeArbiter()
        XCTAssertEqual(a.enqueue("hello", dedupKey: "hello", at: 0), .queued)
        XCTAssertEqual(a.next(at: 1, ttsBusy: false, suppressed: false)?.payload, "hello")
        XCTAssertNil(a.next(at: 2, ttsBusy: false, suppressed: false))
    }

    func testIdenticalQueuedUtteranceMergesRatherThanRepeating() {
        var a = makeArbiter()
        XCTAssertEqual(a.enqueue("a hallway", dedupKey: "a hallway", at: 0), .queued)
        XCTAssertEqual(a.enqueue("A HALLWAY", dedupKey: "A HALLWAY", at: 1), .merged)
        XCTAssertEqual(a.queue.count, 1)
        XCTAssertEqual(a.next(at: 2, ttsBusy: false, suppressed: false)?.duplicates, 2)
    }

    func testSpokenUtteranceIsDroppedInsideDedupWindowAndAcceptedAfter() {
        var a = makeArbiter { $0.dedupWindow = 30 }
        a.enqueue("a hallway", dedupKey: "a hallway", at: 0)
        _ = a.next(at: 0, ttsBusy: false, suppressed: false)
        XCTAssertEqual(a.enqueue("a hallway", dedupKey: "a hallway", at: 20), .alreadySpoken)
        XCTAssertEqual(a.enqueue("a hallway", dedupKey: "a hallway", at: 40), .queued)
    }

    // MARK: - Bounds

    func testQueueDropsOldestNonPriorityAtCap() {
        var a = makeArbiter { $0.queueCap = 2 }
        a.enqueue("one", dedupKey: "one", at: 0)
        a.enqueue("urgent", dedupKey: "urgent", isPriority: true, at: 1)
        a.enqueue("three", dedupKey: "three", at: 2)
        XCTAssertEqual(a.queue.map(\.payload), ["urgent", "three"])
    }

    func testPriorityJumpsAheadOfPlainButBehindEarlierPriority() {
        var a = makeArbiter()
        a.enqueue("plain one", dedupKey: "plain one", at: 0)
        a.enqueue("first urgent", dedupKey: "first urgent", isPriority: true, at: 1)
        a.enqueue("plain two", dedupKey: "plain two", at: 2)
        a.enqueue("second urgent", dedupKey: "second urgent", isPriority: true, at: 3)
        XCTAssertEqual(a.queue.map(\.payload),
                       ["first urgent", "second urgent", "plain one", "plain two"])
    }

    func testRateCapIsRollingOverItsWindow() {
        var a = makeArbiter { $0.rateCapPerMinute = 2; $0.rateWindow = 60 }
        for i in 0..<3 { a.enqueue("m\(i)", dedupKey: "m\(i)", at: Double(i)) }
        XCTAssertNotNil(a.next(at: 10, ttsBusy: false, suppressed: false))
        XCTAssertNotNil(a.next(at: 20, ttsBusy: false, suppressed: false))
        XCTAssertNil(a.next(at: 30, ttsBusy: false, suppressed: false))     // cap spent
        XCTAssertNotNil(a.next(at: 71, ttsBusy: false, suppressed: false))  // window rolled past t=10
    }

    // MARK: - The floor

    func testTTSBusyHoldsTheQueueRatherThanDroppingIt() {
        var a = makeArbiter()
        a.enqueue("waiting", dedupKey: "waiting", at: 0)
        XCTAssertNil(a.next(at: 1, ttsBusy: true, suppressed: false))
        XCTAssertEqual(a.queue.count, 1, "A busy floor must hold, not discard.")
        XCTAssertEqual(a.next(at: 2, ttsBusy: false, suppressed: false)?.payload, "waiting")
    }

    /// Suppression is the stronger gate: nothing accumulates while it's on and whatever was
    /// waiting is dropped, because a description delivered once the ear frees describes a moment
    /// that has passed.
    func testSuppressionFlushesAndBlocksAccumulation() {
        var a = makeArbiter()
        a.enqueue("before", dedupKey: "before", at: 0)
        XCTAssertNil(a.next(at: 1, ttsBusy: false, suppressed: true))
        XCTAssertTrue(a.queue.isEmpty)
        XCTAssertEqual(a.enqueue("during", dedupKey: "during", at: 2, suppressed: true), .suppressed)
        XCTAssertNil(a.next(at: 3, ttsBusy: false, suppressed: false), "Nothing should replay later.")
    }

    func testResetClearsQueueAndBothWindows() {
        var a = makeArbiter { $0.rateCapPerMinute = 1 }
        a.enqueue("spoken", dedupKey: "spoken", at: 0)
        _ = a.next(at: 0, ttsBusy: false, suppressed: false)
        a.enqueue("pending", dedupKey: "pending", at: 1)
        a.reset()
        XCTAssertTrue(a.queue.isEmpty)
        // Rate window cleared, so a fresh utterance speaks immediately…
        a.enqueue("spoken", dedupKey: "spoken", at: 2)
        XCTAssertNotNil(a.next(at: 2, ttsBusy: false, suppressed: false),
                        "…and the dedup window cleared, so the same text is admissible again.")
    }

    // MARK: - The second consumer

    /// The extraction is only worth anything if the second consumer actually fits it. Narration's
    /// payload is a description, its dedup key is the description, and nothing is priority —
    /// no chat-shaped assumptions leaked into the arbiter.
    func testNarrationPresetHoldsAtMostTwoDescriptions() {
        var a = AmbientSpeechArbiter<String>(rules: .narration)
        XCTAssertEqual(AmbientSpeechRules.narration.queueCap, 2)
        a.enqueue("a hallway with doors", dedupKey: "a hallway with doors", at: 0)
        a.enqueue("a staircase going up", dedupKey: "a staircase going up", at: 1)
        a.enqueue("a landing with a window", dedupKey: "a landing with a window", at: 2)
        XCTAssertEqual(a.queue.map(\.payload), ["a staircase going up", "a landing with a window"],
                       "The room the wearer already left drops first.")
    }

    /// The constraint the whole extraction exists for: an ambient description must only ever speak
    /// into silence. If the wearer asked something, the answer owns the floor.
    func testNarrationNeverSpeaksOverAReply() {
        var a = AmbientSpeechArbiter<String>(rules: .narration)
        a.enqueue("a hallway", dedupKey: "a hallway", at: 0)
        for t in stride(from: 1.0, through: 5.0, by: 1.0) {
            XCTAssertNil(a.next(at: t, ttsBusy: true, suppressed: false))
        }
        XCTAssertNotNil(a.next(at: 6, ttsBusy: false, suppressed: false))
    }
}
