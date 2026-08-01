import UIKit
import XCTest
@testable import OpenGlasses

/// Plan CE — frame pinning's deterministic core: the delivery gate at the push chokepoint,
/// the release-trigger policy, and the pin state itself.
@MainActor
final class FramePinTests: XCTestCase {

    // MARK: - FramePinGate

    func testUnpinnedDeliversLive() {
        var gate = FramePinGate()
        XCTAssertEqual(gate.evaluate(isPinned: false, now: 0), .deliverLive)
        XCTAssertEqual(gate.evaluate(isPinned: false, now: 1), .deliverLive)
    }

    func testFirstPinnedDecisionIsResend() {
        var gate = FramePinGate()
        _ = gate.evaluate(isPinned: false, now: 0)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 1), .resendPinned)
    }

    func testPinnedSuppressesUntilHeartbeat() {
        var gate = FramePinGate(heartbeat: 12)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 0), .resendPinned)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 5), .suppress)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 11.9), .suppress)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 12), .resendPinned)
        // Heartbeat clock restarts from the re-send.
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 13), .suppress)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 24), .resendPinned)
    }

    func testImmediatePushIsCreditedAgainstTheHeartbeat() {
        var gate = FramePinGate(heartbeat: 12)
        // The wiring sharp-injects the pinned frame at pin time and records it — the next
        // evaluated camera frame must NOT trigger a duplicate resend.
        gate.notePinnedPushed(now: 0)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 1), .suppress)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 12), .resendPinned)
    }

    func testUnpinResetsTheGateState() {
        var gate = FramePinGate(heartbeat: 12)
        _ = gate.evaluate(isPinned: true, now: 0)
        XCTAssertEqual(gate.evaluate(isPinned: false, now: 1), .deliverLive)
        // A fresh pin starts a fresh cycle: immediate resend again.
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 2), .resendPinned)
    }

    func testZeroHeartbeatNeverResends() {
        var gate = FramePinGate(heartbeat: 0)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 0), .resendPinned)
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 1_000), .suppress)
    }

    func testExplicitResetClearsPinnedSendClock() {
        var gate = FramePinGate(heartbeat: 12)
        _ = gate.evaluate(isPinned: true, now: 0)
        gate.reset()
        XCTAssertEqual(gate.evaluate(isPinned: true, now: 1), .resendPinned)
    }

    // MARK: - Release policy

    func testEveryLifecycleTriggerReleases() {
        // Walking allCases means a future trigger added to the enum fails here until its
        // behavior is consciously decided.
        for trigger in FramePinReleaseTrigger.allCases {
            XCTAssertTrue(FramePinReleasePolicy.shouldRelease(on: trigger), "\(trigger)")
        }
    }

    func testExpiryIsOffByDefaultAndBoundaryInclusive() {
        let pinnedAt = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(FramePinReleasePolicy.isExpired(
            pinnedAt: pinnedAt, now: pinnedAt.addingTimeInterval(1_000_000), maxAge: nil))
        XCTAssertFalse(FramePinReleasePolicy.isExpired(
            pinnedAt: pinnedAt, now: pinnedAt.addingTimeInterval(59), maxAge: 60))
        XCTAssertTrue(FramePinReleasePolicy.isExpired(
            pinnedAt: pinnedAt, now: pinnedAt.addingTimeInterval(60), maxAge: 60))
    }

    // MARK: - FramePin state

    func testPinUnpinLifecycle() {
        let pin = FramePin()
        XCTAssertFalse(pin.isPinned)
        XCTAssertFalse(pin.unpin(), "unpin with nothing held is a no-op")

        let frame = UIImage()
        let at = Date(timeIntervalSinceReferenceDate: 123)
        pin.pin(frame: frame, at: at)
        XCTAssertTrue(pin.isPinned)
        XCTAssertEqual(pin.pinnedAt, at)
        XCTAssertTrue(pin.pinnedFrame === frame)

        XCTAssertTrue(pin.unpin())
        XCTAssertFalse(pin.isPinned)
        XCTAssertNil(pin.pinnedFrame)
        XCTAssertNil(pin.pinnedAt)
    }

    func testRepinReplacesTheFrame() {
        let pin = FramePin()
        pin.pin(frame: UIImage(), at: Date(timeIntervalSinceReferenceDate: 0))
        let second = UIImage()
        let at = Date(timeIntervalSinceReferenceDate: 10)
        pin.pin(frame: second, at: at)
        XCTAssertTrue(pin.pinnedFrame === second)
        XCTAssertEqual(pin.pinnedAt, at)
    }
}
