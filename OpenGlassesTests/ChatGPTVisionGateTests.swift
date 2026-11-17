import XCTest
@testable import OpenGlasses

/// A ChatGPT subscription model takes a photo only when the signed-in account's catalog says it
/// accepts images (`input_modalities`, or no modalities named — the upstream default). Everywhere
/// that decides — the send-time gate, `ModelConfig.visionEnabled`, the fallback chain, and what the
/// model editor stores — reads the same `ChatGPTImageInput`. Unknown is no.
@MainActor
final class ChatGPTVisionGateTests: XCTestCase {

    private var suite = ""
    private var originalStore: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "ChatGPTVisionGateTests.\(UUID().uuidString)"
        originalStore = ChatGPTContextCatalog.store
        ChatGPTContextCatalog.store = UserDefaults(suiteName: suite)!
        ChatGPTImageInput.record(nil)
    }

    override func tearDown() async throws {
        ChatGPTContextCatalog.update(data: Data(), accountID: nil)
        ChatGPTContextCatalog.store.removePersistentDomain(forName: suite)
        ChatGPTContextCatalog.store = originalStore
        ChatGPTImageInput.record(nil)
        try await super.tearDown()
    }

    /// One text-only model, one that names image input, and one that names no modalities.
    private static let catalogPayload = Data(#"""
    {"models":[
      {"slug":"gpt-text","display_name":"Text","input_modalities":["text"]},
      {"slug":"gpt-sees","display_name":"Sees","input_modalities":["text","image"],"is_default":true},
      {"slug":"gpt-legacy","display_name":"Legacy"}
    ]}
    """#.utf8)

    private func chatGPTConfig(model: String, vision: Bool? = nil) -> ModelConfig {
        ModelConfig(id: "chatgpt", name: "ChatGPT", provider: LLMProvider.chatgpt.rawValue,
                    apiKey: "", model: model, baseURL: "", supportsVision: vision)
    }

    // MARK: - The gate

    func testChatGPTPhotoForAModelThatCantSeeIsDeclined() {
        let decision = ChatGPTVisionGate.decide(provider: .chatgpt, hasImage: true, acceptsImages: false)
        guard case .declineVision(let message) = decision else {
            return XCTFail("expected .declineVision, got \(decision)")
        }
        XCTAssertEqual(message, ChatGPTVisionGate.declineMessage)
    }

    func testChatGPTPhotoForAModelThatSeesIsSent() {
        XCTAssertEqual(ChatGPTVisionGate.decide(provider: .chatgpt, hasImage: true, acceptsImages: true),
                       .sendWithImage)
    }

    func testChatGPTWithoutImageIsUnaffected() {
        XCTAssertEqual(ChatGPTVisionGate.decide(provider: .chatgpt, hasImage: false, acceptsImages: false),
                       .sendWithImage)
    }

    func testNonChatGPTProvidersWithImageAreUnaffected() {
        for provider: LLMProvider in [.openai, .gemini, .geminiVertex, .anthropic, .local, .appleOnDevice] {
            XCTAssertEqual(ChatGPTVisionGate.decide(provider: provider, hasImage: true, acceptsImages: false),
                           .sendWithImage,
                           "\(provider) must not be affected by the ChatGPT-only vision gate")
        }
    }

    func testDeclineMessageIsHonestAndPointsAtAlternativesWithoutJargon() {
        let message = ChatGPTVisionGate.declineMessage
        XCTAssertTrue(message.contains("can't see photos"), "must be honest about the limitation")
        XCTAssertTrue(message.contains("Settings"), "must say another ChatGPT model may see")
        XCTAssertTrue(message.contains("OpenAI API key"), "must name the API-key alternative")
        XCTAssertTrue(message.contains("Gemini"), "must name the Gemini alternative")
        XCTAssertTrue(message.contains("on-device"), "must name the on-device alternative")
        XCTAssertFalse(message.lowercased().contains("plan "), "must not reference internal plan docs")
        XCTAssertFalse(message.lowercased().contains("codex"), "must not use internal/jargon model-family names")
    }

    // MARK: - Reading the catalog

    func testACatalogRowTakesImagesWhenItSaysSoOrSaysNothing() {
        XCTAssertTrue(ChatGPTImageInput.rowAcceptsImages(["slug": "a", "input_modalities": ["text", "image"]]))
        XCTAssertTrue(ChatGPTImageInput.rowAcceptsImages(["slug": "a", "inputModalities": ["Image"]]))
        XCTAssertTrue(ChatGPTImageInput.rowAcceptsImages(["slug": "a"]),
                      "a row naming no modalities is text and image, as upstream reads it")
        XCTAssertFalse(ChatGPTImageInput.rowAcceptsImages(["slug": "a", "input_modalities": ["text"]]))
        XCTAssertFalse(ChatGPTImageInput.rowAcceptsImages(["slug": "a", "input_modalities": []]))
        XCTAssertFalse(ChatGPTImageInput.rowAcceptsImages(["slug": "a", "input_modalities": NSNull()]),
                       "a field that is there but unreadable is not a yes")
    }

    func testTheCatalogKeepsWhichModelsTakeImages() throws {
        let catalog = try XCTUnwrap(ChatGPTModelAvailability.Catalog(data: Self.catalogPayload))
        XCTAssertEqual(catalog.imageInput, ["gpt-sees", "gpt-legacy"])
    }

    func testASnapshotStoredBeforeImageInputStillDecodesAndSaysNothing() throws {
        let old = Data(#"{"ids":["gpt-sees"],"pickable":["gpt-sees"],"defaultID":"gpt-sees"}"#.utf8)
        let catalog = try JSONDecoder().decode(ChatGPTModelAvailability.Catalog.self, from: old)
        XCTAssertNil(catalog.imageInput)
    }

    // MARK: - From the stored catalog to every reader

    func testStoringACatalogTellsEveryReaderWhichModelsSee() {
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-sees"), "no catalog yet: no")
        XCTAssertFalse(chatGPTConfig(model: "gpt-sees").visionEnabled)

        ChatGPTContextCatalog.update(data: Self.catalogPayload, accountID: "account-a")

        XCTAssertTrue(ChatGPTImageInput.accepts("gpt-sees"))
        XCTAssertTrue(ChatGPTImageInput.accepts("gpt-legacy"))
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-text"))
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-unlisted"))

        XCTAssertTrue(chatGPTConfig(model: "gpt-sees").visionEnabled)
        XCTAssertFalse(chatGPTConfig(model: "gpt-text").visionEnabled)
        XCTAssertTrue(ModelFallbackChain.candidate(from: chatGPTConfig(model: "gpt-sees")).supportsVision)
        XCTAssertFalse(ModelFallbackChain.candidate(from: chatGPTConfig(model: "gpt-text")).supportsVision)
    }

    func testAnOverrideCannotMakeATextOnlyModelSee() {
        ChatGPTContextCatalog.update(data: Self.catalogPayload, accountID: "account-a")
        XCTAssertFalse(ModelFallbackChain.candidate(from: chatGPTConfig(model: "gpt-text", vision: true)).supportsVision)
        XCTAssertFalse(ModelFallbackChain.candidate(from: chatGPTConfig(model: "gpt-sees", vision: false)).supportsVision,
                       "the wearer's own 'off' stands")
    }

    func testSigningOutForgetsWhichModelsSee() {
        ChatGPTContextCatalog.update(data: Self.catalogPayload, accountID: "account-a")
        ChatGPTContextCatalog.update(data: Data(), accountID: nil)
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-sees"))
    }

    func testHydratingReadsOnlyThisAccountsCatalog() {
        ChatGPTContextCatalog.update(data: Self.catalogPayload, accountID: "account-a")
        ChatGPTImageInput.record(nil)

        ChatGPTContextCatalog.hydrateImageInput(accountID: "account-b")
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-sees"), "another account's catalog says nothing")

        ChatGPTContextCatalog.hydrateImageInput(accountID: "account-a")
        XCTAssertTrue(ChatGPTImageInput.accepts("gpt-sees"))

        ChatGPTContextCatalog.hydrateImageInput(accountID: "account-a",
                                                now: Date().addingTimeInterval(ChatGPTContextCatalog.maxAge + 60))
        XCTAssertFalse(ChatGPTImageInput.accepts("gpt-sees"), "a catalog too old to trust says nothing")
    }

    // MARK: - Saved settings

    func testTheOldForcedOffIsClearedOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite + ".reset"))
        defer { defaults.removePersistentDomain(forName: suite + ".reset") }
        let openAI = ModelConfig(id: "openai", name: "OpenAI", provider: LLMProvider.openai.rawValue,
                                 apiKey: "k", model: "gpt-x", baseURL: "", supportsVision: false)
        var models = [chatGPTConfig(model: "gpt-sees", vision: false), openAI]

        XCTAssertTrue(ChatGPTVisionOverrideReset.apply(to: &models, defaults: defaults))
        XCTAssertNil(models[0].supportsVision, "a ChatGPT model follows its catalog again")
        XCTAssertEqual(models[1].supportsVision, false, "other providers keep their setting")

        models[0].supportsVision = false
        XCTAssertFalse(ChatGPTVisionOverrideReset.apply(to: &models, defaults: defaults))
        XCTAssertEqual(models[0].supportsVision, false, "an 'off' chosen after the reset stays")
    }

    func testTheEditorStoresOnlyARealChoiceForChatGPT() {
        // Before sign-in has loaded a catalog the toggle reads off; saving that must not stick.
        XCTAssertNil(ChatGPTVisionOverrideReset.storedOverride(provider: .chatgpt, model: "gpt-sees", chosen: false))
        XCTAssertNil(ChatGPTVisionOverrideReset.storedOverride(provider: .chatgpt, model: "gpt-sees", chosen: true))

        ChatGPTContextCatalog.update(data: Self.catalogPayload, accountID: "account-a")
        XCTAssertEqual(ChatGPTVisionOverrideReset.storedOverride(provider: .chatgpt, model: "gpt-sees", chosen: false), false)
        XCTAssertNil(ChatGPTVisionOverrideReset.storedOverride(provider: .chatgpt, model: "gpt-sees", chosen: true))
        XCTAssertNil(ChatGPTVisionOverrideReset.storedOverride(provider: .chatgpt, model: "gpt-text", chosen: false))

        XCTAssertEqual(ChatGPTVisionOverrideReset.storedOverride(provider: .openai, model: "gpt-x", chosen: false), false)
        XCTAssertEqual(ChatGPTVisionOverrideReset.storedOverride(provider: .openai, model: "gpt-x", chosen: true), true)
    }
}
