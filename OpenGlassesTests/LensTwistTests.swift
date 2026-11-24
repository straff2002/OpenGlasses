import XCTest
@testable import OpenGlasses

/// Plan NB §2 — the wrist in the app's own words, headless: the twist from a quaternion, its
/// confidence, one clutch's tracker (orientation first, the gyroscope as fallback), the detent
/// that turns it into rungs, and the arm's pan. Every sample here is invented.
final class LensTwistTests: XCTestCase {

    private func deg(_ d: Double) -> Double { WristTwist.radians(d) }

    /// A twist of `degrees` about the forearm (band-local +Y).
    private func twist(_ degrees: Double) -> WristQuaternion {
        WristQuaternion(axis: .forearm, angle: deg(degrees))
    }

    private let ms: Int64 = 1_000_000

    private func sample(_ t: Int64, _ q: WristQuaternion? = nil, gyroY: Double? = nil) -> WristSample {
        WristSample(timestampNs: t * ms, orientation: q, gyroscope: gyroY.map { WristVector(x: 0, y: $0, z: 0) })
    }

    // MARK: - The twist from a quaternion

    func testTheTwistOfAKnownRotationAboutTheForearm() {
        XCTAssertEqual(WristTwist.angle(of: .identity), 0, accuracy: 1e-12)
        for d in [-170.0, -90, -45, -20, 0, 5, 20, 45, 90, 135, 170] {
            XCTAssertEqual(WristTwist.angle(of: twist(d)), deg(d), accuracy: 1e-9, "\(d)°")
        }
    }

    func testARotationAboutAnotherAxisIsNoTwist() {
        for axis in [WristVector(x: 1, y: 0, z: 0), WristVector(x: 0, y: 0, z: 1)] {
            XCTAssertEqual(WristTwist.angle(of: WristQuaternion(axis: axis, angle: deg(40))), 0, accuracy: 1e-12)
        }
    }

    func testTheTwistSurvivesASwingOfTheForearm() {
        // The forearm swung 30° about up, after a 25° twist about itself: the twist part is kept.
        let swing = WristQuaternion(axis: .up, angle: deg(30))
        XCTAssertEqual(WristTwist.angle(of: swing * twist(25)), deg(25), accuracy: 1e-9)
    }

    func testTheNegatedQuaternionIsTheSameTwist() {
        let q = twist(60)
        let negated = WristQuaternion(x: -q.x, y: -q.y, z: -q.z, w: -q.w)
        XCTAssertEqual(WristTwist.angle(of: negated), deg(60), accuracy: 1e-9)
    }

    func testAnUnnormalisedQuaternionIsNormalised() {
        let q = twist(30)
        let scaled = WristQuaternion(x: q.x * 3, y: q.y * 3, z: q.z * 3, w: q.w * 3)
        XCTAssertEqual(WristTwist.angle(of: scaled), deg(30), accuracy: 1e-9)
    }

    func testWrapIsAHalfOpenTurnAroundZero() {
        XCTAssertEqual(WristTwist.wrap(deg(179) - deg(-179)), deg(-2), accuracy: 1e-9, "+179° to −179° is a 2° step")
        XCTAssertEqual(WristTwist.wrap(deg(-179) - deg(179)), deg(2), accuracy: 1e-9)
        XCTAssertEqual(WristTwist.wrap(.pi), -.pi, accuracy: 1e-12, "[−π, π)")
        XCTAssertEqual(WristTwist.wrap(-.pi), -.pi, accuracy: 1e-12)
        XCTAssertEqual(WristTwist.wrap(deg(370)), deg(10), accuracy: 1e-9)
        XCTAssertEqual(WristTwist.wrap(deg(-725)), deg(-5), accuracy: 1e-9)
        XCTAssertEqual(WristTwist.wrap(.infinity), 0)
    }

    // MARK: - Confidence

    func testConfidenceFallsAsTheForearmPointsUpOrDown() {
        XCTAssertEqual(WristTwist.confidence(of: .identity), 1, accuracy: 1e-12, "level")
        XCTAssertEqual(WristTwist.confidence(of: twist(80)), 1, accuracy: 1e-9, "a twist keeps the forearm level")
        // Pitched about the world's x: the forearm (+Y) tilts towards up (+Z).
        let up = WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(90))
        XCTAssertEqual(WristTwist.confidence(of: up), 0, accuracy: 1e-9, "straight up")
        let down = WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(-90))
        XCTAssertEqual(WristTwist.confidence(of: down), 0, accuracy: 1e-9, "straight down")
        let thirty = WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(30))
        XCTAssertEqual(WristTwist.confidence(of: thirty), 0.5, accuracy: 1e-9, "1 − sin 30°")
        let steep = WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(60))
        XCTAssertLessThan(WristTwist.confidence(of: steep), WristTwist.minimumConfidence, "too steep to use")
    }

    // MARK: - The tracker

    func testTheReferenceIsTakenAfterTheSettleNeverFromTheFirstSample() {
        var tracker = TwistTracker()
        XCTAssertNil(tracker.add(sample(0, twist(50))), "the very first sample is never the reference")
        XCTAssertNil(tracker.add(sample(100, twist(40))), "still settling")
        XCTAssertEqual(tracker.add(sample(160, twist(10))), 0, "the first sample after 150 ms")
        XCTAssertEqual(tracker.add(sample(200, twist(25)))!, deg(15), accuracy: 1e-9)
        XCTAssertEqual(tracker.add(sample(240, twist(-5)))!, deg(-15), accuracy: 1e-9)
    }

    func testTheTrackerUnwrapsPastHalfATurn() {
        var tracker = TwistTracker()
        _ = tracker.add(sample(0, twist(170)))
        _ = tracker.add(sample(600, twist(170)))
        XCTAssertEqual(tracker.add(sample(640, twist(179)))!, deg(9), accuracy: 1e-9)
        XCTAssertEqual(tracker.add(sample(680, twist(-179)))!, deg(11), accuracy: 1e-9, "+179° to −179° is 2° more")
        XCTAssertEqual(tracker.add(sample(720, twist(-160)))!, deg(30), accuracy: 1e-9)
    }

    func testAFlipInTheFirstHalfSecondRetakesTheReference() {
        var tracker = TwistTracker()
        _ = tracker.add(sample(0, twist(0)))
        XCTAssertEqual(tracker.add(sample(160, twist(10))), 0)
        XCTAssertEqual(tracker.add(sample(200, twist(-150))), 0, "a 160° jump while settling: the frame, not the wrist")
        XCTAssertEqual(tracker.rereferences, 1)
        XCTAssertEqual(tracker.add(sample(240, twist(-130)))!, deg(20), accuracy: 1e-9)
        // After the first 500 ms a big step is the wrist (or nothing to undo): it is kept.
        XCTAssertEqual(tracker.add(sample(700, twist(0)))!, deg(150), accuracy: 1e-9)
        XCTAssertEqual(tracker.rereferences, 1)
    }

    func testTheGyroscopeFillsInWhereTheOrientationIsMissing() {
        var tracker = TwistTracker()
        _ = tracker.add(sample(0, twist(0)))
        XCTAssertEqual(tracker.add(sample(200, twist(0))), 0)
        // 2 rad/s about the forearm for 50 ms = 0.1 rad.
        XCTAssertEqual(tracker.add(sample(250, gyroY: 2))!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(tracker.add(sample(300, gyroY: 2))!, 0.2, accuracy: 1e-9)
        // The orientation comes back: rebased there, never jumped to.
        XCTAssertEqual(tracker.add(sample(350, twist(90)))!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(tracker.add(sample(400, twist(100)))!, 0.2 + deg(10), accuracy: 1e-9)
    }

    func testAGapInTheGyroscopeIsCappedAtATenthOfASecond() {
        var tracker = TwistTracker()
        _ = tracker.add(sample(0, gyroY: 1))
        XCTAssertEqual(tracker.add(sample(200, gyroY: 1)), 0, "a gyroscope-only reference")
        XCTAssertEqual(tracker.add(sample(2200, gyroY: 1))!, 0.1, accuracy: 1e-9, "two seconds' gap counts as 100 ms")
    }

    func testOutOfOrderAndEmptyAndSteepSamplesAreNotUsed() {
        var tracker = TwistTracker()
        _ = tracker.add(sample(0, twist(0)))
        _ = tracker.add(sample(200, twist(0)))
        XCTAssertEqual(tracker.add(sample(250, twist(20)))!, deg(20), accuracy: 1e-9)
        XCTAssertEqual(tracker.add(sample(220, twist(80)))!, deg(20), accuracy: 1e-9, "older than the last: ignored")
        XCTAssertEqual(tracker.add(sample(300))!, deg(20), accuracy: 1e-9, "no orientation, no gyroscope")
        let steep = WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(70)) * twist(60)
        XCTAssertEqual(tracker.add(WristSample(timestampNs: 320 * ms, orientation: steep,
                                               gyroscope: WristVector(x: 0, y: 5, z: 0)))!,
                       deg(20), accuracy: 1e-9, "a forearm near vertical: not used at all")
    }

    // MARK: - The detent

    func testEveryTwentyDegreesIsOneRung() {
        var detent = TwistZoomDetent(direction: .clockwiseZoomsIn)
        XCTAssertEqual(detent.update(angle: deg(19)), [])
        XCTAssertEqual(detent.update(angle: deg(20)), [.zoomIn])
        XCTAssertEqual(detent.update(angle: deg(39)), [], "the next needs 20° more from the last")
        XCTAssertEqual(detent.update(angle: deg(41)), [.zoomIn])
        XCTAssertEqual(detent.update(angle: deg(85)), [.zoomIn, .zoomIn], "a fast turn: each detent passed")
    }

    func testTurningBackNeedsTheHysteresisToo() {
        var detent = TwistZoomDetent(direction: .clockwiseZoomsIn)
        XCTAssertEqual(detent.update(angle: deg(21)), [.zoomIn])
        XCTAssertEqual(detent.update(angle: deg(1)), [], "20° back is not enough to reverse")
        XCTAssertEqual(detent.update(angle: deg(-4)), [], "24° back")
        XCTAssertEqual(detent.update(angle: deg(-5)), [.zoomOut], "detent + hysteresis back")
        XCTAssertEqual(detent.update(angle: deg(-24)), [], "the next out needs 20° more")
        XCTAssertEqual(detent.update(angle: deg(-25)), [.zoomOut])
        XCTAssertEqual(detent.update(angle: deg(-5)), [], "a hover back is not a rung in")
    }

    func testANegativeTwistZoomsOutAndTheDirectionReverses() {
        var forward = TwistZoomDetent(direction: .clockwiseZoomsIn)
        XCTAssertEqual(forward.update(angle: deg(-20)), [.zoomOut])
        var reversed = TwistZoomDetent(direction: .anticlockwiseZoomsIn)
        XCTAssertEqual(reversed.update(angle: deg(20)), [.zoomOut])
        XCTAssertEqual(reversed.update(angle: deg(-5)), [.zoomIn])
        XCTAssertEqual(TwistDirection.current(reversed: false), .clockwiseZoomsIn)
        XCTAssertEqual(TwistDirection.current(reversed: true), .anticlockwiseZoomsIn)
        XCTAssertTrue(TwistDirection.clockwiseIsPositive, "the constant the device pass sets")
    }

    func testAtMostSixRungsAClutch() {
        var detent = TwistZoomDetent(direction: .clockwiseZoomsIn)
        XCTAssertEqual(detent.update(angle: deg(200)).count, 6)
        XCTAssertTrue(detent.isCapped)
        XCTAssertEqual(detent.update(angle: deg(-200)), [], "capped either way until the next clutch")
        XCTAssertEqual(TwistZoomDetent.maxRungsPerClutch, 6)
        XCTAssertEqual(WristTwist.degrees(TwistZoomDetent.detent), 20, accuracy: 1e-9)
        XCTAssertEqual(WristTwist.degrees(TwistZoomDetent.hysteresis), 5, accuracy: 1e-9)
    }

    func testTheTrackerAndDetentTogetherFromSamples() {
        var tracker = TwistTracker()
        var detent = TwistZoomDetent(direction: .clockwiseZoomsIn)
        var rungs: [TwistRung] = []
        var t: Int64 = 0
        for d in stride(from: 0.0, through: 70, by: 2) {
            if let angle = tracker.add(sample(t, twist(d))) { rungs += detent.update(angle: angle) }
            t += 33
        }
        // Referenced at the first sample past 150 ms (t = 165, 10°): 60° of turn after it.
        XCTAssertEqual(rungs, [.zoomIn, .zoomIn, .zoomIn])
    }

    // MARK: - The arm's pan

    /// The forearm turned `yaw` about up and pitched `pitch` up, with a twist about itself.
    private func arm(yaw: Double, pitch: Double, twist t: Double = 0) -> WristQuaternion {
        // Pitch about the world's x first (+Y towards +Z), then yaw about up.
        WristQuaternion(axis: .up, angle: deg(yaw))
            * WristQuaternion(axis: WristVector(x: 1, y: 0, z: 0), angle: deg(pitch)) * twist(t)
    }

    func testTheArmsDirectionFromAQuaternion() {
        let d = ArmPan.direction(of: arm(yaw: 30, pitch: 10))
        XCTAssertEqual(WristTwist.degrees(d.pitch), 10, accuracy: 1e-9)
        XCTAssertEqual(WristTwist.degrees(WristTwist.wrap(d.yaw - ArmPan.direction(of: .identity).yaw)), 30, accuracy: 1e-9)
    }

    func testPastTwelveDegreesTheArmStepsThatWayAndReanchors() {
        var pan = ArmPan()
        XCTAssertNil(pan.update(sample(0, arm(yaw: 0, pitch: 0))))
        XCTAssertNil(pan.update(sample(160, arm(yaw: 0, pitch: 0))), "the reference, after the settle")
        XCTAssertNil(pan.update(sample(200, arm(yaw: 11, pitch: 0))))
        XCTAssertEqual(pan.update(sample(240, arm(yaw: 13, pitch: 0))), .left, "anticlockwise from above: left")
        XCTAssertNil(pan.update(sample(280, arm(yaw: 20, pitch: 0))), "re-anchored at 13°")
        XCTAssertEqual(pan.update(sample(320, arm(yaw: 26, pitch: 0))), .left)
        XCTAssertEqual(pan.update(sample(360, arm(yaw: 10, pitch: 0))), .right)
        XCTAssertEqual(pan.update(sample(400, arm(yaw: 10, pitch: 14))), .up)
        XCTAssertEqual(pan.update(sample(440, arm(yaw: 10, pitch: 0))), .down)
        XCTAssertEqual(pan.stepsSent, 5)
    }

    func testATwistAloneNeverPans() {
        var pan = ArmPan()
        _ = pan.update(sample(0, .identity))
        _ = pan.update(sample(160, .identity))
        for (i, d) in [20.0, 45, 80, -60].enumerated() {
            XCTAssertNil(pan.update(sample(200 + Int64(i) * 40, twist(d))), "a twist about the forearm keeps its direction")
        }
    }

    func testTheArmIgnoresSamplesWithNoOrientationOrTooSteep() {
        var pan = ArmPan()
        _ = pan.update(sample(0, .identity))
        XCTAssertNil(pan.update(sample(160, gyroY: 3)), "no orientation")
        XCTAssertNil(pan.update(sample(170, arm(yaw: 0, pitch: 75))), "too steep to be the reference")
        XCTAssertNil(pan.update(sample(180, .identity)), "the reference")
        XCTAssertEqual(pan.update(sample(220, arm(yaw: -15, pitch: 0))), .right)
    }
}
