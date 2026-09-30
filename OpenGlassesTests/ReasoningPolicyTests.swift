import XCTest
@testable import OpenGlasses

/// Plan GB P0 — the reasoning setting each request carries, per provider and route, with and
/// without tools. The `gpt-6-sol` + tools + Chat Completions row is the field tester's HTTP 400.
final class ReasoningPolicyTests: XCTestCase {

    private func resolve(_ provider: LLMProvider, _ model: String, tools: Bool,
                         _ requested: ReasoningEffort?, learned: Bool = false) -> ReasoningPolicy.Resolution {
        ReasoningPolicy.resolve(provider: provider, model: model,
                                route: ReasoningRoute.route(for: provider),
                                toolsAttached: tools, requested: requested?.rawValue,
                                learnedToolRejection: learned)
    }

    private func body(_ resolution: ReasoningPolicy.Resolution) -> [String: Any] {
        var body: [String: Any] = ["model": "m"]
        resolution.apply(to: &body)
        return body
    }

    // MARK: - The regression

    func testGPT6SolWithToolsOnChatCompletionsClampsToNone() {
        // "Function tools with reasoning_effort are not supported for gpt-6-sol in
        // /v1/chat/completions … set reasoning_effort to 'none'".
        for requested: ReasoningEffort? in [nil, .low, .medium, .high, .xhigh] {
            let r = resolve(.openai, "gpt-6-sol", tools: true, requested)
            XCTAssertEqual(r.wire, .reasoningEffort(.none), "requested \(String(describing: requested))")
            XCTAssertEqual(r.effective, .level(.none))
            XCTAssertEqual(r.reason, .chatToolsClamp)
            XCTAssertEqual(body(r)["reasoning_effort"] as? String, "none")
        }
    }

    func testGPT6ExplicitNoneWithToolsIsAsSet() {
        let r = resolve(.openai, "gpt-6-sol", tools: true, ReasoningEffort.none)
        XCTAssertEqual(r.wire, .reasoningEffort(.none))
        XCTAssertEqual(r.reason, .asSet)
    }

    func testGPT6WithoutToolsHonoursRequestAndAutomaticSendsNothing() {
        let high = resolve(.openai, "gpt-6-sol", tools: false, .high)
        XCTAssertEqual(high.wire, .reasoningEffort(.high))
        XCTAssertEqual(high.reason, .asSet)

        let auto = resolve(.openai, "gpt-6-sol", tools: false, nil)
        XCTAssertEqual(auto.wire, .omit)
        XCTAssertEqual(auto.effective, .providerDefault(.medium))
        XCTAssertNil(body(auto)["reasoning_effort"])
    }

    // MARK: - Other OpenAI families

    func testGPT55AutomaticWithToolsResolvesToNone() {
        let r = resolve(.openai, "gpt-5.5", tools: true, nil)
        XCTAssertEqual(r.wire, .reasoningEffort(.none))
        XCTAssertEqual(r.effective, .level(.none))
        XCTAssertEqual(r.reason, .automaticToolTurn)
    }

    func testGPT55ExplicitWithToolsIsHonoured() {
        let r = resolve(.openai, "gpt-5.5", tools: true, .medium)
        XCTAssertEqual(r.wire, .reasoningEffort(.medium))
        XCTAssertEqual(r.reason, .asSet)
    }

    func testModelWhoseDefaultIsNoneGetsNothingSentOnAutomaticToolTurn() {
        // Open question 4: if a model's default is already `none`, send nothing.
        let r = resolve(.openai, "gpt-5.1", tools: true, nil)
        XCTAssertEqual(r.wire, .omit)
        XCTAssertEqual(r.effective, .level(.none))
    }

    func testGPT5OriginalMapsNoneToMinimal() {
        let auto = resolve(.openai, "gpt-5-mini", tools: true, nil)
        XCTAssertEqual(auto.wire, .reasoningEffort(.minimal))
        let none = resolve(.openai, "gpt-5", tools: false, ReasoningEffort.none)
        XCTAssertEqual(none.wire, .reasoningEffort(.minimal))
        XCTAssertEqual(none.reason, .adjustedToAccepted)
    }

    func testOSeriesClampsXhighToHigh() {
        let r = resolve(.openai, "o4-mini", tools: false, .xhigh)
        XCTAssertEqual(r.wire, .reasoningEffort(.high))
        XCTAssertEqual(r.reason, .adjustedToAccepted)
    }

    func testNonReasoningOpenAIModelNeverGetsTheParameter() {
        for model in ["gpt-4o", "gpt-4.1-mini", "gpt-5-chat-latest"] {
            let r = resolve(.openai, model, tools: true, .high)
            XCTAssertEqual(r.wire, .omit, model)
            XCTAssertEqual(r.effective, .notApplicable)
        }
    }

    func testLearnedRejectionClampsAFamilyMissingFromTheTable() {
        let r = resolve(.openai, "gpt-5.5", tools: true, .high, learned: true)
        XCTAssertEqual(r.wire, .reasoningEffort(.none))
        XCTAssertEqual(r.reason, .learnedRejection)
    }

    // MARK: - Other routes

    func testResponsesRouteSendsReasoningEffortObject() {
        let r = resolve(.chatgpt, "gpt-5.5", tools: true, .high)
        XCTAssertEqual(r.wire, .responsesEffort(.high))
        XCTAssertEqual((body(r)["reasoning"] as? [String: String])?["effort"], "high")
        let auto = resolve(.chatgpt, "gpt-5.5", tools: true, nil)
        XCTAssertEqual(auto.wire, .omit)
        XCTAssertEqual(auto.effective, .providerDefault(.medium))
    }

    func testAnthropicIsNotSupportedYet() {
        let r = resolve(.anthropic, "claude-sonnet-5", tools: true, .high)
        XCTAssertEqual(r.wire, .omit)
        XCTAssertEqual(r.effective, .notSupported)
        XCTAssertEqual(r.reason, .anthropicNotYet)
    }

    func testCustomAndThirdPartySendOnlyExplicitValues() {
        for provider in [LLMProvider.custom, .openrouter, .mistral, .xai] {
            XCTAssertEqual(resolve(provider, "some-model", tools: true, nil).wire, .omit, "\(provider)")
            XCTAssertEqual(resolve(provider, "some-model", tools: true, .low).wire, .reasoningEffort(.low), "\(provider)")
        }
    }

    func testGeminiAutomaticKeepsShippedBudgetAndExplicitIsBounded() {
        let auto = resolve(.gemini, "gemini-3-flash", tools: true, nil)
        XCTAssertEqual(auto.wire, .omit)
        let autoConfig = auto.geminiGenerationConfig(includesTools: true, configuredMaxTokens: 500)
        XCTAssertEqual(autoConfig["maxOutputTokens"] as? Int, GeminiBudgetPolicy.toolTurnMaxOutputTokens)
        XCTAssertEqual((autoConfig["thinkingConfig"] as? [String: Int])?["thinkingBudget"],
                       GeminiBudgetPolicy.toolTurnThinkingBudget)

        let high = resolve(.gemini, "gemini-3-flash", tools: true, .high)
        XCTAssertEqual(high.wire, .geminiThinkingBudget(8_192))
        let config = high.geminiGenerationConfig(includesTools: true, configuredMaxTokens: 500)
        // CO Item 2: the budget always comes with the answer's allowance on top.
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 8_192 + GeminiBudgetPolicy.toolTurnMaxOutputTokens)
        XCTAssertNil(body(high)["reasoning_effort"])
    }

    func testGeminiProCannotSwitchThinkingOff() {
        let r = resolve(.gemini, "gemini-2.5-pro", tools: false, ReasoningEffort.none)
        XCTAssertEqual(r.wire, .geminiThinkingBudget(128))
        XCTAssertEqual(r.reason, .adjustedToAccepted)
    }

    func testLiveAndOnDevice() {
        let live = ReasoningPolicy.resolve(provider: .gemini, model: "gemini-live", route: .geminiLive,
                                           toolsAttached: true, requested: "high")
        XCTAssertEqual(live.effective, .level(.none))
        XCTAssertEqual(resolve(.local, "gemma", tools: true, .high).effective, .notApplicable)
    }

    // MARK: - Output cap (CO Item 2)

    func testOutputCapRaisedOnlyWhenTheModelReasons() {
        XCTAssertEqual(resolve(.openai, "gpt-6-sol", tools: true, .high).outputCap(base: 1024), 1024)
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: true, .high).outputCap(base: 1024), 4096)
        // Automatic without tools: the provider default (medium) still reasons.
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: false, nil).outputCap(base: 500), 4096)
        XCTAssertEqual(resolve(.openai, "gpt-4o", tools: false, nil).outputCap(base: 500), 500)
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: true, .medium).outputCap(base: 8000), 8000)
    }

    // MARK: - Tokens and the saved setting

    func testTokensAreContentFree() {
        XCTAssertEqual(resolve(.openai, "gpt-6-sol", tools: true, nil).token, "none")
        XCTAssertEqual(resolve(.openai, "gpt-6-sol", tools: false, nil).token, "default-medium")
        XCTAssertEqual(resolve(.anthropic, "claude", tools: true, nil).token, "unsupported")
        XCTAssertEqual(PrivacyToken(resolve(.custom, "x", tools: true, nil).token).description, "default")
    }

    func testUnrecognisedSavedValueIsAutomatic() {
        let r = ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-sol", route: .chatCompletions,
                                        toolsAttached: false, requested: "turbo")
        XCTAssertEqual(r.wire, .omit)
    }

    func testLegacyModelConfigDecodesAsAutomaticAndRoundTrips() throws {
        let legacy = #"{"id":"a","name":"GPT","provider":"openai","apiKey":"","model":"gpt-6-sol","baseURL":"https://api.openai.com/v1","smallContext":false}"#
        let config = try JSONDecoder().decode(ModelConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(config.reasoningEffort)
        XCTAssertNil(config.reasoningLevel)
        XCTAssertEqual(config.reasoningResolution(toolsAttached: true).wire, .reasoningEffort(.none))

        var saved = config
        saved.reasoningEffort = ReasoningEffort.high.rawValue
        let decoded = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.reasoningLevel, .high)
        XCTAssertEqual(decoded, saved)
    }

    // MARK: - Rejection classifier

    func testClassifierRecognisesTheFieldTestersError() {
        let message = "Function tools with reasoning_effort are not supported for gpt-6-sol in /v1/chat/completions. Please use /v1/responses or set reasoning_effort to 'none'."
        XCTAssertTrue(ReasoningRejectionClassifier.isReasoningWithToolsRejection(status: 400, message: message))
        XCTAssertTrue(ReasoningRejectionClassifier.shouldRetry(status: 400, message: message, sentEffort: nil))
        XCTAssertTrue(ReasoningRejectionClassifier.shouldRetry(status: 400, message: message, sentEffort: "medium"))
        // Retrying at `none` after sending `none` would loop.
        XCTAssertFalse(ReasoningRejectionClassifier.shouldRetry(status: 400, message: message, sentEffort: "none"))
    }

    func testClassifierIgnoresOtherErrors() {
        XCTAssertFalse(ReasoningRejectionClassifier.isReasoningWithToolsRejection(
            status: 400, message: "Invalid value for 'messages'"))
        XCTAssertFalse(ReasoningRejectionClassifier.isReasoningWithToolsRejection(
            status: 429, message: "reasoning_effort tools rate limited"))
        XCTAssertFalse(ReasoningRejectionClassifier.isReasoningWithToolsRejection(status: 400, message: nil))
    }
}
