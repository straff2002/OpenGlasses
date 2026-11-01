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

    private static var appFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
    }
}
