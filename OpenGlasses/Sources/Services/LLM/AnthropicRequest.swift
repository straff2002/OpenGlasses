import Foundation

/// The body of every Anthropic `/v1/messages` request the app sends, and how its reply is read
/// (Plan IE P1).
///
/// Five call sites used to build their own dictionary: the summariser, the one-shot frame
/// analysis, structured vision and its text sibling, and the conversation turn. Each knew a
/// different subset of what the model accepts, and two of them forced a tool choice the newest
/// models refuse. They now all come through `body`, which asks `AnthropicModelContract` what this
/// model takes — so the rules live in one place, and a parameter no model takes any more
/// (a sampling setting, a thinking budget, `thinking: disabled`) has no way in at all.
///
/// Pure: dictionaries in, a dictionary out. The caller serialises, and keeps `.sortedKeys` where
/// it relies on byte-stable bodies for the prompt cache.
enum AnthropicRequest {

    /// The `system` field: one string for the one-shot calls, typed blocks (with their cache
    /// breakpoint) for the conversation turn.
    enum System {
        case text(String)
        case blocks([[String: Any]])
    }

    /// The single tool a structured call wants its answer through.
    struct AnswerTool {
        let name: String
        let description: String
        let schema: [String: Any]

        /// The sentence that stands in for a forced tool choice on a model that refuses one.
        var instruction: String {
            "Give your answer by calling the `\(name)` tool, exactly once. Do not answer in plain text."
        }
    }

    /// Build a request body.
    /// - Parameters:
    ///   - maxTokens: the app's own ceiling for this call; raised for a model that thinks by
    ///     default (`AnthropicModelContract.outputCap`).
    ///   - tools: the conversation turn's tool definitions, already carrying their cache
    ///     breakpoint. Ignored when `answerTool` is given.
    ///   - answerTool: a structured call's one tool. Forced where the model allows it; otherwise
    ///     `tool_choice` is `auto`, the tool is `strict` when its schema qualifies, and the system
    ///     text gains an instruction naming the tool.
    ///   - reasoning: what `ReasoningPolicy` resolved for this model; contributes
    ///     `output_config.effort` or nothing.
    static func body(model: String, maxTokens: Int, system: System, messages: [[String: Any]],
                     tools: [[String: Any]]? = nil, answerTool: AnswerTool? = nil,
                     reasoning: ReasoningPolicy.Resolution, stream: Bool = false) -> [String: Any] {
        let contract = AnthropicModelContract.contract(for: model)
        let mustAskInWords = answerTool != nil && !contract.allowsForcedToolChoice

        var body: [String: Any] = [
            "model": model,
            "max_tokens": contract.outputCap(base: maxTokens),
            "messages": messages,
        ]

        switch system {
        case .text(let text):
            body["system"] = mustAskInWords ? text + "\n\n" + (answerTool?.instruction ?? "") : text
        case .blocks(let blocks):
            var blocks = blocks
            if mustAskInWords, let answerTool {
                // After the cached head, so the instruction never moves the cache breakpoint.
                blocks.append(["type": "text", "text": answerTool.instruction])
            }
            body["system"] = blocks
        }

        if let answerTool {
            var tool: [String: Any] = [
                "name": answerTool.name,
                "description": answerTool.description,
                "input_schema": answerTool.schema,
            ]
            if contract.allowsForcedToolChoice {
                body["tool_choice"] = ["type": "tool", "name": answerTool.name]
            } else {
                body["tool_choice"] = ["type": "auto"]
                if AnthropicModelContract.schemaQualifiesForStrict(answerTool.schema) {
                    tool["strict"] = true
                }
            }
            body["tools"] = [tool]
        } else if let tools {
            body["tools"] = tools
        }

        reasoning.apply(to: &body)
        if stream { body["stream"] = true }
        return body
    }
}

/// Reading an Anthropic reply by what its blocks are, never by where they sit (Plan IE P1, P3).
///
/// A model that thinks by default opens its content with a `thinking` block, so "the first
/// block's text" is nothing at all while the answer waits in the second. And a 200 is not always
/// an answer: the stop reason says when the model declined, or ran out of room.
enum AnthropicReply {

    /// What a 200 turned out to be.
    enum Outcome: Equatable {
        case answered
        /// `stop_reason: refusal` — the model declined. Its content is not an answer.
        case declined
        /// `stop_reason: max_tokens` with no text and no tool call: the allowance went on thinking.
        case ranOutOfRoom
    }

    /// The reply's text: every `text` block, joined the way the tool loop has always joined them.
    static func text(in content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    static func outcome(stopReason: String?, text: String, hasToolCalls: Bool) -> Outcome {
        // Checked before the content is read: a declined reply can still carry blocks.
        if stopReason == "refusal" { return .declined }
        if stopReason == "max_tokens", !hasToolCalls,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .ranOutOfRoom
        }
        return .answered
    }

    /// The text of a one-shot reply's body, or nil when the body is not an answer: unreadable,
    /// declined, or empty.
    static func oneShotText(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        let text = Self.text(in: content)
        guard outcome(stopReason: json["stop_reason"] as? String, text: text, hasToolCalls: false) == .answered,
              !text.isEmpty else { return nil }
        return text
    }
}
