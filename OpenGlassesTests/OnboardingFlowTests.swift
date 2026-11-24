import XCTest
@testable import OpenGlasses

/// Plan FY P2 — the first run leads with the assistant, asks about devices last, and treats this
/// phone as a complete answer.
///
/// The exit this pins: a first run with no glasses never shows a screen that treats the user as
/// unfinished. Its other half — the assistant does not describe itself as a glasses product during
/// a phone-only session — is `DeviceIdentityTests.testAPhoneOnlyPromptContainsNoGlasses` (F3),
/// with the preset bodies added in P2 by `testNoShippedPresetBodyAssumesGlassesOnAPhone`.
final class OnboardingFlowTests: XCTestCase {

    // MARK: - Order

    func testTheAssistantPagesComeFirstAndTheDeviceStepLast() {
        let route = OnboardingFlow.route(managed: nil)
        XCTAssertEqual(route, [
            .welcome, .provider, .accessKey, .services, .permissions, .assistantName, .addDevice, .ready,
        ])
        XCTAssertEqual(route.count, 8, "the header says \"Page n of 8\"; the UI test reads it")
        XCTAssertFalse(route.contains(.language), "the language line is for managed phones only")
        XCTAssertEqual(OnboardingFlow.page(after: .assistantName, in: route), .addDevice,
                       "the device step follows the assistant's pages")
        XCTAssertEqual(OnboardingFlow.page(after: .addDevice, in: route), .ready)
        XCTAssertNil(OnboardingFlow.page(after: .ready, in: route))
    }

    // MARK: - The phone path

    /// Walk a first run with no glasses from the welcome page: every page leads to the next, the
    /// device step is answered "Use this phone", and the flow reaches Ready and completes — with
    /// no glasses recorded, so the session card that follows reports the session, not a missing
    /// pair of glasses.
    func testThePhonePathReachesCompletionWithNothingUnfinished() {
        var visited: [OnboardingFlow.Page] = []
        var page: OnboardingFlow.Page? = .welcome
        while let current = page {
            visited.append(current)
            page = current == .addDevice
                ? OnboardingFlow.page(after: OnboardingFlow.DeviceAnswer.thisPhone)
                : OnboardingFlow.page(after: current, in: OnboardingFlow.unmanagedRoute)
        }
        XCTAssertEqual(visited, OnboardingFlow.unmanagedRoute, "the phone path visits every page once")
        XCTAssertEqual(visited.last, .ready, "the flow completes from Ready")

        XCTAssertFalse(OnboardingFlow.addsGlasses(.thisPhone),
                       "choosing this phone records nothing to finish later")
        XCTAssertTrue(OnboardingFlow.phoneIsTheDevice(glassesConnected: false, glassesAdded: false),
                      "after a phone-only first run the phone is the device, not a missing pair of glasses")
    }

    func testGlassesAreAnAnswerThatAlsoFinishesTheStep() {
        XCTAssertEqual(OnboardingFlow.page(after: OnboardingFlow.DeviceAnswer.glasses), .ready,
                       "registration can finish later from Settings; the step itself is done")
        XCTAssertTrue(OnboardingFlow.addsGlasses(.glasses))
    }

    /// Field Assist technicians use glasses, though not all the time: open for them, one tap away
    /// for everyone else.
    func testGlassesStartOpenOnlyForSomeoneSetUpForFieldAssist() {
        XCTAssertTrue(OnboardingFlow.glassesStartOpen(fieldAssistSetUp: true, glassesSupported: true))
        XCTAssertFalse(OnboardingFlow.glassesStartOpen(fieldAssistSetUp: false, glassesSupported: true))
        // Plan JE: a copy that offers no glasses never opens the rows, Field Assist or not.
        XCTAssertFalse(OnboardingFlow.glassesStartOpen(fieldAssistSetUp: true, glassesSupported: false))
        XCTAssertFalse(OnboardingFlow.glassesStartOpen(fieldAssistSetUp: false, glassesSupported: false))
    }

    // MARK: - The session card afterwards

    func testTheSessionCardReportsGlassesOnlyOnceTheyAreAdded() {
        XCTAssertTrue(OnboardingFlow.phoneIsTheDevice(glassesConnected: false, glassesAdded: false))
        XCTAssertFalse(OnboardingFlow.phoneIsTheDevice(glassesConnected: false, glassesAdded: true),
                       "someone who added glasses is told when they are not connected")
        XCTAssertFalse(OnboardingFlow.phoneIsTheDevice(glassesConnected: true, glassesAdded: false))
        XCTAssertFalse(OnboardingFlow.phoneIsTheDevice(glassesConnected: true, glassesAdded: true))
    }

    func testGlassesAddedRoundTripsAndDefaultsToThePhone() {
        let key = "glassesAdded"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.glassesAdded, "a fresh install has not added glasses")
        Config.glassesAdded = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }
}
