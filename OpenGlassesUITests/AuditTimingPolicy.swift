import CoreGraphics
import Foundation

// Pure timing rules for the accessibility audit gate.
//
// This file has no XCTest or XCUITest dependency on purpose. It is compiled into
// `OpenGlassesUITests`, where the audit helpers use it, *and* into `OpenGlassesTests` (see
// `project.tests.yml`), so its rules are checked by the fast unit suite. A UI-test target cannot
// be unit-tested on its own: every case in it launches the app.

/// How the audit helper responds when Xcode's accessibility-audit service times out.
///
/// The timeout is an infrastructure error, not a finding. Findings arrive through the audit's
/// issue handler and are never retried or filtered. On a cold, loaded CI simulator the service
/// sometimes gives up before returning anything. On 8de36b08 three audits hit it even after a
/// single retry, and all three had passed on the previous attempt of the same commit. So retry
/// a small, bounded number of times, with a short pause first so a busy host can catch up.
///
/// Only the exact domain and code count. An invalid target, a crash or any other error still
/// fails on the first attempt.
struct AuditRetryPolicy: Equatable {

    /// How long to wait before each retry. Entry 0 is the wait before attempt 2, entry 1 the wait
    /// before attempt 3. Its length is the number of retries.
    let backoffs: [TimeInterval]

    /// Three attempts in total: wait 2 s before the second and 5 s before the third.
    static let standard = AuditRetryPolicy(backoffs: [2, 5])

    /// First attempt plus one per backoff.
    var maxAttempts: Int { backoffs.count + 1 }

    /// The wait before retrying after `attempt` (1-based) timed out, or `nil` if that was the
    /// last attempt the policy allows.
    func delay(afterTimedOutAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= backoffs.count else { return nil }
        return backoffs[attempt - 1]
    }

    static let timeoutDomain = "com.apple.xcode.xctest.accessibilityAudit"
    static let timeoutCode = -56

    /// The audit service has no public error constants, but its timeout ("Audit failed to complete
    /// in time") is stable Cocoa-style domain/code metadata. The match is exact and must stay so.
    static func isAuditTimeout(domain: String, code: Int) -> Bool {
        domain == timeoutDomain && code == timeoutCode
    }

    static func isAuditTimeout(_ error: Error) -> Bool {
        let error = error as NSError
        return isAuditTimeout(domain: error.domain, code: error.code)
    }
}

/// The audit types a pass reported new (undeferred) findings for, reduced to the one distinction
/// `AuditConfirmationPolicy` cares about. Kept free of `XCUIAccessibilityAuditType` so this file
/// stays unit-testable; the audit helper does the mapping.
enum AuditFindingKind: Hashable {
    /// "Dynamic Type font sizes are (partially) unsupported".
    case dynamicType
    /// Contrast, clipping, hit region, trait, description, element detection.
    case other
}

/// Whether a first pass of the audit is believed as it stands, or measured once more.
///
/// The Dynamic Type check is the one audit that *moves the app while it measures it*. It steps
/// the content size category through about a dozen sizes in a few seconds and reads every text
/// element's frame at each step. On a scroll page of rows that is a full reflow per step: rows
/// grow, the scroll offset is re-clamped, the hero card leaves the screen. A step read before the
/// reflow has finished sees copy still at the previous size, and the audit reports that as
/// "partially unsupported" — on every text element of the container that lagged, all at once.
///
/// That is the shape of every settings-hub failure the gate has had since #484 (nightly
/// 35739123389 on 2026-09-22, PR run 35828512230 attempt 1 on 2026-09-23, and 6f08dfe2/8de36b08
/// before it): 14–17 Dynamic Type findings on the hub's own row titles, subtitles, values and
/// Discover pitches, nothing else new, and nothing reproducible. The screen was measurably still
/// before the audit began (the test's screen recording shows the hub unchanged for 5–7 s, and
/// `awaitStableFrame` logged three identical samples on the unfolded row and the switch). The
/// audit itself took the same 7–10 s as on a pass. And the same copy on the same commit passed
/// on re-run, and passed the hub audit *launched* at AX5 — no sweep — in the same run.
///
/// So there is nothing before the audit to wait for; the transition is the audit's own. What
/// distinguishes a lagged reading from a fixed-size font is that the font reproduces: a second
/// pass on the same still screen fails again. A result whose only new findings are Dynamic Type
/// therefore gets exactly one more pass, and the second pass is the verdict. Nothing is deferred
/// and nothing is filtered — both passes are printed, and a finding of any other type, or a
/// Dynamic Type finding that comes back, fails the case as before.
struct AuditConfirmationPolicy: Equatable {

    /// How many extra passes a Dynamic-Type-only result may get. One: it turns a flake rate of p
    /// into p², and a second lagged reading in a row is worth seeing rather than absorbing.
    let maxConfirmations: Int

    /// Pause before the second pass, so the app has restored its default size and finished the
    /// reflow back from the sweep.
    let settleDelay: TimeInterval

    static let standard = AuditConfirmationPolicy(maxConfirmations: 1, settleDelay: 1)

    /// Whether to measure again, given the kinds of the new findings the last pass reported and
    /// how many extra passes have already run. Only a non-empty, Dynamic-Type-only result
    /// qualifies: a clean pass needs no confirmation, and any other kind of finding is already a
    /// failure that a second look could not change.
    func shouldMeasureAgain(findingKinds: Set<AuditFindingKind>, confirmationsSoFar: Int) -> Bool {
        guard confirmationsSoFar < maxConfirmations else { return false }
        return findingKinds == [.dynamicType]
    }
}

/// Decides when a sampled element frame has stopped moving.
///
/// Feed it one frame per sample, or `nil` when the element does not exist at that moment. It
/// reports settled once the last `requiredIdenticalSamples` frames are all present and exactly
/// equal. A missing sample or a changed frame restarts the count, so an element caught between
/// two animation frames that happen to be close cannot pass. The frames have to be identical.
struct FrameSettleTracker {

    let requiredIdenticalSamples: Int
    private(set) var lastFrame: CGRect?
    private(set) var identicalRun = 0

    init(requiredIdenticalSamples: Int = 3) {
        precondition(requiredIdenticalSamples >= 2,
                     "A single sample cannot show that something has stopped moving")
        self.requiredIdenticalSamples = requiredIdenticalSamples
    }

    var isSettled: Bool { identicalRun >= requiredIdenticalSamples }

    /// Record one sample and return whether the frame is now settled.
    @discardableResult
    mutating func record(_ frame: CGRect?) -> Bool {
        guard let frame else {
            lastFrame = nil
            identicalRun = 0
            return false
        }
        if let lastFrame, lastFrame == frame {
            identicalRun += 1
        } else {
            identicalRun = 1
        }
        lastFrame = frame
        return isSettled
    }
}
