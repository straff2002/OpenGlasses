import XCTest
@testable import OpenGlasses

/// Plan MQ H4: a reading of the phone's heat and power turned into proceed, wait, flag or stop.
final class QualificationRunGateTests: XCTestCase {

    private typealias Gate = QualificationRunGate
    private let policy = Gate.Policy(settleSeconds: 120, capSeconds: 1_200, requiresCharger: true)

    private func reading(_ time: TimeInterval, _ thermal: Gate.Thermal = .nominal, lowPower: Bool = false,
                         power: Gate.Power = .charging, battery: Double? = 0.8) -> Gate.Reading {
        .init(time: time, thermal: thermal, lowPowerMode: lowPower, batteryLevel: battery, power: power)
    }

    func testTheFirstCaseWaitsForTheSettlePeriod() {
        var state = Gate.State()
        XCTAssertEqual(Gate.decide(reading(0), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(119), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(120), state: &state, policy: policy), .proceed)
        // Still cool: no new settle.
        XCTAssertEqual(Gate.decide(reading(500), state: &state, policy: policy), .proceed)
    }

    /// `fair` doesn't throttle: it counts towards settling, measures once settled, and doesn't restart it.
    func testFairIsMeasuredOn() {
        var state = Gate.State()
        XCTAssertEqual(Gate.decide(reading(0, .fair), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(60), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(120, .fair), state: &state, policy: policy), .proceed)
        XCTAssertEqual(Gate.decide(reading(130), state: &state, policy: policy), .proceed)
        XCTAssertEqual(Gate.decide(reading(140, .fair), state: &state, policy: policy), .proceed, "no new settle after fair")
    }

    func testHeatRestartsTheSettlePeriod() {
        var state = Gate.State()
        _ = Gate.decide(reading(0), state: &state, policy: policy)
        XCTAssertEqual(Gate.decide(reading(200), state: &state, policy: policy), .proceed)
        XCTAssertEqual(Gate.decide(reading(300, .serious), state: &state, policy: policy), .wait([.thermal]))
        XCTAssertEqual(Gate.decide(reading(350, .critical), state: &state, policy: policy), .wait([.thermal]))
        // Cool again at fair: the settle period starts there.
        XCTAssertEqual(Gate.decide(reading(400, .fair), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(519), state: &state, policy: policy), .wait([.settling]))
        XCTAssertEqual(Gate.decide(reading(520), state: &state, policy: policy), .proceed)
    }

    func testHeatAtTheCapFlagsAndLaterCasesAreFlaggedUntilItSettles() {
        var state = Gate.State()
        XCTAssertEqual(Gate.decide(reading(0, .serious), state: &state, policy: policy), .wait([.thermal]))
        XCTAssertEqual(Gate.decide(reading(1_199, .serious), state: &state, policy: policy), .wait([.thermal]))
        XCTAssertEqual(Gate.decide(reading(1_200, .serious), state: &state, policy: policy), .flag([.thermal]))
        // Measured flagged at once, rather than each case waiting out the cap again.
        XCTAssertEqual(Gate.decide(reading(1_250, .serious), state: &state, policy: policy), .flag([.thermal]))
        XCTAssertEqual(Gate.decide(reading(1_300, .fair), state: &state, policy: policy), .flag([.settling]))
        XCTAssertEqual(Gate.decide(reading(1_400), state: &state, policy: policy), .flag([.settling]))
        XCTAssertEqual(Gate.decide(reading(1_420), state: &state, policy: policy), .proceed)
        // Cleared: the next heat waits again.
        XCTAssertEqual(Gate.decide(reading(1_600, .serious), state: &state, policy: policy), .wait([.thermal]))
    }

    func testPowerThatStaysBadToTheCapStopsTheRun() {
        var state = Gate.State()
        XCTAssertEqual(Gate.decide(reading(0, power: .unplugged), state: &state, policy: policy),
                       .wait([.settling, .batteryDraining]))
        XCTAssertEqual(Gate.decide(reading(1_200, power: .unplugged), state: &state, policy: policy),
                       .stop([.batteryDraining]))
        var lowPower = Gate.State()
        _ = Gate.decide(reading(0, .serious, lowPower: true), state: &lowPower, policy: policy)
        XCTAssertEqual(Gate.decide(reading(1_200, .serious, lowPower: true), state: &lowPower, policy: policy),
                       .stop([.thermal, .lowPowerMode]), "power stops even when heat would only flag")
        // Even while flagging on heat, a power fault waits and then stops.
        var flagging = Gate.State()
        _ = Gate.decide(reading(0, .serious), state: &flagging, policy: policy)
        XCTAssertEqual(Gate.decide(reading(1_200, .serious), state: &flagging, policy: policy), .flag([.thermal]))
        XCTAssertEqual(Gate.decide(reading(1_300, .serious, lowPower: true), state: &flagging, policy: policy),
                       .wait([.thermal, .lowPowerMode]))
    }

    func testAPowerFaultThatClearsInTimeIsOnlyAWait() {
        var state = Gate.State()
        _ = Gate.decide(reading(0), state: &state, policy: policy)
        XCTAssertEqual(Gate.decide(reading(200, power: .unplugged), state: &state, policy: policy), .wait([.batteryDraining]))
        XCTAssertEqual(Gate.decide(reading(300, power: .full), state: &state, policy: policy), .proceed)
    }

    func testAnUnknownBatteryIsRefusedUnlessTheRunIsAttended() {
        var state = Gate.State()
        XCTAssertEqual(Gate.decide(reading(0, power: .unknown), state: &state, policy: policy),
                       .wait([.settling, .batteryUnknown]))
        var attended = Gate.State()
        let onBattery = Gate.Policy(settleSeconds: 0, capSeconds: 1_200, requiresCharger: false)
        XCTAssertEqual(Gate.decide(reading(0, power: .unplugged), state: &attended, policy: onBattery), .proceed)
        XCTAssertEqual(Gate.decide(reading(10, lowPower: true, power: .unplugged), state: &attended, policy: onBattery),
                       .wait([.lowPowerMode]), "Low Power Mode waits on any run")
    }

    func testTheDefaultsAreTheUnattendedPolicy() {
        XCTAssertEqual(Gate.Policy.unattended, Gate.Policy(settleSeconds: 120, capSeconds: 1_200, requiresCharger: true))
        XCTAssertTrue(Gate.Reason.batteryDraining.isPower)
        XCTAssertFalse(Gate.Reason.thermal.isPower)
        XCTAssertFalse(Gate.Reason.settling.isPower)
    }
}
