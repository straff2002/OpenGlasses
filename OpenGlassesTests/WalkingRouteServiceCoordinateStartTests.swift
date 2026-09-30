import CoreLocation
import MapKit
import XCTest
@testable import OpenGlasses

/// Plan GH P1 — walking back to a coordinate goes straight to directions; it never searches for
/// the label, which would find some other place with the same name.
@MainActor
final class WalkingRouteServiceCoordinateStartTests: XCTestCase {

    private var searches = 0
    private var routedTo: [CLLocationCoordinate2D] = []

    private func makeService(origin: CLLocation?) -> WalkingRouteService {
        let service = WalkingRouteService()
        service.originFix = { origin }
        service.localSearch = { [unowned self] _ in
            self.searches += 1
            return []
        }
        service.directions = { [unowned self] _, item in
            self.routedTo.append(item.location.coordinate)
            throw NavigationError.noRoute
        }
        return service
    }

    private let origin = CLLocation(latitude: -36.85, longitude: 174.76)
    private let car = CLLocationCoordinate2D(latitude: -36.851, longitude: 174.762)

    func testACoordinateStartNeverCallsLocalSearch() async {
        let service = makeService(origin: origin)
        do {
            _ = try await service.start(to: car, label: "your car")
            XCTFail("the faked directions throw")
        } catch {
            XCTAssertEqual(error as? NavigationError, .noRoute)
        }
        XCTAssertEqual(searches, 0)
        XCTAssertEqual(routedTo.count, 1)
        XCTAssertEqual(routedTo.first?.latitude ?? 0, car.latitude, accuracy: 1e-9)
        XCTAssertEqual(routedTo.first?.longitude ?? 0, car.longitude, accuracy: 1e-9)
        XCTAssertEqual(service.state, .idle, "a failed start must not leave the service resolving")
    }

    func testACoordinateStartWithoutAFixAsksForLocation() async {
        let service = makeService(origin: nil)
        do {
            _ = try await service.start(to: car, label: "your car")
            XCTFail("expected noLocation")
        } catch {
            XCTAssertEqual(error as? NavigationError, .noLocation)
        }
        XCTAssertTrue(routedTo.isEmpty)
        XCTAssertEqual(service.state, .idle)
    }

    func testAQueryStartStillSearches() async {
        let service = makeService(origin: origin)
        do {
            _ = try await service.start(destination: "coffee")
            XCTFail("the faked search finds nothing")
        } catch {
            XCTAssertEqual(error as? NavigationError, .noMatch("coffee"))
        }
        XCTAssertEqual(searches, 1)
        XCTAssertTrue(routedTo.isEmpty)
    }
}
