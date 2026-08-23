import XCTest
@testable import OpenGlasses

/// Plan CX P1. Vision as a spoken mode — entered and left by voice, with no wake word between
/// questions while it is on. The suppression is what makes it a conversational state rather than a
/// camera state; the cost is an open mic for the mode's lifetime, so these tests are almost entirely
/// about the mode's *edges*.
final class VisionModePolicyTests: XCTestCase {

    private let capable = VisionModePolicy.Capability(cameraUnavailableReason: nil,
                                                      underPowerPressure: false)

    // MARK: - Entering

    func testEnteringFromOffWarmsUp() {
        XCTAssertEqual(try? VisionModePolicy.enter(from: .off, capability: capable).get(), .warming)
    }

    /// Glasses without a camera must say so in the tier's own words rather than appear to start.
    func testCameraLessGlassesRefuseWithTheirOwnReason() {
        let capability = VisionModePolicy.Capability(
            cameraUnavailableReason: "These glasses have no camera.", underPowerPressure: false)
        guard case .failure(let refusal) = VisionModePolicy.enter(from: .off, capability: capability) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(refusal, .noCamera("These glasses have no camera."))
        XCTAssertEqual(refusal.notice, "These glasses have no camera.")
    }

    /// Declining now with a reason beats starting a camera the device will shortly shut down —
    /// which is what a thermal or power abort looks like from the wearer's side.
    func testPowerPressureRefusesRatherThanStartingAndFailing() {
        let capability = VisionModePolicy.Capability(cameraUnavailableReason: nil,
                                                     underPowerPressure: true)
        guard case .failure(let refusal) = VisionModePolicy.enter(from: .off, capability: capability) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(refusal, .powerPressure)
    }

    func testEnteringTwiceIsRefusedNotRestarted() {
        for state in [VisionModePolicy.State.warming, .on] {
            guard case .failure(let refusal) = VisionModePolicy.enter(from: state, capability: capable) else {
                return XCTFail("expected a refusal from \(state)")
            }
            XCTAssertEqual(refusal, .alreadyOn)
        }
    }

    // MARK: - Wake-word suppression

    /// Suppression starts at `warming`, not at `on`. The camera takes seconds and the wearer starts
    /// talking immediately — requiring the wake word during warm-up loses the very question that
    /// made them turn vision on.
    func testTheWakeWordIsSuppressedFromWarmingOnwards() {
        XCTAssertTrue(VisionModePolicy.suppressesWakeWord(.warming))
        XCTAssertTrue(VisionModePolicy.suppressesWakeWord(.on))
    }

    /// And released the moment the mode starts ending — not when it finishes. Otherwise the mic
    /// stays open through teardown, which is the state nobody is watching.
    func testTheWakeWordReturnsAsSoonAsTheModeStartsEnding() {
        XCTAssertFalse(VisionModePolicy.suppressesWakeWord(.ending(reason: .spokenStop)))
        XCTAssertFalse(VisionModePolicy.suppressesWakeWord(.off))
    }

    // MARK: - Exits

    /// Every exit announces itself. Silence is indistinguishable from "nothing has changed", and
    /// the wearer would go on asking a camera that is off.
    func testEveryExitReasonSaysSomething() {
        let reasons: [VisionModePolicy.ExitReason] =
            [.spokenStop, .inactivity, .sessionEnded, .doffed, .powerPressure, .cameraFailed]
        for reason in reasons {
            XCTAssertFalse(reason.notice.isEmpty, "\(reason) must tell the wearer")
            XCTAssertTrue(reason.notice.lowercased().contains("vision off"),
                          "\(reason) must be unambiguous that the camera is no longer on")
        }
    }

    /// An exit lands in `.ending` first so the notice is delivered before the camera goes down.
    func testExitingPassesThroughEndingRatherThanStraightToOff() {
        XCTAssertEqual(VisionModePolicy.exit(from: .on, reason: .doffed), .ending(reason: .doffed))
        XCTAssertEqual(VisionModePolicy.settled(from: .ending(reason: .doffed)), .off)
    }

    /// A second exit while already leaving must not announce twice — two notices for one event
    /// reads as two failures.
    func testExitingTwiceIsIgnored() {
        XCTAssertNil(VisionModePolicy.exit(from: .ending(reason: .spokenStop), reason: .sessionEnded))
        XCTAssertNil(VisionModePolicy.exit(from: .off, reason: .sessionEnded))
    }

    /// The mode cannot be sat in forever: an open mic and a live camera need a bound that does not
    /// depend on the wearer remembering.
    func testInactivityClosesTheMode() {
        XCTAssertFalse(VisionModePolicy.hasTimedOut(sinceLastQuestion: 10))
        XCTAssertTrue(VisionModePolicy.hasTimedOut(sinceLastQuestion: VisionModePolicy.inactivityTimeout))
    }
}
