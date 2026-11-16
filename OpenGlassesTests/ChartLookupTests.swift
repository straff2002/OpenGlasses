import XCTest
@testable import OpenGlasses

/// Plan LX P0 §5 — a value off a validated reading: interpolated, rounded to the step, never
/// extrapolated. Hand-written readings of an invented chart.
final class ChartLookupTests: XCTestCase {

    private typealias F = ChartFixtures

    private func value(_ result: ChartLookup.Result, file: StaticString = #filePath, line: UInt = #line) -> ChartValue? {
        guard case .value(let value, _) = result else {
            XCTFail("expected a value, got \(result)", file: file, line: line)
            return nil
        }
        return value
    }

    func testExactlyOnATick() throws {
        let found = try XCTUnwrap(value(ChartLookup.value(in: F.validated(), series: "67", at: 85)))
        XCTAssertEqual(found.about, 15)
        XCTAssertEqual(found.step, 5)
        XCTAssertEqual(found.unit, "°F")
    }

    func testBetweenTwoPoints() throws {
        // 28 at 65, 22 at 75: 25 halfway.
        XCTAssertEqual(try XCTUnwrap(value(ChartLookup.value(in: F.validated(), series: "67", at: 70))).about, 25)
    }

    func testRoundingToTheStep() throws {
        // 22 at 75, 15 at 85: 18.5 at 80, given to the reading's step of 5.
        let found = try XCTUnwrap(value(ChartLookup.value(in: F.validated(), series: "67", at: 80)))
        XCTAssertEqual(found.about, 20)
        XCTAssertEqual(found.about.truncatingRemainder(dividingBy: found.step), 0)
    }

    func testBetweenTwoFamilyCurves() throws {
        // Wet bulb 64.5, halfway between the 62 curve (4 at 105) and the 67 curve (6 at 105).
        XCTAssertEqual(try XCTUnwrap(value(ChartLookup.value(in: F.validated(), parameter: 64.5, at: 105))).about, 5)
        // On a family curve, that curve.
        XCTAssertEqual(try XCTUnwrap(value(ChartLookup.value(in: F.validated(), parameter: 67, at: 85))).about, 15)
    }

    func testOutsideTheXRangeGivesNothing() {
        XCTAssertEqual(ChartLookup.value(in: F.validated(), series: "67", at: 120), .outsideChart(.xOutsideAxis))
        XCTAssertEqual(ChartLookup.value(in: F.validated(), parameter: 67, at: 60), .outsideChart(.xOutsideAxis))
    }

    func testPastTheEndOfASeriesGivesNothing() {
        let short = F.chargingReading(series: [.init(label: "67", parameter: 67,
                                                     points: [.init(75, 22), .init(85, 15), .init(105, 6)])])
        XCTAssertEqual(ChartLookup.value(in: F.validated(short), series: "67", at: 65), .outsideChart(.xOutsideSeries))
    }

    func testOutsideTheFamilyGivesNothing() {
        XCTAssertEqual(ChartLookup.value(in: F.validated(), parameter: 75, at: 85), .outsideChart(.parameterOutsideFamily))
        XCTAssertEqual(ChartLookup.value(in: F.validated(), parameter: 55, at: 85), .outsideChart(.parameterOutsideFamily))
    }

    func testInsideAShadedBandTheNoteComesWithTheValue() {
        let banded = F.validated(F.chargingReading(bands: [.init(note: "Do not charge below 55 °F", x: 65...70)]))
        guard case .value(let found, let note) = ChartLookup.value(in: banded, series: "67", at: 65) else {
            return XCTFail("expected a value")
        }
        XCTAssertEqual(found.about, 30, "28 given to the step")
        XCTAssertEqual(note, "Do not charge below 55 °F")
        guard case .value(_, let none) = ChartLookup.value(in: banded, series: "67", at: 85) else { return XCTFail() }
        XCTAssertNil(none)
    }

    func testAnUnknownSeriesGivesNothing() {
        XCTAssertEqual(ChartLookup.value(in: F.validated(), series: "99", at: 85), .noSuchSeries)
    }

    func testALogarithmicAxisInterpolatesInLogSpace() throws {
        let y = ChartLookup.interpolate([.init(10, 0), .init(1000, 20)], at: 100, logX: true)
        XCTAssertEqual(try XCTUnwrap(y), 10, accuracy: 1e-9)
    }
}
