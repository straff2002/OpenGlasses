import CryptoKit
import Foundation

/// Plan GB P5 — the Direct-mode system prompt as a **stable head** and a **volatile tail**, so the
/// provider's prompt cache can reuse the head turn after turn.
///
/// # Why
///
/// The field tester's bill was 97% input at a 33% cache hit rate. Provider prompt caches match a
/// byte-identical *prefix*, and ours broke early: the image instructions, memory, the date and time
/// to the minute, location, voice skills and the manual passages all sat in the middle of the system
/// prompt, ahead of the history, so every turn's prefix diverged a few hundred tokens in. Here the
/// head carries only what does not change between turns — persona, vision guidance, tool guidance,
/// the safety policy — and the tail carries the rest and is sent **after** the history where the
/// request shape allows (OpenAI: a trailing system message; Anthropic: a second, uncached system
/// block). Other providers get `combined`, head first, which still lets a prefix cache reach
/// further than before.
///
/// Pure: the builder hands over the assembled prompt and the byte offset where the head ends.
struct PromptLayout: Equatable {
    /// Byte-stable across turns of one conversation (given the same classifier sections).
    let stable: String
    /// Everything that may change turn to turn. Empty when there is nothing volatile.
    let volatile: String

    /// The single-string prompt for routes that take one system prompt: head, then tail.
    var combined: String { stable + volatile }

    /// Split an assembled prompt. `prompt` is the head (its first `stableHeadBytes` UTF-8 bytes),
    /// then the volatile blocks, then `trailingStable` — text appended last by the builder that
    /// belongs with the head (the safety policy). The builder keeps the policy last in code so the
    /// prompt's source order stays as reviewed; the layout moves it up.
    static func split(_ prompt: String, stableHeadBytes: Int, trailingStable: String) -> PromptLayout {
        let bytes = Array(prompt.utf8)
        let headEnd = min(max(0, stableHeadBytes), bytes.count)
        var tailEnd = bytes.count
        if prompt.hasSuffix(trailingStable), bytes.count - trailingStable.utf8.count >= headEnd {
            tailEnd = bytes.count - trailingStable.utf8.count
        }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        let tail = String(decoding: bytes[headEnd..<tailEnd], as: UTF8.self)
        let trailing = tailEnd < bytes.count ? trailingStable : ""
        return PromptLayout(stable: head + trailing, volatile: tail)
    }

    /// Chat Completions messages: the stable head first, the history, then the volatile tail as a
    /// trailing system message — the one position that leaves the whole conversation cacheable.
    static func chatMessages(stable: String, history: [[String: Any]], volatile: String?) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": stable]]
        messages.append(contentsOf: history)
        if let volatile, !volatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": volatile.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return messages
    }

    /// Anthropic `system` blocks: the cache breakpoint sits on the stable head, which (with the
    /// tools ahead of it) is the prefix every turn shares; the volatile tail follows uncached.
    static func anthropicSystem(stable: String, volatile: String?) -> [[String: Any]] {
        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": stable,
            "cache_control": ["type": "ephemeral"],
        ]]
        if let volatile, !volatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(["type": "text", "text": volatile.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return blocks
    }
}

/// A short digest of what a request's cacheable prefix is made of: the model, the stable head and
/// the tool schemas. Two turns with the same digest share their prefix byte for byte; the digest is
/// also OpenAI's `prompt_cache_key`, which routes requests with the same prefix to the same cache.
/// The key is a hash — it carries none of the prompt's text.
enum PromptPrefixDigest {
    static func digest(model: String, stable: String, tools: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(model.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(stable.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: tools)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `prompt_cache_key` for a request: a fixed prefix and the first 32 hex digits of the digest.
    static func cacheKey(model: String, stable: String, tools: Data) -> String {
        "og-" + digest(model: model, stable: stable, tools: tools).prefix(32)
    }
}
