import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan KH. Phone frames go to the encoder without passing the blur, so these hold what a stream
/// may do with Blur Bystander Faces on, whichever way it was reached.
@MainActor
final class BroadcastSafetyTests: XCTestCase {

    private func live(_ change: (inout BroadcastGoLive.LiveFacts) -> Void = { _ in }) -> BroadcastGoLive.LiveFacts {
        var facts = BroadcastGoLive.LiveFacts(isBroadcasting: true, activeSource: .phoneBack,
                                              phoneInsetOn: false, faceBlurOn: true, glassesConnected: true)
        change(&facts)
        return facts
    }

    // MARK: - A switch during a stream

    func testASwitchToAPhoneCameraIsRefusedWithTheBlurOn() {
        XCTAssertEqual(BroadcastGoLive.decideSwitch(to: .phoneBack, faceBlurOn: true), .phoneCameraNotBlurred)
        XCTAssertEqual(BroadcastGoLive.decideSwitch(to: .phoneFront, faceBlurOn: true), .phoneCameraNotBlurred)
    }

    func testTheGlassesAreAlwaysOpen() {
        XCTAssertEqual(BroadcastGoLive.decideSwitch(to: .glasses, faceBlurOn: true), .switchCamera)
        XCTAssertEqual(BroadcastGoLive.decideSwitch(to: .glasses, faceBlurOn: false), .switchCamera)
    }

    func testASwitchIsOpenWithTheBlurOff() {
        XCTAssertEqual(BroadcastGoLive.decideSwitch(to: .phoneBack, faceBlurOn: false), .switchCamera)
    }

    // MARK: - The blur coming on during a stream

    func testAPhoneStreamMovesToTheGlassesWhenThereAreGlasses() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live()), .moveToGlasses)
        XCTAssertEqual(BroadcastGoLive.whileLive(live { $0.activeSource = .phoneFront }), .moveToGlasses)
    }

    func testAPhoneStreamEndsWhenThereAreNoGlasses() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live { $0.glassesConnected = false }), .end(.blurNeedsGlasses))
    }

    func testAGlassesStreamLosesOnlyItsInset() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live {
            $0.activeSource = .glasses
            $0.phoneInsetOn = true
        }), .dropPhoneInset)
    }

    func testAGlassesStreamCarriesOn() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live { $0.activeSource = .glasses }), .carryOn)
    }

    func testThePhoneStreamCarriesOnWithTheBlurOff() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live { $0.faceBlurOn = false }), .carryOn)
    }

    func testNothingHappensOffAir() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live { $0.isBroadcasting = false }), .carryOn)
    }

    func testEndingSaysWhy() {
        XCTAssertTrue(BroadcastGoLive.endMessage(.blurNeedsGlasses).contains("no glasses"))
        XCTAssertTrue(BroadcastGoLive.endMessage(.glassesGaveNoPicture).contains("didn't start"))
    }

    // MARK: - The move itself

    /// A safety move cannot wait out the debounce: faces would go out for up to a second.
    func testASafetyMoveIgnoresTheDebounce() {
        var selector = BroadcastSourceSelector(initial: .glasses, debounce: 1.0)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(selector.requestSwitch(to: .phoneBack, now: start))
        selector.moveNow(to: .glasses, now: start.addingTimeInterval(0.1))
        XCTAssertEqual(selector.active, .glasses)
    }

    func testASafetyMoveStartsTheDebounce() {
        var selector = BroadcastSourceSelector(initial: .phoneBack, debounce: 1.0)
        let start = Date(timeIntervalSince1970: 100)
        selector.moveNow(to: .glasses, now: start)
        XCTAssertFalse(selector.requestSwitch(to: .phoneBack, now: start.addingTimeInterval(0.5)))
    }

    // MARK: - The service holds the rule without a caller's help

    func testTheServiceRefusesAPhoneStartWithTheBlurOn() async {
        let service = BroadcastService()
        service.faceBlurOn = { true }
        do {
            try await service.startBroadcast(rtmpURL: "rtmp://example.invalid/live", streamKey: "key",
                                             from: PassthroughSubject<UIImage, Never>(), source: .phoneBack)
            XCTFail("a phone stream started with the blur on")
        } catch {
            XCTAssertEqual(error as? BroadcastError, .phoneCameraNotBlurred)
        }
        XCTAssertFalse(service.isBroadcasting)
    }

    func testTheServiceRefusesASwitchOffAir() {
        let service = BroadcastService()
        XCTAssertFalse(service.switchSource(.phoneBack))
    }

    func testTheInsetIsNotReportedOffAir() {
        XCTAssertFalse(BroadcastService().isPhoneInsetOn)
    }

    // MARK: - Every writer of the blur reaches the rule

    func testEveryWriterOfTheBlurEnforcesTheRule() throws {
        let source = try String(contentsOf: Self.appFile, encoding: .utf8)
        for writer in ["func setBystanderBlur(", "func applyOrgPolicyChange("] {
            let body = try XCTUnwrap(source.range(of: writer))
            let window = source[body.lowerBound...].prefix(600)
            XCTAssertTrue(window.contains("enforceBroadcastRules()"), writer)
        }
    }

    // MARK: - Medical Compliance

    func testGoLiveIsBlockedInAllOfMedicalCompliance() {
        XCTAssertEqual(BroadcastGoLive.decide(.init(
            isBroadcasting: false, isConfigured: true, preferredSource: .glasses, glassesConnected: true,
            faceBlurOn: false, phoneCameraDenied: false, setupReachable: true, medicalCompliance: true)),
                       .blockedByMedicalCompliance)
    }

    /// Setting up a key would not change the answer, so that is not what it says.
    func testTheBlockComesBeforeSetup() {
        XCTAssertEqual(BroadcastGoLive.decide(.init(
            isBroadcasting: false, isConfigured: false, preferredSource: .glasses, glassesConnected: true,
            faceBlurOn: false, phoneCameraDenied: false, setupReachable: true, medicalCompliance: true)),
                       .blockedByMedicalCompliance)
    }

    func testStoppingWinsOverTheBlock() {
        XCTAssertEqual(BroadcastGoLive.decide(.init(
            isBroadcasting: true, isConfigured: true, preferredSource: .glasses, glassesConnected: true,
            faceBlurOn: false, phoneCameraDenied: false, setupReachable: true, medicalCompliance: true)),
                       .toggle(startSource: nil))
    }

    func testMedicalComplianceEndsARunningStreamOnEitherCamera() {
        for source in BroadcastVideoSource.allCases {
            for blur in [true, false] {
                XCTAssertEqual(BroadcastGoLive.whileLive(live {
                    $0.activeSource = source
                    $0.faceBlurOn = blur
                    $0.medicalCompliance = true
                }), .end(.medicalCompliance), "\(source)")
            }
        }
    }

    func testMedicalComplianceDoesNothingOffAir() {
        XCTAssertEqual(BroadcastGoLive.whileLive(live {
            $0.isBroadcasting = false
            $0.medicalCompliance = true
        }), .carryOn)
    }

    func testTheEndOfAStreamSaysWhy() {
        XCTAssertTrue(BroadcastGoLive.endMessage(.medicalCompliance).contains("Medical Compliance"))
    }

    func testTheServiceRefusesAStartInMedicalCompliance() async {
        let service = BroadcastService()
        service.faceBlurOn = { false }
        service.medicalComplianceOn = { true }
        do {
            try await service.startBroadcast(rtmpURL: "rtmp://example.invalid/live", streamKey: "key",
                                             from: PassthroughSubject<UIImage, Never>(), source: .glasses)
            XCTFail("a stream started in Medical Compliance mode")
        } catch {
            XCTAssertEqual(error as? BroadcastError, .blockedByMedicalCompliance)
        }
        XCTAssertFalse(service.isBroadcasting)
    }

    /// The mode's one entry point has to reach the rule, or a stream would outlive it.
    func testTurningTheModeOnReachesTheRunningStream() throws {
        let source = try String(contentsOf: Self.appFile, encoding: .utf8)
        let hook = try XCTUnwrap(source.range(of: "hipaaService.onModeChanged = {"))
        XCTAssertTrue(source[hook.lowerBound...].prefix(900).contains("enforceBroadcastRules()"))
    }

    /// Local Only closes the browser stream's route, so it must not report a stream to nothing.
    func testTheBrowserStreamRefusesToStartInLocalOnly() {
        let original = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { .localOnly }
        defer { MedicalEgressGuard.currentMode = original }
        let service = WebRTCStreamingService()
        XCTAssertEqual(service.startStreaming(framePublisher: PassthroughSubject<UIImage, Never>()), "")
        XCTAssertFalse(service.isStreaming)
        XCTAssertEqual(service.errorMessage, MedicalEgressRefusal.userMessage)
    }

    func testThePreviewSaysWhyThereIsNoGoLive() {
        XCTAssertTrue(LivePreviewPicture.streamingOffCaption.contains("Medical Compliance"))
    }

    private static var appFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
    }
}

/// Plan KH. Siri and Shortcuts go through the same checks as Go Live, and neither may put an open
/// microphone on air over a black picture or raise a prompt with nobody holding the phone.
final class BroadcastIntentTests: XCTestCase {

    private func facts(_ change: (inout BroadcastGoLive.Facts) -> Void = { _ in }) -> BroadcastGoLive.Facts {
        var facts = BroadcastGoLive.Facts(
            isBroadcasting: false, isConfigured: true, preferredSource: .glasses,
            glassesConnected: true, faceBlurOn: false, phoneCameraDenied: false, setupReachable: true)
        change(&facts)
        return facts
    }

    private func decide(notAsked: Bool = false, _ change: (inout BroadcastGoLive.Facts) -> Void = { _ in })
        -> BroadcastGoLive.IntentDecision {
        BroadcastGoLive.decideForIntent(facts(change), phoneCameraNotAsked: notAsked)
    }

    func testItStartsOnTheGlassesWithGlasses() {
        XCTAssertEqual(decide(), .start(.glasses))
    }

    func testItStartsOnTheCameraTheSettingNames() {
        XCTAssertEqual(decide { $0.preferredSource = .phoneFront }, .start(.phoneFront))
    }

    func testItFallsBackToThePhoneAsGoLiveDoes() {
        XCTAssertEqual(decide { $0.glassesConnected = false }, .start(.phoneBack))
    }

    func testNotSetUpIsARefusalNotAnError() {
        XCTAssertEqual(decide { $0.isConfigured = false }, .refuse(.notSetUp))
    }

    func testEveryPhoneRouteIsRefusedWithTheBlurOn() {
        XCTAssertEqual(decide { $0.glassesConnected = false; $0.faceBlurOn = true },
                       .refuse(.phoneCameraNotBlurred(.fallback)))
        XCTAssertEqual(decide { $0.preferredSource = .phoneBack; $0.faceBlurOn = true },
                       .refuse(.phoneCameraNotBlurred(.chosen)))
        XCTAssertEqual(decide { $0.dualCaptureOn = true; $0.faceBlurOn = true },
                       .refuse(.phoneCameraNotBlurred(.inset)))
    }

    func testARefusedPhoneCameraIsSaid() {
        XCTAssertEqual(decide { $0.glassesConnected = false; $0.phoneCameraDenied = true },
                       .refuse(.phoneCameraDenied))
    }

    /// An intent never raises the iOS prompt. The preview can, because someone is looking at it.
    func testAnIntentIsRefusedInMedicalCompliance() {
        XCTAssertEqual(decide { $0.medicalCompliance = true }, .refuse(.medicalCompliance))
        XCTAssertEqual(decide { $0.medicalCompliance = true; $0.isBroadcasting = true }, .stop)
    }

    func testAnIntentNeverAsksForThePhoneCamera() {
        XCTAssertEqual(decide(notAsked: true) { $0.glassesConnected = false }, .refuse(.phoneCameraNotAsked))
        XCTAssertEqual(decide(notAsked: true) { $0.preferredSource = .phoneBack }, .refuse(.phoneCameraNotAsked))
        XCTAssertEqual(decide(notAsked: true) { $0.dualCaptureOn = true }, .refuse(.phoneCameraNotAsked))
    }

    func testAPhoneCameraNobodyAskedAboutDoesNotStopAGlassesStream() {
        XCTAssertEqual(decide(notAsked: true), .start(.glasses))
    }

    func testStoppingAlwaysWins() {
        XCTAssertEqual(decide(notAsked: true) {
            $0.isBroadcasting = true
            $0.isConfigured = false
            $0.glassesConnected = false
            $0.faceBlurOn = true
            $0.phoneCameraDenied = true
            $0.dualCaptureOn = true
        }, .stop)
    }

    func testEveryRefusalHasItsOwnSentence() {
        let refusals: [BroadcastGoLive.IntentRefusal] = [
            .notSetUp, .medicalCompliance, .phoneCameraNotBlurred(.fallback), .phoneCameraNotBlurred(.chosen),
            .phoneCameraNotBlurred(.inset), .phoneCameraDenied, .phoneCameraNotAsked, .noPicture,
            .couldNotConnect,
        ]
        let sentences = refusals.map(BroadcastGoLive.spokenRefusal)
        XCTAssertEqual(Set(sentences).count, refusals.count)
    }

    /// Both intents reach the stream through the one that proves a picture, and no intent can start
    /// a stream by the plain toggle.
    func testNoIntentCallsThePlainToggle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/Intents")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var callers = 0
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains(".toggleBroadcast("), file.lastPathComponent)
            if source.contains(".toggleBroadcastFromIntent()") { callers += 1 }
        }
        XCTAssertEqual(callers, 2)
    }
}
