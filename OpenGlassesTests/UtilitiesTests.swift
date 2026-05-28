import XCTest
import CoreLocation
@testable import OpenGlasses

/// Tests for Plan D utilities: OneEuroFilter smoothing/wrap behavior and AircraftOverheadTool's
/// pure bearing/compass helpers.
final class UtilitiesTests: XCTestCase {

    // MARK: - OneEuroFilter

    func testFirstSampleReturnedUnchanged() {
        var filter = OneEuroFilter()
        XCTAssertEqual(filter.filter(5.0, t: 0.0), 5.0, accuracy: 0.0001)
    }

    func testSmoothsNoiseTowardStableSignal() {
        var filter = OneEuroFilter(minCutoff: 0.3, beta: 0.0, dCutoff: 1.0)
        _ = filter.filter(10.0, t: 0.0)
        // Feed a noisy spike around 10; filtered output should stay much closer to 10 than 14.
        var last = 10.0
        var t = 0.1
        for sample in [14.0, 6.0, 13.0, 7.0, 12.0, 8.0] {
            last = filter.filter(sample, t: t)
            t += 0.1
        }
        XCTAssertLessThan(abs(last - 10.0), 3.0, "Filtered output should be smoothed near the stable mean")
    }

    func testTracksRampUpward() {
        var filter = OneEuroFilter()
        var out = 0.0
        var t = 0.0
        for x in stride(from: 0.0, through: 20.0, by: 1.0) {
            out = filter.filter(x, t: t)
            t += 0.1
        }
        // After a steady ramp it should be well above the start, trailing the input slightly.
        XCTAssertGreaterThan(out, 15.0)
        XCTAssertLessThanOrEqual(out, 20.0)
    }

    func testAngleWrapAroundIsContinuous() {
        var filter = OneEuroFilter()
        _ = filter.filterAngle(358.0, t: 0.0)
        let result = filter.filterAngle(2.0, t: 0.1) // crosses 0°
        // Should land near the short-way path (~0°/360°), NOT swing down toward ~180°.
        let distanceToZero = min(result, 360 - result)
        XCTAssertLessThan(distanceToZero, 90, "Wrap should take the short path across 0°, got \(result)")
    }

    func testResetClearsState() {
        var filter = OneEuroFilter()
        _ = filter.filter(100.0, t: 0.0)
        _ = filter.filter(100.0, t: 0.1)
        filter.reset()
        XCTAssertEqual(filter.filter(3.0, t: 1.0), 3.0, accuracy: 0.0001, "After reset the next sample is the first again")
    }

    // MARK: - AircraftOverheadTool helpers

    func testBearingDueNorthAndEast() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let north = CLLocationCoordinate2D(latitude: 1, longitude: 0)
        let east = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        XCTAssertEqual(AircraftOverheadTool.bearing(from: origin, to: north), 0, accuracy: 1.0)
        XCTAssertEqual(AircraftOverheadTool.bearing(from: origin, to: east), 90, accuracy: 1.0)
    }

    func testCompassPoints() {
        XCTAssertEqual(AircraftOverheadTool.compassPoint(0), "N")
        XCTAssertEqual(AircraftOverheadTool.compassPoint(90), "E")
        XCTAssertEqual(AircraftOverheadTool.compassPoint(180), "S")
        XCTAssertEqual(AircraftOverheadTool.compassPoint(270), "W")
        XCTAssertEqual(AircraftOverheadTool.compassPoint(45), "NE")
    }
}
