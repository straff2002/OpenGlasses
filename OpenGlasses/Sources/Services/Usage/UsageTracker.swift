import Foundation

/// Shared entry point for the LLM Cost & Usage Tracker (Plan AU): prices token
/// counts via `ModelPricing`, persists a `UsageRecord` to the local `UsageStore`,
/// and answers windowed rollups for `InsightsView`. Local-only — usage never
/// leaves the device.
///
/// `LLMService` parses each provider's usage block (pure, off the main actor) and
/// hands the token counts here; pricing + persistence happen on the main actor.
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    let store: UsageStore

    /// Groups records from one usage "session" (app run / conversation). Rollups are
    /// by model + window, so this is just a grouping tag; reset on conversation clear.
    private(set) var sessionId = UUID().uuidString

    init(store: UsageStore? = nil) {
        self.store = store ?? UsageStore()
    }

    /// Turns where a usage block was present but in an unrecognized shape (e.g. a
    /// provider renamed its fields), so token counts came back 0 and the turn's cost
    /// went untracked. A rising count is the signal to update the parser (Plan BM P3).
    @Published private(set) var untrackedTurns = 0

    /// Start a new usage session (e.g. when the conversation is cleared).
    func startNewSession() { sessionId = UUID().uuidString }

    /// Price and persist one API call's usage, including Anthropic prompt-cache tokens.
    /// No-op when every count is 0.
    func record(provider: LLMProvider, model: String, tokensIn: Int, tokensOut: Int,
                cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0, at: Date = Date(),
                fieldSessionId: String? = nil) {
        guard tokensIn + tokensOut + cacheWriteTokens + cacheReadTokens > 0 else { return }
        // The ChatGPT subscription is not billed per token, so its turns record tokens only —
        // pricing them at the API's list rate would invent a spend (and trip a spend cap).
        let cost = provider == .chatgpt ? nil : ModelPricing.estimate(
            model: model, tokensIn: tokensIn, tokensOut: tokensOut,
            cacheWriteTokens: cacheWriteTokens, cacheReadTokens: cacheReadTokens)
        store.insert(UsageRecord(sessionId: sessionId,
                                 provider: provider.rawValue,
                                 model: model,
                                 tokensIn: tokensIn,
                                 tokensOut: tokensOut,
                                 cacheWriteTokens: cacheWriteTokens,
                                 cacheReadTokens: cacheReadTokens,
                                 costUSD: cost,
                                 at: at,
                                 fieldSessionId: fieldSessionId))
    }

    /// What one Field Assist job has cost so far (Plan GB P5).
    func jobUsage(fieldSessionId: String) -> JobUsageSummary {
        JobUsageSummary.summarise(store.records(fieldSessionId: fieldSessionId), fieldSessionId: fieldSessionId)
    }

    /// Priced spend so far in the day and month containing `now` (spend caps).
    func spend(now: Date = Date(), calendar: Calendar = .current) -> (today: Double, month: Double) {
        (store.spend(since: SpendCapPolicy.Window.day.start(of: now, calendar: calendar)),
         store.spend(since: SpendCapPolicy.Window.month.start(of: now, calendar: calendar)))
    }

    /// Record a usage block whose shape wasn't recognized — nothing to price, but we
    /// count it so silent drift is visible rather than invisible.
    func noteUntrackedTurn() { untrackedTurns += 1 }

    /// Rolled-up tokens + estimated cost over the last `days`.
    func rollup(days: Int, now: Date = Date()) -> UsageRollup.Result {
        store.rollup(days: days, now: now)
    }

    /// Parsed token usage for one call. `recognized` is false when a usage block was
    /// present but carried none of the expected token keys (shape drift).
    struct ParsedUsage: Equatable {
        let tokensIn: Int
        let tokensOut: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let recognized: Bool
    }

    /// Extract token + cache usage from a provider's response JSON, or `nil` when no
    /// usage block is present at all. Pure and `nonisolated` so `LLMService` can call
    /// it on its own async context (the non-Sendable JSON never crosses an actor hop).
    nonisolated static func parseUsage(provider: LLMProvider, json: [String: Any]) -> ParsedUsage? {
        switch provider {
        case .chatgpt:
            // The Responses backend: `input_tokens` **includes** the cached share, which it reports
            // under `input_tokens_details.cached_tokens` (Plan GB P0 — previously ignored).
            guard let u = json["usage"] as? [String: Any] else { return nil }
            return responsesUsage(u)
        case .anthropic:
            // Anthropic's `input_tokens` already excludes both cache counts.
            guard let u = json["usage"] as? [String: Any] else { return nil }
            let recognized = u["input_tokens"] != nil || u["output_tokens"] != nil
                || u["cache_creation_input_tokens"] != nil || u["cache_read_input_tokens"] != nil
            return ParsedUsage(tokensIn: intValue(u["input_tokens"]),
                               tokensOut: intValue(u["output_tokens"]),
                               cacheWriteTokens: intValue(u["cache_creation_input_tokens"]),
                               cacheReadTokens: intValue(u["cache_read_input_tokens"]),
                               recognized: recognized)
        case .gemini, .geminiVertex:   // Vertex returns the same usageMetadata shape
            guard let u = json["usageMetadata"] as? [String: Any] else { return nil }
            let recognized = u["promptTokenCount"] != nil || u["candidatesTokenCount"] != nil
            // `promptTokenCount` includes `cachedContentTokenCount`; record only the uncached rest
            // as input so the cached share is not billed twice (Plan GB P0).
            let cached = intValue(u["cachedContentTokenCount"])
            return ParsedUsage(tokensIn: max(0, intValue(u["promptTokenCount"]) - cached),
                               tokensOut: intValue(u["candidatesTokenCount"]),
                               cacheWriteTokens: 0,
                               cacheReadTokens: cached,
                               recognized: recognized)
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom, .local, .appleOnDevice:
            guard let u = json["usage"] as? [String: Any] else { return nil }
            // Plan GC: the OpenAI API's Responses route reports the Responses shape.
            if u["input_tokens"] != nil && u["prompt_tokens"] == nil {
                return responsesUsage(u)
            }
            let recognized = u["prompt_tokens"] != nil || u["completion_tokens"] != nil
            // `prompt_tokens` includes `prompt_tokens_details.cached_tokens` (Plan GB P0).
            let cachedRead = (u["prompt_tokens_details"] as? [String: Any]).map { intValue($0["cached_tokens"]) } ?? 0
            return ParsedUsage(tokensIn: max(0, intValue(u["prompt_tokens"]) - cachedRead),
                               tokensOut: intValue(u["completion_tokens"]),
                               cacheWriteTokens: 0,
                               cacheReadTokens: cachedRead,
                               recognized: recognized)
        }
    }

    /// The Responses usage shape (the ChatGPT backend, and the OpenAI API's `/v1/responses`).
    /// `input_tokens` **includes** both the cached share (`input_tokens_details.cached_tokens`,
    /// Plan GB P0) and, on GPT-5.6+, the cache-write share (`cache_write_tokens`, Plan GC), so
    /// both are subtracted and priced on their own — nothing is counted twice. Reasoning tokens
    /// sit inside `output_tokens` and bill as output.
    private nonisolated static func responsesUsage(_ u: [String: Any]) -> ParsedUsage {
        let recognized = u["input_tokens"] != nil || u["output_tokens"] != nil
        let details = u["input_tokens_details"] as? [String: Any]
        let cached = details.map { intValue($0["cached_tokens"]) } ?? 0
        let cacheWrite = details.map { intValue($0["cache_write_tokens"]) } ?? 0
        return ParsedUsage(tokensIn: max(0, intValue(u["input_tokens"]) - cached - cacheWrite),
                           tokensOut: intValue(u["output_tokens"]),
                           cacheWriteTokens: cacheWrite,
                           cacheReadTokens: cached,
                           recognized: recognized)
    }

    /// Back-compat convenience: just the `(tokensIn, tokensOut)` pair.
    nonisolated static func parseTokens(provider: LLMProvider, json: [String: Any]) -> (tokensIn: Int, tokensOut: Int)? {
        parseUsage(provider: provider, json: json).map { ($0.tokensIn, $0.tokensOut) }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return 0
    }
}
