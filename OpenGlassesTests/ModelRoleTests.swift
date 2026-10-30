import XCTest
@testable import OpenGlasses

/// Plan KA P1 — roles: which jobs a key offers, each role's candidates and defaults, the photo-turn
/// order with and without a Vision model, the medical and organisation limits, and the "this key
/// can also…" card. Pure: every input is built here, nothing reads the Keychain or `UserDefaults`.
/// Ids are invented where a real one isn't needed.
final class ModelRoleTests: XCTestCase {

    // MARK: - Fixtures

    private func model(_ id: String, _ provider: LLMProvider, model: String = "m", key: String = "k",
                       baseURL: String = "", vision: Bool? = nil) -> ModelConfig {
        ModelConfig(id: id, name: id, provider: provider.rawValue, apiKey: key, model: model,
                    baseURL: baseURL, supportsVision: vision)
    }

    private func listed(_ ids: [(String, ModelKind)]) -> [ModelFetcher.RemoteModel] {
        ids.map { ModelFetcher.RemoteModel(id: $0.0, name: $0.0, kind: $0.1) }
    }

    private let gemini = ModelConfig(id: "gem", name: "Gemini", provider: LLMProvider.gemini.rawValue,
                                     apiKey: "gem-key", model: "gemini-3.5-flash-lite", baseURL: "")
    private let openAI = ModelConfig(id: "oai", name: "OpenAI", provider: LLMProvider.openai.rawValue,
                                     apiKey: "sk-test", model: "gpt-4o", baseURL: "")
    private let chatGPT = ModelConfig(id: "cgpt", name: "ChatGPT", provider: LLMProvider.chatgpt.rawValue,
                                      apiKey: "", model: "gpt-5-codex", baseURL: "")
    private let claude = ModelConfig(id: "claude", name: "Claude", provider: LLMProvider.anthropic.rawValue,
                                     apiKey: "sk-ant-test", model: "claude-sonnet-5", baseURL: "")

    private func choices(_ role: ModelRole, _ inputs: ModelRoleInputs) -> [ModelRoleOption.Choice] {
        ModelRoleCatalog.options(for: role, inputs: inputs).map(\.choice)
    }

    // MARK: - The role list

    func testSettingsShowsFiveRolesAndNeverImages() {
        XCTAssertEqual(ModelRole.shown, [.assistant, .vision, .voice, .live, .dictation])
        XCTAssertFalse(ModelRole.shown.contains(.images), "Images waits for its tool (Design 12)")
        XCTAssertEqual(ModelRole.voice.kind, .speech)
        XCTAssertEqual(ModelRole.live.kind, .realtime)
        XCTAssertEqual(ModelRole.dictation.kind, .transcription)
        XCTAssertEqual(ModelRole.vision.kind, .chat)
    }

    // MARK: - Roles a key offers

    func testAGeminiKeyOffersVoiceAndLiveButNotDictation() {
        let roles = ModelRoleCatalog.roles(offeredBy: gemini)
        XCTAssertEqual(roles, [.assistant, .vision, .voice, .live])
    }

    func testAnOpenAIKeyOffersEveryShownRole() {
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: openAI), [.assistant, .vision, .voice, .live, .dictation])
    }

    func testAnXAIKeyOffersVoiceButNoLiveTransport() {
        let xai = model("x", .xai, model: "grok-4.7")
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: xai), [.assistant, .vision, .voice])
    }

    func testAnAnthropicOrGroqKeyIsChatAndVisionOnly() {
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: claude), [.assistant, .vision])
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: model("g", .groq)), [.assistant, .vision],
                       "Groq's preview image model; the app has no Groq voice, live or dictation")
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: model("g", .groq, key: "")), [.assistant],
                       "a text Groq model with no key offers nothing more")
    }

    func testTheChatGPTSubscriptionOffersNoVisionRole() {
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: chatGPT), [.assistant])
        var claimed = chatGPT
        claimed.supportsVision = true
        XCTAssertFalse(ModelRoleCatalog.roles(offeredBy: claimed).contains(.vision),
                       "image input on that backend was never confirmed, whatever the override says")
    }

    func testAKeyOnAnotherServerNeverCountsForVoiceLiveOrDictation() {
        let proxied = model("p", .openai, key: "sk-proxy", baseURL: "https://proxy.example.com/v1/chat/completions")
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: proxied), [.assistant, .vision])
        let keyless = model("k", .gemini, key: "")
        XCTAssertFalse(ModelRoleCatalog.roles(offeredBy: keyless).contains(.voice))
    }

    func testALoadedListWithoutAKindRemovesThatRole() {
        let chatOnly = listed([("gemini-3.8-flash", .chat), ("gemini-3.8-flash-tts", .speech)])
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: gemini, listed: chatOnly),
                       [.assistant, .vision, .voice], "no Live model in the list, so no Live")
        let full = listed([("gpt-4o", .chat), ("gpt-realtime-2.1-mini", .realtime)])
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: openAI, listed: full), [.assistant, .vision, .live])
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: openAI, listed: []),
                       ModelRoleCatalog.roles(offeredBy: openAI), "no list loaded: the provider decides")
    }

    func testImagesIsNeverOfferedByAnyKey() {
        let imageList = listed([("gpt-image-1", .image), ("gpt-4o", .chat)])
        for config in [gemini, openAI, claude, model("x", .xai)] {
            XCTAssertFalse(ModelRoleCatalog.roles(offeredBy: config, listed: imageList).contains(.images))
        }
    }

    // MARK: - Defaults

    func testEachProvidersDefaultPerRole() {
        XCTAssertEqual(ModelRoleDefaults.model(for: .voice, provider: .gemini), "gemini-3.8-flash-lite-tts")
        XCTAssertEqual(ModelRoleDefaults.model(for: .voice, provider: .openai), CloudVoiceRequests.openAISpeechModel)
        XCTAssertNil(ModelRoleDefaults.model(for: .voice, provider: .xai), "xAI's voice takes no model id")
        XCTAssertEqual(ModelRoleDefaults.model(for: .live, provider: .gemini), GeminiLiveModelPolicy.offlineFallbackModel)
        XCTAssertEqual(ModelRoleDefaults.model(for: .dictation, provider: .openai), "gpt-transcribe")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .anthropic), "claude-haiku-5-5")
        XCTAssertEqual(ModelRoleDefaults.model(for: .assistant, provider: .gemini), LLMProvider.gemini.defaultModel)
        XCTAssertNil(ModelRoleDefaults.model(for: .images, provider: .openai))
        XCTAssertNil(ModelRoleDefaults.model(for: .dictation, provider: .gemini))
    }

    func testTheCheaperLiveModelIsTheDefaultFromASuggestion() {
        XCTAssertEqual(ModelRoleDefaults.model(for: .live, provider: .openai, fromSuggestion: true),
                       OpenAIRealtimeModelRetirement.mini)
        XCTAssertEqual(ModelRoleDefaults.model(for: .live, provider: .openai), OpenAIRealtimeModelRetirement.full)
    }

    func testEveryVisionDefaultSeesPhotos() {
        for provider in LLMProvider.allCases {
            guard let id = ModelRoleDefaults.model(for: .vision, provider: provider) else { continue }
            let config = model("v", provider, model: id)
            XCTAssertTrue(ModelFallbackChain.candidate(from: config).supportsVision, "\(provider) \(id)")
        }
    }

    // MARK: - Candidates

    func testVisionListsOnlyModelsThatSeePhotosPlusAutomatic() {
        let groq = model("groq", .groq)
        let inputs = ModelRoleInputs(savedModels: [chatGPT, claude, groq, Config.appleIntelligenceDefault])
        XCTAssertEqual(choices(.vision, inputs), [.visionAutomatic, .model(configId: "claude")],
                       "ChatGPT, Groq and Apple's model are text-only for photos")
    }

    func testVoiceListsCloudVoicesOnlyWithTheirCredentials() {
        let none = ModelRoleInputs(savedModels: [claude])
        XCTAssertEqual(choices(.voice, none), [.voice(.auto), .voice(.kokoro), .voice(.system)])
        let withGemini = ModelRoleInputs(savedModels: [gemini], voiceCredentials: [.gemini])
        XCTAssertEqual(choices(.voice, withGemini), [.voice(.auto), .voice(.gemini), .voice(.kokoro), .voice(.system)])
    }

    func testLiveListsSavedLiveModelsThenKeysThatCanRunLive() throws {
        let saved = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "openai", model: "gpt-realtime-2.1",
                                                             apiKey: "sk-live", id: "live1"))
        let inputs = ModelRoleInputs(savedModels: [openAI, gemini, claude], realtimeModels: [saved])
        XCTAssertEqual(choices(.live, inputs), [
            .liveModel(id: "live1"),
            .newLiveModel(providerID: "gemini", model: GeminiLiveModelPolicy.offlineFallbackModel, sourceConfigId: "gem"),
        ], "OpenAI already has a live model saved, so only Gemini's key is offered")
    }

    func testDictationListsOnPhoneRecognisersAndKeyedCloudOnes() {
        let inputs = ModelRoleInputs(savedModels: [openAI], dictationCredentials: [.openAI])
        XCTAssertEqual(choices(.dictation, inputs),
                       [.dictation(.auto), .dictation(.onDevice), .dictation(.appleSpeech), .dictation(.openAI)])
    }

    func testAssistantListsEverySavedModel() {
        let inputs = ModelRoleInputs(savedModels: [claude, chatGPT, Config.appleIntelligenceDefault])
        XCTAssertEqual(choices(.assistant, inputs).count, 3)
    }

    // MARK: - Medical local-only and organisation limits

    private var localOnly: ModelRoleRestrictions { ModelRoleRestrictions(localOnly: true, hipaa: true) }

    func testLocalOnlyTurnsOffLiveAndKeepsVoiceAndDictationOnThePhone() throws {
        let saved = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "gemini", model: "g", apiKey: "k", id: "l"))
        let inputs = ModelRoleInputs(savedModels: [gemini, Config.appleIntelligenceDefault], realtimeModels: [saved],
                                     voiceCredentials: [.gemini], dictationCredentials: [.openAI],
                                     restrictions: localOnly)
        XCTAssertEqual(ModelRoleCatalog.availability(of: .live, inputs: inputs), .offUnderLocalOnly)
        XCTAssertEqual(ModelRoleCatalog.summary(of: .live, state: .init(assistantId: "gem", liveModelId: "l"),
                                                inputs: inputs), "Off")
        XCTAssertEqual(choices(.voice, inputs), [.voice(.kokoro), .voice(.system)])
        XCTAssertEqual(choices(.dictation, inputs), [.dictation(.auto), .dictation(.onDevice), .dictation(.appleSpeech)])
        XCTAssertEqual(choices(.assistant, inputs), [.model(configId: Config.appleIntelligenceDefault.id)])
        XCTAssertEqual(ModelRoleCatalog.availability(of: .voice, inputs: inputs), .available)
    }

    func testLocalOnlyVisionIsOffWithoutAnOnPhoneModelThatSees() {
        let off = ModelRoleInputs(savedModels: [claude], restrictions: localOnly)
        XCTAssertEqual(ModelRoleCatalog.availability(of: .vision, inputs: off), .offUnderLocalOnly,
                       "Automatic alone is not a model")
        let smol = model("smol", .local, model: "mlx-community/SmolVLM2-2.2B-Instruct-mlx", key: "", vision: true)
        let on = ModelRoleInputs(savedModels: [claude, smol], restrictions: localOnly)
        XCTAssertEqual(ModelRoleCatalog.availability(of: .vision, inputs: on), .available)
        XCTAssertEqual(choices(.vision, on), [.visionAutomatic, .model(configId: "smol")])
    }

    func testHIPAAAloneKeepsDictationOnThePhoneOnly() {
        let inputs = ModelRoleInputs(savedModels: [openAI], voiceCredentials: [.openAI], dictationCredentials: [.openAI],
                                     restrictions: ModelRoleRestrictions(hipaa: true))
        XCTAssertFalse(choices(.dictation, inputs).contains(.dictation(.openAI)))
        XCTAssertTrue(choices(.voice, inputs).contains(.voice(.openAI)), "HIPAA without local-only leaves voices alone")
    }

    func testAnOrganisationPinnedRoleIsReadOnly() {
        let inputs = ModelRoleInputs(savedModels: [claude],
                                     restrictions: ModelRoleRestrictions(orgPinned: [.voice], organizationName: "Acme"))
        XCTAssertEqual(ModelRoleCatalog.availability(of: .voice, inputs: inputs), .pinned(organization: "Acme"))
        XCTAssertFalse(ModelRoleCatalog.availability(of: .voice, inputs: inputs).isEditable)
        XCTAssertTrue(ModelRoleCatalog.availability(of: .dictation, inputs: inputs).isEditable)
    }

    func testCloudDictationPinnedOffShowsAutomaticAndLeavesTheStoredChoiceAlone() {
        let inputs = ModelRoleInputs(savedModels: [openAI], dictationCredentials: [.openAI],
                                     restrictions: ModelRoleRestrictions(orgCloudOff: [.dictation]))
        XCTAssertFalse(choices(.dictation, inputs).contains(.dictation(.openAI)))
        let state = ModelRoleState(assistantId: "oai", dictation: .openAI)
        XCTAssertEqual(ModelRoleCatalog.effectiveSelection(.dictation, state: state, inputs: inputs), .dictation(.auto))
        XCTAssertEqual(ModelRoleCatalog.selected(.dictation, state: state), .dictation(.openAI))
    }

    // MARK: - Current values

    func testTheRolesAreTheExistingSettings() {
        let state = ModelRoleState(assistantId: "claude", visionModelId: nil, voice: .gemini,
                                   liveModelId: "legacy-gemini", dictation: .deepgram)
        XCTAssertEqual(ModelRoleCatalog.selected(.assistant, state: state), .model(configId: "claude"))
        XCTAssertEqual(ModelRoleCatalog.selected(.vision, state: state), .visionAutomatic)
        XCTAssertEqual(ModelRoleCatalog.selected(.voice, state: state), .voice(.gemini))
        XCTAssertEqual(ModelRoleCatalog.selected(.live, state: state), .liveModel(id: "legacy-gemini"))
        XCTAssertEqual(ModelRoleCatalog.selected(.dictation, state: state), .dictation(.deepgram))
        XCTAssertNil(ModelRoleCatalog.selected(.live, state: .init(assistantId: "claude")), "no live model saved")
    }

    func testASavedVisionChoiceReadsAsAutomaticOnceItCannotSee() {
        let groq = model("groq", .groq)
        XCTAssertEqual(ModelRoleCatalog.visionModelId(stored: "claude", saved: [claude]), "claude")
        XCTAssertNil(ModelRoleCatalog.visionModelId(stored: "gone", saved: [claude]), "deleted")
        XCTAssertNil(ModelRoleCatalog.visionModelId(stored: "groq", saved: [groq]), "a text-only Groq model")
        let groqVision = model("groqv", .groq, model: "qwen/qwen3.8-27b")
        XCTAssertEqual(ModelRoleCatalog.visionModelId(stored: "groqv", saved: [groqVision]), "groqv")
        XCTAssertNil(ModelRoleCatalog.visionModelId(stored: "cgpt", saved: [chatGPT]), "ChatGPT is text-only for photos")
        XCTAssertNil(ModelRoleCatalog.visionModelId(stored: "", saved: [claude]))
    }

    func testSummaryNamesTheChosenOption() {
        let inputs = ModelRoleInputs(savedModels: [claude, gemini], voiceCredentials: [.gemini])
        let state = ModelRoleState(assistantId: "claude", visionModelId: "gem", voice: .gemini)
        XCTAssertEqual(ModelRoleCatalog.summary(of: .assistant, state: state, inputs: inputs), "Claude")
        XCTAssertEqual(ModelRoleCatalog.summary(of: .vision, state: state, inputs: inputs), "Gemini")
        XCTAssertEqual(ModelRoleCatalog.summary(of: .voice, state: state, inputs: inputs),
                       TTSEnginePreference.gemini.displayName)
        XCTAssertEqual(ModelRoleCatalog.summary(of: .live, state: state, inputs: inputs), "Not set")
    }

    // MARK: - The photo turn

    func testWithNoVisionModelThePhotoOrderIsExactlyTodays() {
        let saved = [chatGPT, claude, gemini]
        let today = ModelFallbackChain.candidates(activeId: "cgpt", saved: saved, fallbackOrder: ["gem"],
                                                  requiresVision: true)
        let withNil = ModelFallbackChain.candidates(activeId: "cgpt", saved: saved, fallbackOrder: ["gem"],
                                                    requiresVision: true, visionModelId: nil)
        XCTAssertEqual(withNil, today)
        XCTAssertEqual(today.map(\.id), ["cgpt", "gem", "claude"])
    }

    func testTheVisionModelLeadsThePhotoTurnThenTodaysOrder() {
        let chain = ModelFallbackChain.candidates(activeId: "cgpt", saved: [chatGPT, claude, gemini],
                                                  fallbackOrder: ["gem"], requiresVision: true, visionModelId: "claude")
        XCTAssertEqual(chain.map(\.id), ["claude", "cgpt", "gem"])
        XCTAssertEqual(ModelFallbackChain.next(candidates: chain, tried: [],
                                               needs: .init(requiresVision: true, isBackgrounded: false),
                                               failure: .retryOtherModel, currentWindow: 0)?.id, "claude")
    }

    func testAVisionModelThatCannotSeeIsIgnored() {
        let chain = ModelFallbackChain.candidates(activeId: "claude", saved: [chatGPT, claude],
                                                  fallbackOrder: [], requiresVision: true, visionModelId: "cgpt")
        XCTAssertEqual(chain.map(\.id), ["claude", "cgpt"], "the ChatGPT model never leads a photo turn")
    }

    func testATextTurnIgnoresTheVisionModel() {
        let chain = ModelFallbackChain.candidates(activeId: "cgpt", saved: [chatGPT, claude],
                                                  fallbackOrder: [], requiresVision: false, visionModelId: "claude")
        XCTAssertEqual(chain.map(\.id), ["cgpt", "claude"], "the rest of the conversation stays on the assistant")
    }

    // MARK: - The key's card

    func testAGeminiKeySuggestsVoiceAndLiveWithWhereTheDataGoes() {
        let inputs = ModelRoleInputs(savedModels: [claude, gemini])
        let suggestions = ModelRoleCatalog.suggestions(for: gemini, inputs: inputs,
                                                       state: .init(assistantId: "claude"))
        XCTAssertEqual(suggestions.map(\.role), [.voice, .live], "Claude already sees photos")
        XCTAssertEqual(suggestions.first?.choice, .voice(.gemini))
        XCTAssertEqual(suggestions.last?.choice,
                       .newLiveModel(providerID: "gemini", model: GeminiLiveModelPolicy.offlineFallbackModel, sourceConfigId: "gem"))
        for suggestion in suggestions {
            XCTAssertTrue(suggestion.destination.contains("Google"), suggestion.destination)
            XCTAssertTrue(suggestion.destination.contains("quota"), "the cost is named: \(suggestion.destination)")
        }
        XCTAssertEqual(ModelRoleCatalog.cardTitle(for: gemini), "This Gemini key can also…")
    }

    func testAnOpenAIKeysLiveSuggestionIsTheCheaperModel() {
        let suggestions = ModelRoleCatalog.suggestions(for: openAI, inputs: .init(savedModels: [openAI]),
                                                       state: .init(assistantId: "oai"))
        XCTAssertEqual(suggestions.map(\.role), [.voice, .live, .dictation])
        XCTAssertEqual(suggestions.first(where: { $0.role == .live })?.choice,
                       .newLiveModel(providerID: "openai", model: OpenAIRealtimeModelRetirement.mini, sourceConfigId: "oai"))
    }

    func testARoleAlreadySetIsNotOfferedAgain() throws {
        let live = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "openai", model: "m", apiKey: "k", id: "l"))
        let inputs = ModelRoleInputs(savedModels: [claude, openAI], realtimeModels: [live])
        let state = ModelRoleState(assistantId: "claude", voice: .kokoro, dictation: .appleSpeech)
        XCTAssertEqual(ModelRoleCatalog.suggestions(for: openAI, inputs: inputs, state: state), [],
                       "voice, live and dictation are already chosen, and Claude sees photos")
    }

    func testATextOnlyAssistantIsOfferedTheNewKeyForPhotos() {
        let inputs = ModelRoleInputs(savedModels: [chatGPT, claude])
        let suggestions = ModelRoleCatalog.suggestions(for: claude, inputs: inputs, state: .init(assistantId: "cgpt"))
        XCTAssertEqual(suggestions.map(\.role), [.vision])
        XCTAssertEqual(suggestions.first?.choice, .model(configId: "claude"))
        XCTAssertTrue(suggestions.first?.destination.contains("Anthropic") == true)
    }

    func testATextOnlyKeyOffersItsProvidersVisionDefault() {
        let mini = model("o3", .openai, model: "o3-mini", key: "sk-x", vision: false)
        let suggestions = ModelRoleCatalog.suggestions(for: mini, inputs: .init(savedModels: [chatGPT, mini]),
                                                       state: .init(assistantId: "cgpt", voice: .kokoro,
                                                                    dictation: .appleSpeech))
        let vision = suggestions.first(where: { $0.role == .vision })
        XCTAssertEqual(vision?.choice, .newVisionModel(sourceConfigId: "o3", model: "gpt-5.4-mini"))
        let made = ModelRoleCatalog.visionModel(from: mini, model: "gpt-5.4-mini", id: "new")
        XCTAssertEqual(made.apiKey, "sk-x")
        XCTAssertEqual(made.provider, mini.provider)
        XCTAssertTrue(ModelFallbackChain.candidate(from: made).supportsVision)
    }

    func testNothingIsSuggestedUnderLocalOnly() {
        let inputs = ModelRoleInputs(savedModels: [chatGPT, openAI], restrictions: localOnly)
        XCTAssertEqual(ModelRoleCatalog.suggestions(for: openAI, inputs: inputs, state: .init(assistantId: "cgpt")), [])
    }

    func testHIPAAOrAnOrganisationPinDropsTheDictationSuggestion() {
        let hipaa = ModelRoleInputs(savedModels: [openAI], restrictions: ModelRoleRestrictions(hipaa: true))
        XCTAssertFalse(ModelRoleCatalog.suggestions(for: openAI, inputs: hipaa, state: .init(assistantId: "oai"))
            .contains { $0.role == .dictation })
        let pinned = ModelRoleInputs(savedModels: [openAI],
                                     restrictions: ModelRoleRestrictions(orgPinned: [.voice], orgCloudOff: [.dictation]))
        XCTAssertEqual(ModelRoleCatalog.suggestions(for: openAI, inputs: pinned, state: .init(assistantId: "oai"))
            .map(\.role), [.live])
    }

    func testALiveModelFromAKeyIsTheTemplateWithThatKey() throws {
        let live = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "gemini", model: "gemini-live-x",
                                                            apiKey: "  gem-key \n", id: "id1"))
        XCTAssertEqual(live.id, "id1")
        XCTAssertEqual(live.apiKey, "gem-key")
        XCTAssertEqual(live.model, "gemini-live-x")
        XCTAssertEqual(live.profile, .geminiLiveV1)
        XCTAssertEqual(live.endpoint, RealtimeProviderCatalog.template("gemini")?.endpoint)
        XCTAssertNil(ModelRoleCatalog.liveModel(providerID: "nope", model: "m", apiKey: "k"))
    }

    // MARK: - Plan KA P2: usable models, shutdown days, new defaults

    private let p2Today = ModelShutdown(year: 2026, month: 10, day: 30).date

    func testTheRealOpenAIListOffersEveryRoleTheAppCanReach() throws {
        let listed = try OpenAIModelListFixture.models()
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: openAI, listed: listed, today: p2Today),
                       [.assistant, .vision, .voice, .live, .dictation])
    }

    /// A list whose only live and transcription models need connections the app lacks offers
    /// neither role, though their kinds are there.
    func testAListWithOnlyUnreachableModelsDoesntOfferTheirRoles() {
        let unreachable = listed([("gpt-5.4-mini", .chat), ("gpt-live-1", .realtime),
                                  ("gpt-live-transcribe", .transcription), ("gpt-realtime-whisper", .transcription)])
        XCTAssertEqual(ModelRoleCatalog.roles(offeredBy: openAI, listed: unreachable, today: p2Today),
                       [.assistant, .vision])
        let suggestions = ModelRoleCatalog.suggestions(for: openAI, listed: unreachable,
                                                       inputs: .init(savedModels: [openAI], today: p2Today),
                                                       state: .init(assistantId: "oai"))
        XCTAssertTrue(suggestions.isEmpty, "\(suggestions.map(\.role))")
    }

    /// A list whose only live model has passed its shutdown day offers no Live.
    func testARetiredListModelDoesntOfferItsRole() {
        let retired = [ModelFetcher.RemoteModel(id: "gpt-realtime", name: "gpt-realtime", kind: .realtime,
                                                shutdown: ModelShutdown("2027-01-20"))]
        let after = ModelShutdown(year: 2027, month: 2, day: 1).date
        XCTAssertFalse(ModelRoleCatalog.roles(offeredBy: openAI, listed: retired, today: after).contains(.live))
        XCTAssertTrue(ModelRoleCatalog.roles(offeredBy: openAI, listed: retired, today: p2Today).contains(.live))
    }

    func testTheNewVisionDefaultsAreTheDocumentedImageModels() {
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .deepseek), "deepseek-flash")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .zai), "glm-5.3-flash")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .qwen), "qwen3.7-plus")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .minimax), "MiniMax-M3.1-Flash")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .openrouter), "anthropic/claude-haiku-5.5")
        XCTAssertEqual(ModelRoleDefaults.model(for: .vision, provider: .groq), "qwen/qwen3.8-27b")
        for provider in [LLMProvider.deepseek, .zai, .qwen, .minimax, .openrouter, .groq] {
            XCTAssertTrue(ModelRoleCatalog.roles(offeredBy: model("v", provider, model: "text-only-x")).contains(.vision),
                          provider.rawValue)
        }
    }

    func testGeminiLiveDefaultsToTheLiveGuidesModel() {
        XCTAssertEqual(ModelRoleDefaults.model(for: .live, provider: .gemini), "gemini-3.8-live")
        XCTAssertEqual(RealtimeProviderCatalog.template("gemini")?.model, "gemini-3.8-live")
    }

    /// A saved model past its shutdown day is shown in the assistant and Vision pickers, dimmed;
    /// one retiring soon stays choosable and says when.
    func testRolePickersDimARetiredSavedModelAndNoteARetiringOne() {
        let retired = model("old", .openai, model: "o4-mini")
        let retiring = model("soon", .openai, model: "gpt-4o")
        let inputs = ModelRoleInputs(savedModels: [retired, retiring, claude], today: p2Today)
        let assistant = ModelRoleCatalog.options(for: .assistant, inputs: inputs)
        XCTAssertEqual(assistant.first { $0.choice == .model(configId: "old") }?.unavailableLabel, "Retired")
        XCTAssertTrue(assistant.first { $0.choice == .model(configId: "soon") }?.isChoosable ?? false)
        XCTAssertTrue(assistant.first { $0.choice == .model(configId: "soon") }?.note?.hasPrefix("Retires") ?? false)
        XCTAssertNil(assistant.first { $0.choice == .model(configId: "claude") }?.note)
        let vision = ModelRoleCatalog.options(for: .vision, inputs: inputs)
        XCTAssertFalse(vision.first { $0.choice == .model(configId: "old") }?.isChoosable ?? true)
    }

    /// A speech model saved as a chat model can't be chosen as the assistant from the role picker.
    func testTheAssistantPickerDimsASavedNonChatModel() {
        let speech = model("tts", .gemini, model: "gemini-3.8-flash-tts")
        let options = ModelRoleCatalog.options(for: .assistant, inputs: .init(savedModels: [speech], today: p2Today))
        XCTAssertEqual(options.first?.unavailableLabel, ModelKind.speech.label)
    }

    func testASavedOpenAILiveModelTheSocketRefusesIsDimmed() throws {
        let refused = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "openai", model: "gpt-live-1",
                                                               apiKey: "k", id: "live1"))
        let fine = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "openai", model: "gpt-realtime-2.1-mini",
                                                            apiKey: "k", id: "live2"))
        let gemini = try XCTUnwrap(ModelRoleCatalog.liveModel(providerID: "gemini", model: "anything-the-account-lists",
                                                              apiKey: "k", id: "live3"))
        let options = ModelRoleCatalog.options(for: .live, inputs: .init(savedModels: [],
                                                                         realtimeModels: [refused, fine, gemini],
                                                                         today: p2Today))
        XCTAssertEqual(options.map(\.unavailableLabel), ["Needs a connection the app doesn't have yet", nil, nil])
    }

    /// The OpenAI voice row says when its speech model goes, once that is within 90 days.
    func testTheOpenAIVoiceSaysWhenItsModelRetires() {
        let inputs = ModelRoleInputs(savedModels: [openAI], voiceCredentials: [.openAI], today: p2Today)
        let row = ModelRoleCatalog.options(for: .voice, inputs: inputs).first { $0.choice == .voice(.openAI) }
        XCTAssertTrue(row?.note?.hasPrefix("Retires") ?? false)
        XCTAssertTrue(row?.isChoosable ?? false)
        let earlier = ModelRoleInputs(savedModels: [openAI], voiceCredentials: [.openAI],
                                      today: ModelShutdown(year: 2026, month: 9, day: 1).date)
        XCTAssertNil(ModelRoleCatalog.options(for: .voice, inputs: earlier).first { $0.choice == .voice(.openAI) }?.note)
    }

    // MARK: - The Gemini speech-model picker reads `.speech`

    func testTheGeminiSpeechPickerTakesTheClassifiersSpeechModels() throws {
        let body = #"""
        {"models":[
          {"name":"models/gemini-3.8-flash-tts","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/gemini-2.5-flash-native-audio-latest","supportedGenerationMethods":["bidiGenerateContent"]},
          {"name":"models/gemini-tts/../files","supportedGenerationMethods":["generateContent"]}
        ]}
        """#
        let models = try CloudVoiceRequests.parseGeminiSpeechModels(Data(body.utf8))
        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash-tts"])
        for id in models.map(\.id) {
            XCTAssertEqual(ModelKindClassifier.kind(provider: .gemini, id: id), .speech)
        }
        XCTAssertEqual(ModelKindClassifier.kind(provider: .gemini, id: "gemini-tts/../files"), .speech,
                       "the classifier calls it speech; the URL-safety check is what keeps it out")
    }
}
