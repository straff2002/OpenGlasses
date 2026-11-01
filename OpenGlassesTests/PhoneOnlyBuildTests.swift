#if AVENKIN_PHONE_ONLY
import XCTest
@testable import OpenGlasses

@MainActor
final class PhoneOnlyBuildTests: XCTestCase {
    func testHardwareCannotBeEnabledBySavedStateOrAnOverride() {
        GlassesSupportPolicy.overrideForTesting = .supported
        defer { GlassesSupportPolicy.overrideForTesting = nil }
        XCTAssertFalse(GlassesSupportPolicy.isSupported)
        XCTAssertFalse(WearablesBootstrap.ensureConfigured())
        XCTAssertEqual(WearablesBootstrap.registrationSnapshot.rawValue, 0)
        let link = GlassesBackendFactory.link()
        XCTAssertFalse(link.activate())
        XCTAssertTrue(link.devices.isEmpty)
        XCTAssertFalse(GlassesBackendFactory.camera().isReady(configuringIfNeeded: true))
    }
    func testCameraEntryPointsRefuseInsteadOfPretendingToCapture() async {
        let camera = GlassesBackendFactory.camera()
        do { _ = try await camera.capturePhoto(); XCTFail("No glasses in this binary") }
        catch { XCTAssertTrue(error is WearablesBootstrap.Unavailable) }
        do { try await camera.startStreaming(); XCTFail("No glasses in this binary") }
        catch { XCTAssertTrue(error is WearablesBootstrap.Unavailable) }
    }
    func testHardwareSiriActionsAreExcludedAndSavedBindingsAreRefused() {
        for id in BuiltinSiriAction.glassesOnlyIDs {
            XCTAssertNil(BuiltinSiriAction.action(id: id), id)
            XCTAssertNotNil(SiriActionDispatcher.refusalReason(for: .builtin(id: id)), id)
        }
        XCTAssertNotNil(BuiltinSiriAction.action(id: "take_photo"), "Phone photo analysis remains available")
    }
    func testSavedEvenPairingCannotEnableBLEDisplay() {
        let backend = Config.displayBackend
        let left = Config.evenLeftPeripheralID
        defer { Config.displayBackend = backend; Config.evenLeftPeripheralID = left }
        Config.displayBackend = .evenG2
        Config.evenLeftPeripheralID = UUID().uuidString
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        XCTAssertFalse(display.deviceSupportsDisplay())
        XCTAssertFalse(display.hasDisplayCapability)
    }
}
#endif
