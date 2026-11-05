import XCTest
@testable import OpenGlasses

/// Plan GM P0 — a route delta is sent on a banded-distance change, a step change or a cue, at
/// most once every 2 s (a cue always goes).
final class RouteDeltaTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func delta(_ id: String = "r", step: Int = 1, band: Int = 80, cue: RouteDelta.Cue? = nil,
                       at seconds: TimeInterval = 0) -> RouteDelta {
        RouteDelta(surfaceId: id, wearer: nil, activeStepIndex: step, bandedMetersToManeuver: band,
                   remainingMeters: 400, cue: cue, sentAt: t0.addingTimeInterval(seconds))
    }

    func testTheFirstDeltaAlwaysGoes() {
        XCTAssertTrue(delta().shouldSend(after: nil))
    }

    func testNothingNewIsNotSent() {
        XCTAssertFalse(delta(at: 10).isMeaningfulChange(from: delta()))
        XCTAssertFalse(delta(at: 10).shouldSend(after: delta()))
    }

    func testABandOrStepChangeIsMeaningful() {
        XCTAssertTrue(delta(band: 50, at: 3).shouldSend(after: delta()))
        XCTAssertTrue(delta(step: 2, at: 3).shouldSend(after: delta()))
    }

    func testAChangeWaitsTwoSeconds() {
        XCTAssertFalse(delta(band: 50, at: 1.9).shouldSend(after: delta()))
        XCTAssertTrue(delta(band: 50, at: 2).shouldSend(after: delta()))
    }

    func testACueGoesAtOnce() {
        XCTAssertTrue(delta(cue: .imminent, at: 0.5).shouldSend(after: delta()))
        XCTAssertTrue(delta(cue: .rerouting, at: 0.1).shouldSend(after: delta()))
    }

    func testANewRouteStartsAfresh() {
        XCTAssertTrue(delta("r2", at: 0.5).shouldSend(after: delta("r1")))
    }

    func testADeltaAppliesOnlyToItsRoute() {
        let point = GlancePoint(latitude: 0, longitude: 0)
        let snapshot = RouteSnapshot(polyline: GlancePolyline(points: [point]), destinationName: "X",
                                     destination: point, mode: .walking, activeStepIndex: 0, next: nil,
                                     then: nil, remainingMeters: 0, arrivalAt: nil, wearer: nil)
        let route = GlanceSurface(id: "r", createdAt: t0, expiresAt: nil, mapAllowed: true, kind: .route(snapshot))
        let other = GlanceSurface(id: "r2", createdAt: t0, expiresAt: nil, mapAllowed: true, kind: .route(snapshot))
        let place = GlanceSurface(id: "r", createdAt: t0, expiresAt: nil, mapAllowed: true,
                                  kind: .whereAmI(WhereCard(wearer: WearerFix(coordinate: point, fixAt: t0,
                                                                              horizontalAccuracy: 5),
                                                            street: nil, locality: nil)))
        XCTAssertTrue(delta().applies(to: route))
        XCTAssertFalse(delta().applies(to: other))
        XCTAssertFalse(delta().applies(to: place), "a delta moves a route, nothing else")
    }
}
