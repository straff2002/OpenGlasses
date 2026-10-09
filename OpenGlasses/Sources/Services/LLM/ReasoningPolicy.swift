import Foundation

/// How hard a reasoning model thinks before it answers — the value a saved model carries in
/// `ModelConfig.reasoningEffort` (Plan GB P0). `nil` there is **Automatic**.
///
/// The raw values are OpenAI's `reasoning_effort` vocabulary (verified 2026-09-30 against the
/// provider's reasoning guide: "none, minimal, low, medium, high, xhigh", model-dependent). `max`
/// exists on a few models but is deliberately not offered: it is the one setting that can run a
/// voice turn for minutes.
enum ReasoningEffort: String, CaseIterable, Codable, Comparable {
    case none, minimal, low, medium, high, xhigh

    private var rank: Int {
        switch self {
        case .none: return 0
        case .minimal: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .xhigh: return 5
        }
    }

    static func < (lhs: ReasoningEffort, rhs: ReasoningEffort) -> Bool { lhs.rank < rhs.rank }

    /// The editor's label for this level.
    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        }
    }
}

/// Which request shape a turn goes out in. The same model can take reasoning on one route and not
/// on another — that asymmetry is the whole reason this is a parameter and not a lookup.
enum ReasoningRoute: String, Equatable {
    /// OpenAI-style `/chat/completions`: OpenAI and every OpenAI-compatible provider.
    case chatCompletions
    /// The Responses API: the ChatGPT subscription backend, and (Plan GC) OpenAI API tool turns
    /// that carry reasoning — chosen per request by `OpenAIRouteSelector`, not by `route(for:)`.
    case responses
    case anthropicMessages
    case geminiREST
    case geminiLive
    case onDevice

    static func route(for provider: LLMProvider) -> ReasoningRoute {
        switch provider {
        case .anthropic: return .anthropicMessages
        case .chatgpt: return .responses
        case .gemini, .geminiVertex: return .geminiREST
        case .local, .appleOnDevice: return .onDevice
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return .chatCompletions
        }
    }
}

/// Plan GB P0 — the reasoning setting a turn actually sends, and why.
///
/// # The failure this prevents
///
/// Nothing ever sent `reasoning_effort` to OpenAI, so each model's server default applied — and on
/// `gpt-6-sol` that default is rejected over `/v1/chat/completions` whenever function tools are
/// attached ("Function tools with reasoning_effort are not supported … set reasoning_effort to
/// 'none'"). Tools are attached to every Direct-mode turn, and a 400 is terminal in the fallback
/// cascade, so the model could not answer at all.
///
/// # The rule
///
/// Reasoning is set per saved model (decided 2026-09-30). **Automatic** is the default:
/// - Chat Completions with tools → the model's lowest setting (`none` on the GPT-5.1+ and GPT-6
///   families). Reasoning tokens bill as output, and a voice tool turn wants speed.
/// - Chat Completions without tools, and the Responses route without tools → nothing sent: the
///   provider decides.
/// - Responses with tools on the API route (Plan GC) → the model's lowest setting, as on Chat
///   Completions; the ChatGPT subscription route still sends nothing.
/// - Gemini REST → the existing bounded tool-turn budget (`GeminiBudgetPolicy`, CO Item 2).
/// An explicit level is honoured, except that a family which rejects reasoning with tools on Chat
/// Completions is clamped to `none` there, and a level the model does not take moves to the nearest
/// one it does. Plan GC: which *route* an OpenAI API turn takes — so whether the clamp applies at
/// all — is `OpenAIRouteSelector`'s decision; this type resolves the level for the route it is given.
/// Anthropic (Plan IE P3) takes `output_config.effort`, resolved against the model's request
/// contract: at Automatic a model that thinks before every answer is sent `low`, a model that does
/// not is sent nothing; an explicit level is sent as the nearest one the model takes; a model that
/// takes no effort setting is never sent one. Gemini Live stays at 0.
///
/// Pure and table-tested. `LLMService` resolves once per request and applies the result; the model
/// editor shows the same resolution with and without tools, so what the tester reads is what goes
/// over the wire.
enum ReasoningPolicy {

    /// What a known OpenAI reasoning family accepts.
    struct Family: Equatable {
        /// Settings the model takes, lowest first.
        let accepted: [ReasoningEffort]
        /// The server's default when nothing is sent.
        let providerDefault: ReasoningEffort
        /// Chat Completions takes function tools only at effort `none` (GPT-5.4 onwards, per the
        /// provider's migration guide: no tool calling there unless `reasoning_effort` is `none`).
        let chatToolsRequireNone: Bool
        /// Chat Completions takes no function tools at all for this model, at any effort
        /// (`gpt-6-astra`, `gpt-6.1-sol`). Tool turns can only go to the Responses API (Plan GC).
        let chatToolsUnavailable: Bool

        init(accepted: [ReasoningEffort], providerDefault: ReasoningEffort,
             chatToolsRequireNone: Bool = false, chatToolsUnavailable: Bool = false) {
            self.accepted = accepted
            self.providerDefault = providerDefault
            self.chatToolsRequireNone = chatToolsRequireNone
            self.chatToolsUnavailable = chatToolsUnavailable
        }

        /// Chat Completions refuses function tools alongside any reasoning above `none` — either
        /// because tools need `none` there, or because the model takes no tools there at all.
        /// Kept for GB's call sites; Plan GC's route selector reads the two facts separately.
        var rejectsReasoningWithToolsOnChat: Bool { chatToolsRequireNone || chatToolsUnavailable }

        var lowest: ReasoningEffort { accepted.first ?? ReasoningEffort.none }

        /// `requested`, or the nearest accepted level to it (ties go down — cheaper).
        func nearestAccepted(_ requested: ReasoningEffort) -> ReasoningEffort {
            if accepted.contains(requested) { return requested }
            let lower = accepted.last { $0 < requested }
            let higher = accepted.first { $0 > requested }
            return lower ?? higher ?? requested
        }
    }

    /// The OpenAI reasoning family a model id belongs to, or nil for a model that does not reason
    /// (`gpt-4o`, `gpt-4.1`, `gpt-5-chat-latest`).
    ///
    /// Verified 2026-09-30 against the provider's reasoning guide, migration guide and per-model
    /// pages (Plan GC corrected GB's table, which marked only `gpt-6*` as refusing reasoning with
    /// tools on Chat Completions):
    /// - `gpt-6.1*`, `gpt-6-astra*`: `low`…`xhigh` only (`none` is a 400); no tools on Chat
    ///   Completions at all. `gpt-6.1-sol` defaults to `medium`; `gpt-6-astra`'s default is not
    ///   stated by the docs — `medium` is assumed, matching its siblings.
    /// - `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6*`, `gpt-5.5*`: `none`…`xhigh`, default `medium`;
    ///   tools on Chat Completions only at `none`.
    /// - `gpt-5.4*`: the same, but defaults to `none`.
    /// - `gpt-5.1*`, `gpt-5.2*`: `none`…`xhigh`, default `none`; tools with reasoning are fine on
    ///   Chat Completions.
    /// - `gpt-5`, `gpt-5-mini`, `gpt-5-nano`: `minimal`…`high`, default `medium`.
    /// - `o1`, `o3`, `o4`: `low`…`high`, default `medium` (not stated for o3/o4-mini).
    /// The docs also list `max` on several models; it is deliberately not offered (see
    /// `ReasoningEffort`). Matching is by prefix, most specific first, so a dated snapshot
    /// (`gpt-5.5-2026-06-01`) resolves to its family.
    static func openAIFamily(model: String) -> Family? {
        let id = model.lowercased().trimmingCharacters(in: .whitespaces)
        let fullRange: [ReasoningEffort] = [.none, .low, .medium, .high, .xhigh]
        let noNone: [ReasoningEffort] = [.low, .medium, .high, .xhigh]
        if id.hasPrefix("gpt-6.1") || id.hasPrefix("gpt-6-astra") {
            return Family(accepted: noNone, providerDefault: .medium, chatToolsUnavailable: true)
        }
        if id.hasPrefix("gpt-6") {
            // gpt-6-sol, gpt-6-luna (there is no bare `gpt-6` id; an unknown 6.x variant is
            // treated like sol, the conservative side: tools on Chat Completions only at `none`).
            return Family(accepted: fullRange, providerDefault: .medium, chatToolsRequireNone: true)
        }
        if id.hasPrefix("gpt-5.4") {
            return Family(accepted: fullRange, providerDefault: .none, chatToolsRequireNone: true)
        }
        if id.hasPrefix("gpt-5.5") || id.hasPrefix("gpt-5.6") {
            return Family(accepted: fullRange, providerDefault: .medium, chatToolsRequireNone: true)
        }
        if id.hasPrefix("gpt-5.") {
            // gpt-5.1*, gpt-5.2* (and any other 5.x point release the table does not name).
            return Family(accepted: fullRange, providerDefault: .none)
        }
        if id.hasPrefix("gpt-5-chat") { return nil }
        if id.hasPrefix("gpt-5") {
            return Family(accepted: [.minimal, .low, .medium, .high], providerDefault: .medium)
        }
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return Family(accepted: [.low, .medium, .high], providerDefault: .medium)
        }
        return nil
    }

    struct Resolution: Equatable {

        /// What goes on the wire.
        enum Wire: Equatable {
            case omit
            /// Chat Completions: `reasoning_effort`.
            case reasoningEffort(ReasoningEffort)
            /// Responses: `reasoning.effort`.
            case responsesEffort(ReasoningEffort)
            /// Gemini REST: `thinkingConfig.thinkingBudget`, always paired with a raised output cap.
            case geminiThinkingBudget(Int)
            /// Anthropic Messages: `output_config.effort`. Only ever `low`…`xhigh`.
            case anthropicEffort(ReasoningEffort)
        }

        /// What the model will actually do.
        enum Effective: Equatable {
            case level(ReasoningEffort)
            /// Nothing sent; the provider's default applies (nil when we don't know it).
            case providerDefault(ReasoningEffort?)
            /// The model has no reasoning setting at all.
            case notApplicable
        }

        enum Reason: String, Equatable {
            case asSet
            case adjustedToAccepted
            case chatToolsClamp
            case automaticToolTurn
            case automaticProviderDefault
            case automaticGeminiToolBudget
            case learnedRejection
            case notReasoningModel
            case automaticThinkingModel
            case noEffortSetting
            case unrecognisedModel
            case liveSessionOff
            case onDevice

            /// One plain line for the model editor.
            var explanation: String {
                switch self {
                case .asSet: return "As set for this model."
                case .adjustedToAccepted: return "The nearest setting this model accepts."
                case .chatToolsClamp: return "Chat Completions doesn't allow reasoning with tools for this model."
                case .automaticToolTurn: return "Automatic uses this model's lowest setting when tools are attached, to keep answers quick."
                case .automaticProviderDefault: return "Automatic sends nothing, so the provider's default applies."
                case .automaticGeminiToolBudget: return "Automatic gives tool turns a small thinking budget."
                case .learnedRejection: return "The provider refused reasoning with tools for this model earlier."
                case .notReasoningModel: return "This model has no reasoning setting."
                case .automaticThinkingModel: return "Automatic keeps a model that thinks before every answer at its lowest effort, to keep answers quick."
                case .noEffortSetting: return "This model doesn't take an effort setting, so nothing is sent."
                case .unrecognisedModel: return "The app doesn't know this model yet, so it sends no effort setting and the provider's default applies."
                case .liveSessionOff: return "Live voice sessions don't use reasoning."
                case .onDevice: return "On-device models don't have this setting."
                }
            }
        }

        let wire: Wire
        let effective: Effective
        let reason: Reason

        /// Content-free token for the trace and the privacy log: `none`, `medium`, `default`,
        /// `default-medium`, `na`.
        var token: String {
            switch effective {
            case .level(let level): return level.rawValue
            case .providerDefault(let level?): return "default-\(level.rawValue)"
            case .providerDefault(nil): return "default"
            case .notApplicable: return "na"
            }
        }

        /// The editor's readout: "None", "Medium (provider default)", "Not applicable".
        var displayValue: String {
            switch effective {
            case .level(let level): return level.label
            case .providerDefault(let level?): return "\(level.label) (provider default)"
            case .providerDefault(nil): return "Provider default"
            case .notApplicable: return "Not applicable"
            }
        }

        /// Whether reasoning tokens will be drawn from the output allowance.
        var reasonsAboveNone: Bool {
            switch effective {
            case .level(let level): return level > .none
            case .providerDefault(let level?): return level > .none
            case .providerDefault(nil), .notApplicable: return false
            }
        }

        /// CO Item 2 — a reasoning budget always comes with room for the answer. When the model
        /// will reason, the output cap is raised to at least `reasoningOutputFloor`; otherwise
        /// reasoning spends the 1024-token tool-turn cap and the completion comes back empty.
        func outputCap(base: Int) -> Int {
            reasonsAboveNone ? max(base, ReasoningPolicy.reasoningOutputFloor) : base
        }

        /// Merge this resolution into a Chat Completions, Responses or Anthropic Messages body.
        /// Gemini's budget is applied through `geminiGenerationConfig`, not here.
        func apply(to body: inout [String: Any]) {
            switch wire {
            case .omit, .geminiThinkingBudget: return
            case .reasoningEffort(let level): body["reasoning_effort"] = level.rawValue
            case .responsesEffort(let level): body["reasoning"] = ["effort": level.rawValue]
            case .anthropicEffort(let level): body["output_config"] = ["effort": level.rawValue]
            }
        }

        /// The Gemini REST `generationConfig`: an explicit budget with the answer's allowance on
        /// top of it, or `GeminiBudgetPolicy`'s shipped behaviour for Automatic.
        func geminiGenerationConfig(includesTools: Bool, configuredMaxTokens: Int) -> [String: Any] {
            guard case .geminiThinkingBudget(let budget) = wire else {
                return GeminiBudgetPolicy.generationConfig(includesTools: includesTools,
                                                           configuredMaxTokens: configuredMaxTokens)
            }
            let answer = includesTools ? GeminiBudgetPolicy.toolTurnMaxOutputTokens : configuredMaxTokens
            return ["maxOutputTokens": budget + answer,
                    "thinkingConfig": ["thinkingBudget": budget]]
        }
    }

    /// Output-token floor for a turn that reasons (plan: "at least 4096").
    static let reasoningOutputFloor = 4_096

    /// Gemini thinking budgets per level. Bounded at every level (CO Item 2): the largest is far
    /// under any Gemini model's output ceiling.
    static func geminiThinkingBudget(_ level: ReasoningEffort, model: String) -> Int {
        switch level {
        // Pro models cannot switch thinking off; 128 is their floor.
        case .none: return model.lowercased().contains("-pro") ? 128 : 0
        case .minimal: return 128
        case .low: return 512
        case .medium: return 2_048
        case .high: return 8_192
        case .xhigh: return 16_384
        }
    }

    /// Resolve the setting for one request.
    ///
    /// - Parameters:
    ///   - requested: the saved `ModelConfig.reasoningEffort` raw value; nil or unrecognised is
    ///     Automatic.
    ///   - learnedToolRejection: the provider already refused reasoning with tools for this model in
    ///     this app run (`ReasoningRejectionClassifier`), so it is treated as a rejecting family.
    static func resolve(provider: LLMProvider, model: String, route: ReasoningRoute,
                        toolsAttached: Bool, requested: String?,
                        learnedToolRejection: Bool = false) -> Resolution {
        let explicit = requested.flatMap(ReasoningEffort.init(rawValue:))
        switch route {
        case .onDevice:
            return Resolution(wire: .omit, effective: .notApplicable, reason: .onDevice)
        case .geminiLive:
            return Resolution(wire: .omit, effective: .level(.none), reason: .liveSessionOff)
        case .anthropicMessages:
            return resolveAnthropic(model: model, explicit: explicit)
        case .geminiREST:
            guard let explicit else {
                return toolsAttached
                    ? Resolution(wire: .omit, effective: .level(.low), reason: .automaticGeminiToolBudget)
                    : Resolution(wire: .omit, effective: .providerDefault(nil), reason: .automaticProviderDefault)
            }
            let budget = geminiThinkingBudget(explicit, model: model)
            let adjusted = explicit == .none && budget > 0
            return Resolution(wire: .geminiThinkingBudget(budget),
                              effective: .level(adjusted ? .minimal : explicit),
                              reason: adjusted ? .adjustedToAccepted : .asSet)
        case .responses:
            let family = openAIFamily(model: model)
            guard let explicit else {
                // Plan GC: on the API route a tool turn at Automatic reasons as little as the
                // model allows — only models that take no tools on Chat Completions reach here
                // at Automatic (`OpenAIRouteSelector`), and `low` is the cheapest they answer at.
                // The ChatGPT subscription route keeps its shipped behaviour (nothing sent).
                if toolsAttached, provider != .chatgpt, let family {
                    let lowest = family.lowest
                    let wire: Resolution.Wire = lowest == family.providerDefault ? .omit : .responsesEffort(lowest)
                    return Resolution(wire: wire, effective: .level(lowest), reason: .automaticToolTurn)
                }
                return Resolution(wire: .omit, effective: .providerDefault(family?.providerDefault),
                                  reason: .automaticProviderDefault)
            }
            let level = family?.nearestAccepted(explicit) ?? explicit
            return Resolution(wire: .responsesEffort(level), effective: .level(level),
                              reason: level == explicit ? .asSet : .adjustedToAccepted)
        case .chatCompletions:
            return resolveChat(provider: provider, model: model, toolsAttached: toolsAttached,
                               explicit: explicit, learnedToolRejection: learnedToolRejection)
        }
    }

    /// The effort an Anthropic request carries (Plan IE P3), from the model's request contract.
    ///
    /// Effort is the only control sent. `thinking: disabled`, a thinking budget and the
    /// between-tools switch are each refused by some current model, and none of them is needed:
    /// lowering effort is what every model that thinks by default accepts.
    ///
    /// - Automatic on a model that thinks by default → `low`. Left alone, such a model thinks at
    ///   its own default before almost every spoken reply; a voice turn wants the answer.
    /// - Automatic on a model that does not think unless asked → nothing sent.
    /// - An explicit level → that level, or the nearest the model takes. The app's `none` and
    ///   `minimal` have no Anthropic equivalent and become `low`; `max` is never chosen.
    /// - A model that takes no effort setting, or one the table does not know → nothing sent.
    private static func resolveAnthropic(model: String, explicit: ReasoningEffort?) -> Resolution {
        let contract = AnthropicModelContract.contract(for: model)
        // The levels this model takes, in the app's vocabulary. `max` has no case there on purpose.
        let accepted = contract.effortLevels.compactMap { ReasoningEffort(rawValue: $0.rawValue) }
        guard !accepted.isEmpty else {
            return Resolution(wire: .omit,
                              effective: contract.thinksByDefault ? .providerDefault(nil) : .notApplicable,
                              reason: contract.isKnownModel ? .noEffortSetting : .unrecognisedModel)
        }
        guard let explicit else {
            guard contract.thinksByDefault else {
                return Resolution(wire: .omit, effective: .providerDefault(nil), reason: .automaticProviderDefault)
            }
            let lowest = accepted[0]
            return Resolution(wire: .anthropicEffort(lowest), effective: .level(lowest),
                              reason: .automaticThinkingModel)
        }
        let level = Family(accepted: accepted, providerDefault: accepted[0]).nearestAccepted(explicit)
        return Resolution(wire: .anthropicEffort(level), effective: .level(level),
                          reason: level == explicit ? .asSet : .adjustedToAccepted)
    }

    private static func resolveChat(provider: LLMProvider, model: String, toolsAttached: Bool,
                                    explicit: ReasoningEffort?, learnedToolRejection: Bool) -> Resolution {
        guard provider == .openai else {
            // Custom, OpenRouter, Mistral, xAI and the rest: we cannot know what each accepts, so
            // only an explicit value is sent. A refusal is caught by the classifier's one retry.
            guard let explicit else {
                return Resolution(wire: .omit, effective: .providerDefault(nil), reason: .automaticProviderDefault)
            }
            if toolsAttached && learnedToolRejection {
                return Resolution(wire: .reasoningEffort(.none), effective: .level(.none), reason: .learnedRejection)
            }
            return Resolution(wire: .reasoningEffort(explicit), effective: .level(explicit), reason: .asSet)
        }
        guard let family = openAIFamily(model: model) else {
            // Sending `reasoning_effort` to a non-reasoning model is itself a 400.
            return Resolution(wire: .omit, effective: .notApplicable, reason: .notReasoningModel)
        }
        if toolsAttached {
            if family.rejectsReasoningWithToolsOnChat || learnedToolRejection {
                let reason: Resolution.Reason = family.rejectsReasoningWithToolsOnChat ? .chatToolsClamp : .learnedRejection
                return Resolution(wire: .reasoningEffort(.none), effective: .level(.none),
                                  reason: explicit == ReasoningEffort.none ? .asSet : reason)
            }
            guard let explicit else {
                let lowest = family.lowest
                // A model whose default already is its lowest gets nothing sent (open question 4).
                let wire: Resolution.Wire = lowest == family.providerDefault ? .omit : .reasoningEffort(lowest)
                return Resolution(wire: wire, effective: .level(lowest), reason: .automaticToolTurn)
            }
            let level = family.nearestAccepted(explicit)
            return Resolution(wire: .reasoningEffort(level), effective: .level(level),
                              reason: level == explicit ? .asSet : .adjustedToAccepted)
        }
        guard let explicit else {
            return Resolution(wire: .omit, effective: .providerDefault(family.providerDefault),
                              reason: .automaticProviderDefault)
        }
        let level = family.nearestAccepted(explicit)
        return Resolution(wire: .reasoningEffort(level), effective: .level(level),
                          reason: level == explicit ? .asSet : .adjustedToAccepted)
    }
}

/// Recognises the provider's "reasoning with function tools is not supported" 400, so a model
/// missing from `ReasoningPolicy`'s table gets one retry at `none` instead of dead-ending in the
/// fallback cascade (where a 400 is terminal). Pure: status and message in, verdict out.
enum ReasoningRejectionClassifier {
    static func isReasoningWithToolsRejection(status: Int, message: String?) -> Bool {
        guard status == 400, let text = message?.lowercased() else { return false }
        guard text.contains("reasoning_effort") || text.contains("reasoning effort") else { return false }
        return text.contains("tool") || text.contains("not supported")
    }

    /// Whether a retry at `none` could change anything: it would not if `none` was already sent.
    static func shouldRetry(status: Int, message: String?, sentEffort: String?) -> Bool {
        isReasoningWithToolsRejection(status: status, message: message) && sentEffort != ReasoningEffort.none.rawValue
    }
}
