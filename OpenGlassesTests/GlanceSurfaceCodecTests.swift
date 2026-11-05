import XCTest
@testable import OpenGlasses

/// Plan GM P0 — the shared surface payload round-trips per kind, keeps to its byte budget, drops
/// trailing nearby rows to fit (and says how many), and refuses anything else that is too big.
final class GlanceSurfaceCodecTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let tower = GlancePoint(latitude: -36.848_4, longitude: 174.762_2)
    private lazy var wearer = WearerFix(coordinate: GlancePoint(latitude: -36.853_0, longitude: 174.768_0),
                                        fixAt: now, horizontalAccuracy: 8)

    private func surface(_ kind: GlanceSurface.Kind, id: String = "s1") -> GlanceSurface {
        GlanceSurface(id: id, createdAt: now, expiresAt: now.addingTimeInterval(900), mapAllowed: true, kind: kind)
    }

    private func roundTrip(_ set: GlanceSurfaceSet, file: StaticString = #filePath, line: UInt = #line) throws -> GlanceSurfaceSet {
        let encoded = try GlanceSurfaceCodec.encode(set).get()
        return try XCTUnwrap(GlanceSurfaceCodec.decode(encoded.data), file: file, line: line)
    }

    // MARK: - Round trip per kind

    func testEveryKindRoundTrips() throws {
        let kinds: [GlanceSurface.Kind] = [
            .place(PlaceCard(name: "Sky Tower", subtitle: "Victoria Street West", coordinate: tower,
                             wearer: wearer, straightLineMeters: 640, bearingDegrees: 312,
                             routeMeters: 820, etas: [GlanceETA(mode: .walking, seconds: 600)])),
            .whereAmI(WhereCard(wearer: wearer, street: "12 Queen Street", locality: "Auckland")),
            .places(PlacesCard(query: "pharmacy",
                               rows: [PlaceRow(id: "0", name: "Unichem", category: "Pharmacy",
                                               meters: 210, coordinate: tower)],
                               wearer: wearer)),
            .route(RouteSnapshot(polyline: GlancePolyline(points: [wearer.coordinate, tower]),
                                 destinationName: "Sky Tower", destination: tower, mode: .walking,
                                 activeStepIndex: 1,
                                 next: GlanceManeuver(maneuver: "turnLeft", street: "Hobson Street", bandedMeters: 80),
                                 then: GlanceManeuver(maneuver: "turnRight", street: nil, bandedMeters: 200),
                                 remainingMeters: 640, arrivalAt: now.addingTimeInterval(500), wearer: wearer)),
            .list(ListCard(title: "Shopping", items: [.init(id: "a", text: "Milk", checked: false),
                                                       .init(id: "b", text: "Bread", checked: true)],
                           origin: "answer")),
            .image(ImageCard(caption: "Harbour Bridge camera", source: "add-on", fileName: "cam.jpg")),
        ]
        for kind in kinds {
            let set = GlanceSurfaceSet(current: surface(kind), route: nil, playsTap: true, usesMetric: false)
            XCTAssertEqual(try roundTrip(set), set, kind.tag)
        }
    }

    func testCurrentAndRouteTravelTogether() throws {
        let place = surface(.whereAmI(WhereCard(wearer: wearer, street: nil, locality: nil)), id: "a")
        let route = GlanceSurface(id: "r", createdAt: now, expiresAt: nil, mapAllowed: false,
                                  kind: .route(RouteSnapshot(polyline: GlancePolyline(points: [tower]),
                                                             destinationName: "Home", destination: tower,
                                                             mode: .walking, activeStepIndex: 0, next: nil,
                                                             then: nil, remainingMeters: 10, arrivalAt: nil,
                                                             wearer: nil)))
        let set = GlanceSurfaceSet(current: place, route: route)
        XCTAssertEqual(try roundTrip(set), set)
    }

    func testUnknownBytesDecodeToNothing() {
        XCTAssertNil(GlanceSurfaceCodec.decode(Data("not a plist".utf8)))
        XCTAssertNil(GlanceSurfaceCodec.decodeDelta(Data([0, 1, 2])))
    }

    // MARK: - The packed line

    func testAThreeHundredPointLineIsTwoPointFourKilobytes() throws {
        let points = (0..<300).map { GlancePoint(latitude: -36.85 + Double($0) * 0.0001, longitude: 174.76) }
        struct Box: Codable, Equatable { let line: GlancePolyline }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Box(line: GlancePolyline(points: points)))
        XCTAssertLessThan(data.count, 2_400 + 100, "packed as one Data value, 8 bytes a point")
        let decoded = try PropertyListDecoder().decode(Box.self, from: data)
        XCTAssertEqual(decoded.line.points, points)
    }

    func testAFullRouteFitsTheWatchBudget() {
        let points = (0..<RouteSnapshot.maxPoints).map {
            GlancePoint(latitude: -36.85 + Double($0) * 0.0001, longitude: 174.76 - Double($0) * 0.0001)
        }
        let route = surface(.route(RouteSnapshot(polyline: GlancePolyline(points: points),
                                                 destinationName: "Sky Tower", destination: tower, mode: .walking,
                                                 activeStepIndex: 0, next: nil, then: nil,
                                                 remainingMeters: 3_000, arrivalAt: nil, wearer: wearer)))
        guard case .success(let encoded) = GlanceSurfaceCodec.encode(GlanceSurfaceSet(current: nil, route: route)) else {
            return XCTFail("a capped route must fit")
        }
        XCTAssertLessThan(encoded.data.count, GlanceSurfaceCodec.Budget.watch.surfacesBytes / 4)
    }

    // MARK: - Budget

    func testOverBudgetIsRefusedNotTruncated() {
        // Distinct texts: a binary property list stores a repeated string only once.
        let card = surface(.list(ListCard(title: nil,
                                          items: (0..<30).map { .init(id: "\($0)", text: "\($0) " + String(repeating: "x", count: 200), checked: false) },
                                          origin: "answer")))
        let tiny = GlanceSurfaceCodec.Budget(surfacesBytes: 1_000, deltaBytes: 100)
        guard case .failure(.overBudget(let bytes, let limit)) = GlanceSurfaceCodec.encode(GlanceSurfaceSet(current: card), budget: tiny) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertGreaterThan(bytes, limit)
        XCTAssertEqual(limit, 1_000)
    }

    func testNearbyRowsDropFromTheEndAndSaySo() throws {
        let rows = (0..<8).map {
            PlaceRow(id: "\($0)", name: "Place \($0) " + String(repeating: "n", count: 120), category: nil,
                     meters: Double($0 * 100), coordinate: tower)
        }
        let set = GlanceSurfaceSet(current: surface(.places(PlacesCard(query: "cafe", rows: rows, wearer: wearer))))
        guard case .success(let full) = GlanceSurfaceCodec.encode(set) else { return XCTFail() }
        // A budget a few rows short of the whole card.
        let budget = GlanceSurfaceCodec.Budget(surfacesBytes: full.data.count - 300, deltaBytes: 100)
        guard case .success(let trimmed) = GlanceSurfaceCodec.encode(set, budget: budget) else {
            return XCTFail("places shrink to fit")
        }
        XCTAssertLessThanOrEqual(trimmed.data.count, budget.surfacesBytes)
        guard case .places(let card) = try XCTUnwrap(GlanceSurfaceCodec.decode(trimmed.data)?.current).kind else {
            return XCTFail()
        }
        XCTAssertLessThan(card.rows.count, 8)
        XCTAssertGreaterThan(card.rows.count, 0)
        XCTAssertEqual(card.droppedRows, 8 - card.rows.count)
        XCTAssertEqual(card.rows.map(\.id), rows.prefix(card.rows.count).map(\.id), "the first rows, in spoken order")
        XCTAssertEqual(trimmed.set, GlanceSurfaceCodec.decode(trimmed.data))
    }

    func testNearbyThatCannotFitEvenEmptyIsRefused() {
        let set = GlanceSurfaceSet(current: surface(.places(PlacesCard(
            query: "cafe", rows: [PlaceRow(id: "0", name: "A", category: nil, meters: 1, coordinate: tower)],
            wearer: wearer))))
        let budget = GlanceSurfaceCodec.Budget(surfacesBytes: 10, deltaBytes: 10)
        guard case .failure(.overBudget) = GlanceSurfaceCodec.encode(set, budget: budget) else {
            return XCTFail("expected a refusal")
        }
    }

    // MARK: - Deltas

    func testDeltaRoundTripsAndKeepsToItsBudget() throws {
        let delta = RouteDelta(surfaceId: "r", wearer: wearer, activeStepIndex: 2, bandedMetersToManeuver: 80,
                               remainingMeters: 410, cue: .approach, sentAt: now)
        guard case .success(let data) = GlanceSurfaceCodec.encode(delta) else { return XCTFail() }
        XCTAssertLessThan(data.count, GlanceSurfaceCodec.Budget.watch.deltaBytes)
        XCTAssertEqual(GlanceSurfaceCodec.decodeDelta(data), delta)

        let tiny = GlanceSurfaceCodec.Budget(surfacesBytes: 10, deltaBytes: 10)
        guard case .failure(.overBudget) = GlanceSurfaceCodec.encode(delta, budget: tiny) else {
            return XCTFail("expected a refusal")
        }
    }

    // MARK: - Expiry

    func testLiveDropsWhatHasExpired() {
        let place = surface(.whereAmI(WhereCard(wearer: wearer, street: nil, locality: nil)))
        let set = GlanceSurfaceSet(current: place)
        XCTAssertEqual(set.live(at: now.addingTimeInterval(899)).current, place)
        XCTAssertNil(set.live(at: now.addingTimeInterval(900)).current)
        XCTAssertTrue(set.live(at: now.addingTimeInterval(900)).isEmpty)
    }
}
