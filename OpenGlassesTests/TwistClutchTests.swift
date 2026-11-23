import XCTest
@testable import OpenGlasses

/// Plan NB §3 — when a wrist gesture counts (`TwistClutch`), the press that ends one
/// (`ClutchPressGuard`), and the two gestures together (`LensWristGestures`): headless, with the
/// clock passed in. Every input and sample here is invented.
final class TwistClutchTests: XCTestCase {

    private let start = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }

    private let burst = GlassesInput(kind: .drag(.down), origin: .neuralBandDrag)
    private let select = GlassesInput(kind: .select, origin: .neuralBand)

    // MARK: - The clutch

    func testAPinchsBurstOpensItAndItsSelectClosesIt() {
        var clutch = TwistClutch()
        XCTAssertEqual(clutch.handle(select, at: at(0)), [], "a select with no clutch open does nothing")
        XCTAssertEqual(clutch.handle(burst, at: at(10)), [.opened])
        XCTAssertTrue(clutch.isOpen)
        XCTAssertEqual(clutch.handle(GlassesInput(kind: .drag(.move), origin: .neuralBandDrag), at: at(50)), [])
        XCTAssertEqual(clutch.handle(GlassesInput(kind: .nav(.left), origin: .neuralBand), at: at(60)), [])
        XCTAssertEqual(clutch.handle(select, at: at(900)), [.closed(.select)])
        XCTAssertFalse(clutch.isOpen)
    }

    func testOnlyTheBandsDragBurstOpensIt() {
        var clutch = TwistClutch()
        for input in [GlassesInput(kind: .drag(.down), origin: .captouch),
                      GlassesInput(kind: .drag(.down), origin: .neuralBand),
                      GlassesInput(kind: .drag(.move), origin: .neuralBandDrag),
                      GlassesInput(kind: .drag(.up), origin: .neuralBandDrag),
                      GlassesInput(kind: .nav(.right), origin: .neuralBand)] {
            XCTAssertEqual(clutch.handle(input, at: at(0)), [], "\(input.kind.reportToken) (\(input.origin.rawValue))")
        }
        XCTAssertFalse(clutch.isOpen, "without a burst nothing opens")
    }

    func testANewPinchClosesTheOldClutchAndOpensItsOwn() {
        var clutch = TwistClutch()
        _ = clutch.handle(burst, at: at(0))
        XCTAssertEqual(clutch.handle(burst, at: at(1200)), [.closed(.newPinch), .opened])
        XCTAssertEqual(clutch.openedAt, at(1200))
    }

    func testItClosesAtTheCap() {
        var clutch = TwistClutch()
        _ = clutch.handle(burst, at: at(0))
        XCTAssertNil(clutch.expire(at: at(2999)))
        XCTAssertEqual(clutch.expire(at: at(3000)), .closed(.cap))
        XCTAssertFalse(clutch.isOpen)
        _ = clutch.handle(burst, at: at(4000))
        XCTAssertEqual(clutch.handle(select, at: at(7500)), [.closed(.cap)],
                       "a select after the cap finds it closed already, and closes nothing more")
        XCTAssertEqual(TwistClutch.cap, .seconds(3))
    }

    // MARK: - The press guard

    func testThePressThatEndsAGestureIsDropped() {
        var guardian = ClutchPressGuard()
        guardian.clutchOpened(at: at(0))
        guardian.sent()
        guardian.clutchClosed(at: at(1000))
        XCTAssertTrue(guardian.swallows(at: at(1500)), "Meta's press with the pinch's select")
        XCTAssertFalse(guardian.swallows(at: at(1600)), "one press a clutch")
    }

    func testAPressBeforeTheSelectIsDroppedToo() {
        var guardian = ClutchPressGuard()
        guardian.clutchOpened(at: at(0))
        guardian.sent()
        XCTAssertTrue(guardian.swallows(at: at(900)), "the press may land before the select closes the clutch")
        guardian.clutchClosed(at: at(950))
        XCTAssertFalse(guardian.swallows(at: at(1000)), "that clutch's press was the one dropped")
    }

    func testAPressPastTheWindowOrAfterNoGestureGoesThrough() {
        var guardian = ClutchPressGuard()
        guardian.clutchOpened(at: at(0))
        guardian.sent()
        guardian.clutchClosed(at: at(1000))
        XCTAssertFalse(guardian.swallows(at: at(1801)), "past 800 ms")

        guardian.clutchOpened(at: at(2000))
        guardian.clutchClosed(at: at(2300))
        XCTAssertFalse(guardian.swallows(at: at(2400)), "a plain pinch: nothing was sent, the press is the wearer's")

        guardian.sent()
        XCTAssertFalse(guardian.swallows(at: at(2500)), "a send with no clutch open arms nothing")
    }

    func testAClutchThatNeverClosesStopsGuardingAfterItsCap() {
        var guardian = ClutchPressGuard()
        guardian.clutchOpened(at: at(0))
        guardian.sent()
        XCTAssertFalse(guardian.swallows(at: at(3801)), "past the cap and the window: a lost select never eats presses")
    }

    func testANewPinchClearsTheOldWindow() {
        var guardian = ClutchPressGuard()
        guardian.clutchOpened(at: at(0))
        guardian.sent()
        guardian.clutchClosed(at: at(500))
        guardian.clutchOpened(at: at(700))
        guardian.clutchClosed(at: at(1000))
        XCTAssertFalse(guardian.swallows(at: at(1100)), "the second pinch sent nothing: its press is the wearer's")
    }

    // MARK: - Both gestures

    private let ms: Int64 = 1_000_000

    private func twist(_ t: Int64, _ degrees: Double) -> WristSample {
        WristSample(timestampNs: t * ms, orientation: WristQuaternion(axis: .forearm, angle: WristTwist.radians(degrees)))
    }

    private func arm(_ t: Int64, yaw: Double) -> WristSample {
        WristSample(timestampNs: t * ms, orientation: WristQuaternion(axis: .up, angle: WristTwist.radians(yaw)))
    }

    private func feed(_ gestures: inout LensWristGestures, _ samples: [WristSample]) -> [LensWristGestures.Output] {
        samples.flatMap { gestures.sample($0, at: at(Int($0.timestampNs / ms))) }
    }

    func testNothingCountsOutsideAClutch() {
        var gestures = LensWristGestures()
        XCTAssertEqual(feed(&gestures, [twist(0, 0), twist(200, 0), twist(300, 60)]), [])
    }

    func testATwistInAClutchSendsRungs() {
        var gestures = LensWristGestures()
        let on = LensWristGestures.Switches(twist: true, pan: false)
        XCTAssertEqual(gestures.input(burst, at: at(0), switches: on), [.clutchOpened])
        let out = feed(&gestures, [twist(0, 0), twist(200, 0), twist(240, 25), twist(280, 45)])
        XCTAssertEqual(out, [.rung(.zoomIn), .rung(.zoomIn)])
        XCTAssertEqual(gestures.owner, .twist)
        XCTAssertEqual(gestures.input(select, at: at(400), switches: on), [.clutchClosed(.select)])
        XCTAssertNil(gestures.owner)
        XCTAssertEqual(feed(&gestures, [twist(500, 90)]), [], "closed: nothing")
    }

    func testTheReversedTwistIsReadAtTheClutch() {
        var gestures = LensWristGestures()
        _ = gestures.input(burst, at: at(0), switches: .init(twist: true, pan: false, direction: .anticlockwiseZoomsIn))
        XCTAssertEqual(feed(&gestures, [twist(0, 0), twist(200, 0), twist(240, 25)]), [.rung(.zoomOut)])
    }

    func testEachClutchStartsAfresh() {
        var gestures = LensWristGestures()
        let on = LensWristGestures.Switches(twist: true, pan: false)
        _ = gestures.input(burst, at: at(0), switches: on)
        XCTAssertEqual(feed(&gestures, [twist(0, 0), twist(200, 0), twist(240, 130)]).count, 6, "the cap")
        XCTAssertEqual(gestures.input(burst, at: at(1000), switches: on), [.clutchClosed(.newPinch), .clutchOpened])
        XCTAssertEqual(feed(&gestures, [twist(1000, 130), twist(1200, 130), twist(1240, 150)]), [.rung(.zoomIn)],
                       "a new reference and a new cap")
    }

    func testTheCapClosesTheClutchOnTheNextSample() {
        var gestures = LensWristGestures()
        _ = gestures.input(burst, at: at(0), switches: .init(twist: true, pan: false))
        XCTAssertEqual(gestures.sample(twist(3100, 0), at: at(3100)), [.clutchClosed(.cap)])
        XCTAssertEqual(gestures.expire(at: at(4000)), [])
    }

    func testThePanAloneSendsSteps() {
        var gestures = LensWristGestures()
        _ = gestures.input(burst, at: at(0), switches: .init(twist: false, pan: true))
        let turned = WristSample(timestampNs: 280 * ms,
                                 orientation: WristQuaternion(axis: .up, angle: WristTwist.radians(14))
                                     * WristQuaternion(axis: .forearm, angle: WristTwist.radians(90)))
        let out = feed(&gestures, [arm(0, yaw: 0), arm(200, yaw: 0), arm(240, yaw: 14), turned])
        XCTAssertEqual(out, [.pan(.left)], "with the twist off a twist does nothing")
        XCTAssertEqual(gestures.owner, .pan)
    }

    func testWithBothOnTheFirstPastItsThresholdOwnsTheClutch() {
        let both = LensWristGestures.Switches(twist: true, pan: true)
        // The twist first: an arm move later in the same clutch is ignored.
        var twisting = LensWristGestures()
        _ = twisting.input(burst, at: at(0), switches: both)
        let out = feed(&twisting, [twist(0, 0), twist(200, 0), twist(240, 22),
                                   WristSample(timestampNs: 280 * ms,
                                               orientation: WristQuaternion(axis: .up, angle: WristTwist.radians(30))
                                                   * WristQuaternion(axis: .forearm, angle: WristTwist.radians(22)))])
        XCTAssertEqual(out, [.rung(.zoomIn)])
        XCTAssertEqual(twisting.owner, .twist)

        // The arm first: a twist later in the same clutch is ignored.
        var panning = LensWristGestures()
        _ = panning.input(burst, at: at(0), switches: both)
        let panned = feed(&panning, [arm(0, yaw: 0), arm(200, yaw: 0), arm(240, yaw: -15),
                                     WristSample(timestampNs: 280 * ms,
                                                 orientation: WristQuaternion(axis: .up, angle: WristTwist.radians(-15))
                                                     * WristQuaternion(axis: .forearm, angle: WristTwist.radians(60)))])
        XCTAssertEqual(panned, [.pan(.right)])
        XCTAssertEqual(panning.owner, .pan)

        // The next clutch is anyone's again.
        _ = panning.input(select, at: at(400), switches: both)
        _ = panning.input(burst, at: at(500), switches: both)
        XCTAssertNil(panning.owner)
        XCTAssertEqual(feed(&panning, [twist(500, 0), twist(700, 0), twist(740, 21)]), [.rung(.zoomIn)])
    }
}
