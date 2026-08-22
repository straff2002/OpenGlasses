import XCTest
@testable import OpenGlasses
import MWDATCore

/// The Meta-registration wait policy: the registered threshold, actionable status text, and a
/// deadline long enough for the real Meta AI approval round-trip.
final class RegistrationFlowTests: XCTestCase {

    func testRegisteredThreshold() {
        XCTAssertFalse(RegistrationFlow.isRegistered(stateRaw: 0))
        XCTAssertFalse(RegistrationFlow.isRegistered(stateRaw: 2))
        XCTAssertTrue(RegistrationFlow.isRegistered(stateRaw: 3))
        XCTAssertTrue(RegistrationFlow.isRegistered(stateRaw: 4))
    }

    func testStatusTellsTheUserWhatToDoWhileWaiting() {
        let waiting = RegistrationFlow.status(stateRaw: 2)
        XCTAssertTrue(waiting.contains("Meta AI"), "the blocked state is fixed in the Meta AI app — say so")
        XCTAssertFalse(waiting.contains("state"), "never surface a raw internal state number")
        XCTAssertFalse(waiting.contains(where: \.isNumber), "no digits in the user-facing status")
    }

    func testStatusOnceRegistered() {
        XCTAssertEqual(RegistrationFlow.status(stateRaw: 3), "Waiting for device…")
        XCTAssertEqual(RegistrationFlow.status(stateRaw: 4), "Waiting for device…")
    }

    func testDeadlineCoversTheObservedApprovalLatency() {
        XCTAssertGreaterThanOrEqual(RegistrationFlow.approvalDeadlineSeconds, 25,
            "Meta AI approval has been observed to take ~25s; the old 10s deadline gave up too early")
    }

    // MARK: - Registration failure copy (device-traced 2026-08-23)

    /// The bug this pins: `startRegistration()` throws `.alreadyRegistered` on every connect after
    /// the first, `connect()` treated every throw as failure, and so the one state from which
    /// reconnecting is guaranteed possible was the one state it refused to reconnect from. A wearer
    /// whose glasses dropped mid-session could press Connect forever.
    ///
    /// The behaviour lives in `connect()`; what is assertable here is that the string this case
    /// maps to never reads as a failure, so it cannot be reintroduced as one by a future caller.
    func testAlreadyRegisteredNeverReadsAsAFailure() {
        let message = RegistrationFlow.registrationErrorMessage(.alreadyRegistered)
        XCTAssertFalse(message.lowercased().contains("failed"))
        XCTAssertFalse(message.lowercased().contains("error"))
    }

    /// Every message is short enough to survive the status capsule, which is sized for
    /// "Glasses Idle". The device-traced symptom was a sentence truncated to "User is already…",
    /// cutting the exact word that showed it was benign.
    func testEveryRegistrationMessageFitsTheStatusCapsule() {
        let cases: [RegistrationError] = [
            .alreadyRegistered, .metaAINotInstalled, .networkUnavailable,
            .timeout, .configurationInvalid, .unknown
        ]
        for error in cases {
            let message = RegistrationFlow.registrationErrorMessage(error)
            XCTAssertFalse(message.isEmpty, "\(error) must say something")
            XCTAssertLessThanOrEqual(message.count, 80,
                                     "\(error) is too long for the capsule and will truncate: \(message)")
        }
    }

    /// House rule for this type: tell the user what to *do*. A message that only names the SDK's
    /// internal state is the thing `connectFailureMessage` was written to stop.
    func testActionableFailuresNameAnAction() {
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.metaAINotInstalled).contains("Meta AI"))
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.timeout).lowercased().contains("try again"))
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.networkUnavailable).lowercased().contains("connection"))
    }
}
