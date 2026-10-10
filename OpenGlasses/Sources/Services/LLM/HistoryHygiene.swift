import Foundation

/// Pure hygiene passes over the Anthropic-shaped `[[String: Any]]` conversation history
/// (docs/plans/BF-llm-turn-hygiene.md). No I/O — each function takes a history and returns a
/// cleaned copy so it can be unit-tested against fixture transcripts.
///
/// The three problems it solves, all found by the round-12 audit:
///  1. A `tool_use` block with no matching `tool_result` makes Anthropic reject EVERY later request
///     with a 400 — one malformed or interrupted tool call bricks the whole conversation.
///  2. Full base64 images pile up in history and are re-uploaded (and re-billed) every turn.
///  3. The token estimator counts an image block at the 50-token floor, so image weight never
///     triggers compaction.
enum HistoryHygiene {

    /// A synthetic result inserted for a `tool_use` that never got one.
    static let interruptedToolResult = "Error: tool execution was interrupted; no result was produced."

    /// Placeholder that replaces a pruned image so the turn still reads coherently.
    static let prunedImagePlaceholder = "[earlier photo omitted to save context]"

    // MARK: - Dangling tool_use repair

    /// Ensure every assistant `tool_use` block is answered by a `tool_result` in the immediately
    /// following user turn (Anthropic's required shape). Missing ids — a skipped/malformed block, a
    /// partially-answered turn, or a turn that threw mid-execution — get a synthetic error result
    /// merged into that single following user message, so the request is valid.
    static func repairDanglingToolUse(_ history: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < history.count {
            let message = history[i]
            i += 1
            out.append(message)

            guard (message["role"] as? String) == "assistant",
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            let toolUseIds = blocks
                .filter { $0["type"] as? String == "tool_use" }
                .compactMap { $0["id"] as? String }
            guard !toolUseIds.isEmpty else { continue }

            // Consume the immediately-following user tool_result message if there is one, so all
            // results for this assistant turn land in a single user message.
            var resultBlocks: [[String: Any]] = []
            var answered = Set<String>()
            if i < history.count,
               (history[i]["role"] as? String) == "user",
               let nextBlocks = history[i]["content"] as? [[String: Any]],
               nextBlocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                resultBlocks = nextBlocks
                for block in nextBlocks where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String { answered.insert(id) }
                }
                i += 1   // consume it — we re-emit it (possibly extended) below
            }

            for id in toolUseIds where !answered.contains(id) {
                resultBlocks.append(["type": "tool_result", "tool_use_id": id, "content": interruptedToolResult])
            }
            if !resultBlocks.isEmpty {
                out.append(["role": "user", "content": resultBlocks])
            }
        }
        return out
    }

    // MARK: - Image pruning

    /// Replace the image blocks in all but the newest `keepLast` image-bearing user messages with a
    /// short text placeholder, so old frames stop being re-uploaded every turn. The newest image(s)
    /// and all text are preserved.
    static func pruneImages(_ history: [[String: Any]], keepLast: Int = 1) -> [[String: Any]] {
        // Indices of messages that carry at least one image block, oldest → newest.
        let imageIndices = history.indices.filter { messageHasImage(history[$0]) }
        guard imageIndices.count > keepLast else { return history }
        let pruneUpTo = imageIndices.count - keepLast
        let indicesToPrune = Set(imageIndices.prefix(pruneUpTo))

        var out = history
        for i in indicesToPrune {
            out[i] = stripImages(from: out[i])
        }
        return out
    }

    /// An image block in ANY of the three provider shapes the shared history can hold:
    /// Anthropic (`type: image`), OpenAI-compatible (`type: image_url`), and Gemini
    /// (`inlineData` inside a `parts` array). The prune runs for every provider now, so it
    /// must recognise every shape or old photos silently keep re-uploading on that path.
    private static func isImageBlock(_ block: [String: Any]) -> Bool {
        if let type = block["type"] as? String, type == "image" || type == "image_url" { return true }
        return block["inlineData"] != nil
    }

    private static func messageHasImage(_ message: [String: Any]) -> Bool {
        let blocks = (message["content"] as? [[String: Any]]) ?? (message["parts"] as? [[String: Any]]) ?? []
        return blocks.contains(where: isImageBlock)
    }

    private static func stripImages(from message: [String: Any]) -> [String: Any] {
        let contentKey = message["content"] is [[String: Any]] ? "content"
                       : message["parts"] is [[String: Any]] ? "parts" : nil
        guard let key = contentKey, let blocks = message[key] as? [[String: Any]] else { return message }
        var newBlocks: [[String: Any]] = []
        var replacedAny = false
        for block in blocks {
            if isImageBlock(block) {
                replacedAny = true
            } else {
                newBlocks.append(block)
            }
        }
        if replacedAny {
            // Gemini `parts` use `text` fields directly; content arrays use typed text blocks.
            newBlocks.append(key == "parts" ? ["text": prunedImagePlaceholder]
                                            : ["type": "text", "text": prunedImagePlaceholder])
        }
        var out = message
        out[key] = newBlocks
        return out
    }

    // MARK: - Responses replay items (Plan GC)

    /// Remove the Responses output items an assistant message carries for in-turn replay
    /// (`ResponsesTranslator.rawOutputItemsKey`) from every message. Run when a turn finalises
    /// — the items are kilobytes of opaque ciphertext — and before any Chat Completions body,
    /// which would reject the unknown field. Everything else in each message is left as is.
    static func stripResponsesItems(_ history: [[String: Any]]) -> [[String: Any]] {
        history.map { message in
            guard message[ResponsesTranslator.rawOutputItemsKey] != nil else { return message }
            var out = message
            out.removeValue(forKey: ResponsesTranslator.rawOutputItemsKey)
            return out
        }
    }

    // MARK: - Thinking blocks (Plan IE P2)

    /// What stands in for an assistant message that was nothing but thinking, so the strip never
    /// leaves a message with no content (which the service refuses).
    static let omittedThinkingPlaceholder = "[earlier reasoning omitted]"

    private static func isThinkingBlock(_ block: [String: Any]) -> Bool {
        let type = block["type"] as? String
        return type == "thinking" || type == "redacted_thinking"
    }

    /// Whether any message carries a `thinking` or `redacted_thinking` block.
    static func containsThinking(_ history: [[String: Any]]) -> Bool {
        history.contains { message in
            (message["content"] as? [[String: Any]])?.contains(where: isThinkingBlock) ?? false
        }
    }

    /// Remove every `thinking` and `redacted_thinking` block.
    ///
    /// The invariant this enforces: **history older than the turn in flight never holds a
    /// thinking block.** A block is only valid replayed exactly as received, to the model that
    /// produced it, over the very system prompt, tools and messages it was produced over — and
    /// between turns this app changes all three (the dated tail of the prompt, image pruning, the
    /// history budget, compaction, the active model). Leaving a finished turn's blocks out is
    /// always legal; replaying one over a changed prefix is a 400 on the newest models. So the
    /// strip runs where a new user turn begins, which also covers a turn that was abandoned
    /// half-way, a switch of model, and a loaded conversation.
    ///
    /// Everything else in each message is kept, in order. A message left with no blocks gets a
    /// one-line text placeholder rather than empty content.
    static func stripThinkingBlocks(_ history: [[String: Any]]) -> [[String: Any]] {
        history.map { message in
            guard let blocks = message["content"] as? [[String: Any]],
                  blocks.contains(where: isThinkingBlock) else { return message }
            let kept = blocks.filter { !isThinkingBlock($0) }
            var out = message
            out["content"] = kept.isEmpty
                ? [["type": "text", "text": omittedThinkingPlaceholder]]
                : kept
            return out
        }
    }

    // MARK: - Token estimation

    /// Estimate the token weight of a history, counting image blocks by their base64 payload size
    /// (~1.5k chars per 1k tokens) instead of the flat 50-token floor a text-only estimate applies.
    static func estimatedTokens(_ history: [[String: Any]]) -> Int {
        history.reduce(0) { $0 + estimatedTokens(forMessage: $1) }
    }

    static func estimatedTokens(forMessage message: [String: Any]) -> Int {
        // An OpenAI assistant turn that called tools carries its arguments outside `content`.
        let toolCallTokens = (message["tool_calls"] as? [[String: Any]] ?? []).reduce(0) { total, call in
            let function = call["function"] as? [String: Any] ?? [:]
            let text = (function["name"] as? String ?? "") + (function["arguments"] as? String ?? "")
            return total + max(text.count / 4, 1)
        }
        if let text = message["content"] as? String {
            return max(text.count / 4 + toolCallTokens, 50)
        }
        // Gemini history keeps its turns under `parts`.
        guard let blocks = (message["content"] as? [[String: Any]]) ?? (message["parts"] as? [[String: Any]]) else {
            return max(toolCallTokens, 50)
        }
        var tokens = toolCallTokens
        for block in blocks {
            if let inline = block["inlineData"] as? [String: Any] {
                tokens += imageTokens(base64Length: (inline["data"] as? String ?? "").count)
                continue
            }
            switch block["type"] as? String {
            case "text":
                tokens += max((block["text"] as? String ?? "").count / 4, 1)
            case "image":
                let base64 = (block["source"] as? [String: Any])?["data"] as? String ?? ""
                tokens += imageTokens(base64Length: base64.count)
            case "image_url":
                // Plan GB P5: an OpenAI image block used to fall through to the 1-token default,
                // so a resent ~880 KB photo never moved the estimate at all.
                let url = (block["image_url"] as? [String: Any])?["url"] as? String ?? ""
                let payload = url.range(of: "base64,").map { url[$0.upperBound...].count } ?? 0
                tokens += imageTokens(base64Length: payload)
            case "tool_result":
                if let content = block["content"] as? String {
                    tokens += max(content.count / 4, 1)
                } else if let nested = block["content"] as? [[String: Any]] {
                    tokens += estimatedTokens(forMessage: ["content": nested])
                } else {
                    tokens += 1
                }
            case nil where block["text"] != nil:
                tokens += max((block["text"] as? String ?? "").count / 4, 1)
            default:
                tokens += 1
            }
        }
        return max(tokens, 50)
    }

    /// A JPEG costs roughly base64Bytes / 1500 tokens on Anthropic vision, and OpenAI's tiled
    /// high-detail cost lands in the same range for the app's prepared sizes. An image whose bytes
    /// are not in hand (a URL) still costs something: never less than 85 tokens (a low-detail tile).
    static func imageTokens(base64Length: Int) -> Int {
        max(base64Length / 1500, 85)
    }

    // MARK: - Stale images within a turn (Plan GB P5)

    /// A request copy in which images ride only in the messages after the last assistant turn:
    /// the user's own turn on the first request, a capture tool's photo on the round-trip after
    /// it. An image the model has already answered from is not resent on every tool round-trip.
    static func imagesOnlyAfterLastAssistant(_ history: [[String: Any]]) -> [[String: Any]] {
        guard let lastAssistant = history.lastIndex(where: { ($0["role"] as? String) == "assistant" || ($0["role"] as? String) == "model" }) else {
            return history
        }
        var out = history
        for index in 0...lastAssistant where messageHasImage(out[index]) {
            out[index] = stripImages(from: out[index])
        }
        return out
    }
}
