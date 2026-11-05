import XCTest
@testable import OpenGlasses

/// Plan GM P0 — a route line simplified to the point cap, with the endpoints and every maneuver
/// point kept.
final class PolylineSimplifierTests: XCTestCase {

    /// A winding line: a slow sine across ~5 km, 1,000 points.
    private func winding(_ count: Int = 1_000) -> [GlancePoint] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return GlancePoint(latitude: -36.85 + t * 0.04, longitude: 174.76 + 0.003 * sin(t * 40))
        }
    }

    func testALineUnderTheCapIsUnchanged() {
        let line = Array(winding().prefix(50))
        XCTAssertEqual(PolylineSimplifier.simplify(line, cap: 300), line)
    }

    func testALongLineComesDownToTheCapWithItsEnds() {
        let line = winding()
        let simplified = PolylineSimplifier.simplify(line, cap: 300)
        XCTAssertLessThanOrEqual(simplified.count, 300)
        XCTAssertGreaterThan(simplified.count, 100, "the tolerance is searched, so the cap is used, not wasted")
        XCTAssertEqual(simplified.first, line.first)
        XCTAssertEqual(simplified.last, line.last)
    }

    func testManeuverPointsAlwaysSurvive() {
        let line = winding()
        let maneuvers: Set<Int> = [17, 250, 251, 600, 998]
        let simplified = PolylineSimplifier.simplify(line, cap: 40, keeping: maneuvers)
        XCTAssertLessThanOrEqual(simplified.count, 40)
        for index in maneuvers {
            XCTAssertTrue(simplified.contains(line[index]), "maneuver \(index) was smoothed away")
        }
    }

    func testPointsStayInRouteOrder() {
        let line = winding()
        let simplified = PolylineSimplifier.simplify(line, cap: 120, keeping: [400])
        let indices = simplified.map { point in line.firstIndex(of: point)! }
        XCTAssertEqual(indices, indices.sorted())
    }

    func testAStraightLineCollapsesToItsKeptPoints() {
        let line = (0..<500).map { GlancePoint(latitude: -36.85 + Double($0) * 0.0001, longitude: 174.76) }
        let simplified = PolylineSimplifier.simplify(line, cap: 300, keeping: [250])
        XCTAssertEqual(simplified, [line[0], line[250], line[499]])
    }

    func testMoreTurnsThanTheCapKeepsEveryTurn() {
        let line = winding()
        let maneuvers = Set(stride(from: 0, to: 1_000, by: 10))
        let simplified = PolylineSimplifier.simplify(line, cap: 30, keeping: maneuvers)
        XCTAssertEqual(simplified.count, maneuvers.count + 1, "every turn, plus the end; a turn beats the cap")
    }
}
