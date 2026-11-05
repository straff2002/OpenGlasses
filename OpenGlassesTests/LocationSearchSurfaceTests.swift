import CoreLocation
import MapKit
import XCTest
@testable import OpenGlasses

/// Plan GM P1a — `find_nearby` with an injected search: the results come closest first and go to
/// the bus as a `places` card in the order they are spoken, and `nearest` answers "how far is that tower?" with a
/// `place` card. No MapKit request runs.
@MainActor
final class LocationSearchSurfaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var location: CLLocation?
    private var results: [MKMapItem] = []
    private var published: [(surface: GlanceSurface, asked: Bool)] = []
    private var mapAllowed = true

    override func setUp() {
        super.setUp()
        location = CLLocation(coordinate: .init(latitude: -36.853, longitude: 174.768), altitude: 0,
                              horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: now)
        results = []
        published = []
        mapAllowed = true
    }

    private func item(_ name: String, _ lat: Double, _ lon: Double) -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        item.name = name
        return item
    }

    private func makeTool() -> LocationSearchTool {
        LocationSearchTool(seams: .init(
            currentLocation: { [unowned self] in self.location },
            search: { [unowned self] _ in self.results },
            publishSurface: { [unowned self] surface, asked in self.published.append((surface, asked)) },
            mapAllowed: { [unowned self] in self.mapAllowed },
            metric: { true },
            now: { [unowned self] in self.now }))
    }

    func testResultsComeClosestFirstInTheAnswerAndTheCard() async throws {
        // Search order is relevance; from the wearer these are ~380 m, ~780 m and ~240 m away.
        results = [item("Unichem Queen St", -36.850, 174.766),
                   item("Life Pharmacy", -36.860, 174.770),
                   item("Chemist Warehouse", -36.851, 174.769)]
        let reply = try await makeTool().execute(args: ["query": "pharmacy", "limit": 3])

        let closestFirst = ["Chemist Warehouse", "Unichem Queen St", "Life Pharmacy"]
        let positions = closestFirst.map { reply.range(of: $0)!.lowerBound }
        XCTAssertEqual(positions, positions.sorted(), reply)

        let publication = try XCTUnwrap(published.last)
        XCTAssertFalse(publication.asked)
        guard case .places(let card) = publication.surface.kind else { return XCTFail() }
        XCTAssertEqual(card.query, "pharmacy")
        XCTAssertEqual(card.rows.map(\.name), closestFirst, "the card lists them in the order spoken")
        XCTAssertEqual(card.rows.map(\.meters), card.rows.map(\.meters).sorted())
        XCTAssertEqual(card.wearer?.coordinate, GlancePoint(latitude: -36.853, longitude: 174.768))
        XCTAssertTrue(publication.surface.mapAllowed)
    }

    func testTheLimitKeepsTheClosest() async throws {
        // Due north of the wearer, farther with each one; the search returns them farthest first.
        results = (1...6).reversed().map { item("Cafe \($0)", -36.853 + Double($0) * 0.001, 174.768) }
        _ = try await makeTool().execute(args: ["query": "cafe", "limit": 2])
        guard case .places(let card) = try XCTUnwrap(published.last).surface.kind else { return XCTFail() }
        XCTAssertEqual(card.rows.map(\.name), ["Cafe 1", "Cafe 2"])
    }

    func testEqualDistancesKeepTheSearchOrder() {
        let wearer = CLLocation(latitude: -36.853, longitude: 174.768)
        // Two shops in one building.
        let a = item("Upstairs", -36.852, 174.768), b = item("Downstairs", -36.852, 174.768)
        XCTAssertEqual(LocationSearchTool.closestFirst([a, b], from: wearer).map(\.name), ["Upstairs", "Downstairs"])
        XCTAssertEqual(LocationSearchTool.closestFirst([b, a], from: wearer).map(\.name), ["Downstairs", "Upstairs"])
    }

    func testShowOnWatchIsAnAsk() async throws {
        results = [item("Unichem", -36.850, 174.766)]
        _ = try await makeTool().execute(args: ["query": "pharmacy", "show_on_watch": true])
        XCTAssertEqual(published.last?.asked, true)
    }

    func testLocalOnlyMarksTheCardMapless() async throws {
        mapAllowed = false
        results = [item("Unichem", -36.850, 174.766)]
        _ = try await makeTool().execute(args: ["query": "pharmacy"])
        XCTAssertEqual(published.last?.surface.mapAllowed, false)
    }

    func testNearestAnswersWithTheClosestMatchAndAPlaceCard() async throws {
        // The search's first result is not the closest one.
        results = [item("Sky Tower Casino Entrance", -36.840, 174.750),
                   item("Sky Tower", -36.8484, 174.7622)]
        let reply = try await makeTool().execute(args: ["query": "Sky Tower", "nearest": true])

        XCTAssertTrue(reply.hasPrefix("Sky Tower is "), reply)
        XCTAssertTrue(reply.contains("in a straight line"), reply)
        XCTAssertTrue(reply.contains("north-west"), reply)

        guard case .place(let card) = try XCTUnwrap(published.last).surface.kind else { return XCTFail() }
        XCTAssertEqual(card.name, "Sky Tower")
        XCTAssertTrue(card.isStraightLine)
        // The spoken figure and the card's are the same number.
        XCTAssertTrue(reply.contains(DistanceFormatter.spoken(Int(card.straightLineMeters.rounded()), metric: true)), reply)
    }

    func testNothingIsPublishedWithoutAFixOrResults() async throws {
        location = nil
        _ = try await makeTool().execute(args: ["query": "pharmacy"])
        location = CLLocation(latitude: -36.853, longitude: 174.768)
        results = []
        _ = try await makeTool().execute(args: ["query": "pharmacy"])
        _ = try await makeTool().execute(args: ["query": "pharmacy", "nearest": true])
        XCTAssertTrue(published.isEmpty)
    }
}
