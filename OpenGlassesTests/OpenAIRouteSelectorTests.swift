import XCTest
@testable import OpenGlasses

/// Plan GC P0 — which OpenAI endpoint a request goes to and at what reasoning level. The
/// `gpt-6-sol` + Medium + tools row is the field tester's case: GB clamped it to `none` on Chat
/// Completions; it now runs on the Responses API at Medium.
final class OpenAIRouteSelectorTests: XCTestCase {

    private let api = "https://api.openai.com/v1"

    private func select(_ model: String, provider: LLMProvider = .openai, base: String? = nil,
                        tools: Bool = true, _ requested: ReasoningEffort?,
                        learnedTool: Bool = false, learnedResponses: Bool = false) -> OpenAIRouteSelector.Selection {
        OpenAIRouteSelector.select(provider: provider, model: model, baseURL: base ?? api,
                                   toolsAttached: tools, requested: requested?.rawValue,
                                   learnedToolRejection: learnedTool,
                                   learnedResponsesRejection: learnedResponses)
    }

    // MARK: - The rule table

    func testEveryRule() {
        struct Row {
            let name: String
            let selection: OpenAIRouteSelector.Selection
            let endpoint: OpenAIRouteSelector.Endpoint
            let reason: OpenAIRouteSelector.Reason
            let effective: ReasoningPolicy.Resolution.Effective
        }
        let rows: [Row] = [
            // 1. Other providers.
            Row(name: "groq", selection: select("llama-3.3", provider: .groq, base: "https://api.groq.com/openai/v1", .high),
                endpoint: .chatCompletions, reason: .otherProvider, effective: .level(.high)),
            Row(name: "custom responses URL", selection: select("gpt-5.5", provider: .custom, base: "https://proxy.test/v1/responses", .medium),
                endpoint: .responses, reason: .customHostResponsesURL, effective: .level(.medium)),
            Row(name: "anthropic", selection: select("claude-sonnet-5", provider: .anthropic, base: "", .high),
                endpoint: .chatCompletions, reason: .otherProvider, effective: .level(.high)),
            // 2. OpenAI provider, other host.
            Row(name: "azure chat", selection: select("gpt-6-sol", base: "https://r.openai.azure.com/openai/v1", .medium),
                endpoint: .chatCompletions, reason: .customHostChat, effective: .level(.none)),
            Row(name: "azure responses", selection: select("gpt-6-sol", base: "https://r.openai.azure.com/openai/v1/responses", .medium),
                endpoint: .responses, reason: .customHostResponsesURL, effective: .level(.medium)),
            // 3. Non-reasoning model.
            Row(name: "gpt-4o", selection: select("gpt-4o", .high),
                endpoint: .chatCompletions, reason: .notReasoningModel, effective: .notApplicable),
            // 4. Responses refused earlier.
            Row(name: "refused", selection: select("gpt-5.2", .high, learnedResponses: true),
                endpoint: .chatCompletions, reason: .responsesRefusedEarlier, effective: .level(.none)),
            // 5. No tools.
            Row(name: "no tools", selection: select("gpt-6-sol", tools: false, .high),
                endpoint: .chatCompletions, reason: .noToolsAttached, effective: .level(.high)),
            Row(name: "no tools automatic", selection: select("gpt-6-sol", tools: false, nil),
                endpoint: .chatCompletions, reason: .noToolsAttached, effective: .providerDefault(.medium)),
            // 6. No tools on Chat Completions at all.
            Row(name: "6.1-sol explicit", selection: select("gpt-6.1-sol", .high),
                endpoint: .responses, reason: .chatToolsUnavailable, effective: .level(.high)),
            Row(name: "astra none", selection: select("gpt-6-astra", ReasoningEffort.none),
                endpoint: .responses, reason: .chatToolsUnavailable, effective: .level(.low)),
            // 7. Explicit above none with tools.
            Row(name: "5.2 medium", selection: select("gpt-5.2", .medium),
                endpoint: .responses, reason: .reasoningWithTools, effective: .level(.medium)),
            Row(name: "o4-mini xhigh", selection: select("o4-mini", .xhigh),
                endpoint: .responses, reason: .reasoningWithTools, effective: .level(.high)),
            // 8. Explicit none.
            Row(name: "5.5 none", selection: select("gpt-5.5", ReasoningEffort.none),
                endpoint: .chatCompletions, reason: .explicitNone, effective: .level(.none)),
            // 9. Automatic with tools.
            Row(name: "5.5 automatic", selection: select("gpt-5.5", nil),
                endpoint: .chatCompletions, reason: .automaticStaysCheap, effective: .level(.none)),
        ]
        for row in rows {
            XCTAssertEqual(row.selection.endpoint, row.endpoint, row.name)
            XCTAssertEqual(row.selection.reason, row.reason, row.name)
            XCTAssertEqual(row.selection.reasoning.effective, row.effective, row.name)
            XCTAssertEqual(row.selection.token, row.endpoint.rawValue, row.name)
        }
    }

    // MARK: - Named regressions

    func testGPT6SolExplicitMediumWithToolsGoesToResponsesAtMedium() {
        let s = select("gpt-6-sol", .medium)
        XCTAssertEqual(s.endpoint, .responses)
        XCTAssertEqual(s.reason, .reasoningWithTools)
        XCTAssertEqual(s.reasoning.wire, .responsesEffort(.medium))
        XCTAssertEqual(s.reasoning.effective, .level(.medium))
        XCTAssertEqual(s.token, "responses")
        XCTAssertEqual(s.displayValue, "Medium · Responses API")
    }

    func testGPT6SolAutomaticWithToolsStaysOnChatAtNone() {
        let s = select("gpt-6-sol", nil)
        XCTAssertEqual(s.endpoint, .chatCompletions)
        XCTAssertEqual(s.reason, .automaticStaysCheap)
        XCTAssertEqual(s.reasoning.wire, .reasoningEffort(.none))
        XCTAssertEqual(s.token, "chatCompletions")
        XCTAssertEqual(s.displayValue, "None · Chat Completions")
    }

    func testGPT6SolResponsesRefusedFallsBackToChatAtNone() {
        let s = select("gpt-6-sol", .medium, learnedResponses: true)
        XCTAssertEqual(s.endpoint, .chatCompletions)
        XCTAssertEqual(s.reason, .responsesRefusedEarlier)
        XCTAssertEqual(s.reasoning.wire, .reasoningEffort(.none))
        XCTAssertEqual(s.reasoning.effective, .level(.none))
    }

    func testGPT6AstraAutomaticWithToolsGoesToResponsesAtLow() {
        let s = select("gpt-6-astra", nil)
        XCTAssertEqual(s.endpoint, .responses)
        XCTAssertEqual(s.reason, .chatToolsUnavailable)
        XCTAssertEqual(s.reasoning.wire, .responsesEffort(.low))
        XCTAssertEqual(s.reasoning.effective, .level(.low))
        XCTAssertEqual(s.displayValue, "Low · Responses API")
    }

    func testGPT55ExplicitHighNoToolsStaysOnChatWithReasoningEffort() {
        let s = select("gpt-5.5", tools: false, .high)
        XCTAssertEqual(s.endpoint, .chatCompletions)
        XCTAssertEqual(s.reason, .noToolsAttached)
        XCTAssertEqual(s.reasoning.wire, .reasoningEffort(.high))
        var body: [String: Any] = [:]
        s.reasoning.apply(to: &body)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["reasoning"])
    }

    func testGPT41NeverMoves() {
        for requested: ReasoningEffort? in [nil, ReasoningEffort.none, .medium, .xhigh] {
            for tools in [true, false] {
                let s = select("gpt-4.1", tools: tools, requested)
                XCTAssertEqual(s.endpoint, .chatCompletions)
                XCTAssertEqual(s.reason, .notReasoningModel)
                XCTAssertEqual(s.reasoning.wire, .omit)
                XCTAssertEqual(s.displayValue, "Not applicable")
            }
        }
    }

    func testAzureHostStaysOnChatUnlessURLNamesResponses() {
        let base = "https://r.openai.azure.com/openai/v1"
        let chat = select("gpt-6-sol", base: base, .high)
        XCTAssertEqual(chat.endpoint, .chatCompletions)
        XCTAssertEqual(chat.reason, .customHostChat)
        XCTAssertEqual(chat.reasoning.wire, .reasoningEffort(.none), "GB's clamp still applies on Chat Completions")

        for url in [base + "/responses", base + "/responses/", base + "/Responses"] {
            let responses = select("gpt-6-sol", base: url, .high)
            XCTAssertEqual(responses.endpoint, .responses, url)
            XCTAssertEqual(responses.reason, .customHostResponsesURL, url)
            XCTAssertEqual(responses.reasoning.wire, .responsesEffort(.high), url)
        }
        XCTAssertFalse(OpenAIRouteSelector.isOpenAIAPIHost(base))
    }

    func testCustomProviderResponsesURLOptsIn() {
        let s = select("my-deployment", provider: .custom, base: "https://gateway.example/v1/responses", tools: true, .low)
        XCTAssertEqual(s.endpoint, .responses)
        XCTAssertEqual(s.reason, .customHostResponsesURL)
        XCTAssertEqual(s.reasoning.wire, .responsesEffort(.low))

        let plain = select("my-deployment", provider: .custom, base: "https://gateway.example/v1", tools: true, .low)
        XCTAssertEqual(plain.endpoint, .chatCompletions)
        XCTAssertEqual(plain.reason, .otherProvider)
        XCTAssertEqual(plain.reasoning.wire, .reasoningEffort(.low))
    }

    func testLearnedResponsesRefusalOverridesTheURLOptIn() {
        // Plan GC Decision 6 for URL opt-ins: once a custom or Azure `/responses` endpoint refused
        // the model, later turns go to Chat Completions (at `none` with tools) instead of paying
        // for a refused request every turn.
        let azure = select("gpt-6-sol", base: "https://r.openai.azure.com/openai/v1/responses", .medium,
                           learnedResponses: true)
        XCTAssertEqual(azure.endpoint, .chatCompletions)
        XCTAssertEqual(azure.reason, .responsesRefusedEarlier)
        XCTAssertEqual(azure.reasoning.effective, .level(.none))
        let custom = select("gpt-5.5", provider: .custom, base: "https://proxy.test/v1/responses", .medium,
                            learnedResponses: true)
        XCTAssertEqual(custom.endpoint, .chatCompletions)
        XCTAssertEqual(custom.reason, .responsesRefusedEarlier)
        XCTAssertEqual(custom.reasoning.wire, .reasoningEffort(.none))
    }

    func testAPIHostClassification() {
        XCTAssertTrue(OpenAIRouteSelector.isOpenAIAPIHost(""))
        XCTAssertTrue(OpenAIRouteSelector.isOpenAIAPIHost("  "))
        XCTAssertTrue(OpenAIRouteSelector.isOpenAIAPIHost("https://api.openai.com/v1"))
        XCTAssertTrue(OpenAIRouteSelector.isOpenAIAPIHost("https://API.openai.com/v1/chat/completions"))
        XCTAssertFalse(OpenAIRouteSelector.isOpenAIAPIHost("https://api.openai.com.evil.test/v1"))
        XCTAssertFalse(OpenAIRouteSelector.isOpenAIAPIHost("https://proxy.test/api.openai.com"))
        // The API host with an empty base URL still routes by the table.
        XCTAssertEqual(select("gpt-6-sol", base: "", .medium).endpoint, .responses)
    }

    func testEndpointURLDerivation() {
        typealias S = OpenAIRouteSelector
        XCTAssertEqual(S.endpointURL(baseURL: "", endpoint: .responses), "https://api.openai.com/v1/responses")
        XCTAssertEqual(S.endpointURL(baseURL: "", endpoint: .chatCompletions), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1", endpoint: .responses),
                       "https://api.openai.com/v1/responses")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1/", endpoint: .chatCompletions),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1/chat/completions", endpoint: .responses),
                       "https://api.openai.com/v1/responses")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1/chat/completions", endpoint: .chatCompletions),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1/responses/", endpoint: .chatCompletions),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(S.endpointURL(baseURL: "https://api.openai.com/v1/responses/", endpoint: .responses),
                       "https://api.openai.com/v1/responses")
        XCTAssertEqual(S.endpointURL(baseURL: "https://r.openai.azure.com/openai/v1", endpoint: .responses),
                       "https://r.openai.azure.com/openai/v1/responses")
        XCTAssertEqual(S.endpointURL(baseURL: " https://r.openai.azure.com/openai/v1 ", endpoint: .chatCompletions),
                       "https://r.openai.azure.com/openai/v1/chat/completions")
    }

    func testDisplayValueAndExplanationAreNonEmpty() {
        let reasons: [OpenAIRouteSelector.Reason] = [
            .reasoningWithTools, .chatToolsUnavailable, .automaticStaysCheap, .noToolsAttached,
            .explicitNone, .notReasoningModel, .otherProvider, .customHostChat,
            .customHostResponsesURL, .responsesRefusedEarlier,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.explanation.isEmpty, reason.rawValue)
            XCTAssertTrue(reason.explanation.hasSuffix("."), reason.rawValue)
        }
        let samples = [select("gpt-6-sol", .medium), select("gpt-6-sol", nil), select("gpt-4o", .high),
                       select("claude-sonnet-5", provider: .anthropic, base: "", .high),
                       select("x", provider: .custom, base: "https://h.test/v1", nil)]
        for sample in samples {
            XCTAssertFalse(sample.displayValue.isEmpty)
        }
        // Anthropic never names an OpenAI endpoint it does not use.
        XCTAssertFalse(select("claude-sonnet-5", provider: .anthropic, base: "", .high).displayValue.contains("Chat Completions"))
        XCTAssertEqual(select("gpt-5.5", tools: false, .medium).displayValue, "Medium · Chat Completions")
    }

    func testModelConfigRouteSelectionWrapsTheSelector() {
        var config = ModelConfig(id: "a", name: "GPT", provider: LLMProvider.openai.rawValue, apiKey: "",
                                 model: "gpt-6-sol", baseURL: api)
        XCTAssertEqual(config.routeSelection(toolsAttached: true).endpoint, .chatCompletions)
        config.reasoningEffort = ReasoningEffort.medium.rawValue
        XCTAssertEqual(config.routeSelection(toolsAttached: true), select("gpt-6-sol", .medium))
        XCTAssertEqual(config.routeSelection(toolsAttached: true, learnedResponsesRejection: true).endpoint,
                       .chatCompletions)
    }

    func testChatGPTSubscriptionIsReportedOnResponsesAndUnchanged() {
        let s = select("gpt-5.5", provider: .chatgpt, base: "https://chatgpt.com/backend-api/codex/responses", nil)
        XCTAssertEqual(s.endpoint, .responses)
        XCTAssertEqual(s.reason, .otherProvider)
        XCTAssertEqual(s.reasoning.wire, .omit)
    }
}
