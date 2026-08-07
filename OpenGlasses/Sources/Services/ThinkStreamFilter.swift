import Foundation

/// Incremental `<think>` suppressor for on-device reasoning models (LFM2.5).
///
/// A reasoning model spends the start of every completion on chain-of-thought. Two wrinkles
/// make a plain regex insufficient on the streaming path:
///  1. **The opening tag never appears in the output.** LFM2.5's chat template emits `<think>`
///     as part of the generation prompt, so the completion is `…reasoning…</think>answer` —
///     the stream begins *inside* the think block (`startsInThink`).
///  2. **Tags straddle chunk boundaries.** The detokenizer can split `</think>` across two
///     chunks (`"</th"` + `"ink>"`), so the filter holds back the shortest suffix that could
///     still become a tag instead of matching per-chunk.
///
/// `ingest(_:)` returns the speakable text of a chunk (usually empty while thinking);
/// `flush()` releases any held-back tail at end of stream. Suppressed text accumulates in
/// `reasoning` for the prompt inspector. Deliberately headless — no MLX import — so the
/// boundary cases are unit-testable.
final class ThinkStreamFilter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var inThink: Bool
    /// Swallow whitespace right after a think block — the answer conventionally starts
    /// after a blank line, which may arrive in a *later* chunk than the close tag.
    private var trimLeadingWhitespace: Bool
    private var pending = ""
    /// Suppressed chain-of-thought, accumulated across the stream.
    private(set) var reasoning = ""

    init(startsInThink: Bool = true) {
        self.inThink = startsInThink
        self.trimLeadingWhitespace = startsInThink
    }

    /// Feed one streamed chunk; returns the part that is speakable *now*.
    func ingest(_ chunk: String) -> String {
        pending += chunk
        var visible = ""
        while true {
            if inThink {
                guard let close = pending.range(of: Self.closeTag) else {
                    // Everything except a possible partial `</think>` at the tail is reasoning.
                    let hold = Self.partialTagSuffixLength(of: pending, tag: Self.closeTag)
                    reasoning += pending.dropLast(hold)
                    pending = String(pending.suffix(hold))
                    return visible
                }
                reasoning += pending[..<close.lowerBound]
                pending = String(pending[close.upperBound...])
                inThink = false
                trimLeadingWhitespace = true
            } else {
                if trimLeadingWhitespace {
                    pending = String(pending.drop(while: \.isWhitespace))
                    if pending.isEmpty { return visible }   // more whitespace may follow next chunk
                    trimLeadingWhitespace = false
                }
                guard let open = pending.range(of: Self.openTag) else {
                    let hold = Self.partialTagSuffixLength(of: pending, tag: Self.openTag)
                    visible += pending.dropLast(hold)
                    pending = String(pending.suffix(hold))
                    return visible
                }
                visible += pending[..<open.lowerBound]
                pending = String(pending[open.upperBound...])
                inThink = true
            }
        }
    }

    /// End of stream: release a held-back tail that never completed into a tag.
    /// (While thinking, a partial tail is reasoning, not speech.)
    func flush() -> String {
        defer { pending = "" }
        if inThink {
            reasoning += pending
            return ""
        }
        return pending
    }

    /// Strip a complete (non-streamed) completion. Returns the speakable text and the
    /// suppressed reasoning (nil when the model emitted no think content).
    static func strip(_ text: String, startsInThink: Bool = true) -> (spoken: String, reasoning: String?) {
        let filter = ThinkStreamFilter(startsInThink: startsInThink)
        var spoken = filter.ingest(text)
        spoken += filter.flush()
        let reasoning = filter.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        return (spoken.trimmingCharacters(in: .whitespacesAndNewlines),
                reasoning.isEmpty ? nil : reasoning)
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag` — the part
    /// that might still grow into the tag on the next chunk and must be held back.
    private static func partialTagSuffixLength(of text: String, tag: String) -> Int {
        let maxLen = min(text.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(len)) { return len }
        }
        return 0
    }
}
