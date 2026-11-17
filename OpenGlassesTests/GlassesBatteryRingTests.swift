import XCTest
@testable import OpenGlasses

/// The status mark's battery ring. What these pin: a level is drawn only while the glasses are
/// connected and report one — anything else leaves the card's ring as it always was — and a low
/// battery is a warning only while it is not already charging.
final class GlassesBatteryRingTests: XCTestCase {

    // MARK: - No reading, no ring

    func testNotConnectedShowsNoBatteryEvenWithALevel() {
        XCTAssertNil(GlassesBatteryRing.reading(level: 64, isCharging: false, connected: false),
                     "a level must never outlive the link")
        XCTAssertNil(GlassesBatteryRing.reading(level: 64, isCharging: true, connected: false))
    }

    func testConnectedWithoutALevelShowsNoBattery() {
        XCTAssertNil(GlassesBatteryRing.reading(level: nil, isCharging: false, connected: true))
        XCTAssertNil(GlassesBatteryRing.reading(level: nil, isCharging: true, connected: true),
                     "charging alone, with no level, is not a ring to draw")
    }

    func testPhoneOnlyBuildsNeverGetAReading() {
        // Phone-only builds have no glasses SDK: the service never connects and never has a level.
        XCTAssertNil(GlassesBatteryRing.reading(level: nil, isCharging: false, connected: false))
    }

    // MARK: - Fraction

    func testFractionFollowsTheLevel() throws {
        let cases: [(Int, Double)] = [(0, 0), (1, 0.01), (64, 0.64), (100, 1)]
        for (level, fraction) in cases {
            let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: level, isCharging: false,
                                                                connected: true))
            XCTAssertEqual(ring.percent, level)
            XCTAssertEqual(ring.fraction, fraction, accuracy: 0.0001, "\(level)")
        }
    }

    func testOutOfRangeLevelsAreClamped() throws {
        let over = try XCTUnwrap(GlassesBatteryRing.reading(level: 130, isCharging: false, connected: true))
        XCTAssertEqual(over.percent, 100)
        XCTAssertEqual(over.fraction, 1, accuracy: 0.0001)
        let under = try XCTUnwrap(GlassesBatteryRing.reading(level: -5, isCharging: false, connected: true))
        XCTAssertEqual(under.percent, 0)
        XCTAssertEqual(under.fraction, 0, accuracy: 0.0001)
    }

    // MARK: - Low

    func testLowAtAndBelowTheThresholdOnly() throws {
        for level in [0, 5, 10, GlassesBatteryRing.lowPercent] {
            let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: level, isCharging: false,
                                                                connected: true))
            XCTAssertTrue(ring.isLow, "\(level)")
        }
        for level in [GlassesBatteryRing.lowPercent + 1, 50, 100] {
            let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: level, isCharging: false,
                                                                connected: true))
            XCTAssertFalse(ring.isLow, "\(level)")
        }
    }

    func testChargingIsNeverDrawnAsLow() throws {
        let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: 5, isCharging: true, connected: true))
        XCTAssertTrue(ring.isCharging)
        XCTAssertFalse(ring.isLow, "glasses on charge are already being fixed")
    }

    func testArcColourFollowsTheChargeOnly() throws {
        let charged = try XCTUnwrap(GlassesBatteryRing.reading(level: 64, isCharging: false, connected: true))
        XCTAssertEqual(charged.arcTint, .charged)
        let low = try XCTUnwrap(GlassesBatteryRing.reading(level: 12, isCharging: false, connected: true))
        XCTAssertEqual(low.arcTint, .low)
        let lowCharging = try XCTUnwrap(GlassesBatteryRing.reading(level: 12, isCharging: true, connected: true))
        XCTAssertEqual(lowCharging.arcTint, .charged, "on charge: green, with the bolt")
    }

    func testTheLowThresholdMatchesTheWidgets() {
        XCTAssertTrue(WidgetGlassesPresentation.batteryThresholds.contains(GlassesBatteryRing.lowPercent))
    }

    // MARK: - Resting hue

    func testRestingMarkIsGreenOnlyWhileGlassesAreConnected() {
        XCTAssertEqual(StatusMarkRestTint.tint(glassesConnected: true), .glassesConnected)
        XCTAssertEqual(StatusMarkRestTint.tint(glassesConnected: false), .inactive,
                       "no glasses, a phone-only build or a pair in its case: grey, as before")
    }

    // MARK: - VoiceOver

    func testSpokenLevel() throws {
        let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: 64, isCharging: false, connected: true))
        XCTAssertEqual(ring.accessibilityLabel, "Glasses battery")
        XCTAssertEqual(ring.accessibilityValue, 64.formatted(.percent))
    }

    func testSpokenLevelWhileCharging() throws {
        let ring = try XCTUnwrap(GlassesBatteryRing.reading(level: 64, isCharging: true, connected: true))
        XCTAssertEqual(ring.accessibilityValue, 64.formatted(.percent) + ", charging")
    }
}
