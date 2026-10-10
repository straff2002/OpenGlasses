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

    /// Three testers on 2026-10-08 saw only Meta AI's "Internal error" and asked what it meant.
    /// The pre-hand-off copy names the gate and both ways through it, and quotes the dialog so a
    /// wearer who meets it knows it was expected.
    func testBeforeHandoffCopyNamesTheGateAndBothWaysThrough() {
        let copy = RegistrationFlow.beforeHandoffMessage(appName: "Avenkin")
        XCTAssertTrue(copy.contains("Meta AI opens next"), "say the app is about to leave")
        XCTAssertTrue(copy.contains("invited"), "the release channel is one way through")
        XCTAssertTrue(copy.contains("Developer Mode"), "Developer Mode is the other")
        XCTAssertTrue(copy.contains("five times"), "say how to reach Developer Mode")
        XCTAssertTrue(copy.contains("\"Internal error\""), "quote Meta AI's refusal so it is recognisable")
        XCTAssertTrue(copy.contains("Avenkin"), "name the app Meta AI will ask about")
        XCTAssertFalse(copy.contains(where: \.isNumber), "no state numbers in wearer-facing copy")
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
            .configurationInvalid, .unknown
        ]
        for error in cases {
            let message = RegistrationFlow.registrationErrorMessage(error)
            XCTAssertFalse(message.isEmpty, "\(error) must say something")
            XCTAssertLessThanOrEqual(message.count, 80,
                                     "\(error) is too long for the capsule and will truncate: \(message)")
        }
    }

    // MARK: - A connect that gave up (Plan HX P3)

    private func failure(_ registration: GlassesRegistration, _ links: [GlassesLinkState] = [],
                         _ permission: GlassesCameraPermission = .notChecked) -> String {
        RegistrationFlow.connectFailureMessage(
            reachability: GlassesReachability(registration: registration, links: links, permission: permission),
            bundleID: RegistrationFlow.publishedBundleID, appName: "Avenkin")
    }

    /// House rule for this type: tell the user what to *do*. A message that only names the SDK's
    /// internal state is the thing `connectFailureMessage` was written to stop.
    func testEveryConnectFailureIsItsOwnSentenceWithNoStateNumber() {
        let failed = GlassesCameraPermission.failed(
            SafeErrorSummary(category: .unknown, detail: PrivacyToken("noDevice"), code: 3))
        let messages = [
            failure(.notRegistered),
            failure(.registered, [], .notGranted),
            failure(.registered, [], .declined),
            failure(.registered, [], .phoneCameraDenied),
            failure(.registered, [], failed),
            failure(.registered, [], .granted),
            failure(.registered, [.disconnected], .granted),
            failure(.registered, [.connecting], .granted),
            failure(.registered, [.connected], .granted),
        ]
        XCTAssertEqual(Set(messages).count, messages.count, "no two causes read the same")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertNil(message.rangeOfCharacter(from: .decimalDigits), message)
            XCTAssertFalse(message.localizedCaseInsensitiveContains("state"), message)
            XCTAssertFalse(message.contains("no device appeared"),
                           "the sentence that named neither the permission nor Developer Mode is retired")
        }
    }

    /// The tester's case: registered, no error, nothing listed. The likeliest cause is named, and
    /// so is where the button for it is.
    func testRegisteredWithNothingListedNamesTheCameraPermissionAndWhereToAllowIt() {
        for permission in [GlassesCameraPermission.notChecked, .notGranted] {
            let message = failure(.registered, [], permission)
            XCTAssertTrue(message.contains("camera access"), message)
            XCTAssertTrue(message.contains("Meta AI"), message)
            XCTAssertTrue(message.contains("Settings › Devices & Privacy › Glasses"), message)
            XCTAssertTrue(message.contains("Avenkin"), message)
        }
    }

    func testEachWayThePermissionWasNotGrantedSaysWhereTheSwitchIs() {
        XCTAssertTrue(failure(.registered, [], .declined).contains("wasn't allowed in Meta AI"))
        let phone = failure(.registered, [], .phoneCameraDenied)
        XCTAssertTrue(phone.contains("iPhone's Settings"))
        XCTAssertFalse(phone.contains("wasn't allowed in Meta AI"))
        let failed = failure(.registered, [], .failed(SafeErrorSummary(category: .unknown,
                                                                       detail: PrivacyToken("metaAINotInstalled"))))
        XCTAssertTrue(failed.contains("(metaAINotInstalled)"), "the reason can be quoted to support")
    }

    func testGrantedWithNothingListedNamesDeveloperModesOneAppLimit() {
        let message = failure(.registered, [], .granted)
        XCTAssertTrue(message.contains("Camera access is allowed"))
        XCTAssertTrue(message.contains("connected in the Meta AI app"))
        XCTAssertTrue(message.contains("Developer Mode"))
    }

    func testAListedPairThatIsOutOfReachIsNotToldToFixAPermission() {
        for permission in [GlassesCameraPermission.notChecked, .notGranted, .declined, .granted] {
            let message = failure(.registered, [.disconnected], permission)
            XCTAssertTrue(message.contains("out of reach"), message)
            XCTAssertTrue(message.contains("out of their case"), message)
            XCTAssertFalse(message.contains("camera access"), "\(permission): a listed device is past it")
        }
    }

    /// A pair that is listed keeps its own sentence even while registration reads below
    /// registered, which it has been seen doing during a healthy session.
    func testAListedPairIsNotToldItsRegistrationFailed() {
        let message = RegistrationFlow.connectFailureMessage(
            reachability: GlassesReachability(registration: .notRegistered, links: [.disconnected]),
            configStatus: .placeholder(key: "MetaAppID"), bundleID: RegistrationFlow.publishedBundleID)
        XCTAssertTrue(message.contains("out of reach"))
    }

    // MARK: - Refused registration (release-channel gate)

    /// Outside Developer Mode Meta registers a distributed app only for invited testers. The
    /// refused wearer has to learn both ways in from the message itself.
    func testNotApprovedMessageNamesBothWaysIn() {
        let message = RegistrationFlow.notApprovedMessage(appName: "Avenkin")
        XCTAssertTrue(message.contains("Avenkin"))
        XCTAssertTrue(message.contains("invite-only"))
        XCTAssertTrue(message.contains("tester group"))
        XCTAssertTrue(message.contains("Developer Mode"))
        XCTAssertFalse(message.contains(where: \.isNumber), "no internal state numbers")
    }

    func testRefusedCallbackGetsTheNotApprovedMessage() {
        XCTAssertEqual(RegistrationFlow.callbackFailureMessage(.registrationError, appName: "Avenkin"),
                       RegistrationFlow.notApprovedMessage(appName: "Avenkin"))
    }

    func testUnregistrationCallbackFailureStaysQuiet() {
        XCTAssertNil(RegistrationFlow.callbackFailureMessage(.unregistrationError))
    }

    func testApprovalTimeoutStatusFitsTheCapsuleAndMentionsTheGate() {
        let status = RegistrationFlow.approvalTimedOutStatus(appName: "Avenkin")
        XCTAssertLessThanOrEqual(status.count, 80, "too long for the status capsule: \(status)")
        XCTAssertTrue(status.contains("Meta AI"))
        XCTAssertTrue(status.contains("invite-only"))
    }

    func testStatusNamesTheApp() {
        XCTAssertTrue(RegistrationFlow.status(stateRaw: 2, appName: "Avenkin").contains("Avenkin"))
    }

    func testActionableFailuresNameAnAction() {
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.metaAINotInstalled).contains("Meta AI"))
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.unknown).lowercased().contains("try again"))
        XCTAssertTrue(RegistrationFlow.registrationErrorMessage(.networkUnavailable).lowercased().contains("connection"))
    }
}
