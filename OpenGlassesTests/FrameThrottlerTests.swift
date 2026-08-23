import XCTest
import UIKit
@testable import OpenGlasses

final class FrameThrottlerTests: XCTestCase {

    // MARK: - Basic Throttling

    func testFirstFrameIsAlwaysForwarded() {
        let throttler = FrameThrottler(interval: 1.0)
        let expectation = expectation(description: "frame forwarded")

        throttler.onThrottledFrame = { image in
            XCTAssertNotNil(image)
            expectation.fulfill()
        }

        throttler.submit(UIImage())
        waitForExpectations(timeout: 1.0)
    }

    func testFrameWithinIntervalIsDropped() {
        let throttler = FrameThrottler(interval: 1.0)
        var forwardedCount = 0

        throttler.onThrottledFrame = { _ in
            forwardedCount += 1
        }

        // First frame — forwarded
        throttler.submit(UIImage())
        // Second frame immediately after — should be dropped
        throttler.submit(UIImage())
        // Third frame immediately after — should be dropped
        throttler.submit(UIImage())

        XCTAssertEqual(forwardedCount, 1, "Only the first frame should be forwarded within the interval")
    }

    func testFrameAfterIntervalIsForwarded() {
        // Use a very short interval so the test doesn't take long
        let throttler = FrameThrottler(interval: 0.05)
        var forwardedCount = 0

        throttler.onThrottledFrame = { _ in
            forwardedCount += 1
        }

        // First frame
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 1)

        // Wait for the interval to pass
        let expectation = expectation(description: "wait for interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Second frame after interval
            throttler.submit(UIImage())
            XCTAssertEqual(forwardedCount, 2, "Frame should be forwarded after interval")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)
    }

    func testResetAllowsImmediateFrame() {
        let throttler = FrameThrottler(interval: 10.0) // Very long interval
        var forwardedCount = 0

        throttler.onThrottledFrame = { _ in
            forwardedCount += 1
        }

        // First frame
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 1)

        // Second frame without reset — should be dropped (10s interval)
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 1)

        // Reset, then submit — should be forwarded
        throttler.reset()
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 2, "Frame should be forwarded after reset")
    }

    func testNoCallbackDoesNotCrash() {
        let throttler = FrameThrottler(interval: 1.0)
        // onThrottledFrame is nil — should not crash
        throttler.submit(UIImage())
    }

    func testCustomInterval() {
        let throttler = FrameThrottler(interval: 0.5)
        var forwardedCount = 0

        throttler.onThrottledFrame = { _ in
            forwardedCount += 1
        }

        // Submit first frame
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 1)

        // Submit immediately — dropped
        throttler.submit(UIImage())
        XCTAssertEqual(forwardedCount, 1)
    }

    func testRapidFireOnlyForwardsAtRate() {
        let throttler = FrameThrottler(interval: 0.1)
        var forwardedCount = 0

        throttler.onThrottledFrame = { _ in
            forwardedCount += 1
        }

        // Fire 100 frames rapidly
        for _ in 0..<100 {
            throttler.submit(UIImage())
        }

        // Only the first should have been forwarded
        XCTAssertEqual(forwardedCount, 1, "Rapid fire should only forward the first frame")
    }

    // MARK: - A turn gets a current frame (device-traced 2026-08-23)

    /// With the content gate on, a still scene forwards nothing between heartbeats — so a question
    /// could be answered against a frame up to twelve seconds old. The heartbeat is right for its
    /// own job (keeping a background view from going stale) and wrong as the wait behind a question.
    func testAFreshFrameRequestBypassesTheRateLimit() {
        var now = Date(timeIntervalSince1970: 1_000)
        let throttler = FrameThrottler(interval: 1.0, now: { now })

        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }

        throttler.submit(UIImage())
        XCTAssertEqual(forwarded, 1, "first frame always goes")

        now = now.addingTimeInterval(0.1)
        throttler.submit(UIImage())
        XCTAssertEqual(forwarded, 1, "still inside the interval")

        throttler.requestFreshFrame()
        throttler.submit(UIImage())
        XCTAssertEqual(forwarded, 2, "a turn is starting — the model needs a current view")
    }

    /// Several partial transcripts arrive in one turn; they must not force several frames.
    func testTheRequestIsConsumedByASingleFrame() {
        var now = Date(timeIntervalSince1970: 2_000)
        let throttler = FrameThrottler(interval: 1.0, now: { now })
        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }

        throttler.submit(UIImage())
        throttler.requestFreshFrame()
        throttler.requestFreshFrame()
        now = now.addingTimeInterval(0.1)
        throttler.submit(UIImage())
        now = now.addingTimeInterval(0.1)
        throttler.submit(UIImage())

        XCTAssertEqual(forwarded, 2, "one forced frame, then normal throttling resumes")
    }

    /// A forced frame is not evidence of a new scene, so it must not reach keyframe consumers —
    /// they exist to describe what changed, and nothing did.
    func testAForcedFrameIsNotAKeyframe() {
        var now = Date(timeIntervalSince1970: 3_000)
        let throttler = FrameThrottler(interval: 1.0, now: { now })
        var keyframes = 0
        throttler.onKeyframe = { _ in keyframes += 1 }

        throttler.submit(UIImage())
        let baseline = keyframes
        throttler.requestFreshFrame()
        now = now.addingTimeInterval(0.05)
        throttler.submit(UIImage())
        XCTAssertEqual(keyframes, baseline)
    }
}
