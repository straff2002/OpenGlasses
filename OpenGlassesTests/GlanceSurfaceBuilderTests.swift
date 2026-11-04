import CoreLocation
import MapKit
import XCTest
@testable import OpenGlasses

/// Plan GM P1a — surfaces built from stub map items and fixes (no MapKit request), and the bus
/// that carries them.
@MainActor
final class GlanceSurfaceBuilderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var fix = CLLocation(coordinate: .init(latitude: -36.853, longitude: 174.768), altitude: 0,
                                      horizontalAccuracy: 12, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-4))

    private func item(_ name: String, _ lat: Double, _ lon: Double,
                      category: MKPointOfInterestCategory? = nil) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        item.name = name
        item.pointOfInterestCategory = category
        return item
    }

    func testTheWearerIsThePhonesFix() {
        let wearer = GlanceSurfaceBuilder.wearer(fix)
        XCTAssertEqual(wearer.coordinate, GlancePoint(latitude: -36.853, longitude: 174.768))
        XCTAssertEqual(wearer.fixAt, fix.timestamp)
        XCTAssertEqual(wearer.horizontalAccuracy, 12)
    }

    func testAPlaceCardMeasuresAStraightLineFromTheWearer() throws {
        let tower = GlancePoint(latitude: -36.8484, longitude: 174.7622)
        let surface = GlanceSurfaceBuilder.place(name: "Sky Tower", subtitle: "Victoria Street West",
                                                 coordinate: tower, wearer: GlanceSurfaceBuilder.wearer(fix),
                                                 mapAllowed: true, now: now, id: "p")
        guard case .place(let card) = surface.kind else { return XCTFail() }
        XCTAssertEqual(card.straightLineMeters, 727, accuracy: 15)
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: card.bearingDegrees), .northWest)
        XCTAssertTrue(card.isStraightLine)
        XCTAssertEqual(surface.expiresAt, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(surface.id, "p")
    }

    func testAPlaceWithoutAFixHasNoDistance() {
        let surface = GlanceSurfaceBuilder.place(name: "X", subtitle: nil, coordinate: GlancePoint(latitude: 1, longitude: 1),
                                                 wearer: nil, mapAllowed: false, now: now)
        guard case .place(let card) = surface.kind else { return XCTFail() }
        XCTAssertEqual(card.straightLineMeters, 0)
        XCTAssertFalse(surface.mapAllowed)
    }

    func testWhereAmILastsFiveMinutes() {
        let surface = GlanceSurfaceBuilder.whereAmI(wearer: GlanceSurfaceBuilder.wearer(fix), street: "Queen Street",
                                                    locality: "Auckland", mapAllowed: true, now: now)
        XCTAssertEqual(surface.expiresAt, now.addingTimeInterval(5 * 60))
        guard case .whereAmI(let card) = surface.kind else { return XCTFail() }
        XCTAssertEqual(card.street, "Queen Street")
        XCTAssertEqual(card.locality, "Auckland")
    }

    func testNearbyRowsKeepTheSearchOrderAndCap() {
        let items = (0..<11).map { item("Cafe \($0)", -36.85 + Double($0) * 0.001, 174.76) }
        let candidates = GlanceSurfaceBuilder.candidates(from: items, wearer: fix)
        let surface = GlanceSurfaceBuilder.places(query: "cafe", candidates: candidates,
                                                  wearer: GlanceSurfaceBuilder.wearer(fix), mapAllowed: true, now: now)
        guard case .places(let card) = surface.kind else { return XCTFail() }
        XCTAssertEqual(card.rows.count, PlacesCard.maxRows)
        XCTAssertEqual(card.rows.map(\.name), (0..<8).map { "Cafe \($0)" })
        XCTAssertEqual(card.rows.map(\.id), (0..<8).map(String.init))
        XCTAssertEqual(card.rows[0].meters, fix.distance(from: items[0].location), accuracy: 0.001,
                       "the distance the answer speaks")
    }

    func testCategoryWords() {
        XCTAssertEqual(GlanceSurfaceBuilder.categoryWords(.pharmacy), "Pharmacy")
        XCTAssertEqual(GlanceSurfaceBuilder.categoryWords(.publicTransport), "Public transport")
        XCTAssertEqual(GlanceSurfaceBuilder.categoryWords(.evCharger), "EV charger")
        XCTAssertNil(GlanceSurfaceBuilder.categoryWords(nil))
    }

    // MARK: - Bus

    func testTheBusForgetsAnExpiredCard() {
        let bus = GlanceSurfaceBus()
        var clock = now
        bus.now = { clock }
        let surface = GlanceSurfaceBuilder.whereAmI(wearer: GlanceSurfaceBuilder.wearer(fix), street: nil,
                                                    locality: nil, mapAllowed: true, now: now, id: "w")
        bus.publish(surface, asked: true)
        XCTAssertEqual(bus.latest?.asked, true)
        XCTAssertEqual(bus.surface(id: "w"), surface)
        XCTAssertNil(bus.surface(id: "other"))

        clock = now.addingTimeInterval(5 * 60)
        XCTAssertNil(bus.current)
        XCTAssertNil(bus.surface(id: "w"))
    }
}
