import XCTest
@testable import OpenGlasses

/// Plan GE P0 — what thinks on the phone, in a hand and in a pocket.
final class OfflineBrainSelectorTests: XCTestCase {

    private let everything = OfflineBrainSelector.Available(
        localModelConfigId: "local", localModelIsGGUF: false,
        appleOnDeviceConfigId: "apple")

    func testForegroundPrefersTheInstalledOnDeviceModel() {
        XCTAssertEqual(OfflineBrainSelector.select(appActive: true, available: everything),
                       .localModel(configId: "local"))
    }

    func testForegroundFallsToAppleWithoutALocalModel() {
        let appleOnly = OfflineBrainSelector.Available(appleOnDeviceConfigId: "apple")
        XCTAssertEqual(OfflineBrainSelector.select(appActive: true, available: appleOnly),
                       .appleOnDevice(configId: "apple"))
    }

    func testNothingInstalledMeansNoBrain() {
        XCTAssertEqual(OfflineBrainSelector.select(appActive: true, available: .init()), .none)
        XCTAssertFalse(OfflineBrainSelector.Available().hasAnyModel)
    }

    /// The rule that keeps Metal out of the background: never MLX there, whatever is installed.
    func testBackgroundNeverUsesMLX() {
        for gguf in [false, true] {
            for cpu in [false, true] {
                let available = OfflineBrainSelector.Available(
                    localModelConfigId: "local", localModelIsGGUF: gguf, cpuTierAllowed: cpu)
                let brain = OfflineBrainSelector.select(appActive: false, available: available)
                XCTAssertNotEqual(brain, .localModel(configId: "local"), "gguf=\(gguf) cpu=\(cpu)")
                if !gguf { XCTAssertEqual(brain, .none, "an MLX model never runs backgrounded") }
            }
        }
    }

    func testUnverifiedBackgroundTiersStayOff() {
        XCTAssertFalse(OfflineBrainSelector.appleOnDeviceVerifiedInBackground)
        XCTAssertFalse(OfflineBrainSelector.cpuTierVerifiedOnDevice)
        let shipped = OfflineBrainSelector.Available(
            localModelConfigId: "local", localModelIsGGUF: true, appleOnDeviceConfigId: "apple",
            appleOnDeviceServesBackground: OfflineBrainSelector.appleOnDeviceVerifiedInBackground,
            cpuTierAllowed: OfflineBrainSelector.cpuTierVerifiedOnDevice)
        XCTAssertEqual(OfflineBrainSelector.select(appActive: false, available: shipped), .none,
                       "locked in a pocket with the shipped flags: deterministic answers, then hold")
    }

    func testVerifiedTiersWouldBeUsedInLadderOrder() {
        let verifiedApple = OfflineBrainSelector.Available(
            localModelConfigId: "local", localModelIsGGUF: true, appleOnDeviceConfigId: "apple",
            appleOnDeviceServesBackground: true, cpuTierAllowed: true)
        XCTAssertEqual(OfflineBrainSelector.select(appActive: false, available: verifiedApple),
                       .appleOnDevice(configId: "apple"))
        let cpuOnly = OfflineBrainSelector.Available(
            localModelConfigId: "local", localModelIsGGUF: true, cpuTierAllowed: true)
        XCTAssertEqual(OfflineBrainSelector.select(appActive: false, available: cpuOnly),
                       .cpuLocalModel(configId: "local"))
    }

    func testTheSettingNeedsAModelAndStaysInertUnderMedicalLocalOnly() {
        XCTAssertTrue(ConnectivityHandoffController.isEffectivelyEnabled(
            setting: true, available: everything, medicalLocalOnly: false))
        XCTAssertFalse(ConnectivityHandoffController.isEffectivelyEnabled(
            setting: true, available: .init(), medicalLocalOnly: false), "no model, nothing to hand to")
        XCTAssertFalse(ConnectivityHandoffController.isEffectivelyEnabled(
            setting: false, available: everything, medicalLocalOnly: false))
        XCTAssertFalse(ConnectivityHandoffController.isEffectivelyEnabled(
            setting: true, available: everything, medicalLocalOnly: true), "local-only never uses the cloud")
    }

    func testTheSettingDefaultsOn() {
        let key = "offlineHandoffEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(Config.offlineHandoffEnabled)
    }
}
