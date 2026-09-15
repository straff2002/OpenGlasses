import CoreGraphics
import XCTest

/// The accessibility audit gate's timing rules (`OpenGlassesUITests/AuditTimingPolicy.swift`,
/// compiled into this target as well). The UI-test target launches the app for every case, so the
/// rules are checked here where they run in milliseconds.
final class AuditTimingPolicyTests: XCTestCase {

    // MARK: AuditRetryPolicy

    func testStandardPolicyAllowsThreeAttemptsWithShortBackoff() {
        let policy = AuditRetryPolicy.standard
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.delay(afterTimedOutAttempt: 1), 2)
        XCTAssertEqual(policy.delay(afterTimedOutAttempt: 2), 5)
        XCTAssertNil(policy.delay(afterTimedOutAttempt: 3),
                     "The third timeout is the last: the gate must fail, not loop")
    }

    func testDelayIsNilOutsideTheScheduledAttempts() {
        let policy = AuditRetryPolicy.standard
        XCTAssertNil(policy.delay(afterTimedOutAttempt: 0))
        XCTAssertNil(policy.delay(afterTimedOutAttempt: -1))
        XCTAssertNil(policy.delay(afterTimedOutAttempt: 4))
    }

    func testAPolicyWithoutBackoffsNeverRetries() {
        let policy = AuditRetryPolicy(backoffs: [])
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertNil(policy.delay(afterTimedOutAttempt: 1))
    }

    func testTimeoutMatchIsExactOnDomainAndCode() {
        XCTAssertTrue(AuditRetryPolicy.isAuditTimeout(
            domain: "com.apple.xcode.xctest.accessibilityAudit", code: -56))
        XCTAssertTrue(AuditRetryPolicy.isAuditTimeout(
            NSError(domain: "com.apple.xcode.xctest.accessibilityAudit", code: -56)))

        // Same domain, another code: any other audit-service error still fails first time.
        XCTAssertFalse(AuditRetryPolicy.isAuditTimeout(
            domain: "com.apple.xcode.xctest.accessibilityAudit", code: -55))
        XCTAssertFalse(AuditRetryPolicy.isAuditTimeout(
            domain: "com.apple.xcode.xctest.accessibilityAudit", code: 56))
        // Same code, another domain: no broadening to look-alikes.
        XCTAssertFalse(AuditRetryPolicy.isAuditTimeout(domain: NSCocoaErrorDomain, code: -56))
        XCTAssertFalse(AuditRetryPolicy.isAuditTimeout(
            domain: "com.apple.xcode.xctest.accessibilityAudit.extra", code: -56))
        XCTAssertFalse(AuditRetryPolicy.isAuditTimeout(
            NSError(domain: "com.apple.dt.XCTest", code: -56)))
    }

    // MARK: FrameSettleTracker

    private let a = CGRect(x: 0, y: 100, width: 390, height: 60)
    private let b = CGRect(x: 0, y: 104, width: 390, height: 60)

    func testSettlesOnlyAfterTheRequiredRunOfIdenticalFrames() {
        var tracker = FrameSettleTracker(requiredIdenticalSamples: 3)
        XCTAssertFalse(tracker.record(a))
        XCTAssertFalse(tracker.record(a))
        XCTAssertTrue(tracker.record(a))
        XCTAssertTrue(tracker.record(a), "Once settled, a further identical sample stays settled")
    }

    func testAMovingFrameRestartsTheRun() {
        var tracker = FrameSettleTracker(requiredIdenticalSamples: 3)
        tracker.record(a)
        tracker.record(a)
        XCTAssertFalse(tracker.record(b), "The frame moved on the last sample")
        XCTAssertFalse(tracker.record(b))
        XCTAssertTrue(tracker.record(b))
    }

    func testANearlyIdenticalFrameIsStillMovement() {
        var tracker = FrameSettleTracker(requiredIdenticalSamples: 2)
        tracker.record(a)
        XCTAssertFalse(tracker.record(a.offsetBy(dx: 0, dy: 0.5)))
    }

    func testAMissingSampleRestartsTheRun() {
        var tracker = FrameSettleTracker(requiredIdenticalSamples: 3)
        tracker.record(a)
        tracker.record(a)
        XCTAssertFalse(tracker.record(nil))
        XCTAssertNil(tracker.lastFrame)
        XCTAssertFalse(tracker.record(a))
        XCTAssertFalse(tracker.record(a))
        XCTAssertTrue(tracker.record(a))
    }

    func testDefaultRequiresThreeIdenticalSamples() {
        var tracker = FrameSettleTracker()
        XCTAssertEqual(tracker.requiredIdenticalSamples, 3)
        tracker.record(a)
        XCTAssertFalse(tracker.record(a))
        XCTAssertTrue(tracker.record(a))
    }
}
