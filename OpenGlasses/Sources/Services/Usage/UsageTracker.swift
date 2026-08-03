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
                cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0, at: Date = Date()) {
        guard tokensIn + tokensOut + cacheWriteTokens + cacheReadTokens > 0 else { return }
        let cost = ModelPricing.estimate(model: model, tokensIn: tokensIn, tokensOut: tokensOut,
                                          cacheWriteTokens: cacheWriteTokens, cacheReadTokens: cacheReadTokens)
        store.insert(UsageRecord(sessionId: sessionId,
                                 provider: provider.rawValue,
                                 model: model,
                                 tokensIn: tokensIn,
                                 tokensOut: tokensOut,
                                 cacheWriteTokens: cacheWriteTokens,
                                 cacheReadTokens: cacheReadTokens,
                                 costUSD: cost,
                                 at: at))
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
        case .anthropic, .chatgpt:   // the Responses backend uses the same input/output_tokens keys
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
            return ParsedUsage(tokensIn: intValue(u["promptTokenCount"]),
                               tokensOut: intValue(u["candidatesTokenCount"]),
                               cacheWriteTokens: 0,
                               cacheReadTokens: intValue(u["cachedContentTokenCount"]),
                               recognized: recognized)
        case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom, .local, .appleOnDevice:
            guard let u = json["usage"] as? [String: Any] else { return nil }
            let recognized = u["prompt_tokens"] != nil || u["completion_tokens"] != nil
            let cachedRead = (u["prompt_tokens_details"] as? [String: Any]).map { intValue($0["cached_tokens"]) } ?? 0
            return ParsedUsage(tokensIn: intValue(u["prompt_tokens"]),
                               tokensOut: intValue(u["completion_tokens"]),
                               cacheWriteTokens: 0,
                               cacheReadTokens: cachedRead,
                               recognized: recognized)
        }
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
