import Foundation

/// Accumulates token usage across a streamed (SSE) LLM response (Plan AU follow-up).
/// The non-streaming paths read a single `usage` block; streaming splits it across
/// events — Anthropic reports input on `message_start` and a running output on each
/// `message_delta`; OpenAI-compatible servers emit a final chunk carrying `usage`
/// (only when the request asked for `stream_options.include_usage`). Pure +
/// headless-testable; the SSE reconstructors feed it each decoded event.
struct StreamingUsageAccumulator {
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    /// Anthropic prompt-cache counts, reported once on `message_start` (OpenAI-compatible
    /// servers put cached reads in the final chunk's `prompt_tokens_details`).
    private(set) var cacheWriteTokens = 0
    private(set) var cacheReadTokens = 0

    var hasUsage: Bool { tokensIn + tokensOut + cacheWriteTokens + cacheReadTokens > 0 }

    /// Feed one decoded Anthropic stream event.
    mutating func consumeAnthropic(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_start":
            if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                tokensIn = max(tokensIn, Self.int(usage["input_tokens"]))
                tokensOut = max(tokensOut, Self.int(usage["output_tokens"]))
                cacheWriteTokens = max(cacheWriteTokens, Self.int(usage["cache_creation_input_tokens"]))
                cacheReadTokens = max(cacheReadTokens, Self.int(usage["cache_read_input_tokens"]))
            }
        case "message_delta":
            // Output is cumulative across deltas — keep the largest seen.
            if let usage = event["usage"] as? [String: Any] {
                tokensOut = max(tokensOut, Self.int(usage["output_tokens"]))
            }
        default:
            break
        }
    }

    /// Feed one decoded OpenAI-compatible stream chunk. Only the final chunk (empty
    /// `choices`) carries `usage`; earlier content chunks are ignored here.
    mutating func consumeOpenAI(_ chunk: [String: Any]) {
        guard let usage = chunk["usage"] as? [String: Any] else { return }
        tokensOut = max(tokensOut, Self.int(usage["completion_tokens"]))
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            cacheReadTokens = max(cacheReadTokens, Self.int(details["cached_tokens"]))
        }
        // `prompt_tokens` includes the cached share; keep only the uncached rest as input so
        // `ModelPricing` doesn't bill cached tokens twice (Plan GB P0).
        tokensIn = max(tokensIn, max(0, Self.int(usage["prompt_tokens"]) - cacheReadTokens))
    }

    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return 0
    }
}
