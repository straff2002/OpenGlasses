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
