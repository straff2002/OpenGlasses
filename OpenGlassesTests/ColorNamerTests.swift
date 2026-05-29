import XCTest
@testable import OpenGlasses

/// Tests the pure RGB→name color mapping used by identify_color.
final class ColorNamerTests: XCTestCase {

    func testPrimaries() {
        XCTAssertEqual(ColorNamer.name(r: 1, g: 0, b: 0), "red")
        XCTAssertEqual(ColorNamer.name(r: 0, g: 1, b: 0), "green")
        XCTAssertEqual(ColorNamer.name(r: 0, g: 0, b: 1), "blue")
    }

    func testGrayscaleRamp() {
        XCTAssertEqual(ColorNamer.name(r: 0, g: 0, b: 0), "black")
        XCTAssertEqual(ColorNamer.name(r: 1, g: 1, b: 1), "white")
        XCTAssertEqual(ColorNamer.name(r: 0.5, g: 0.5, b: 0.5), "gray")
    }

    func testLightnessQualifier() {
        // Dark blue vs light blue.
        XCTAssertEqual(ColorNamer.name(r: 0, g: 0, b: 0.3), "dark blue")
        XCTAssertTrue(ColorNamer.name(r: 0.6, g: 0.8, b: 1.0).contains("blue"))
    }

    func testYellowAndOrange() {
        XCTAssertEqual(ColorNamer.name(r: 1, g: 1, b: 0), "yellow")
        XCTAssertEqual(ColorNamer.name(r: 1, g: 0.55, b: 0), "orange")
    }

    func testBrownIsDarkLowSatOrange() {
        XCTAssertTrue(ColorNamer.name(r: 0.4, g: 0.26, b: 0.13).contains("brown"))
    }

    func testHSVConversionSanity() {
        let (h, s, v) = ColorNamer.rgbToHSV(r: 1, g: 0, b: 0)
        XCTAssertEqual(h, 0, accuracy: 1)
        XCTAssertEqual(s, 1, accuracy: 0.001)
        XCTAssertEqual(v, 1, accuracy: 0.001)
    }
}
