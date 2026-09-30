import Foundation

/// Per-model API pricing (USD per 1M tokens) for the LLM Cost & Usage Tracker (Plan AU).
///
/// Pure: a bundled default table (which inevitably drifts) plus runtime `overrides`,
/// matched by longest model-id prefix so dated variants (`claude-opus-4-8`,
/// `gpt-4o-2024-…`) resolve to their family. An unknown/unpriced model yields `nil`
/// — the tracker reports tokens and omits the dollar figure rather than guessing.
///
/// NOTE — realtime voice: the OpenAI/Gemini realtime models bill audio input/output at
/// **audio token rates**, which these text rates don't capture. For a realtime session
/// the token *counts* are right but the dollar estimate is a text-rate approximation
/// (an undercount) — treat realtime cost as indicative, not exact.
enum ModelPricing {

    struct Rate: Equatable, Codable {
        let inputPer1M: Double
        let outputPer1M: Double
        /// The provider's published cached-input rate, when it differs from the generic
        /// `cacheReadMultiplier` (Plan GB P0: `gpt-6.1-sol` caches at 0.05× input, not 0.1×).
        /// Optional so overrides saved before the field decode unchanged.
        let cachedInputPer1M: Double?
        init(_ inputPer1M: Double, _ outputPer1M: Double, cached cachedInputPer1M: Double? = nil) {
            self.inputPer1M = inputPer1M
            self.outputPer1M = outputPer1M
            self.cachedInputPer1M = cachedInputPer1M
        }
    }

    /// Bundled defaults. Keys are matched as lowercased prefixes of the model id,
    /// longest match wins (so `gpt-4o-mini` beats `gpt-4o`). Representative public
    /// list prices at time of writing; override from Settings when they change.
    static let defaults: [String: Rate] = [
        // Anthropic
        "claude-fable-5": Rate(10, 50),
        "claude-opus-4-8": Rate(5, 25),
        "claude-opus-4-7": Rate(5, 25),
        "claude-opus-4-6": Rate(5, 25),
        "claude-opus-4": Rate(15, 75),
        "claude-sonnet-5": Rate(3, 15),
        "claude-sonnet-4": Rate(3, 15),
        "claude-haiku-4": Rate(1, 5),
        "claude-3-5-sonnet": Rate(3, 15),
        "claude-3-5-haiku": Rate(0.80, 4),
        "claude-3-opus": Rate(15, 75),
        "claude-3-haiku": Rate(0.25, 1.25),
        // OpenAI — the GPT-5.x / GPT-6 rows were read off the provider's published price list on
        // 2026-09-30 (standard tier: input / cached input / output per 1M). `gpt-5.5` also matches
        // the field tester's bill ($5 / $0.50 / $30). A family member missing here (a `-pro`
        // variant, a new point release) stays unpriced rather than borrowing a sibling's rate.
        "gpt-6-astra": Rate(10, 50, cached: 1.00),
        "gpt-6-sol": Rate(2, 10, cached: 0.20),
        "gpt-6-luna": Rate(0.10, 0.50, cached: 0.01),
        "gpt-6.1-sol": Rate(2, 10, cached: 0.10),
        "gpt-5.6-sol": Rate(4, 20, cached: 0.40),
        "gpt-5.6-terra": Rate(2, 12, cached: 0.20),
        "gpt-5.6-luna": Rate(0.20, 1.20, cached: 0.02),
        "gpt-5.5": Rate(5, 30, cached: 0.50),
        "gpt-5.4": Rate(2.50, 15, cached: 0.25),
        "gpt-5.4-mini": Rate(0.75, 4.50, cached: 0.075),
        "gpt-5.4-nano": Rate(0.20, 1.25, cached: 0.02),
        "gpt-5.2": Rate(1.75, 14, cached: 0.175),
        "gpt-5.1": Rate(1.25, 10, cached: 0.125),
        "gpt-5": Rate(1.25, 10, cached: 0.125),
        "gpt-5-mini": Rate(0.25, 2, cached: 0.025),
        "gpt-5-nano": Rate(0.05, 0.40, cached: 0.005),
        "gpt-4o-mini": Rate(0.15, 0.60),
        "gpt-4o": Rate(2.50, 10),
        "gpt-4.1-mini": Rate(0.40, 1.60),
        "gpt-4.1": Rate(2, 8),
        "gpt-4-turbo": Rate(10, 30),
        "gpt-4": Rate(30, 60),
        "o4-mini": Rate(1.10, 4.40),
        "o3-mini": Rate(1.10, 4.40),
        // xAI
        "grok-4-fast": Rate(0.20, 0.50),
        "grok-4": Rate(3, 15),
        "grok-3-mini": Rate(0.30, 0.50),
        "grok-3": Rate(3, 15),
        // Google
        "gemini-2.0-flash": Rate(0.10, 0.40),
        "gemini-1.5-flash": Rate(0.075, 0.30),
        "gemini-1.5-pro": Rate(1.25, 5),
        "gemini-pro": Rate(0.50, 1.50),
    ]

    /// Runtime overrides (e.g. from a Settings editor), merged over `defaults` and
    /// taking precedence on key collision. Injectable for tests.
    static var overrides: [String: Rate] = [:]

    /// Anthropic prompt-cache multipliers over the base **input** rate (5-minute TTL):
    /// a cache *write* costs ≈1.25× input, a cache *read* ≈0.1×. Named (not inlined)
    /// so the cost math isn't magic, and calibrated to Anthropic — the dominant cache
    /// consumer post-BF `cache_control`. Other providers' read discounts differ; a read
    /// billed at 0.1× is a safe floor (never overstates cost).
    static let cacheWriteMultiplier = 1.25
    static let cacheReadMultiplier = 0.10

    /// The rate for a model, or `nil` if neither overrides nor defaults price it.
    /// Exact id wins; otherwise the longest key that is a prefix followed by a **dated
    /// snapshot** suffix (`-20260101`, `-2024-08-06`, `@…`) resolves to its family. A
    /// bare version bump like `claude-opus-4-9` is deliberately NOT absorbed by the
    /// `claude-opus-4` family — it yields `nil` (report tokens, omit dollars) rather
    /// than silently billing a future model at an older family's rate.
    static func rate(for model: String) -> Rate? {
        let id = model.lowercased()
        let table = defaults.merging(overrides) { _, override in override }
        if let exact = table[id] { return exact }
        let match = table.keys
            .filter { id.hasPrefix($0) && isSnapshotSuffix(String(id.dropFirst($0.count))) }
            .max(by: { $0.count < $1.count })
        return match.flatMap { table[$0] }
    }

    /// A remainder is a dated-snapshot suffix — a `-`/`@`/`:` boundary carrying a date
    /// (≥6 digits, e.g. `20260101` or `2024-08-06`). Short version tails (`-9`, `-002`)
    /// are not snapshots, so an unknown family-version bump stays unpriced.
    private static func isSnapshotSuffix(_ remainder: String) -> Bool {
        guard let first = remainder.first, first == "-" || first == "@" || first == ":" else { return false }
        return remainder.filter(\.isNumber).count >= 6
    }

    /// Estimated USD cost for a call, or `nil` if the model is unpriced. Zero tokens
    /// at a known rate is `0` (priced, just free), distinct from `nil` (unpriced).
    /// Cache-creation and cache-read tokens are separate input-side counts, **excluded from
    /// `tokensIn`** on every provider: Anthropic reports them that way, and `UsageTracker`
    /// subtracts the cached share from OpenAI's and Gemini's prompt counts, which include it
    /// (Plan GB P0 — the double count overstated cost by 10% of cached tokens). A cache read is
    /// priced at the model's published cached rate, else off the input rate via the multiplier.
    static func estimate(model: String, tokensIn: Int, tokensOut: Int,
                         cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let perToken = rate.inputPer1M / 1_000_000
        let input = Double(max(0, tokensIn)) / 1_000_000 * rate.inputPer1M
        let output = Double(max(0, tokensOut)) / 1_000_000 * rate.outputPer1M
        let cacheWrite = Double(max(0, cacheWriteTokens)) * perToken * cacheWriteMultiplier
        let cacheReadPerToken = rate.cachedInputPer1M.map { $0 / 1_000_000 } ?? perToken * cacheReadMultiplier
        let cacheRead = Double(max(0, cacheReadTokens)) * cacheReadPerToken
        return input + output + cacheWrite + cacheRead
    }
}
