import XCTest
@testable import OpenGlasses

/// Plan GM P0 — distance, bearing, compass words and map framing (including across the
/// antimeridian), plus the point encoding and the card's distance text.
final class GlanceGeometryTests: XCTestCase {

    private func p(_ lat: Double, _ lon: Double) -> GlancePoint { GlancePoint(latitude: lat, longitude: lon) }

    // MARK: - Points

    func testPointsKeepAboutACentimetre() {
        let point = p(-36.848_412_3, 174.762_219_8)
        XCTAssertEqual(point.latitude, -36.848_412_3, accuracy: 1e-7)
        XCTAssertEqual(point.longitude, 174.762_219_8, accuracy: 1e-7)
    }

    func testLongitudeIsNormalisedAndLatitudeClamped() {
        XCTAssertEqual(p(10, 190).longitude, -170, accuracy: 1e-7)
        XCTAssertEqual(p(10, -190).longitude, 170, accuracy: 1e-7)
        XCTAssertEqual(p(95, 0).latitude, 90, accuracy: 1e-7)
    }

    // MARK: - Distance

    func testOneDegreeOfLatitude() {
        XCTAssertEqual(GlanceGeometry.distanceMeters(p(0, 0), p(1, 0)), 111_195, accuracy: 5)
    }

    func testAShortCityDistance() {
        // Two points about 640 m apart in central Auckland.
        let d = GlanceGeometry.distanceMeters(p(-36.853_0, 174.768_0), p(-36.848_4, 174.762_2))
        XCTAssertEqual(d, 723, accuracy: 15)
        XCTAssertEqual(GlanceGeometry.distanceMeters(p(1, 1), p(1, 1)), 0)
    }

    // MARK: - Bearing

    func testCardinalBearings() {
        XCTAssertEqual(GlanceGeometry.initialBearingDegrees(from: p(0, 0), to: p(1, 0)), 0, accuracy: 0.01)
        XCTAssertEqual(GlanceGeometry.initialBearingDegrees(from: p(0, 0), to: p(0, 1)), 90, accuracy: 0.01)
        XCTAssertEqual(GlanceGeometry.initialBearingDegrees(from: p(0, 0), to: p(-1, 0)), 180, accuracy: 0.01)
        XCTAssertEqual(GlanceGeometry.initialBearingDegrees(from: p(0, 0), to: p(0, -1)), 270, accuracy: 0.01)
        XCTAssertEqual(GlanceGeometry.initialBearingDegrees(from: p(5, 5), to: p(5, 5)), 0)
    }

    func testBearingAcrossTheAntimeridianGoesTheShortWay() {
        let east = GlanceGeometry.initialBearingDegrees(from: p(0, 179.9), to: p(0, -179.9))
        XCTAssertEqual(east, 90, accuracy: 0.01)
    }

    func testCompassWords() {
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 0).words, "north")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 44).words, "north-east")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 135).words, "south-east")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 225).words, "south-west")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 330).words, "north-west")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: 350).words, "north")
        XCTAssertEqual(GlanceGeometry.compassPoint(forBearing: -90).words, "west")
    }

    // MARK: - Framing

    func testNoPointsFrameNothing() {
        XCTAssertNil(GlanceGeometry.region(framing: []))
    }

    func testTwoPointsAreBothInsideThePaddedRegion() throws {
        let a = p(-36.853, 174.768), b = p(-36.848, 174.762)
        let region = try XCTUnwrap(GlanceGeometry.region(framing: [a, b], padding: 0.25))
        for point in [a, b] {
            XCTAssertLessThan(abs(point.latitude - region.centerLatitude), region.latitudeDelta / 2)
            XCTAssertLessThan(abs(point.longitude - region.centerLongitude), region.longitudeDelta / 2)
        }
        // A quarter on each side: one and a half times the span.
        XCTAssertEqual(region.latitudeDelta, 0.005 * 1.5, accuracy: 1e-6)
    }

    func testOnePointFramesTheMinimumSpan() throws {
        let region = try XCTUnwrap(GlanceGeometry.region(framing: [p(0, 0)], padding: 0, minimumSpanMeters: 300))
        XCTAssertEqual(region.latitudeDelta * 111_195, 300, accuracy: 1)
        XCTAssertEqual(region.centerLatitude, 0, accuracy: 1e-9)
    }

    func testABottomInsetMovesTheCentreSouth() throws {
        let points = [p(-36.853, 174.768), p(-36.848, 174.762)]
        let plain = try XCTUnwrap(GlanceGeometry.region(framing: points, padding: 0))
        let inset = try XCTUnwrap(GlanceGeometry.region(framing: points, padding: 0, bottomInset: 0.5))
        XCTAssertLessThan(inset.centerLatitude, plain.centerLatitude)
        XCTAssertGreaterThan(inset.latitudeDelta, plain.latitudeDelta)
    }

    func testFramingAcrossTheAntimeridianKeepsASmallSpan() throws {
        let region = try XCTUnwrap(GlanceGeometry.region(framing: [p(-16.5, 179.9), p(-16.6, -179.9)], padding: 0))
        XCTAssertLessThan(region.longitudeDelta, 1, "the short way round, not 359.8°")
        XCTAssertEqual(abs(region.centerLongitude), 180, accuracy: 0.001)
    }

    // MARK: - Distance text

    func testCardDistanceTextMatchesThePhone() {
        XCTAssertEqual(GlanceDistanceText.short(meters: 847.3, metric: true), "847 m")
        XCTAssertEqual(GlanceDistanceText.short(meters: 1_234, metric: true), "1.2 km")
        XCTAssertEqual(GlanceDistanceText.short(meters: 100, metric: false), "330 ft")
        XCTAssertEqual(GlanceDistanceText.short(meters: 3_700, metric: false), "2.3 mi")
        for meters in [5.0, 640, 999, 1_500, 12_000] {
            XCTAssertEqual(GlanceDistanceText.short(meters: meters, metric: true),
                           DistanceFormatter.compact(Int(meters), metric: true))
            XCTAssertEqual(GlanceDistanceText.short(meters: meters, metric: false),
                           DistanceFormatter.compact(Int(meters), metric: false))
        }
    }

    // MARK: - A row tapped on the watch

    func testAPlaceCardFromARowKeepsTheSpokenDistance() {
        let wearer = WearerFix(coordinate: p(0, 0), fixAt: Date(), horizontalAccuracy: 5)
        let row = PlaceRow(id: "2", name: "Unichem", category: "Pharmacy", meters: 111_200, coordinate: p(0, 1))
        let card = PlaceCard.from(row: row, wearer: wearer)
        XCTAssertEqual(card.straightLineMeters, 111_200)
        XCTAssertEqual(card.bearingDegrees, 90, accuracy: 0.01)
        XCTAssertTrue(card.isStraightLine)
        XCTAssertEqual(card.subtitle, "Pharmacy")
        XCTAssertEqual(PlaceCard.from(row: row, wearer: nil).bearingDegrees, 0)
    }
}
