import XCTest
@testable import OpenGlasses

/// Plan FY F3 — the identity line names the device in use, and never a vendor.
///
/// The shipped prompts used to open "a voice assistant on Ray-Ban Meta smart glasses" whatever the
/// device: wrong for a phone-only user, and wrong for EVEN Realities wearers. The device is now
/// composed at prompt time from signals the caller reads once per turn; a prompt the wearer wrote
/// or edited is returned byte for byte, whatever the device.
final class DeviceIdentityTests: XCTestCase {

    private let nameKey = "assistantDisplayName"
    private let personaKey = "activePersonaId"
    private let presetKey = "activePromptPresetId"
    private let presetsKey = "savedPromptPresets"
    private let legacyPromptKey = "customSystemPrompt"

    private var saved: [String: Any?] = [:]

    private var allKeys: [String] { [nameKey, personaKey, presetKey, presetsKey, legacyPromptKey] }

    override func setUp() {
        super.setUp()
        for key in allKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in allKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        saved = [:]
        super.tearDown()
    }

    /// The opening line, with the quoted wake phrase taken out: the default wake phrase is still
    /// the old product name (it moves in P3's own migration), and it is a phrase to say, not a
    /// claim about the device.
    private func firstLine(_ prompt: String) -> String {
        withoutWakePhrase(String(prompt.split(separator: "\n", maxSplits: 1,
                                              omittingEmptySubsequences: false).first ?? ""))
    }

    private func withoutWakePhrase(_ text: String) -> String {
        text.replacingOccurrences(of: "\"\(Config.wakePhrase)\"", with: "\"<wake phrase>\"")
    }

    // MARK: - The phrase

    func testThePhraseNamesTheDeviceAndNeverAVendor() {
        XCTAssertEqual(AssistantIdentity.devicePhrase(glassesConnected: true, watchOnly: false),
                       "on smart glasses")
        XCTAssertEqual(AssistantIdentity.devicePhrase(glassesConnected: false, watchOnly: true),
                       "on the user's watch")
        XCTAssertEqual(AssistantIdentity.devicePhrase(glassesConnected: false, watchOnly: false),
                       "on the user's phone")
        XCTAssertEqual(AssistantIdentity.devicePhrase(glassesConnected: true, watchOnly: true),
                       "on smart glasses", "connected glasses are the device in use")

        XCTAssertEqual(AssistantIdentity.devicePhraseZH(glassesConnected: true, watchOnly: false), "智能眼镜上")
        XCTAssertEqual(AssistantIdentity.devicePhraseZH(glassesConnected: false, watchOnly: true), "用户的手表上")
        XCTAssertEqual(AssistantIdentity.devicePhraseZH(glassesConnected: false, watchOnly: false), "用户的手机上")

        for device in AssistantIdentity.Device.allCases {
            for vendor in ["Ray-Ban", "Meta", "Oakley", "EVEN", "G2"] {
                XCTAssertFalse(device.phrase.contains(vendor))
                XCTAssertFalse(device.phraseZH.contains(vendor))
            }
        }
    }

    // MARK: - Phone only

    @MainActor
    func testAPhoneOnlyPromptContainsNoGlasses() {
        _ = Config.savedPresets                                   // seed the way first run does
        Config.setActivePresetId("preset-default")
        let prompt = Config.systemPrompt(device: .phone)
        XCTAssertTrue(prompt.hasPrefix("You are Avenkin, a voice assistant running on the user's phone."))
        XCTAssertFalse(withoutWakePhrase(prompt).localizedCaseInsensitiveContains("glasses"),
                       "a phone-only user is never told they are wearing anything")

        let cloud = LLMService.leanCloudPrompt(hasImage: true, device: .phone)
        XCTAssertFalse(cloud.localizedCaseInsensitiveContains("glasses"))

        for preset in Config.builtInPresets(device: .phone) {
            XCTAssertFalse(firstLine(preset.prompt).localizedCaseInsensitiveContains("glasses"),
                           "\(preset.id) opens with a glasses identity on a phone")
            XCTAssertTrue(firstLine(preset.prompt).contains("on the user's phone"), preset.id)
        }
    }

    // MARK: - Glasses

    func testAGlassesSessionSaysSmartGlassesAndNeverAVendor() {
        _ = Config.savedPresets
        Config.setActivePresetId("preset-default")
        let prompt = Config.systemPrompt(device: .glasses)
        XCTAssertTrue(prompt.hasPrefix("You are Avenkin, a voice assistant running on smart glasses."))
        XCTAssertFalse(prompt.contains("Ray-Ban"))

        for preset in Config.builtInPresets(device: .glasses) {
            XCTAssertTrue(firstLine(preset.prompt).contains("on smart glasses"), preset.id)
            XCTAssertFalse(preset.prompt.contains("Ray-Ban"), "\(preset.id) names a vendor")
        }
        for preset in Config.chineseBuiltInPresets(device: .glasses) {
            XCTAssertFalse(preset.prompt.contains("Ray-Ban"), "\(preset.id) (zh) names a vendor")
        }
    }

    // MARK: - Watch

    func testAWatchTurnSaysWatch() {
        _ = Config.savedPresets
        for id in ["preset-default", "preset-concise", "preset-museum-guide"] {
            Config.setActivePresetId(id)
            let prompt = Config.systemPrompt(device: .watch)
            XCTAssertTrue(firstLine(prompt).contains("on the user's watch"), id)
            XCTAssertFalse(firstLine(prompt).localizedCaseInsensitiveContains("glasses"), id)
        }
    }

    // MARK: - Chinese

    func testTheChineseOpeningNamesTheDevice() {
        let glasses = Config.chineseBuiltInPresets(device: .glasses)
        let phone = Config.chineseBuiltInPresets(device: .phone)
        let watch = Config.chineseBuiltInPresets(device: .watch)
        XCTAssertTrue(glasses[0].prompt.hasPrefix("你是 Avenkin，一个运行在智能眼镜上的语音助手。"))
        XCTAssertTrue(phone[0].prompt.hasPrefix("你是 Avenkin，一个运行在用户的手机上的语音助手。"))
        XCTAssertTrue(watch[0].prompt.hasPrefix("你是 Avenkin，一个运行在用户的手表上的语音助手。"))
        for preset in phone {
            XCTAssertFalse(firstLine(preset.prompt).contains("眼镜"), "\(preset.id) (zh) opens with glasses on a phone")
            XCTAssertTrue(firstLine(preset.prompt).contains("用户的手机上"), preset.id)
        }
    }

    // MARK: - The wearer's own prompt

    func testAUsersOwnPromptIsUnchangedOnEveryDevice() {
        let custom = "You are Hal, a voice assistant on Ray-Ban Meta smart glasses.\nBe brief."
        let edited = PromptPreset(id: "preset-concise", name: "Concise (mine)",
                                  prompt: "You are Hal, on my glasses.\nOne sentence.", isBuiltIn: false)
        let mine = PromptPreset(id: "user-1", name: "Mine", prompt: custom, isBuiltIn: false)
        Config.setSavedPresets(Config.savedPresets.filter { $0.id != edited.id } + [edited, mine])
        let stored = UserDefaults.standard.data(forKey: presetsKey)

        for device in AssistantIdentity.Device.allCases {
            Config.setActivePresetId("user-1")
            XCTAssertEqual(Array(Config.systemPrompt(device: device).utf8), Array(custom.utf8))
            Config.setActivePresetId(edited.id)
            XCTAssertEqual(Array(Config.systemPrompt(device: device).utf8), Array(edited.prompt.utf8))
        }
        XCTAssertEqual(UserDefaults.standard.data(forKey: presetsKey), stored,
                       "composing for a device never writes storage")
    }

    func testTheLegacyCustomPromptKeyIsUnchangedOnEveryDevice() {
        let custom = "You are Hal on smart glasses. Be brief."
        UserDefaults.standard.set(custom, forKey: legacyPromptKey)
        UserDefaults.standard.set("no-such-preset", forKey: presetKey)
        for device in AssistantIdentity.Device.allCases {
            XCTAssertEqual(Config.systemPrompt(device: device), custom)
        }
    }

    // MARK: - Stored shipped text

    /// An existing install seeded its Default preset with the pre-F3 text, whose body said the
    /// user wears smart glasses. That stored copy is still shipped text nobody edited, so it is
    /// recomposed for the device in use rather than frozen on the old identity — and storage is
    /// left exactly as it was.
    func testAnEarlierBuildsStoredDefaultIsRecomposedForTheDevice() {
        let shipped = Config.builtInPresets(device: .phone)[0]
        XCTAssertEqual(shipped.id, "preset-default")
        var legacyLines = shipped.prompt.components(separatedBy: "\n")
        legacyLines[0] = "You are OpenGlasses, a voice assistant running on Ray-Ban Meta smart glasses. "
            + "Your responses will be spoken aloud via text-to-speech. Your name is OpenGlasses and "
            + "the user activates you by saying \"\(Config.wakePhrase)\"."
        let legacyText = legacyLines.joined(separator: "\n")
            .replacingOccurrences(of: AssistantIdentity.contextLine(device: .phone),
                                  with: AssistantIdentity.legacyContextLine)
            .replacingOccurrences(of: Config.cameraSentence, with: "The glasses have a camera.")
        XCTAssertTrue(legacyText.contains("The user is wearing smart glasses"))

        var legacy = shipped
        legacy.prompt = legacyText
        Config.setSavedPresets([legacy])
        Config.setActivePresetId("preset-default")
        let stored = UserDefaults.standard.data(forKey: presetsKey)

        XCTAssertEqual(Config.systemPrompt(device: .phone), Config.defaultSystemPrompt(device: .phone))
        XCTAssertEqual(Config.systemPrompt(device: .glasses), Config.defaultSystemPrompt(device: .glasses))
        XCTAssertFalse(Config.systemPrompt(device: .glasses).contains("Ray-Ban"))
        XCTAssertEqual(UserDefaults.standard.data(forKey: presetsKey), stored)
    }

    /// A shipped preset stored while one device was in use (the presets list saves what it shows)
    /// follows the device of the turn, not the one it happened to be stored under.
    func testAStoredBuiltInFollowsTheDeviceOfTheTurn() {
        Config.setSavedPresets(Config.builtInPresets(device: .glasses))
        for id in ["preset-default", "preset-tokens", "preset-navigation", "preset-ultra-concise",
                   "preset-golf-caddy"] {
            Config.setActivePresetId(id)
            XCTAssertTrue(firstLine(Config.systemPrompt(device: .phone)).contains("on the user's phone"), id)
            XCTAssertTrue(firstLine(Config.systemPrompt(device: .glasses)).contains("on smart glasses"), id)
        }
    }

    // MARK: - Plan FY P2: the preset bodies and the agent documents

    /// F3 made the opening line name the device; P2 carries it through the bodies. The camera may
    /// be the phone's, so no shipped preset, the on-device photo prompt or the image note says it
    /// is the glasses'.
    @MainActor
    func testNoShippedPresetBodyAssumesGlassesOnAPhone() {
        for preset in Config.builtInPresets(device: .phone) {
            XCTAssertFalse(withoutWakePhrase(preset.prompt).localizedCaseInsensitiveContains("glasses"),
                           "\(preset.id) mentions glasses on a phone")
        }
        for preset in Config.chineseBuiltInPresets(device: .phone) {
            XCTAssertFalse(preset.prompt.contains("眼镜"), "\(preset.id) (zh) mentions glasses on a phone")
        }
        XCTAssertFalse(Config.compactVisionTurnPrompt(from: "You are Avenkin.", languageCode: "en")
            .localizedCaseInsensitiveContains("glasses"))
    }

    /// A built-in seeded by an earlier build still carries the old camera line. It is shipped text
    /// nobody edited, so it follows the new wording — and storage is left as it was.
    func testAPresetStoredWithThePreP2CameraLineIsStillRecognisedAsShipped() throws {
        let shipped = try XCTUnwrap(Config.builtInPresets(device: .phone).first { $0.id == "preset-concise" })
        var legacy = shipped
        legacy.prompt = shipped.prompt.replacingOccurrences(
            of: "You CAN see images from the camera when provided.",
            with: "You CAN see images from the glasses camera when provided.")
        XCTAssertNotEqual(legacy.prompt, shipped.prompt, "the concise preset carries the camera line")

        Config.setSavedPresets([legacy])
        Config.setActivePresetId("preset-concise")
        let stored = UserDefaults.standard.data(forKey: presetsKey)

        XCTAssertEqual(Config.systemPrompt(device: .phone), shipped.prompt)
        XCTAssertEqual(UserDefaults.standard.data(forKey: presetsKey), stored)
    }

    func testTheLegacyCameraLinesFoldOntoTodaysWording() {
        for line in Config.legacyCameraLines {
            XCTAssertNotEqual(line.legacy, line.current)
            XCTAssertFalse(line.current.localizedCaseInsensitiveContains("glasses"))
            XCTAssertFalse(line.current.contains("眼镜"))
        }
    }

    /// Agent mode's documents are written once on first use and then belong to the user; the
    /// template a new one starts from no longer says the agent lives on one vendor's glasses.
    func testTheAgentDocumentTemplatesDoNotAssumeGlasses() {
        let soul = AgentDocumentStore.defaultSoul
        XCTAssertFalse(soul.contains("Ray-Ban"))
        XCTAssertFalse(soul.contains("lives on"))
        XCTAssertTrue(soul.contains("their phone, their watch, or their smart glasses"))
        XCTAssertFalse(soul.contains("when glasses are off"))
    }
}
