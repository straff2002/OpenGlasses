import XCTest
@testable import OpenGlasses

/// Plan GC P3 — the model editor's "Effective with tools" / "Effective without tools" lines, from
/// the same route selection the request builder makes. The rows follow the plan's "How the field
/// tester uses it".
final class ModelReasoningReadoutTests: XCTestCase {

    private func lines(_ model: String, effort: ReasoningEffort?, tools: Bool,
                       provider: LLMProvider = .openai,
                       base: String = "https://api.openai.com/v1/chat/completions") -> ModelReasoningReadout.Lines {
        let config = ModelConfig(id: "r", name: "r", provider: provider.rawValue, apiKey: "",
                                 model: model, baseURL: base, reasoningEffort: effort?.rawValue)
        return ModelReasoningReadout.lines(for: config.routeSelection(toolsAttached: tools))
    }

    func testAutomaticKeepsToolTurnsCheapOnChatCompletions() {
        let withTools = lines("gpt-6-sol", effort: nil, tools: true)
        XCTAssertEqual(withTools.value, "None · Chat Completions")
        XCTAssertEqual(withTools.explanation,
                       "Automatic keeps tool turns on Chat Completions without reasoning, to stay quick and cheap.")
        let withoutTools = lines("gpt-6-sol", effort: nil, tools: false)
        XCTAssertEqual(withoutTools.value, "Medium (provider default) · Chat Completions")
        XCTAssertEqual(withoutTools.explanation, "Automatic sends nothing, so the provider's default applies.",
                       "the reasoning's own, more specific reason wins over the generic no-tools one")
    }

    func testMediumUsesResponsesWithToolsAndChatWithout() {
        let withTools = lines("gpt-6-sol", effort: .medium, tools: true)
        XCTAssertEqual(withTools.value, "Medium · Responses API")
        XCTAssertEqual(withTools.explanation, "This level needs the Responses API when tools are attached.")
        let withoutTools = lines("gpt-5.5", effort: .medium, tools: false)
        XCTAssertEqual(withoutTools.value, "Medium · Chat Completions")
        XCTAssertEqual(withoutTools.explanation, "Without tools, Chat Completions carries this setting itself.")
    }

    func testNoneIsAsSet() {
        let withTools = lines("gpt-6-sol", effort: ReasoningEffort.none, tools: true)
        XCTAssertEqual(withTools.value, "None · Chat Completions")
        XCTAssertEqual(withTools.explanation, "As set for this model.")
    }

    func testNearestAcceptedLevelShowsItsOwnReason() {
        // `gpt-5` takes minimal…high: an explicit None moves to Minimal, and says so.
        let withoutTools = lines("gpt-5", effort: ReasoningEffort.none, tools: false)
        XCTAssertEqual(withoutTools.value, "Minimal · Chat Completions")
        XCTAssertEqual(withoutTools.explanation, "The nearest setting this model accepts.")
    }

    func testNonReasoningModelIsNotApplicable() {
        for tools in [true, false] {
            let line = lines("gpt-4.1", effort: .medium, tools: tools)
            XCTAssertEqual(line.value, "Not applicable")
            XCTAssertEqual(line.explanation, "This model has no reasoning setting.")
        }
    }

    func testAzureHostStaysOnChatCompletions() {
        let line = lines("gpt-6-sol", effort: .medium, tools: true,
                         base: "https://r.openai.azure.com/openai/v1")
        XCTAssertEqual(line.value, "None · Chat Completions")
        XCTAssertEqual(line.explanation,
                       "Custom hosts stay on Chat Completions unless the base URL names a Responses endpoint.")
    }

    func testResponsesURLOptsIn() {
        let line = lines("gpt-5.5", effort: .medium, tools: true, provider: .custom,
                         base: "https://proxy.test/v1/responses")
        XCTAssertEqual(line.value, "Medium · Responses API")
        XCTAssertEqual(line.explanation, "The base URL names a Responses endpoint.")
    }

    func testOtherProviderShowsTheReasoningReason() {
        let line = lines("claude-sonnet-5", effort: .high, tools: true, provider: .anthropic, base: "")
        XCTAssertEqual(line.value, "High", "no endpoint named for a provider that uses neither")
        XCTAssertEqual(line.explanation, "As set for this model.")
    }

    // Plan IE P3: what the editor says about a Claude model is what `ReasoningPolicy` sends it.
    func testAnthropicReadoutPerSetting() {
        let automatic = lines("claude-sonnet-5-5", effort: nil, tools: true, provider: .anthropic, base: "")
        XCTAssertEqual(automatic.value, "Low")
        XCTAssertEqual(automatic.explanation,
                       "Automatic keeps a model that thinks before every answer at its lowest effort, to keep answers quick.")

        let adjusted = lines("claude-opus-5-5", effort: ReasoningEffort.none, tools: true, provider: .anthropic, base: "")
        XCTAssertEqual(adjusted.value, "Low")
        XCTAssertEqual(adjusted.explanation, "The nearest setting this model accepts.")

        let older = lines("claude-haiku-4-5", effort: .high, tools: false, provider: .anthropic, base: "")
        XCTAssertEqual(older.value, "Not applicable")
        XCTAssertEqual(older.explanation, "This model doesn't take an effort setting, so nothing is sent.")

        let unknown = lines("claude-nova-9", effort: .high, tools: true, provider: .anthropic, base: "")
        XCTAssertEqual(unknown.value, "Provider default")
        XCTAssertEqual(unknown.explanation,
                       "The app doesn't know this model yet, so it sends no effort setting and the provider's default applies.")
    }

    func testNoRenderedLineNamesAPlan() {
        // Plan letters belong in comments. Every reason's sentence is rendered in the editor.
        let reasons: [ReasoningPolicy.Resolution.Reason] = [
            .asSet, .adjustedToAccepted, .chatToolsClamp, .automaticToolTurn, .automaticProviderDefault,
            .automaticGeminiToolBudget, .learnedRejection, .notReasoningModel, .automaticThinkingModel,
            .noEffortSetting, .unrecognisedModel, .liveSessionOff, .onDevice,
        ]
        for reason in reasons {
            XCTAssertNil(reason.explanation.range(of: #"\bPlan [A-Z]{1,2}\b"#, options: .regularExpression),
                         "\(reason)")
        }
    }
}
