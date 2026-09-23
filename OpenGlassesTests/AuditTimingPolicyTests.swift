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

    // MARK: AuditConfirmationPolicy

    func testADynamicTypeOnlyResultIsMeasuredExactlyOnceMore() {
        let policy = AuditConfirmationPolicy.standard
        XCTAssertEqual(policy.maxConfirmations, 1)
        XCTAssertTrue(policy.shouldMeasureAgain(findingKinds: [.dynamicType], confirmationsSoFar: 0))
        XCTAssertFalse(policy.shouldMeasureAgain(findingKinds: [.dynamicType], confirmationsSoFar: 1),
                       "The second pass is the verdict: a Dynamic Type finding that comes back "
                       + "fails, it does not get a third look")
    }

    func testACleanPassNeedsNoConfirmation() {
        XCTAssertFalse(AuditConfirmationPolicy.standard
            .shouldMeasureAgain(findingKinds: [], confirmationsSoFar: 0))
    }

    func testAnyOtherKindOfFindingFailsFirstTime() {
        let policy = AuditConfirmationPolicy.standard
        XCTAssertFalse(policy.shouldMeasureAgain(findingKinds: [.other], confirmationsSoFar: 0),
                       "Contrast, clipping and the rest do not perturb the app; a second look "
                       + "would be a plain retry")
        XCTAssertFalse(policy.shouldMeasureAgain(findingKinds: [.dynamicType, .other],
                                                 confirmationsSoFar: 0),
                       "A genuine finding alongside a Dynamic Type burst is a failure either way")
    }

    func testAPolicyWithoutConfirmationsBelievesTheFirstPass() {
        let policy = AuditConfirmationPolicy(maxConfirmations: 0, settleDelay: 0)
        XCTAssertFalse(policy.shouldMeasureAgain(findingKinds: [.dynamicType], confirmationsSoFar: 0))
    }

    func testTheStandardSettleDelayIsShort() {
        // Long enough for the app to restore its default size after the sweep, short enough not
        // to make a passing suite noticeably slower: it is paid only when a first pass flaked.
        XCTAssertEqual(AuditConfirmationPolicy.standard.settleDelay, 1)
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
