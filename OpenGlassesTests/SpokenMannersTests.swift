import XCTest
@testable import OpenGlasses

/// Plan LO P0 + P1 — how a spoken reply is shaped: the fixed block beside the app guide on every
/// route (a preset the user wrote included), its two-line on-device form within the window, the
/// reply-language line that follows the voice, arithmetic routed to the tools, the camera in the
/// user's words, and no shipped prompt ending on an offer.
@MainActor
final class SpokenMannersTests: XCTestCase {

    private let keys = ["activePromptPresetId", "savedPromptPresets", "customSystemPrompt", "ttsEnginePreference"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The iOS voice: every language, so the line is the plain "answer in their language".
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

    private var fullBlock: String { SystemPromptBuilder.spokenManners(replyLanguage: .followUser) }
    private var shortBlock: String { SystemPromptBuilder.onDeviceSpokenManners(replyLanguage: .followUser) }

    private func useCustomPreset(_ prompt: String = "You are Nova, a terse helper. Be brief.") {
        Config.setSavedPresets([PromptPreset(id: "custom-test", name: "Mine", prompt: prompt, isBuiltIn: false)])
        Config.setActivePresetId("custom-test")
    }

    // MARK: - The block

    func testTheBlockSaysEachMannerOnce() {
        let block = fullBlock
        XCTAssertTrue(block.hasPrefix("SPOKEN REPLIES:"))
        for rule in ["End on the answer", "FOLLOW-UPS tail", "never in what you say", "never say \"as I said\"",
                     "a short question gets a short answer", "acknowledge it; don't try to fix it",
                     "Answer in the language the user spoke", "say why once", "allow that you could be mistaken",
                     "don't argue the point twice", "answer the likeliest meaning",
                     "Before sending a message, making a call or controlling the home"] {
            XCTAssertEqual(block.components(separatedBy: rule).count - 1, 1, "\(rule) in \(block)")
        }
        XCTAssertEqual(block.components(separatedBy: "\n").count, 8, "a heading, a lead-in and six rules")
        XCTAssertFalse(block.contains("Plan "), "no plan letters in model-facing text")
    }

    func testTheShortFormIsTwoLinesAndSmall() {
        let short = shortBlock
        XCTAssertEqual(short.components(separatedBy: "\n").count, 2)
        XCTAssertLessThanOrEqual(short.count, 420)
        XCTAssertLessThan(short.count, fullBlock.count / 2)
        for rule in ["End on the answer", "\"as I said\"", "Answer in the language the user spoke",
                     "say why once", "home control"] {
            XCTAssertTrue(short.contains(rule), rule)
        }
    }

    // MARK: - Direct mode

    func testTheDirectPromptCarriesTheBlockInTheStableHead() async {
        let layout = await LLMService.promptLayoutForTesting(locationContext: "Wellington")
        XCTAssertTrue(layout.stable.contains(fullBlock))
        XCTAssertFalse(layout.volatile.contains("SPOKEN REPLIES"))
        let guide = layout.stable.range(of: "THIS APP:")
        let manners = layout.stable.range(of: fullBlock)
        XCTAssertNotNil(guide)
        XCTAssertLessThan(guide!.lowerBound, manners!.lowerBound, "beside the app guide, after it")
    }

    func testAPresetTheUserWroteCarriesTheBlockToo() async {
        useCustomPreset()
        XCTAssertEqual(Config.systemPrompt(device: .phone), "You are Nova, a terse helper. Be brief.")
        let layout = await LLMService.promptLayoutForTesting()
        XCTAssertTrue(layout.stable.hasPrefix("You are Nova, a terse helper. Be brief."), "the user's words untouched")
        XCTAssertTrue(layout.stable.contains(fullBlock))
    }

    func testTheHeadIsByteIdenticalAcrossTwoTurns() async {
        let first = await LLMService.promptLayoutForTesting(
            locationContext: "Wellington", memoryContext: "partner = Alex", hasImage: false,
            turn: "how does a heat pump defrost")
        let second = await LLMService.promptLayoutForTesting(
            locationContext: "Petone", memoryContext: "partner = Alex; likes tea", hasImage: true,
            turn: "how does a heat pump defrost")
        XCTAssertEqual(Array(first.stable.utf8), Array(second.stable.utf8))
        XCTAssertTrue(first.stable.contains("SPOKEN REPLIES:"))
    }

    func testTheHeadMovesOnlyWhenTheVoiceSettingDoes() async {
        let before = await LLMService.promptLayoutForTesting()
        let again = await LLMService.promptLayoutForTesting()
        XCTAssertEqual(before.stable, again.stable)
        // Kokoro without its model falls back to the iOS voice, so the line is the same.
        UserDefaults.standard.set(TTSEnginePreference.kokoro.rawValue, forKey: "ttsEnginePreference")
        let expected = ReplyLanguagePolicy.clause(for: ReplyLanguagePolicy.directModeVoice())
        let kokoro = await LLMService.promptLayoutForTesting()
        XCTAssertTrue(kokoro.stable.contains(SystemPromptBuilder.spokenManners(replyLanguage: expected)))
    }

    // MARK: - On device

    func testTheLeanOnDevicePromptCarriesTheShortForm() async {
        let prompt = await LLMService.leanOnDevicePrompt(locationContext: nil, memoryContext: nil,
                                                         hasImage: false, turn: "hello")
        XCTAssertTrue(prompt.contains(shortBlock))
        XCTAssertFalse(prompt.contains(fullBlock))
    }

    func testTheAppleOnDevicePromptCarriesTheShortFormWithinItsBudget() {
        let prompt = LLMService.appleOnDevicePrompt(locationContext: "Christchurch",
                                                    memoryContext: String(repeating: "prefers metric; ", count: 60))
        XCTAssertTrue(prompt.contains(shortBlock))
        XCTAssertLessThanOrEqual(prompt.count, AppleOnDeviceInstructions.characterBudget)

        useCustomPreset(String(repeating: "Always answer in a calm and friendly tone. ", count: 200))
        let custom = LLMService.appleOnDevicePrompt(locationContext: "Christchurch", memoryContext: nil)
        XCTAssertTrue(custom.contains(shortBlock), "a long preset the user wrote is condensed, the manners kept")
        XCTAssertLessThanOrEqual(custom.count, AppleOnDeviceInstructions.characterBudget)
    }

    func testTheBudgetHoldsWithEverythingSwitchedOn() {
        let built = AppleOnDeviceInstructions.build(.init(
            persona: Config.defaultSystemPrompt(device: .glasses),
            appGuide: SystemPromptBuilder.onDeviceAppGuide(appName: "OpenGlasses"),
            spokenManners: shortBlock,
            safetyPolicy: PromptInjectionPolicy.onDeviceSystemPromptPolicy,
            dateTime: "Monday, 20 October 2026, 9:14 AM (Pacific/Auckland)",
            location: String(repeating: "Christchurch ", count: 40),
            memory: String(repeating: "prefers metric units; ", count: 60),
            weather: String(repeating: "light rain; ", count: 40),
            job: .init(reference: "JOB-1", unit: "SLP99UH070", openTasks: ["check the flame sensor"],
                       lastReading: nil, questions: [], paused: false),
            fieldAssistActive: true, modelSettingsPath: "Settings > Intelligence",
            speakerLine: "The person speaking to you is the user."))
        XCTAssertLessThanOrEqual(built.text.count, AppleOnDeviceInstructions.characterBudget)
        XCTAssertTrue(built.text.contains(shortBlock))
        XCTAssertTrue(built.blocks.map(\.name).contains("spoken manners (on-device)"))
        XCTAssertEqual(built.blocks.reduce(0) { $0 + $1.characters }, built.text.count)
    }

    func testTheCondensedCloudPromptCarriesTheShortForm() {
        let condensed = LLMService.condensedCloudPrompt(locationContext: nil, memoryContext: nil, hasImage: false,
                                                        toolGuide: "TOOL DEFINITIONS ON DEMAND:")
        XCTAssertTrue(condensed.text.contains(shortBlock))
    }

    // MARK: - Realtime

    func testTheLiveInstructionCarriesTheBlockWithTheUsersLanguage() {
        let manager = RealtimeSessionManager()
        let instruction = manager.systemInstructionForTesting()
        XCTAssertTrue(instruction.contains(fullBlock), "a live voice speaks any language")

        useCustomPreset()
        let custom = RealtimeSessionManager().systemInstructionForTesting()
        XCTAssertTrue(custom.contains("You are Nova, a terse helper."))
        XCTAssertTrue(custom.contains(fullBlock))
    }

    func testTheLiveVisionBlockSpeaksOfWhatTheyAreLookingAt() {
        let manager = RealtimeSessionManager()
        manager.isCameraStreaming = true
        let instruction = manager.systemInstructionForTesting()
        XCTAssertTrue(instruction.contains(SystemPromptBuilder.visionWordingLine))
        XCTAssertTrue(instruction.contains(SystemPromptBuilder.visionAmbiguityLine))
        XCTAssertFalse(instruction.contains("describe what you observe"))
    }

    // MARK: - Arithmetic goes to a tool

    func testTheArithmeticRuleOnlyWithTheToolsItNames() {
        XCTAssertFalse(SystemPromptBuilder.routingRules(toolNames: ["get_weather"]).contains("in your head"))

        let both = SystemPromptBuilder.routingRules(toolNames: ["calculate", "convert_units"])
        XCTAssertTrue(both.contains("decimals, percentages or more than two numbers goes through calculate"))
        XCTAssertTrue(both.contains("every unit conversion goes through convert_units"))
        XCTAssertTrue(both.contains("Say the result, not the working."))
        XCTAssertFalse(both.contains("domain_calc"))
        XCTAssertFalse(both.contains("\n"), "one bullet")

        let calcOnly = SystemPromptBuilder.routingRules(toolNames: ["calculate"])
        XCTAssertTrue(calcOnly.contains("calculate"))
        XCTAssertFalse(calcOnly.contains("convert_units"))

        let convertOnly = SystemPromptBuilder.routingRules(toolNames: ["convert_units"])
        XCTAssertTrue(convertOnly.contains("convert_units"))
        XCTAssertFalse(convertOnly.contains("goes through calculate"))

        let trade = SystemPromptBuilder.routingRules(toolNames: ["calculate", "domain_calc"])
        XCTAssertTrue(trade.contains("A trade calculation domain_calc covers still goes to domain_calc."))
    }

    func testTheDirectPromptRoutesArithmeticWhenCalculateIsOffered() async {
        let layout = await LLMService.promptLayoutForTesting(nativeToolNames: ["get_weather", "calculate"])
        XCTAssertTrue(layout.stable.contains("MANDATORY ROUTING:"))
        XCTAssertTrue(layout.stable.contains("goes through calculate"))
        let without = await LLMService.promptLayoutForTesting(nativeToolNames: ["get_weather"])
        XCTAssertFalse(without.stable.contains("goes through calculate"))
    }

    // MARK: - The reply language follows the voice

    func testEachVoiceSpeaksWhatItCan() {
        XCTAssertEqual(ReplyLanguagePolicy.languages(of: .liveModel), .any)
        for engine in [TTSEngine.system, .openAI, .xai, .gemini, .elevenLabs] {
            XCTAssertEqual(ReplyLanguagePolicy.languages(of: .engine(engine)), .any, engine.rawValue)
        }
        XCTAssertEqual(ReplyLanguagePolicy.languages(of: .engine(.kokoro)), .only(["en", "zh"]))
        XCTAssertEqual(KokoroModelBundle.active.spokenLanguages, ["en", "zh"], "read from the bundle's lexicons")
        XCTAssertEqual(ReplyLanguagePolicy.languages(of: .engine(.elevenLabs), elevenLabsModel: "eleven_monolingual_v1"),
                       .only(["en"]), "an English-only model limits the voice")
        XCTAssertEqual(TextToSpeechService.elevenLabsModelID, "eleven_flash_v2_5")
    }

    func testTheClausePerVoiceAndAppLanguage() {
        XCTAssertEqual(ReplyLanguagePolicy.clause(for: .engine(.system), appLanguageCode: "en"), .followUser)
        XCTAssertEqual(ReplyLanguagePolicy.clause(for: .liveModel, appLanguageCode: "de"), .followUser)
        XCTAssertEqual(ReplyLanguagePolicy.clause(for: .engine(.kokoro), appLanguageCode: "en"),
                       .limited(speaks: ["en", "zh"], fallback: "en"))
        XCTAssertEqual(ReplyLanguagePolicy.clause(for: .engine(.kokoro), appLanguageCode: "zh"),
                       .limited(speaks: ["en", "zh"], fallback: "zh"))
        XCTAssertEqual(ReplyLanguagePolicy.clause(for: .engine(.kokoro), appLanguageCode: "es"),
                       .limited(speaks: ["en", "zh"], fallback: "en"), "an app language the voice can't say falls back to its first")

        XCTAssertEqual(ReplyLanguagePolicy.text(.followUser),
                       "Answer in the language the user spoke, unless they ask for another.")
        XCTAssertEqual(ReplyLanguagePolicy.text(.limited(speaks: ["en", "zh"], fallback: "en")),
                       "Your voice speaks only English and Chinese: answer in the language the user spoke when it is "
                       + "one of those, otherwise in English, quoting their original words where it helps.")
        XCTAssertEqual(ReplyLanguagePolicy.text(.limited(speaks: ["en"], fallback: "en")),
                       "Your voice speaks only English: answer in English whatever language the user spoke, quoting "
                       + "their original words where it helps.")
        XCTAssertEqual(ReplyLanguagePolicy.shortText(.limited(speaks: ["en", "zh"], fallback: "en")),
                       "Answer in the user's language if it is English or Chinese, else in English.")
        let limited = SystemPromptBuilder.spokenManners(replyLanguage: .limited(speaks: ["en"], fallback: "en"))
        XCTAssertFalse(limited.contains("Answer in the language the user spoke"))
        XCTAssertTrue(limited.contains("quoting their original words"))
    }

    func testTheExpectedVoiceComesFromTheSettingsAlone() {
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .system, configuredCloudVoices: [.elevenLabs],
                                                          kokoroReady: true), .system)
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .gemini, configuredCloudVoices: [],
                                                          kokoroReady: true), .gemini, "the chosen voice")
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .kokoro, configuredCloudVoices: [],
                                                          kokoroReady: false), .system, "no model, the iOS voice")
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .kokoro, configuredCloudVoices: [],
                                                          kokoroReady: true), .kokoro)
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .auto, configuredCloudVoices: [.gemini, .openAI],
                                                          kokoroReady: true), .openAI, "Auto's own order")
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .auto, configuredCloudVoices: [],
                                                          kokoroReady: true), .kokoro)
        XCTAssertEqual(ReplyLanguagePolicy.expectedEngine(preference: .auto, configuredCloudVoices: [],
                                                          kokoroReady: false), .system)
    }

    // MARK: - The shipped prompts lose their offers (P1)

    private var shippedPrompts: [(String, String)] {
        var prompts: [(String, String)] = []
        for device in AssistantIdentity.Device.allCases {
            prompts.append(("default \(device)", Config.defaultSystemPrompt(device: device)))
            prompts += Config.builtInPresets(device: device).map { ("preset \($0.id) \(device)", $0.prompt) }
            prompts += Config.chineseBuiltInPresets(device: device).map { ("zh preset \($0.id) \(device)", $0.prompt) }
        }
        prompts += LiveAIMode.builtIn.map { ("live mode \($0.id)", $0.promptPrefix) }
        prompts.append(("agent soul", AgentDocumentStore.defaultSoul))
        prompts.append(("camera rules", Config.visionAndCameraRules))
        return prompts
    }

    func testNoShippedPromptEndsOnAnOffer() async {
        for (name, prompt) in shippedPrompts {
            let lower = prompt.lowercased()
            XCTAssertFalse(lower.contains("want me to"), name)
            XCTAssertFalse(lower.contains("offer to"), name)
            XCTAssertFalse(prompt.contains("要我详细说说吗"), name)
        }
        // A preset the user wrote that never mentions the camera gets the camera rules re-added —
        // without the offer they used to carry.
        useCustomPreset("You are Nova. Be brief.")
        let layout = await LLMService.promptLayoutForTesting(hasImage: true)
        XCTAssertTrue(layout.combined.contains("VISION & CAMERA:\n" + Config.visionAndCameraRules))
        XCTAssertFalse(layout.combined.lowercased().contains("offer to"))
        XCTAssertFalse(layout.combined.lowercased().contains("want me to"))
    }

    func testBrevityStopsAtANaturalBreak() {
        let prompt = Config.defaultSystemPrompt(device: .glasses)
        XCTAssertTrue(prompt.contains("Complex topics: 4–6 sentences; stop at a natural break."))
        XCTAssertFalse(prompt.contains("break the topic into parts"))
    }

    // MARK: - The camera in the user's words (P1)

    func testEveryVisionBlockSpeaksOfWhatTheyAreLookingAt() async {
        let rules = Config.visionAndCameraRules
        XCTAssertTrue(Config.defaultSystemPrompt(device: .glasses).contains(rules))
        XCTAssertTrue(rules.contains("You CAN see"), "the realtime log still reads it")
        XCTAssertTrue(rules.contains(SystemPromptBuilder.visionWordingLine))
        XCTAssertTrue(rules.contains(SystemPromptBuilder.visionAmbiguityLine))
        XCTAssertFalse(rules.contains("You CAN see images"))

        let layout = await LLMService.promptLayoutForTesting(hasImage: true)
        XCTAssertTrue(layout.volatile.contains("VISION INPUT:"))
        XCTAssertTrue(layout.volatile.contains("of what they are looking at"))
        XCTAssertTrue(layout.volatile.contains(SystemPromptBuilder.visionAmbiguityLine))
        XCTAssertFalse(layout.volatile.contains("analyze that image"))
        XCTAssertFalse(layout.volatile.contains("visible in the image"))
    }

    // MARK: - The follow-up tail still parses (P1)

    func testAReplyUnderTheNewPromptStillYieldsItsFollowUps() async {
        let layout = await LLMService.promptLayoutForTesting(offersFollowUps: true)
        // The block's follow-up rule names the same tail the clause asks for.
        XCTAssertTrue(FollowUpPrompt.clause.hasPrefix("FOLLOW-UPS:"))
        XCTAssertTrue(layout.stable.contains("FOLLOW-UPS tail"))

        let reply = "A heat pump defrosts by running the cycle backwards for a few minutes, warming the outdoor coil "
            + "until the ice melts.\n\(FollowUpTail.openTag)How long does it take?|Does it waste energy?\(FollowUpTail.closeTag)"
        let tail = FollowUpTail.parse(reply)
        XCTAssertTrue(tail.removedTail)
        XCTAssertEqual(tail.followUps, ["How long does it take?", "Does it waste energy?"])
        XCTAssertTrue(tail.answer.hasSuffix("until the ice melts."), "the spoken answer ends on its last fact")
        XCTAssertFalse(tail.answer.contains("?"))
    }
}
