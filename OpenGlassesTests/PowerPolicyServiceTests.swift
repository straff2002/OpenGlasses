import XCTest
import UIKit
import MWDATCore
@testable import OpenGlasses

/// Plan BV P2 — the `PowerPolicyService` wiring (injected signal seams, posture publishing,
/// hysteresis across samples), the glasses thermal mapping, and the live-mode frame-throttle
/// stretch. Plan HX P1 added the glasses' live thermal reading as a signal.
final class PowerPolicyServiceTests: XCTestCase {

    // MARK: - Glasses thermal level → ThermalPressure

    func testGlassesThermalMapping() {
        XCTAssertEqual(ThermalPressure(GlassesThermal.normal), .nominal)
        XCTAssertEqual(ThermalPressure(GlassesThermal.light), .nominal)
        XCTAssertEqual(ThermalPressure(GlassesThermal.moderate), .fair)
        XCTAssertEqual(ThermalPressure(GlassesThermal.severe), .serious)
        XCTAssertEqual(ThermalPressure(GlassesThermal.critical), .critical)
        XCTAssertEqual(ThermalPressure(GlassesThermal.emergency), .critical)
        XCTAssertEqual(ThermalPressure(GlassesThermal.shutdown), .critical)
    }

    /// The SDK's level is mapped once, at the link source, case for case. Unknown is nil there:
    /// no reading, rather than a cool one.
    func testTheLinkSourceMapsTheSDKsThermalLevelCaseForCase() {
        XCTAssertNil(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.unknown))
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.none), .normal)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.light), .light)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.moderate), .moderate)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.severe), .severe)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.critical), .critical)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.emergency), .emergency)
        XCTAssertEqual(WearablesGlassesLinkSource.map(MWDATCore.ThermalLevel.shutdown), .shutdown)
    }

    /// The two steps together are the table this plan shipped with, which took the SDK's level
    /// directly. The one difference is deliberate and changes no posture: an unknown level used
    /// to read as nominal, and is now no signal at all.
    func testSDKLevelToPressureIsUnchangedThroughTheAppsOwnEnum() {
        func pressure(_ level: MWDATCore.ThermalLevel) -> ThermalPressure? {
            WearablesGlassesLinkSource.map(level).map { ThermalPressure($0) }
        }
        XCTAssertNil(pressure(.unknown))
        XCTAssertEqual(pressure(.none), .nominal)
        XCTAssertEqual(pressure(.light), .nominal)
        XCTAssertEqual(pressure(.moderate), .fair)
        XCTAssertEqual(pressure(.severe), .serious)
        XCTAssertEqual(pressure(.critical), .critical)
        XCTAssertEqual(pressure(.emergency), .critical)
        XCTAssertEqual(pressure(.shutdown), .critical)
    }

    // MARK: - Glasses thermal moves the posture (Plan HX P1)

    @MainActor
    func testHotGlassesMoveThePosture() {
        let service = PowerPolicyService()
        var thermal: GlassesThermal? = .severe
        service.glassesThermal = { thermal.map { ThermalPressure($0) } }

        service.update()
        XCTAssertEqual(service.posture, .conserve)
        XCTAssertEqual(service.explanation, "conserving — glasses running warm")

        thermal = .critical
        service.update()
        XCTAssertEqual(service.posture, .reserve)
        XCTAssertEqual(service.explanation, "power reserve — glasses running warm")

        thermal = .moderate
        service.update()
        XCTAssertEqual(service.posture, .normal, "thermals are bands, not sticky: cooled glasses lift it")
        XCTAssertNil(service.explanation)
    }

    @MainActor
    func testNoGlassesReadingLeavesThePostureAlone() {
        let service = PowerPolicyService()
        service.glassesThermal = { nil }
        service.update()
        XCTAssertEqual(service.posture, .normal)
        XCTAssertNil(service.explanation)

        // And it does not soften what the phone says by itself.
        service.phoneThermal = { .serious }
        service.update()
        XCTAssertEqual(service.posture, .conserve)
        XCTAssertEqual(service.explanation, "conserving — phone running warm")
    }

    /// The wiring `AppState` does, end to end without `Wearables`: the connection service's
    /// reading feeds the posture while the link is up, and stops feeding it the moment it is not.
    @MainActor
    func testThePostureFollowsTheConnectionServicesReadingAndNeverAStaleOne() {
        let source = GlassesConnectionServiceTests.FakeLinkSource()
        let glasses = GlassesConnectionService(source: source, observeNow: true)
        let service = PowerPolicyService()
        service.glassesThermal = { [weak glasses] in glasses?.thermal.map { ThermalPressure($0) } }

        source.sendDevices(["a"])
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: .emergency))
        service.update()
        XCTAssertEqual(service.posture, .reserve)

        // Into the case, still hot as far as the SDK's last word goes.
        source.sendState("a", GlassesDeviceState(link: .disconnected, thermal: .emergency))
        service.update()
        XCTAssertEqual(service.posture, .normal, "a reading from glasses that have gone holds nothing down")
        XCTAssertNil(service.explanation)

        // Connected again without a thermal reading: still no signal.
        source.sendState("a", GlassesDeviceState(link: .connected, thermal: nil))
        service.update()
        XCTAssertEqual(service.posture, .normal)
    }

    // MARK: - Service fusion & publishing

    @MainActor
    func testServiceFusesInjectedSignals() {
        let service = PowerPolicyService()
        service.glassesBatteryPercent = { 25 }
        service.update()
        XCTAssertEqual(service.posture, .conserve)
        XCTAssertEqual(service.explanation, "conserving — glasses battery 25%")
    }

    @MainActor
    func testServiceDefaultsToNormal() {
        let service = PowerPolicyService()
        service.update()
        XCTAssertEqual(service.posture, .normal)
        XCTAssertNil(service.explanation)
    }

    @MainActor
    func testChargingRelievesPhoneBattery() {
        let service = PowerPolicyService()
        service.phoneBatteryFraction = { 0.05 }
        service.phoneCharging = { true }
        service.update()
        XCTAssertEqual(service.posture, .normal)
    }

    // MARK: - Hysteresis across successive samples (service holds `previous`)

    @MainActor
    func testServiceHysteresisIsStickyAcrossUpdates() {
        let service = PowerPolicyService()
        var battery = 0.28
        service.phoneBatteryFraction = { battery }

        service.update()
        XCTAssertEqual(service.posture, .conserve)   // entered conserve at ≤0.30

        battery = 0.32                               // in the 0.30–0.35 hysteresis band
        service.update()
        XCTAssertEqual(service.posture, .conserve)   // ...stays conserve, doesn't flap

        battery = 0.40                               // clears the exit threshold
        service.update()
        XCTAssertEqual(service.posture, .normal)
    }

    // MARK: - Posture frame-interval multiplier

    func testFrameIntervalMultiplierByPosture() {
        XCTAssertEqual(PowerPosture.normal.frameIntervalMultiplier, 1.0)
        XCTAssertEqual(PowerPosture.conserve.frameIntervalMultiplier, 2.0)
        XCTAssertEqual(PowerPosture.reserve.frameIntervalMultiplier, 4.0)
    }

    // MARK: - FrameThrottler power stretch (deterministic via injected clock)

    func testThrottlerStretchesIntervalUnderPowerMultiplier() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let throttler = FrameThrottler(interval: 10, now: { t })
        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }
        let frame = UIImage()

        // Multiplier 1.0: a frame at t=11 clears the 10s interval.
        throttler.submit(frame)                       // t=0 → forwarded (first frame)
        t = Date(timeIntervalSinceReferenceDate: 11)
        throttler.submit(frame)                       // t=11 → forwarded
        XCTAssertEqual(forwarded, 2)

        // Now stretch ×2 → effective interval 20s. A frame 15s later is dropped...
        throttler.powerIntervalMultiplier = 2.0
        t = Date(timeIntervalSinceReferenceDate: 26)
        throttler.submit(frame)                       // 26-11 = 15 < 20 → dropped
        XCTAssertEqual(forwarded, 2)
        // ...but at 20s+ it forwards again.
        t = Date(timeIntervalSinceReferenceDate: 32)
        throttler.submit(frame)                       // 32-11 = 21 ≥ 20 → forwarded
        XCTAssertEqual(forwarded, 3)
    }

    func testThrottlerMultiplierFlooredAtOne() {
        // A sub-1 multiplier must not *speed up* the stream.
        var t = Date(timeIntervalSinceReferenceDate: 0)
        let throttler = FrameThrottler(interval: 10, now: { t })
        throttler.powerIntervalMultiplier = 0.1
        var forwarded = 0
        throttler.onThrottledFrame = { _ in forwarded += 1 }
        let frame = UIImage()

        throttler.submit(frame)                       // t=0 → forwarded
        t = Date(timeIntervalSinceReferenceDate: 5)
        throttler.submit(frame)                       // 5 < 10 (floor) → dropped
        XCTAssertEqual(forwarded, 1)
    }
}
