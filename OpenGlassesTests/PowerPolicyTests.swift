import XCTest
@testable import OpenGlasses

/// Plan BV — Power Policy P1: pure fusion of battery/thermal signals → posture, with hysteresis.
/// All headless — no device, no clock.
final class PowerPolicyTests: XCTestCase {

    // MARK: - ThermalPressure

    func testThermalPressureMapsProcessInfoState() {
        // Qualify the state type: `ThermalPressure` also has a `GlassesThermal` initializer whose
        // enum shares case names (`.critical`), so a bare leading-dot is ambiguous.
        XCTAssertEqual(ThermalPressure(ProcessInfo.ThermalState.nominal), .nominal)
        XCTAssertEqual(ThermalPressure(ProcessInfo.ThermalState.fair), .fair)
        XCTAssertEqual(ThermalPressure(ProcessInfo.ThermalState.serious), .serious)
        XCTAssertEqual(ThermalPressure(ProcessInfo.ThermalState.critical), .critical)
    }

    func testThermalPressureIsOrdered() {
        XCTAssertLessThan(ThermalPressure.nominal, .fair)
        XCTAssertLessThan(ThermalPressure.serious, .critical)
        XCTAssertEqual(max(ThermalPressure.fair, .serious), .serious)
    }

    // MARK: - Fusion: defaults & missing inputs

    func testEmptyStateIsNormal() {
        XCTAssertEqual(PowerPolicy.decide(PowerState()), .normal)
    }

    func testUnknownPhoneBatteryNeverDowngrades() {
        // A missing battery reading must not be read as "empty".
        let state = PowerState(phoneBatteryFraction: nil)
        XCTAssertEqual(PowerPolicy.decide(state), .normal)
    }

    func testPhoneOnlyPostureIsUsefulWithoutGlasses() {
        let state = PowerState(phoneBatteryFraction: 0.10, glassesBatteryPercent: nil)
        XCTAssertEqual(PowerPolicy.decide(state), .reserve)
    }

    // MARK: - Battery table (from normal)

    func testBatteryEntersConserveAtThreshold() {
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.31)), .normal)
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.30)), .conserve)
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.16)), .conserve)
    }

    func testBatteryEntersReserveAtThreshold() {
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.15)), .reserve)
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.05)), .reserve)
    }

    func testChargingRelievesPhoneBatteryButNotThermals() {
        // Very low but on the charger → no battery downgrade.
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.05, phoneCharging: true)),
                       .normal)
        // ...thermals still bite while charging.
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.05,
                                                     phoneCharging: true,
                                                     phoneThermal: .critical)),
                       .reserve)
    }

    func testGlassesBatteryCountsEvenWhenPhoneHealthy() {
        let state = PowerState(phoneBatteryFraction: 0.95, glassesBatteryPercent: 25)
        XCTAssertEqual(PowerPolicy.decide(state), .conserve)

        let critical = PowerState(phoneBatteryFraction: 0.95, glassesBatteryPercent: 10)
        XCTAssertEqual(PowerPolicy.decide(critical), .reserve)
    }

    // MARK: - Thermal table

    func testThermalBands() {
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneThermal: .fair)), .normal)
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneThermal: .serious)), .conserve)
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneThermal: .critical)), .reserve)
    }

    func testGlassesThermalCounts() {
        let state = PowerState(phoneThermal: .nominal, glassesThermal: .critical)
        XCTAssertEqual(PowerPolicy.decide(state), .reserve)
    }

    // MARK: - Fusion: worst signal wins & low power mode

    func testWorstSignalWins() {
        // Healthy battery but hot → still reserve.
        let hot = PowerState(phoneBatteryFraction: 0.90, phoneThermal: .critical)
        XCTAssertEqual(PowerPolicy.decide(hot), .reserve)
    }

    func testLowPowerModeFloorsAtConserve() {
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.95, lowPowerMode: true)),
                       .conserve)
        // ...but never masks a worse signal.
        let worse = PowerState(phoneBatteryFraction: 0.05, lowPowerMode: true)
        XCTAssertEqual(PowerPolicy.decide(worse), .reserve)
    }

    // MARK: - Hysteresis

    func testConserveBandIsStickyBetweenEnterAndExit() {
        // 0.32 sits between conserveEnter (0.30) and conserveExit (0.35).
        let state = PowerState(phoneBatteryFraction: 0.32)
        // Coming from normal, 0.32 stays normal (hasn't crossed enter)...
        XCTAssertEqual(PowerPolicy.decide(state, previous: .normal), .normal)
        // ...but once conserving, it stays conserving until it climbs past exit.
        XCTAssertEqual(PowerPolicy.decide(state, previous: .conserve), .conserve)
        // Clearing the exit threshold recovers to normal.
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.35), previous: .conserve),
                       .normal)
    }

    func testReserveBandIsStickyBetweenEnterAndExit() {
        // 0.18 sits between reserveEnter (0.15) and reserveExit (0.20).
        let state = PowerState(phoneBatteryFraction: 0.18)
        // From conserve, 0.18 hasn't hit reserve-enter yet → conserve.
        XCTAssertEqual(PowerPolicy.decide(state, previous: .conserve), .conserve)
        // From reserve, 0.18 is still below the wider exit → stays reserve.
        XCTAssertEqual(PowerPolicy.decide(state, previous: .reserve), .reserve)
        // Climbing to the exit threshold steps back up to conserve, not all the way to normal.
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.20), previous: .reserve),
                       .conserve)
    }

    func testRecoveryFromReserveToNormalWhenBatteryHealthyAgain() {
        // e.g. reserve was driven by thermals that have now cleared; battery is fine.
        let healthy = PowerState(phoneBatteryFraction: 0.80, phoneThermal: .nominal)
        XCTAssertEqual(PowerPolicy.decide(healthy, previous: .reserve), .normal)
    }

    // MARK: - Custom thresholds

    func testCustomThresholdsAreHonoured() {
        var t = PowerPolicy.Thresholds.default
        t.conserveBatteryEnter = 0.50
        XCTAssertEqual(PowerPolicy.decide(PowerState(phoneBatteryFraction: 0.45), thresholds: t),
                       .conserve)
    }

    func testConfigPowerThresholdsDefaults() {
        let t = Config.powerThresholds
        XCTAssertEqual(t.conserveBatteryEnter, 0.30, accuracy: 0.0001)
        XCTAssertEqual(t.reserveBatteryEnter, 0.15, accuracy: 0.0001)
        XCTAssertEqual(t.conserveThermal, .serious)
        XCTAssertEqual(t.reserveThermal, .critical)
    }

    // MARK: - Consumer contract & explanation

    func testPostureConsumerFlags() {
        XCTAssertFalse(PowerPosture.normal.prefersSnapshotOverStream)
        XCTAssertTrue(PowerPosture.conserve.prefersSnapshotOverStream)
        XCTAssertTrue(PowerPosture.conserve.prefersSmallerLocalModel)
        XCTAssertFalse(PowerPosture.conserve.requiresConfirmationBeforeStream)
        XCTAssertTrue(PowerPosture.reserve.requiresConfirmationBeforeStream)
    }

    /// Plan HE: a recorded job going to the office waits whenever the phone is economising.
    func testBulkTransferWaitsWheneverThePhoneIsEconomising() {
        XCTAssertFalse(PowerPosture.normal.defersBulkTransfer)
        XCTAssertTrue(PowerPosture.conserve.defersBulkTransfer)
        XCTAssertTrue(PowerPosture.reserve.defersBulkTransfer)
    }

    func testExplanationNilWhenNormal() {
        XCTAssertNil(PowerPolicy.explanation(PowerState(), posture: .normal))
    }

    func testExplanationNamesGlassesBattery() {
        let state = PowerState(phoneBatteryFraction: 0.95, glassesBatteryPercent: 18)
        let posture = PowerPolicy.decide(state)
        XCTAssertEqual(PowerPolicy.explanation(state, posture: posture), "conserving — glasses battery 18%")
    }

    func testExplanationNamesThermalsFirst() {
        let state = PowerState(phoneBatteryFraction: 0.10, phoneThermal: .critical)
        let posture = PowerPolicy.decide(state)   // reserve
        XCTAssertEqual(PowerPolicy.explanation(state, posture: posture), "power reserve — phone running warm")
    }
}
