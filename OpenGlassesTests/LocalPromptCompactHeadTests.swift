import XCTest
@testable import OpenGlasses

/// Plan MQ P1 — a downloaded model's prompt is built with the short forms the Apple on-device path
/// already uses (the persona's short form, the on-device app guide and safety policy, one camera
/// line on a turn with no photo), so a 4,096-token window has room for an open job, the turn's
/// tools and three exchanges (`FieldAssistContextAuditTests`). Cloud prompts keep the long forms
/// byte for byte.
@MainActor
final class LocalPromptCompactHeadTests: XCTestCase {

    private let keys = ["activePromptPresetId", "savedPromptPresets", "customSystemPrompt", "ttsEnginePreference"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(TTSEnginePreference.system.rawValue, forKey: "ttsEnginePreference")
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    private func lean(hasImage: Bool = false) async -> String {
        await LLMService.leanOnDevicePrompt(locationContext: "Auckland", memoryContext: nil,
                                            hasImage: hasImage, turn: "hello")
    }

    // MARK: - Cloud unchanged

    /// The cloud head is exactly the long persona, the long app guide, the long spoken manners and
    /// the long safety policy — byte for byte, nothing of the local trim in it.
    func testTheCloudHeadIsTheLongFormsByteForByte() async {
        let layout = await LLMService.promptLayoutForTesting(includeTools: false, offersFollowUps: false)
        let replyLanguage = ReplyLanguagePolicy.clause(for: ReplyLanguagePolicy.directModeVoice())
        let expected = Config.systemPrompt(device: .phone)
            + "\n\n" + SystemPromptBuilder.appGuide(appName: RegistrationFlow.appName)
            + "\n\n" + SystemPromptBuilder.spokenManners(replyLanguage: replyLanguage)
            + PromptInjectionPolicy.systemPromptPolicy
        XCTAssertEqual(Array(layout.stable.utf8), Array(expected.utf8))
        XCTAssertFalse(layout.combined.contains(PromptInjectionPolicy.onDeviceSystemPromptPolicy))
        XCTAssertFalse(layout.combined.contains(SystemPromptBuilder.onDeviceCameraLine))
    }

    func testTheApplePromptIsItsOwnBuilderUnchanged() {
        let prompt = LLMService.appleOnDevicePrompt(locationContext: "Auckland", memoryContext: nil)
        XCTAssertTrue(prompt.contains(PromptInjectionPolicy.onDeviceSystemPromptPolicy))
        XCTAssertTrue(prompt.contains(SystemPromptBuilder.onDeviceAppGuide(appName: RegistrationFlow.appName)))
        XCTAssertFalse(prompt.contains(SystemPromptBuilder.onDeviceCameraLine), "the Apple model never sees a photo")
        XCTAssertFalse(prompt.contains(Config.onDeviceDefaultSystemPrompt(device: .phone)),
                       "the Apple path condenses the long persona itself")
        XCTAssertLessThanOrEqual(prompt.count, AppleOnDeviceInstructions.characterBudget)
    }

    // MARK: - The local prompt

    func testTheLocalPromptCarriesTheShortFormsAndKeepsEverySafetyLine() async {
        let prompt = await lean()
        XCTAssertTrue(prompt.hasPrefix(Config.onDeviceDefaultSystemPrompt(device: .phone)),
                      "the shipped persona in its short form")
        XCTAssertTrue(prompt.contains(SystemPromptBuilder.onDeviceAppGuide(appName: RegistrationFlow.appName)))
        XCTAssertFalse(prompt.contains(SystemPromptBuilder.appGuide(appName: RegistrationFlow.appName)))
        XCTAssertTrue(prompt.contains(PromptInjectionPolicy.onDeviceSystemPromptPolicy))
        XCTAssertFalse(prompt.contains(PromptInjectionPolicy.systemPromptPolicy))
        XCTAssertTrue(prompt.contains(SystemPromptBuilder.onDeviceCameraLine))
        XCTAssertFalse(prompt.contains("VISION & CAMERA:"), "no photo, so one camera line")
        XCTAssertTrue(prompt.contains("Never address \(Config.assistantName)"), "the speaker line stays")
        XCTAssertTrue(prompt.contains("USER LOCATION: Auckland"))
        XCTAssertTrue(prompt.contains("CURRENT DATE & TIME"))
        // The local trim takes words, not rules.
        for rule in ["say plainly that you are an AI assistant", "Never claim or imply to be a person",
                     "Confirm first", "Always confirm anything involving money", "Never share the camera feed",
                     "Speech recognition may mishear", "No markdown"] {
            XCTAssertTrue(prompt.contains(rule), rule)
        }
        XCTAssertLessThan(prompt.count, 6_000, "the head a downloaded model reads before the job and its tools")
    }

    func testAPhotoTurnCarriesTheFullCameraRules() async {
        let prompt = await lean(hasImage: true)
        XCTAssertTrue(prompt.contains(Config.visionAndCameraRules))
        XCTAssertTrue(prompt.contains("VISION INPUT:"))
        XCTAssertFalse(prompt.contains(SystemPromptBuilder.onDeviceCameraLine))
    }

    func testAPromptTheWearerWroteIsSentAsWritten() async {
        let mine = "You are Nova, a terse helper. Be brief."
        Config.setSavedPresets([PromptPreset(id: "custom-test", name: "Mine", prompt: mine, isBuiltIn: false)])
        Config.setActivePresetId("custom-test")
        XCTAssertEqual(Config.onDeviceSystemPrompt(device: .phone), mine)
        let prompt = await lean()
        XCTAssertTrue(prompt.hasPrefix(mine))
        XCTAssertFalse(prompt.contains("STYLE: Short, natural spoken answers"))
    }

    func testTheShortPersonaKeepsTheIdentityOpening() {
        for device in [AssistantIdentity.Device.phone, .glasses] {
            let short = Config.onDeviceDefaultSystemPrompt(device: device)
            let opening = AssistantIdentity.defaultPromptOpening(name: Config.assistantName,
                                                                 wakePhrase: Config.wakePhrase, device: device)
            XCTAssertTrue(short.hasPrefix(opening))
            XCTAssertTrue(short.contains(AssistantIdentity.contextLine(device: device)))
            XCTAssertLessThan(short.count, Config.defaultSystemPrompt(device: device).count / 2)
            XCTAssertFalse(short.contains("Plan "), "no plan letters in model-facing text")
        }
    }
}
