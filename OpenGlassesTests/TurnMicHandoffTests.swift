import XCTest
@testable import OpenGlasses

/// Plan GU §2 — switch first, then listen. The tone (`startTurn`) only ever comes after the route
/// resolved to the target **and** live frames arrived, or at the deadline on the phone.
final class TurnMicHandoffTests: XCTestCase {

    // MARK: - Target

    func testTargetIsTheConversationMicWhenItIsThere() {
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .glasses, glassesStoodDown: false, glassesWorn: true,
                                             routePortAvailable: true), .glasses)
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .glasses, glassesStoodDown: false, glassesWorn: nil,
                                             routePortAvailable: true), .glasses,
                       "unknown worn state (non-Meta glasses) keeps the glasses mic")
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .headset, glassesStoodDown: false, glassesWorn: nil,
                                             routePortAvailable: true), .headset)
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .phone, glassesStoodDown: false, glassesWorn: true,
                                             routePortAvailable: true), .phone)
    }

    func testGlassesNotInUseGoStraightToThePhone() {
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .glasses, glassesStoodDown: true, glassesWorn: true,
                                             routePortAvailable: true), .phone, "stood down")
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .glasses, glassesStoodDown: false, glassesWorn: false,
                                             routePortAvailable: true), .phone,
                       "off the face with the link up: the phone (Greig, answer 2)")
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .glasses, glassesStoodDown: false, glassesWorn: true,
                                             routePortAvailable: false), .phone, "port not there")
        XCTAssertEqual(TurnMicHandoff.target(micRoute: .headset, glassesStoodDown: false, glassesWorn: nil,
                                             routePortAvailable: false), .phone)
    }

    // MARK: - Sequencing

    func testRouteThenFramesThenTheTurn() {
        var m = TurnMicHandoff.Machine(target: .glasses)
        XCTAssertEqual(m.handle(.routeObserved(.phone)), .none, "not there yet")
        XCTAssertEqual(m.handle(.routeObserved(nil)), .none)
        XCTAssertEqual(m.handle(.routeObserved(.glasses)), .buildEngine)
        XCTAssertEqual(m.state, .waitingForFrames)
        XCTAssertEqual(m.handle(.framesNonSilent), .startTurn(on: .glasses))
        XCTAssertEqual(m.state, .live(.glasses))
    }

    func testToneNeverBeforeLive() {
        // Frames before the route was seen — a half-up link's buffers on the old input — must not
        // start the turn.
        var m = TurnMicHandoff.Machine(target: .glasses)
        XCTAssertEqual(m.handle(.framesNonSilent), .none)
        XCTAssertEqual(m.state, .waitingForRoute)
        // The route alone is not enough either.
        _ = m.handle(.routeObserved(.glasses))
        XCTAssertNotEqual(m.state, .live(.glasses))
    }

    func testDeadlineFallsBackToThePhone() {
        var waitingForRoute = TurnMicHandoff.Machine(target: .glasses)
        XCTAssertEqual(waitingForRoute.handle(.deadline), .fallBackToPhone)
        XCTAssertEqual(waitingForRoute.state, .fellBack)

        var waitingForFrames = TurnMicHandoff.Machine(target: .headset)
        _ = waitingForFrames.handle(.routeObserved(.headset))
        XCTAssertEqual(waitingForFrames.handle(.deadline), .fallBackToPhone, "a link that is up but silent")
        XCTAssertEqual(TurnMicHandoff.deadline, 2.0)
    }

    func testThePhoneStartsAtTheDeadlineRatherThanFallingFurther() {
        var m = TurnMicHandoff.Machine(target: .phone)
        XCTAssertEqual(m.handle(.deadline), .startTurn(on: .phone))
        XCTAssertEqual(m.state, .live(.phone))
    }

    func testNothingStartsTwice() {
        var m = TurnMicHandoff.Machine(target: .glasses)
        _ = m.handle(.routeObserved(.glasses))
        XCTAssertEqual(m.handle(.framesNonSilent), .startTurn(on: .glasses))
        XCTAssertEqual(m.handle(.framesNonSilent), .none)
        XCTAssertEqual(m.handle(.deadline), .none, "a deadline after going live does nothing")
        var fell = TurnMicHandoff.Machine(target: .glasses)
        _ = fell.handle(.deadline)
        XCTAssertEqual(fell.handle(.routeObserved(.glasses)), .none, "too late: the phone has the turn")
        XCTAssertEqual(fell.handle(.framesNonSilent), .none)
    }

    func testLiveFramesAreAboveTheZeroFloor() {
        XCTAssertFalse(TurnMicHandoff.isLiveFrame(rms: 0), "a half-up link's all-zero frames")
        XCTAssertFalse(TurnMicHandoff.isLiveFrame(rms: 1e-7))
        XCTAssertTrue(TurnMicHandoff.isLiveFrame(rms: 1e-4), "a quiet room is still a live mic")
    }
}
