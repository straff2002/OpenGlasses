import XCTest
@testable import OpenGlasses

/// Tests for the Vehicle/EV tool's pure summary formatter (the HA reads need a live
/// instance, so the device-independent formatting is factored out and tested here).
@MainActor
final class VehicleToolTests: XCTestCase {
    private typealias Reading = VehicleTool.Reading

    func testFullSummary() {
        let s = VehicleTool.summary(
            battery: Reading(name: "Tesla Battery", state: "72"),
            range: Reading(name: "Tesla Range", state: "210 mi"),
            charging: Reading(name: "Tesla Charging", state: "charging"),
            plugged: Reading(name: "Tesla Plug", state: "on")
        )
        XCTAssertEqual(s, "Tesla Battery: 72% charged, about 210 mi range, currently charging, plugged in.")
    }

    func testNotChargingUnplugged() {
        let s = VehicleTool.summary(
            battery: Reading(name: "Car", state: "55"),
            range: nil,
            charging: Reading(name: "Charging", state: "off"),
            plugged: Reading(name: "Plug", state: "off")
        )
        XCTAssertEqual(s, "Car: 55% charged, not charging, unplugged.")
    }

    func testBatteryOnly() {
        let s = VehicleTool.summary(battery: Reading(name: "EV", state: "80"), range: nil, charging: nil, plugged: nil)
        XCTAssertEqual(s, "EV: 80% charged.")
    }

    func testNoSensorsMessage() {
        let s = VehicleTool.summary(battery: nil, range: nil, charging: nil, plugged: nil)
        XCTAssertTrue(s.contains("couldn't find"))
        XCTAssertTrue(s.contains("Home Assistant"))
    }

    func testChargingTruthyVariantsAreCaseInsensitive() {
        for state in ["on", "Charging", "TRUE", "yes"] {
            let s = VehicleTool.summary(battery: nil, range: nil, charging: Reading(name: "c", state: state), plugged: nil)
            XCTAssertTrue(s.contains("currently charging"), "state '\(state)' should read as charging")
        }
        let idle = VehicleTool.summary(battery: nil, range: nil, charging: Reading(name: "c", state: "idle"), plugged: nil)
        XCTAssertTrue(idle.contains("not charging"))
    }

    func testLabelFallsBackToRangeThenGeneric() {
        let rangeLabel = VehicleTool.summary(battery: nil, range: Reading(name: "My Range", state: "100"), charging: nil, plugged: nil)
        XCTAssertTrue(rangeLabel.hasPrefix("My Range:"))
        let generic = VehicleTool.summary(battery: nil, range: nil, charging: Reading(name: "x", state: "on"), plugged: nil)
        XCTAssertTrue(generic.hasPrefix("Your vehicle:"))
    }
}
