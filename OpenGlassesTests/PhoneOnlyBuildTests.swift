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
        let backend = UserDefaults.standard.object(forKey: "displayBackend")
        let left = Config.evenLeftPeripheralID
        defer {
            UserDefaults.standard.set(backend, forKey: "displayBackend")
            Config.evenLeftPeripheralID = left
        }
        UserDefaults.standard.set("evenG2", forKey: "displayBackend")
        Config.evenLeftPeripheralID = UUID().uuidString
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        XCTAssertFalse(display.deviceSupportsDisplay())
        XCTAssertFalse(display.hasDisplayCapability)
    }

    // MARK: - Nothing a person can reach or hear says glasses

    func testNoRegisteredToolMentionsGlasses() {
        let accessibility = Config.accessibilityModeEnabled
        defer { Config.setAccessibilityModeEnabled(accessibility) }
        Config.setAccessibilityModeEnabled(true)
        let camera = CameraService()
        let registry = NativeToolRegistry(locationService: LocationService(), cameraService: camera)
        registry.register(LiveTranslationTool())
        registry.register(TeleprompterTool(service: TeleprompterService(store: TeleprompterScriptStore()),
                                           documentStore: nil))
        XCTAssertFalse(registry.allTools.isEmpty)
        for tool in registry.allTools {
            XCTAssertFalse(tool.name.lowercased().contains("glasses"), tool.name)
            XCTAssertFalse(tool.description.lowercased().contains("glasses"), tool.name)
            XCTAssertFalse(String(describing: tool.parametersSchema).lowercased().contains("glasses"), tool.name)
        }
        withExtendedLifetime(camera) {}
    }

    func testToolsThatNeedALivePictureAreNotRegistered() {
        let camera = CameraService()
        let registry = NativeToolRegistry(locationService: LocationService(), cameraService: camera)
        let names = Set(registry.allTools.map(\.name))
        // `fitness_coach` stays, without its form check.
        let gone = PhoneCapturePolicy.glassesOnlyTools.subtracting(["fitness_coach"]).union(["reading_session"])
        XCTAssertTrue(names.isDisjoint(with: gone), "\(names.intersection(gone))")
        XCTAssertTrue(names.contains("capture_photo"))
        withExtendedLifetime(camera) {}
    }

    func testTheSystemPromptNeverSaysGlasses() {
        var prompts = [
            Config.defaultSystemPrompt(device: .phone),
            Config.defaultSystemPrompt(device: .watch),
            SystemPromptBuilder.appGuide(appName: "Avenkin"),
            SystemPromptBuilder.onDeviceAppGuide(appName: "Avenkin"),
            LiveCameraFailureInstruction.unavailable(reason: nil),
            AgentDocumentStore.defaultSoul,
            AgentDocumentStore.defaultSkills,
            HermesAgentAPI.spokenReplyInstructions,
        ]
        prompts += LiveAIMode.builtIn.map(\.promptPrefix)
        prompts += Config.builtInPresets(device: .phone).map(\.prompt)
        for prompt in prompts {
            XCTAssertFalse(prompt.lowercased().contains("glasses"), prompt)
        }
    }

    // MARK: - Go Live

    func testGoLiveOffersOnlyThePhoneCameras() {
        XCTAssertEqual(BroadcastVideoSource.available, [.phoneBack, .phoneFront])
        XCTAssertFalse(BroadcastVideoSource.available.contains(.glasses))
    }

    func testASavedOrMissingGlassesCameraIsThePhonesBackCamera() {
        XCTAssertEqual(BroadcastVideoSource.resolved(nil), .phoneBack)
        XCTAssertEqual(BroadcastVideoSource.resolved("glasses"), .phoneBack)
        XCTAssertEqual(BroadcastVideoSource.resolved("something-new"), .phoneBack)
        XCTAssertEqual(BroadcastVideoSource.resolved("phone_front"), .phoneFront)

        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: "broadcastDefaultSource")
        defer { defaults.set(stored, forKey: "broadcastDefaultSource") }
        defaults.set("glasses", forKey: "broadcastDefaultSource")
        XCTAssertEqual(Config.broadcastDefaultSource, BroadcastVideoSource.phoneBack.rawValue)
        defaults.removeObject(forKey: "broadcastDefaultSource")
        XCTAssertEqual(Config.broadcastDefaultSource, BroadcastVideoSource.phoneBack.rawValue)
    }

    func testTheBlurRefusesEveryStreamAndSaysSoWithoutNamingGlasses() {
        let decision = BroadcastGoLive.decide(.init(
            isBroadcasting: false, isConfigured: true,
            preferredSource: BroadcastVideoSource.resolved("glasses"), glassesConnected: false,
            faceBlurOn: true, phoneCameraDenied: false, setupReachable: true))
        XCTAssertEqual(decision, .phoneCameraNotBlurred(.chosen))

        var lines = GoLiveGuide.phoneCameraNotes
        lines.append(LivePreviewPicture.phoneCaption(isBroadcasting: false, blurOn: true))
        lines.append(BroadcastGoLive.endMessage(.blurNeedsGlasses))
        lines.append(BroadcastGoLive.endMessage(.glassesGaveNoPicture))
        for route in [BroadcastGoLive.PhoneRoute.fallback, .chosen, .inset, .midStreamSwitch] {
            lines.append(BroadcastGoLive.spokenRefusal(.phoneCameraNotBlurred(route)))
            lines.append(BystanderBlurControl.refusal(route: route, changeable: true, organization: nil).message)
            lines.append(BystanderBlurControl.refusal(route: route, changeable: false, organization: "Northfield").message)
        }
        for line in lines {
            XCTAssertFalse(line.lowercased().contains("glasses"), line)
        }
    }

    // MARK: - Saved by a beta

    func testASavedGlassesMicIsThePhonesMic() {
        XCTAssertFalse(MicRoute.available.contains(.glasses))
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: "micRoute")
        defer { defaults.set(stored, forKey: "micRoute") }
        defaults.set(MicRoute.glasses.rawValue, forKey: "micRoute")
        XCTAssertEqual(Config.micRoute, .phone)
    }

    func testTheDockDropsTheGlassesControl() {
        XCTAssertFalse(DockLayout.canonical.contains(.disconnect))
        XCTAssertFalse(DockLayout.effectiveOrder(stored: ["disconnect", "model"]).contains(.disconnect))
    }
}
#endif
