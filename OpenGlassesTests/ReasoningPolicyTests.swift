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
        // Plan GC: GPT-5.5 takes tools on Chat Completions only at `none` (the provider's
        // migration guide, read 2026-09-30), so the reason is now the clamp, not Automatic's
        // choice. The wire and the effective level are unchanged.
        let r = resolve(.openai, "gpt-5.5", tools: true, nil)
        XCTAssertEqual(r.wire, .reasoningEffort(.none))
        XCTAssertEqual(r.effective, .level(.none))
        XCTAssertEqual(r.reason, .chatToolsClamp)
    }

    func testGPT55ExplicitWithToolsOnChatClampsToNone() {
        // Plan GC corrected GB's table: an explicit level with tools on Chat Completions is a 400
        // for GPT-5.5, so the chat route clamps it; `OpenAIRouteSelector` sends such turns to
        // Responses instead, where the level is honoured.
        let r = resolve(.openai, "gpt-5.5", tools: true, .medium)
        XCTAssertEqual(r.wire, .reasoningEffort(.none))
        XCTAssertEqual(r.reason, .chatToolsClamp)
    }

    func testGPT52ExplicitWithToolsIsHonouredOnChat() {
        let r = resolve(.openai, "gpt-5.2", tools: true, .medium)
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
        // Plan GC: GPT-5.5 is now a clamping family, so a family that still takes reasoning with
        // tools on Chat Completions (GPT-5.2) stands in for "missing from the table".
        let r = resolve(.openai, "gpt-5.2", tools: true, .high, learned: true)
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

    // MARK: - Anthropic (Plan IE P3)

    private typealias Wire = ReasoningPolicy.Resolution.Wire
    private typealias Effective = ReasoningPolicy.Resolution.Effective
    private typealias Reason = ReasoningPolicy.Resolution.Reason

    /// Every family, at Automatic: a model that thinks by default is sent `low`; a model that
    /// does not is sent nothing; a model that takes no effort setting is never sent one.
    func testAnthropicAutomaticPerFamily() {
        let rows: [(model: String, wire: Wire, effective: Effective, reason: Reason)] = [
            ("claude-fable-5-1", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-mythos-5-1", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-fable-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-mythos-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-opus-5-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-opus-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-sonnet-5-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-sonnet-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-haiku-5-5", .anthropicEffort(.low), .level(.low), .automaticThinkingModel),
            ("claude-opus-4-8", .omit, .providerDefault(nil), .automaticProviderDefault),
            ("claude-opus-4-7", .omit, .providerDefault(nil), .automaticProviderDefault),
            ("claude-opus-4-6", .omit, .providerDefault(nil), .automaticProviderDefault),
            ("claude-sonnet-4-6", .omit, .providerDefault(nil), .automaticProviderDefault),
            ("claude-opus-4-5", .omit, .providerDefault(nil), .automaticProviderDefault),
            ("claude-haiku-4-5", .omit, .notApplicable, .noEffortSetting),
            ("claude-sonnet-4-5", .omit, .notApplicable, .noEffortSetting),
            ("claude-3-5-haiku-20241022", .omit, .notApplicable, .noEffortSetting),
            ("claude-nova-9", .omit, .providerDefault(nil), .unrecognisedModel),
        ]
        for row in rows {
            for tools in [true, false] {
                let r = resolve(.anthropic, row.model, tools: tools, nil)
                XCTAssertEqual(r.wire, row.wire, "\(row.model) tools=\(tools)")
                XCTAssertEqual(r.effective, row.effective, "\(row.model) tools=\(tools)")
                XCTAssertEqual(r.reason, row.reason, "\(row.model) tools=\(tools)")
            }
        }
    }

    /// Every setting level on a family that takes all five: the app's `none` and `minimal` have
    /// no equivalent and become `low`; the rest go as set.
    func testAnthropicExplicitLevelsOnACurrentFamily() {
        let expected: [(ReasoningEffort, ReasoningEffort, Reason)] = [
            (.none, .low, .adjustedToAccepted), (.minimal, .low, .adjustedToAccepted),
            (.low, .low, .asSet), (.medium, .medium, .asSet),
            (.high, .high, .asSet), (.xhigh, .xhigh, .asSet),
        ]
        for model in ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
                      "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5"] {
            for (requested, sent, reason) in expected {
                let r = resolve(.anthropic, model, tools: true, requested)
                XCTAssertEqual(r.wire, .anthropicEffort(sent), "\(model) \(requested)")
                XCTAssertEqual(r.effective, .level(sent), "\(model) \(requested)")
                XCTAssertEqual(r.reason, reason, "\(model) \(requested)")
                XCTAssertEqual((body(r)["output_config"] as? [String: String])?["effort"], sent.rawValue)
            }
        }
    }

    /// A family without `xhigh` gets `high` for it — the nearest level it takes, never `max`.
    func testAnthropicExplicitLevelIsClampedToTheFamily() {
        for model in ["claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5"] {
            let r = resolve(.anthropic, model, tools: true, .xhigh)
            XCTAssertEqual(r.wire, .anthropicEffort(.high), model)
            XCTAssertEqual(r.reason, .adjustedToAccepted, model)
            XCTAssertEqual(resolve(.anthropic, model, tools: true, .medium).wire, .anthropicEffort(.medium), model)
        }
    }

    /// An explicit setting never reaches a model that would refuse the field.
    func testAnthropicNeverSendsEffortWhereItIsAnError() {
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-1", "claude-nova-9", ""] {
            for requested in ReasoningEffort.allCases {
                let r = resolve(.anthropic, model, tools: true, requested)
                XCTAssertEqual(r.wire, .omit, "\(model) \(requested)")
                XCTAssertNil(body(r)["output_config"], "\(model) \(requested)")
            }
        }
    }

    /// Whatever is resolved, the body gains `output_config` or nothing: no thinking configuration
    /// and no budget, on any family at any setting.
    func testAnthropicBodyNeverCarriesAThinkingConfiguration() {
        let models = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
                      "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5", "claude-opus-4-6",
                      "claude-opus-4-5", "claude-haiku-4-5", "claude-nova-9"]
        for model in models {
            for requested in [ReasoningEffort?.none] + ReasoningEffort.allCases.map(Optional.some) {
                let sent = body(resolve(.anthropic, model, tools: true, requested))
                XCTAssertTrue(Set(sent.keys).isSubset(of: ["model", "output_config"]), "\(model): \(sent.keys)")
                if let effort = (sent["output_config"] as? [String: String])?["effort"] {
                    XCTAssertTrue(["low", "medium", "high", "xhigh"].contains(effort), "\(model): \(effort)")
                }
            }
        }
    }

    func testCustomAndThirdPartySendOnlyExplicitValues() {
        for provider in [LLMProvider.custom, .openrouter, .mistral, .xai] {
            XCTAssertEqual(resolve(provider, "some-model", tools: true, nil).wire, .omit, "\(provider)")
            XCTAssertEqual(resolve(provider, "some-model", tools: true, .low).wire, .reasoningEffort(.low), "\(provider)")
        }
    }

    func testGeminiAutomaticKeepsShippedBudgetAndExplicitIsBounded() {
        // A model that takes a thinking budget: the 2.5 family.
        let auto = resolve(.gemini, "gemini-2.5-flash", tools: true, nil)
        XCTAssertEqual(auto.wire, .omit)
        let autoConfig = auto.geminiGenerationConfig(includesTools: true, configuredMaxTokens: 500)
        XCTAssertEqual(autoConfig["maxOutputTokens"] as? Int, GeminiBudgetPolicy.toolTurnMaxOutputTokens)
        XCTAssertEqual((autoConfig["thinkingConfig"] as? [String: Int])?["thinkingBudget"],
                       GeminiBudgetPolicy.toolTurnThinkingBudget)

        let plain = resolve(.gemini, "gemini-2.5-flash", tools: false, nil)
        XCTAssertEqual(plain.wire, .omit)
        let plainConfig = plain.geminiGenerationConfig(includesTools: false, configuredMaxTokens: 500)
        XCTAssertEqual(plainConfig["maxOutputTokens"] as? Int, 500)
        XCTAssertNil(plainConfig["thinkingConfig"])

        let high = resolve(.gemini, "gemini-2.5-flash", tools: true, .high)
        XCTAssertEqual(high.wire, .geminiThinkingBudget(8_192))
        let config = high.geminiGenerationConfig(includesTools: true, configuredMaxTokens: 500)
        // CO Item 2: the budget always comes with the answer's allowance on top.
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 8_192 + GeminiBudgetPolicy.toolTurnMaxOutputTokens)
        XCTAssertNil((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"])
        XCTAssertNil(body(high)["reasoning_effort"])
    }

    func testGeminiProCannotSwitchThinkingOff() {
        let r = resolve(.gemini, "gemini-2.5-pro", tools: false, ReasoningEffort.none)
        XCTAssertEqual(r.wire, .geminiThinkingBudget(128))
        XCTAssertEqual(r.effective, .level(.minimal))
        XCTAssertEqual(r.reason, .adjustedToAccepted)
    }

    func testGeminiBudgetsStayInsideEachModelsRange() {
        typealias Row = (model: String, requested: ReasoningEffort, budget: Int,
                         effective: ReasoningEffort, reason: ReasoningPolicy.Resolution.Reason)
        let rows: [Row] = [
            ("gemini-2.5-flash", .none, 0, .none, .asSet),
            ("gemini-2.5-flash", .minimal, 128, .minimal, .asSet),
            ("gemini-2.5-flash", .low, 512, .low, .asSet),
            ("gemini-2.5-flash", .medium, 2_048, .medium, .asSet),
            ("gemini-2.5-flash", .xhigh, 16_384, .xhigh, .asSet),
            // Flash-Lite takes 0, or 512 and up: nothing in between.
            ("gemini-2.5-flash-lite", .none, 0, .none, .asSet),
            ("gemini-2.5-flash-lite", .minimal, 512, .low, .adjustedToAccepted),
            ("gemini-2.5-flash-lite", .low, 512, .low, .asSet),
            // Pro cannot switch thinking off.
            ("gemini-2.5-pro", .none, 128, .minimal, .adjustedToAccepted),
            ("gemini-2.5-pro", .high, 8_192, .high, .asSet),
            // An id the table cannot place keeps the budget shape.
            ("gemini-exp-1206", .low, 512, .low, .asSet),
        ]
        for row in rows {
            let r = resolve(.gemini, row.model, tools: true, row.requested)
            XCTAssertEqual(r.wire, .geminiThinkingBudget(row.budget), "\(row.model) \(row.requested)")
            XCTAssertEqual(r.effective, .level(row.effective), "\(row.model) \(row.requested)")
            XCTAssertEqual(r.reason, row.reason, "\(row.model) \(row.requested)")
        }
    }

    // MARK: - Gemini 3 and later: a thinking level, never a budget

    func testGemini3AutomaticNamesALevelOnEveryTurn() {
        typealias Row = (model: String, tools: Bool, level: ReasoningEffort,
                         reason: ReasoningPolicy.Resolution.Reason)
        let rows: [Row] = [
            // Tool turns deliberate a little: `low` everywhere.
            ("gemini-3.5-flash-lite", true, .low, .automaticGeminiToolBudget),
            ("gemini-3.6-flash", true, .low, .automaticGeminiToolBudget),
            ("gemini-3.8-flash", true, .low, .automaticGeminiToolBudget),
            ("gemini-3.1-pro-preview", true, .low, .automaticGeminiToolBudget),
            ("gemini-3.9-flash", true, .low, .automaticGeminiToolBudget),
            // Plain turns take the model's lowest level; `minimal` is an error on 3.8 Flash.
            ("gemini-3.5-flash-lite", false, .minimal, .automaticThinkingModel),
            ("gemini-3.6-flash", false, .minimal, .automaticThinkingModel),
            ("gemini-3-flash-preview", false, .minimal, .automaticThinkingModel),
            ("gemini-3.8-flash", false, .low, .automaticThinkingModel),
            ("gemini-3.1-pro-preview", false, .low, .automaticThinkingModel),
            ("gemini-3.9-flash", false, .low, .automaticThinkingModel),
            ("gemini-flash-latest", false, .low, .automaticThinkingModel),
        ]
        for provider in [LLMProvider.gemini, .geminiVertex] {
            for row in rows {
                let r = resolve(provider, row.model, tools: row.tools, nil)
                XCTAssertEqual(r.wire, .geminiThinkingLevel(row.level), "\(row.model) tools=\(row.tools)")
                XCTAssertEqual(r.effective, .level(row.level), "\(row.model) tools=\(row.tools)")
                XCTAssertEqual(r.reason, row.reason, "\(row.model) tools=\(row.tools)")
            }
        }
    }

    func testGemini3ExplicitLevelIsTheNearestTheModelTakes() {
        typealias Row = (model: String, requested: ReasoningEffort, sent: ReasoningEffort)
        let rows: [Row] = [
            // No Gemini 3 model switches thinking off: None is the lowest level it takes.
            ("gemini-3.5-flash-lite", .none, .minimal),
            ("gemini-3.6-flash", .none, .minimal),
            ("gemini-3.8-flash", .none, .low),
            ("gemini-3.8-flash", .minimal, .low),
            ("gemini-3.8-flash", .low, .low),
            ("gemini-3.8-flash", .medium, .medium),
            ("gemini-3.8-flash", .high, .high),
            ("gemini-3.8-flash", .xhigh, .high),
            ("gemini-3.6-flash", .minimal, .minimal),
            ("gemini-3.5-flash-lite", .medium, .medium),
            ("gemini-3.1-pro-preview", .minimal, .low),
            // 3 Pro takes low and high only; a tie goes down.
            ("gemini-3-pro-preview", .medium, .low),
            ("gemini-3-pro-preview", .xhigh, .high),
            // An unlisted Gemini 3 id is kept to the two levels every listed chat model takes.
            ("gemini-3.9-flash", .minimal, .low),
            ("gemini-3.9-flash", .medium, .low),
            ("gemini-3.9-flash", .high, .high),
            ("gemini-4-flash", .none, .low),
        ]
        for row in rows {
            for tools in [true, false] {
                let r = resolve(.gemini, row.model, tools: tools, row.requested)
                XCTAssertEqual(r.wire, .geminiThinkingLevel(row.sent), "\(row.model) \(row.requested)")
                XCTAssertEqual(r.effective, .level(row.sent), "\(row.model) \(row.requested)")
                XCTAssertEqual(r.reason, row.sent == row.requested ? .asSet : .adjustedToAccepted,
                               "\(row.model) \(row.requested)")
            }
        }
    }

    /// The two controls are never sent together (a 400), a Gemini 3 model is never sent a budget,
    /// and a level the model refuses never reaches the wire.
    func testGeminiRequestCarriesOneThinkingControlTheModelAccepts() {
        let accepted: [String: Set<String>] = [
            "gemini-3.8-flash": ["low", "medium", "high"],
            "gemini-3.6-flash": ["minimal", "low", "medium", "high"],
            "gemini-3.5-flash-lite": ["minimal", "low", "medium", "high"],
            "gemini-3.1-flash-lite": ["minimal", "low", "medium", "high"],
            "gemini-3.1-pro-preview": ["low", "medium", "high"],
            "gemini-3-flash-preview": ["minimal", "low", "medium", "high"],
            "gemini-3-pro-preview": ["low", "high"],
        ]
        for (model, levels) in accepted {
            for requested in [ReasoningEffort?.none] + ReasoningEffort.allCases.map(Optional.some) {
                for tools in [true, false] {
                    let config = resolve(.gemini, model, tools: tools, requested)
                        .geminiGenerationConfig(includesTools: tools, configuredMaxTokens: 500)
                    let thinking = config["thinkingConfig"] as? [String: Any]
                    let label = "\(model) \(String(describing: requested)) tools=\(tools)"
                    XCTAssertEqual(thinking?.count, 1, label)
                    XCTAssertNil(thinking?["thinkingBudget"], label)
                    let level = thinking?["thinkingLevel"] as? String
                    XCTAssertTrue(level.map(levels.contains) ?? false, "\(label): \(String(describing: level))")
                }
            }
        }
        for model in ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite", "gemini-2.0-flash"] {
            for requested in [ReasoningEffort?.none] + ReasoningEffort.allCases.map(Optional.some) {
                for tools in [true, false] {
                    let config = resolve(.gemini, model, tools: tools, requested)
                        .geminiGenerationConfig(includesTools: tools, configuredMaxTokens: 500)
                    // `thinkingLevel` on a model before Gemini 3 is an error.
                    XCTAssertNil((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"],
                                 "\(model) \(String(describing: requested))")
                }
            }
        }
    }

    /// The failure: a Gemini 3 model thinks before every answer and thinking shares
    /// `maxOutputTokens` with the reply, so a plain turn capped at the configured 500 tokens could
    /// spend them all thinking. Every turn now leaves the answer its full allowance.
    func testGemini3AllowanceLeavesRoomForTheAnswer() {
        for model in ["gemini-3.5-flash-lite", "gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.1-pro-preview"] {
            for requested in [ReasoningEffort?.none] + ReasoningEffort.allCases.map(Optional.some) {
                let plain = resolve(.gemini, model, tools: false, requested)
                    .geminiBudget(includesTools: false, configuredMaxTokens: 500)
                XCTAssertEqual(plain.answerAllowance, 500, "\(model) \(String(describing: requested))")
                XCTAssertGreaterThanOrEqual(plain.thinkingAllowance, 1_024)
                XCTAssertEqual(plain.maxOutputTokens, plain.thinkingAllowance + 500)

                let tool = resolve(.gemini, model, tools: true, requested)
                    .geminiBudget(includesTools: true, configuredMaxTokens: 500)
                XCTAssertEqual(tool.answerAllowance, GeminiBudgetPolicy.toolTurnMaxOutputTokens)
                // Far under the 64K output limit these models publish.
                XCTAssertLessThanOrEqual(tool.maxOutputTokens, 32_768)
            }
        }
        // The shipped default: Automatic on `gemini-3.5-flash-lite`.
        let auto = resolve(.gemini, LLMProvider.gemini.defaultModel, tools: true, nil)
            .geminiGenerationConfig(includesTools: true, configuredMaxTokens: 500)
        XCTAssertEqual((auto["thinkingConfig"] as? [String: String])?["thinkingLevel"], "low")
        XCTAssertEqual(auto["maxOutputTokens"] as? Int,
                       GeminiBudgetPolicy.thinkingHeadroom(for: .low) + GeminiBudgetPolicy.toolTurnMaxOutputTokens)
    }

    /// One-shot requests size their cap for the answer alone. A Gemini 3 model gets its level and
    /// headroom on top; a 2.x model is sent exactly what it was sent before.
    func testGeminiOneShotConfig() {
        func oneShot(_ model: String, saved: ReasoningEffort?) -> [String: Any] {
            var config = ModelConfig.defaultConfig(for: .gemini)
            config.model = model
            config.reasoningEffort = saved?.rawValue
            return config.oneShotReasoningResolution().geminiOneShotGenerationConfig(maxTokens: 512)
        }
        // A level saved for conversation is not carried into a one-shot, which has a short timeout:
        // the model's lowest level, whatever is saved.
        for saved: ReasoningEffort? in [nil, .high] {
            let lite = oneShot("gemini-3.5-flash-lite", saved: saved)
            XCTAssertEqual((lite["thinkingConfig"] as? [String: String])?["thinkingLevel"], "minimal")
            XCTAssertEqual(lite["maxOutputTokens"] as? Int, GeminiBudgetPolicy.thinkingHeadroom(for: .minimal) + 512)

            let flash = oneShot("gemini-3.8-flash", saved: saved)
            XCTAssertEqual((flash["thinkingConfig"] as? [String: String])?["thinkingLevel"], "low")
            XCTAssertEqual(flash["maxOutputTokens"] as? Int, GeminiBudgetPolicy.thinkingHeadroom(for: .low) + 512)

            let older = oneShot("gemini-2.5-flash", saved: saved)
            XCTAssertEqual(older.count, 1)
            XCTAssertEqual(older["maxOutputTokens"] as? Int, 512)
        }
    }

    // MARK: - Groq gpt-oss: reasons inside the output cap

    /// `openai/gpt-oss-120b` reasons before every answer and that reasoning counts toward
    /// `max_tokens`. Sending nothing left it at the provider's default inside the tool turn's
    /// 1024-token cap, where a reply can come back with no content.
    func testGroqGPTOSSAutomaticSendsLowAndRaisesTheCap() {
        XCTAssertEqual(LLMProvider.groq.defaultModel, "openai/gpt-oss-120b")
        for model in ["openai/gpt-oss-120b", "openai/gpt-oss-20b", " OpenAI/GPT-OSS-120B "] {
            for tools in [true, false] {
                let r = resolve(.groq, model, tools: tools, nil)
                XCTAssertEqual(r.wire, .reasoningEffort(.low), "\(model) tools=\(tools)")
                XCTAssertEqual(r.effective, .level(.low))
                XCTAssertEqual(r.reason, .automaticThinkingModel)
                XCTAssertEqual(body(r)["reasoning_effort"] as? String, "low")
                // The tool turn's 1024 and the plain turn's 500 both clear the floor.
                XCTAssertEqual(r.outputCap(base: 1024), ReasoningPolicy.groqLowEffortOutputFloor)
                XCTAssertEqual(r.outputCap(base: 500), ReasoningPolicy.groqLowEffortOutputFloor)
                XCTAssertEqual(r.outputCap(base: 8000), 8000)
            }
        }
    }

    func testGroqGPTOSSExplicitLevelIsTheNearestAccepted() {
        typealias Row = (requested: ReasoningEffort, sent: ReasoningEffort, cap: Int)
        let rows: [Row] = [
            // `none` and `minimal` are not values these models take.
            (.none, .low, ReasoningPolicy.groqLowEffortOutputFloor),
            (.minimal, .low, ReasoningPolicy.groqLowEffortOutputFloor),
            (.low, .low, ReasoningPolicy.groqLowEffortOutputFloor),
            (.medium, .medium, ReasoningPolicy.reasoningOutputFloor),
            (.high, .high, ReasoningPolicy.reasoningOutputFloor),
            (.xhigh, .high, ReasoningPolicy.reasoningOutputFloor),
        ]
        for row in rows {
            // A learned refusal must not turn into `none`, which these models reject.
            for learned in [false, true] {
                let r = resolve(.groq, "openai/gpt-oss-120b", tools: true, row.requested, learned: learned)
                XCTAssertEqual(r.wire, .reasoningEffort(row.sent), "\(row.requested)")
                XCTAssertEqual(r.reason, row.sent == row.requested ? .asSet : .adjustedToAccepted, "\(row.requested)")
                XCTAssertEqual(r.outputCap(base: 1024), row.cap, "\(row.requested)")
            }
        }
    }

    func testOtherGroqModelsAndOtherHostsAreUntouched() {
        // Not a model the effort setting is documented for.
        for model in ["openai/gpt-oss-safeguard-20b", "llama-3.3-70b-versatile", "qwen/qwen3.8-27b"] {
            let r = resolve(.groq, model, tools: true, nil)
            XCTAssertEqual(r.wire, .omit, model)
            XCTAssertEqual(r.outputCap(base: 1024), 1024, model)
            XCTAssertEqual(resolve(.groq, model, tools: true, .low).wire, .reasoningEffort(.low), model)
        }
        // The same id on another host keeps that host's rule: only an explicit value is sent.
        for provider in [LLMProvider.openrouter, .custom] {
            XCTAssertEqual(resolve(provider, "openai/gpt-oss-120b", tools: true, nil).wire, .omit, "\(provider)")
        }
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
        // Plan GC: GPT-5.5 clamps to `none` with tools on Chat Completions; GPT-5.2 does not.
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: true, .high).outputCap(base: 1024), 1024)
        XCTAssertEqual(resolve(.openai, "gpt-5.2", tools: true, .high).outputCap(base: 1024), 4096)
        // Automatic without tools: the provider default (medium) still reasons.
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: false, nil).outputCap(base: 500), 4096)
        XCTAssertEqual(resolve(.openai, "gpt-4o", tools: false, nil).outputCap(base: 500), 500)
        XCTAssertEqual(resolve(.openai, "gpt-5.5", tools: true, .medium).outputCap(base: 8000), 8000)
    }

    // MARK: - Tokens and the saved setting

    func testTokensAreContentFree() {
        XCTAssertEqual(resolve(.openai, "gpt-6-sol", tools: true, nil).token, "none")
        XCTAssertEqual(resolve(.openai, "gpt-6-sol", tools: false, nil).token, "default-medium")
        XCTAssertEqual(resolve(.anthropic, "claude", tools: true, nil).token, "default")
        XCTAssertEqual(resolve(.anthropic, "claude-sonnet-5-5", tools: true, nil).token, "low")
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

    // MARK: - Plan GC: corrected family table (verified 2026-09-30)

    func testFamilyTableFlags() throws {
        let requireNone = ["gpt-5.4", "gpt-5.4-mini", "gpt-5.5", "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra",
                           "gpt-5.6-luna", "gpt-6-sol", "gpt-6-luna"]
        for model in requireNone {
            let family = try XCTUnwrap(ReasoningPolicy.openAIFamily(model: model), model)
            XCTAssertTrue(family.chatToolsRequireNone, model)
            XCTAssertFalse(family.chatToolsUnavailable, model)
            XCTAssertTrue(family.rejectsReasoningWithToolsOnChat, model)
            XCTAssertEqual(family.accepted, [.none, .low, .medium, .high, .xhigh], model)
        }
        for model in ["gpt-6-astra", "gpt-6.1-sol"] {
            let family = try XCTUnwrap(ReasoningPolicy.openAIFamily(model: model), model)
            XCTAssertTrue(family.chatToolsUnavailable, model)
            XCTAssertFalse(family.chatToolsRequireNone, model)
            XCTAssertTrue(family.rejectsReasoningWithToolsOnChat, model)
            XCTAssertEqual(family.accepted, [.low, .medium, .high, .xhigh], model)
            XCTAssertEqual(family.providerDefault, .medium, model)
        }
        for model in ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.2", "o1", "o3", "o4-mini"] {
            let family = try XCTUnwrap(ReasoningPolicy.openAIFamily(model: model), model)
            XCTAssertFalse(family.rejectsReasoningWithToolsOnChat, model)
        }
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5.4")?.providerDefault, ReasoningEffort.none)
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5.1")?.providerDefault, ReasoningEffort.none)
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5.5")?.providerDefault, .medium)
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5")?.accepted, [.minimal, .low, .medium, .high])
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "o3")?.accepted, [.low, .medium, .high])
        XCTAssertNil(ReasoningPolicy.openAIFamily(model: "gpt-5-chat-latest"))
        XCTAssertNil(ReasoningPolicy.openAIFamily(model: "gpt-4.1"))
    }

    func testDateSuffixedAndUntrimmedIdsMatchTheirFamily() {
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5.5-2026-06-01"),
                       ReasoningPolicy.openAIFamily(model: "gpt-5.5"))
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: " GPT-6-Sol "),
                       ReasoningPolicy.openAIFamily(model: "gpt-6-sol"))
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-6.1-sol-2026-09-01")?.chatToolsUnavailable, true)
        XCTAssertEqual(ReasoningPolicy.openAIFamily(model: "gpt-5.4-mini-2026-03-01")?.providerDefault, ReasoningEffort.none)
    }

    func testGPT55WithToolsOnChatClampsToNoneAtEveryLevel() {
        for requested: ReasoningEffort? in [nil, .low, .medium, .high, .xhigh] {
            let r = resolve(.openai, "gpt-5.5", tools: true, requested)
            XCTAssertEqual(r.wire, .reasoningEffort(.none), "requested \(String(describing: requested))")
        }
    }

    func testGPT6AstraNearestAcceptedNoneIsLow() throws {
        let family = try XCTUnwrap(ReasoningPolicy.openAIFamily(model: "gpt-6-astra"))
        XCTAssertEqual(family.nearestAccepted(.none), .low)
        XCTAssertEqual(family.nearestAccepted(.minimal), .low)
        XCTAssertEqual(family.lowest, .low)
    }

    func testResponsesAutomaticWithToolsUsesLowestOnTheAPIRoute() {
        let astra = ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-astra", route: .responses,
                                            toolsAttached: true, requested: nil)
        XCTAssertEqual(astra.wire, .responsesEffort(.low))
        XCTAssertEqual(astra.effective, .level(.low))
        XCTAssertEqual(astra.reason, .automaticToolTurn)

        let sol = ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-sol", route: .responses,
                                          toolsAttached: true, requested: nil)
        XCTAssertEqual(sol.wire, .responsesEffort(.none))

        // Lowest already the default: nothing sent, effective still the lowest.
        let five4 = ReasoningPolicy.resolve(provider: .openai, model: "gpt-5.4", route: .responses,
                                            toolsAttached: true, requested: nil)
        XCTAssertEqual(five4.wire, .omit)
        XCTAssertEqual(five4.effective, .level(.none))

        // Without tools Automatic still sends nothing.
        let noTools = ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-astra", route: .responses,
                                              toolsAttached: false, requested: nil)
        XCTAssertEqual(noTools.wire, .omit)
        XCTAssertEqual(noTools.effective, .providerDefault(.medium))
    }

    func testResponsesExplicitNoneOnAstraMovesToLow() {
        let r = ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-astra", route: .responses,
                                        toolsAttached: true, requested: "none")
        XCTAssertEqual(r.wire, .responsesEffort(.low))
        XCTAssertEqual(r.reason, .adjustedToAccepted)
    }

    func testChatGPTSubscriptionAutomaticIsUnchangedByPlanGC() {
        // The subscription path is out of Plan GC's scope: Automatic still sends nothing.
        let r = resolve(.chatgpt, "gpt-6-astra", tools: true, nil)
        XCTAssertEqual(r.wire, .omit)
        XCTAssertEqual(r.reason, .automaticProviderDefault)
    }
}
