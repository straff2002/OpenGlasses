import XCTest
@testable import OpenGlasses

/// Plan CA — the deterministic navigation core: maneuver parsing/phrasing, distance
/// banding/formatting, cue policy, geometry, and the progress tracker under synthetic walks
/// (straight leg, jitter, detour, throttle, arrival).
final class WalkingNavigationTests: XCTestCase {

    // Rough conversions at the test latitude (0°): 1° lat ≈ 111.19 km, 1° lon ≈ 111.19 km.
    private let metersPerDegree = 111_194.9

    private func point(north meters: Double, east eastMeters: Double = 0) -> RoutePoint {
        RoutePoint(lat: meters / metersPerDegree, lon: eastMeters / metersPerDegree)
    }

    /// depart at 0 m → turn left at 200 m → arrive at 200 m north, 150 m east.
    private func straightThenLeftRoute() -> [RouteStep] {
        let start = point(north: 0)
        let corner = point(north: 200)
        let end = point(north: 200, east: 150)
        return [
            RouteStep(instruction: "Head north", maneuver: .depart, streetName: nil,
                      maneuverPoint: start, inboundLeg: [start], inboundDistance: 0),
            RouteStep(instruction: "Turn left onto King Street", maneuver: .turnLeft, streetName: "King Street",
                      maneuverPoint: corner, inboundLeg: [start, corner], inboundDistance: 200),
            RouteStep(instruction: "Arrive at your destination", maneuver: .arrive, streetName: nil,
                      maneuverPoint: end, inboundLeg: [corner, end], inboundDistance: 150),
        ]
    }

    // MARK: - Maneuver parsing

    func testManeuverParsing() {
        XCTAssertEqual(Maneuver.parse(instruction: "Turn left onto King Street"), .turnLeft)
        XCTAssertEqual(Maneuver.parse(instruction: "Turn right onto Main St"), .turnRight)
        XCTAssertEqual(Maneuver.parse(instruction: "Bear left onto the path"), .slightLeft)
        XCTAssertEqual(Maneuver.parse(instruction: "Keep right at the fork"), .slightRight)
        XCTAssertEqual(Maneuver.parse(instruction: "Make a U-turn"), .uTurn)
        XCTAssertEqual(Maneuver.parse(instruction: "At the roundabout, take the second exit"), .roundabout)
        XCTAssertEqual(Maneuver.parse(instruction: "Arrive at your destination"), .arrive)
        XCTAssertEqual(Maneuver.parse(instruction: "Head south on Broadway"), .depart)
        // Unparseable (incl. non-English) degrades to continue — text still renders.
        XCTAssertEqual(Maneuver.parse(instruction: "Biegen Sie links ab"), .continueStraight)
    }

    // MARK: - Banding & formatting

    func testDistanceBanding() {
        XCTAssertEqual(DistanceFormatter.banded(8), 0)
        XCTAssertEqual(DistanceFormatter.banded(15), 0)
        XCTAssertEqual(DistanceFormatter.banded(43), 40)
        XCTAssertEqual(DistanceFormatter.banded(97), 100)
        XCTAssertEqual(DistanceFormatter.banded(430), 450)
        XCTAssertEqual(DistanceFormatter.banded(1240), 1200)
    }

    func testCompactAndSpokenFormatting() {
        XCTAssertEqual(DistanceFormatter.compact(40, metric: true), "40 m")
        XCTAssertEqual(DistanceFormatter.compact(1200, metric: true), "1.2 km")
        XCTAssertEqual(DistanceFormatter.compact(40, metric: false), "130 ft")
        XCTAssertEqual(DistanceFormatter.compact(2000, metric: false), "1.2 mi")
        XCTAssertEqual(DistanceFormatter.spoken(40, metric: true), "40 metres")
        XCTAssertEqual(DistanceFormatter.spoken(2000, metric: true), "2 kilometres")
        XCTAssertEqual(DistanceFormatter.spoken(40, metric: false), "130 feet")
    }

    // MARK: - Phrasing

    func testHUDLinePhrasing() {
        XCTAssertEqual(ManeuverPhraser.hudLine(maneuver: .turnLeft, streetName: "King St",
                                               bandedMeters: 40, metric: true),
                       "← 40 m · King St")
        XCTAssertEqual(ManeuverPhraser.hudLine(maneuver: .turnLeft, streetName: "King St",
                                               bandedMeters: 0, metric: true),
                       "← King St")
        XCTAssertEqual(ManeuverPhraser.hudLine(maneuver: .arrive, streetName: nil,
                                               bandedMeters: 200, metric: true),
                       "⚑ 200 m")
        XCTAssertEqual(ManeuverPhraser.hudLine(maneuver: .turnRight, streetName: nil,
                                               bandedMeters: 0, metric: true),
                       "→ now")
    }

    func testSpokenPhrasing() {
        XCTAssertEqual(ManeuverPhraser.spoken(maneuver: .turnLeft, streetName: "King Street",
                                              bandedMeters: 40, metric: true),
                       "In 40 metres, turn left onto King Street.")
        XCTAssertEqual(ManeuverPhraser.spoken(maneuver: .turnLeft, streetName: "King Street",
                                              bandedMeters: 0, metric: true),
                       "Turn left onto King Street now.")
        XCTAssertEqual(ManeuverPhraser.spoken(maneuver: .continueStraight, streetName: "Broadway",
                                              bandedMeters: 100, metric: true),
                       "In 100 metres, continue straight on Broadway.")
        XCTAssertEqual(ManeuverPhraser.spoken(maneuver: .arrive, streetName: nil,
                                              bandedMeters: 0, metric: true),
                       "You've arrived.")
    }

    // MARK: - Cue policy

    func testCuePolicySpeaksApproachOnceAndImminentOnce() {
        var policy = NavigationCuePolicy()
        XCTAssertEqual(policy.cue(stepIndex: 1, bandedMeters: 200), .approach)
        XCTAssertNil(policy.cue(stepIndex: 1, bandedMeters: 150))
        XCTAssertNil(policy.cue(stepIndex: 1, bandedMeters: 40))
        XCTAssertEqual(policy.cue(stepIndex: 1, bandedMeters: 0), .imminent)
        XCTAssertNil(policy.cue(stepIndex: 1, bandedMeters: 0))
        // Next step restarts the pair; activating already-imminent speaks imminent only.
        XCTAssertEqual(policy.cue(stepIndex: 2, bandedMeters: 0), .imminent)
        XCTAssertNil(policy.cue(stepIndex: 2, bandedMeters: 0))
    }

    // MARK: - Geometry

    func testDistanceToLegOnAndOff() {
        let leg = [point(north: 0), point(north: 200)]
        XCTAssertEqual(RouteGeometry.distanceToLeg(point(north: 100), leg: leg), 0, accuracy: 1)
        XCTAssertEqual(RouteGeometry.distanceToLeg(point(north: 100, east: 50), leg: leg), 50, accuracy: 1)
        // Beyond the segment end, distance is to the endpoint, not the infinite line.
        XCTAssertEqual(RouteGeometry.distanceToLeg(point(north: 300), leg: leg), 100, accuracy: 1)
    }

    // MARK: - Tracker

    func testDepartAdvancesImmediatelyThenLegAdvancesAtManeuverNotBefore() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        let start = Date(timeIntervalSinceReferenceDate: 0)
        // Standing at the start: the depart step is passed at once — the corner becomes active.
        let atStart = point(north: 5)
        XCTAssertEqual(tracker.accept(lat: atStart.lat, lon: atStart.lon, accuracy: 10, now: start),
                       .advancedTo(1))
        // Fixes along the leg, well outside the corner's advance radius: no advancement.
        for (i, north) in [60.0, 100, 140, 170].enumerated() {
            let fix = point(north: north)
            XCTAssertEqual(tracker.accept(lat: fix.lat, lon: fix.lon, accuracy: 10,
                                          now: start.addingTimeInterval(Double(i + 1))), .none)
        }
        // 15 m from the corner → advance to the final (arrive) step.
        let near = point(north: 185)
        XCTAssertEqual(tracker.accept(lat: near.lat, lon: near.lon, accuracy: 10,
                                      now: start.addingTimeInterval(10)), .advancedTo(2))
    }

    func testJitterDoesNotFalseAdvanceOrReroute() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        _ = tracker.accept(lat: point(north: 5).lat, lon: 0, accuracy: 10,
                           now: Date(timeIntervalSinceReferenceDate: 0))   // depart → step 1
        // Mid-leg zig-zag ±20 m east: inside the off-route threshold, far from the maneuver.
        for (i, east) in [20.0, -20, 20, -20, 20, -20].enumerated() {
            let fix = point(north: 100 + Double(i) * 5, east: east)
            let event = tracker.accept(lat: fix.lat, lon: fix.lon, accuracy: 10,
                                       now: Date(timeIntervalSinceReferenceDate: Double(i + 1)))
            XCTAssertEqual(event, .none, "jitter fix \(i) must not advance or reroute")
        }
        XCTAssertEqual(tracker.activeStepIndex, 1)
    }

    func testDetourNeedsKConsecutiveFixesThenThrottles() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        let base = Date(timeIntervalSinceReferenceDate: 0)
        // 3 off-route fixes then one on-route: streak resets, no reroute.
        for i in 0..<3 {
            XCTAssertEqual(tracker.accept(lat: point(north: 100 + Double(i)).lat,
                                          lon: point(north: 0, east: 80).lon,
                                          accuracy: 10, now: base.addingTimeInterval(Double(i))), .none)
        }
        XCTAssertEqual(tracker.accept(lat: point(north: 110).lat, lon: 0, accuracy: 10,
                                      now: base.addingTimeInterval(3)), .none)
        // 4 consecutive off-route fixes → one reroute request…
        var events: [RouteProgressTracker.Event] = []
        for i in 0..<8 {
            events.append(tracker.accept(lat: point(north: 120 + Double(i)).lat,
                                         lon: point(north: 0, east: 80).lon,
                                         accuracy: 10, now: base.addingTimeInterval(4 + Double(i))))
        }
        XCTAssertEqual(events.filter { $0 == .offRoute }.count, 1,
                       "second streak within the 30 s throttle must not fire")
    }

    func testAccuracyScalesAdvanceRadius() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        let base = Date(timeIntervalSinceReferenceDate: 0)
        _ = tracker.accept(lat: point(north: 2).lat, lon: 0, accuracy: 10, now: base)   // depart → step 1
        // 60 m short of the corner with a 70 m-accuracy fix: inside max(20, 70) → advance.
        let fix = point(north: 140)
        XCTAssertEqual(tracker.accept(lat: fix.lat, lon: fix.lon, accuracy: 70,
                                      now: base.addingTimeInterval(1)), .advancedTo(2))
    }

    func testArrivalOnFinalStepOnly() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        let base = Date(timeIntervalSinceReferenceDate: 0)
        _ = tracker.accept(lat: point(north: 5).lat, lon: 0, accuracy: 10, now: base)   // depart → step 1
        let corner = point(north: 185)
        XCTAssertEqual(tracker.accept(lat: corner.lat, lon: corner.lon, accuracy: 10,
                                      now: base.addingTimeInterval(1)), .advancedTo(2))
        // 50 m from the destination: outside max(25, 10) → not arrived yet.
        let nearEnd = point(north: 200, east: 100)
        XCTAssertEqual(tracker.accept(lat: nearEnd.lat, lon: nearEnd.lon, accuracy: 10,
                                      now: base.addingTimeInterval(2)), .none)
        let end = point(north: 200, east: 148)
        XCTAssertEqual(tracker.accept(lat: end.lat, lon: end.lon, accuracy: 10,
                                      now: base.addingTimeInterval(3)), .arrived)
        XCTAssertTrue(tracker.finished)
        // After arrival the tracker is inert.
        XCTAssertEqual(tracker.accept(lat: end.lat, lon: end.lon, accuracy: 10,
                                      now: base.addingTimeInterval(4)), .none)
    }

    func testRemainingDistanceSumsDistanceToManeuverPlusLaterLegs() {
        var tracker = RouteProgressTracker(steps: straightThenLeftRoute())
        let base = Date(timeIntervalSinceReferenceDate: 0)
        _ = tracker.accept(lat: point(north: 5).lat, lon: 0, accuracy: 10, now: base)   // depart → step 1
        _ = tracker.accept(lat: point(north: 100).lat, lon: 0, accuracy: 10,
                           now: base.addingTimeInterval(1))
        // 100 m to the corner + the 150 m final leg.
        XCTAssertEqual(tracker.remainingDistance ?? 0, 250, accuracy: 5)
    }
}
