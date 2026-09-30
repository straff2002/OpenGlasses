import Foundation

/// Pure wire-format translation for the Responses-API backend that ChatGPT subscription tokens
/// authenticate against (Plan BW P2). The conversation history stays in the OpenAI *chat* shape
/// the rest of the app already understands (`role`/`content`, assistant `tool_calls`,
/// `role: "tool"` results — so `HistoryHygiene` image pruning works unchanged); this enum
/// converts to Responses *items* at request time and parses output items back.
///
/// No I/O — every function is testable against fixtures, like `GeminiSchemaTranslator`.
enum ResponsesTranslator {

    // MARK: - Request building

    /// Where an assistant history message keeps the Responses `output` items it came from
    /// (Plan GC Decision 4): reasoning, message and function_call items, in the order received,
    /// `phase` and `encrypted_content` intact. `inputItems` replays them verbatim so a reasoning
    /// item is never sent without the item that followed it. Not a chat field — strip it with
    /// `HistoryHygiene.stripResponsesItems` before any Chat Completions body and when the turn
    /// finalises.
    static let rawOutputItemsKey = "responses_output_items"

    /// Optional request fields for the OpenAI API route (Plan GC). The defaults reproduce the
    /// ChatGPT subscription body exactly, so that path is unchanged.
    struct RequestOptions {
        /// Adds `include: ["reasoning.encrypted_content"]` — the stateless (`store: false`) way to
        /// get reasoning items back for replay across the tool round-trips of a turn.
        var includeEncryptedReasoning = false
        /// `max_output_tokens`; it includes reasoning tokens, so pass `Resolution.outputCap`.
        var maxOutputTokens: Int? = nil
        /// Top-level `prompt_cache_key` (`PromptPrefixDigest.cacheKey`).
        var promptCacheKey: String? = nil
        /// Applied through `Resolution.apply` — `reasoning.effort` for a `.responsesEffort` wire.
        var reasoning: ReasoningPolicy.Resolution? = nil
        /// GB's volatile tail: sent as a final `developer` message after the history, so the
        /// stable `instructions` and the conversation stay a byte-identical cacheable prefix.
        var trailingDeveloperMessage: String? = nil

        init(includeEncryptedReasoning: Bool = false, maxOutputTokens: Int? = nil,
             promptCacheKey: String? = nil, reasoning: ReasoningPolicy.Resolution? = nil,
             trailingDeveloperMessage: String? = nil) {
            self.includeEncryptedReasoning = includeEncryptedReasoning
            self.maxOutputTokens = maxOutputTokens
            self.promptCacheKey = promptCacheKey
            self.reasoning = reasoning
            self.trailingDeveloperMessage = trailingDeveloperMessage
        }
    }

    /// Full request body: system prompt rides `instructions`; history becomes `input` items.
    ///
    /// Always streams. The backend rejects non-streaming requests outright
    /// (`400 {"detail":"Stream must be set to true"}`), matching the upstream client, which
    /// hardwires `stream: true`; callers that don't need live tokens still read the SSE and
    /// take the `response.completed` payload.
    static func requestBody(model: String, instructions: String, history: [[String: Any]],
                            tools: [[String: Any]]?,
                            options: RequestOptions = RequestOptions()) -> [String: Any] {
        var input = inputItems(history: history)
        if let tail = options.trailingDeveloperMessage, !tail.isEmpty {
            input.append(messageItem(role: "developer", blocks: [["type": "input_text", "text": tail]]))
        }
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            // The backend keeps no server-side state for us — we resend history each turn.
            "store": false,
            "stream": true,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = responseTools(fromChatTools: tools)
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        if options.includeEncryptedReasoning {
            body["include"] = ["reasoning.encrypted_content"]
        }
        if let maxOutputTokens = options.maxOutputTokens {
            body["max_output_tokens"] = maxOutputTokens
        }
        if let key = options.promptCacheKey, !key.isEmpty {
            body["prompt_cache_key"] = key
        }
        options.reasoning?.apply(to: &body)
        return body
    }

    /// Chat-format history → Responses input items.
    static func inputItems(history: [[String: Any]]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in history {
            let role = message["role"] as? String ?? "user"
            switch role {
            case "tool":
                // Chat tool result → function_call_output, matched by call id.
                items.append([
                    "type": "function_call_output",
                    "call_id": message["tool_call_id"] as? String ?? "",
                    "output": message["content"] as? String ?? "",
                ])
            case "assistant":
                // A Responses turn's own output items (reasoning first), replayed exactly as
                // received — never re-synthesised, so no reasoning item loses its successor.
                if let raw = message[rawOutputItemsKey] as? [[String: Any]], !raw.isEmpty {
                    items.append(contentsOf: raw)
                    continue
                }
                // Assistant text (if any) then its tool calls as function_call items.
                if let text = message["content"] as? String, !text.isEmpty {
                    items.append(messageItem(role: "assistant", blocks: [outputText(text)]))
                }
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let function = call["function"] as? [String: Any] ?? [:]
                        items.append([
                            "type": "function_call",
                            "call_id": call["id"] as? String ?? "",
                            "name": function["name"] as? String ?? "",
                            "arguments": function["arguments"] as? String ?? "{}",
                        ])
                    }
                }
            default:   // user (and anything unrecognised is safest treated as user text)
                items.append(messageItem(role: "user", blocks: userBlocks(message["content"])))
            }
        }
        return items
    }

    /// Chat function tools (`{type: "function", function: {name, description, parameters}}`) →
    /// Responses tools, which hoist the fields to the top level.
    static func responseTools(fromChatTools chatTools: [[String: Any]]) -> [[String: Any]] {
        chatTools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return [
                "type": "function",
                "name": name,
                "description": function["description"] as? String ?? "",
                "parameters": function["parameters"] ?? ["type": "object"],
            ]
        }
    }

    // MARK: - Response parsing

    /// Response `output` items → concatenated text + normalised tool calls. Leniency built in
    /// from day one (the lesson the chat-completions path learned live): only `name` is truly
    /// required — a missing call id is synthesised, missing arguments default to `{}`.
    ///
    /// `rawOutputItems` is the `output` array exactly as received (reasoning items, `phase`,
    /// `encrypted_content` and all) for `assistantHistoryMessage(…rawOutputItems:)` to keep.
    static func parseOutput(_ response: [String: Any])
        -> (text: String, toolCalls: [ToolInvocation], rawOutputItems: [[String: Any]]) {
        var text = ""
        var toolCalls: [ToolInvocation] = []
        let output = response["output"] as? [[String: Any]] ?? []
        for (index, item) in output.enumerated() {
            switch item["type"] as? String {
            case "message":
                for block in item["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "output_text" {
                    text += block["text"] as? String ?? ""
                }
            case "function_call":
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let callID = (item["call_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
                let argsString = item["arguments"] as? String ?? "{}"
                let parsedArgs = try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any]
                toolCalls.append(ToolInvocation(id: callID, name: name,
                                                arguments: parsedArgs, rawArguments: argsString))
            default:
                break   // reasoning items etc. — not ours to consume, only to replay
            }
        }
        return (text, toolCalls, output)
    }

    /// `incomplete_details.reason` (e.g. `max_output_tokens`) when the response stopped short
    /// with `status: "incomplete"` — `unknown` if it gave no reason — else nil (Plan GC
    /// Decision 9).
    static func incompleteReason(_ response: [String: Any]) -> String? {
        guard response["status"] as? String == "incomplete" else { return nil }
        let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
        return reason ?? "unknown"
    }

    /// The chat-format assistant message to append to history for a tool-calling turn, so the
    /// next request's `inputItems` round-trips it back into function_call items.
    ///
    /// With `rawOutputItems` (Plan GC), the response's own output items ride along under
    /// `rawOutputItemsKey` and are what `inputItems` replays; the chat-shape `content` and
    /// `tool_calls` stay so the message still reads correctly once the key is stripped.
    static func assistantHistoryMessage(text: String, toolCalls: [ToolInvocation],
                                        rawOutputItems: [[String: Any]] = []) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !rawOutputItems.isEmpty {
            message[rawOutputItemsKey] = rawOutputItems
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id ?? "",
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.rawArguments ?? "{}"],
                ]
            }
        }
        return message
    }

    // MARK: - Streaming

    /// Folds Responses SSE events into (a) live text deltas for the UI and (b) the final
    /// response object. The authoritative result is always the `response.completed` payload —
    /// deltas are presentation only, so a shed delta can't corrupt the turn.
    struct StreamAccumulator {
        private(set) var completedResponse: [String: Any]?
        private(set) var failureMessage: String?
        private(set) var failureCode: String?
        /// Output items collected from `response.output_item.done` as they stream. The backend's
        /// `response.completed` envelope has slimmed to metadata/usage — the upstream client never
        /// reads `output` from it, and neither can we: the items arrive one event each, done-side.
        private(set) var doneItems: [[String: Any]] = []
        /// Take a `response.incomplete` envelope (`status: "incomplete"`, e.g. the output cap was
        /// reached) as the result, so the caller can name it (Plan GC Decision 9). Off by default:
        /// the subscription path keeps treating a stream without `response.completed` as failed.
        let acceptIncomplete: Bool

        init(acceptIncomplete: Bool = false) {
            self.acceptIncomplete = acceptIncomplete
        }

        /// The response to hand `parseOutput`: the completed payload with the streamed items
        /// substituted in whenever the envelope's own `output` is missing or empty. A fat
        /// envelope (fixtures, older backends) still wins when it actually carries items.
        var effectiveResponse: [String: Any]? {
            guard var response = completedResponse else { return nil }
            let envelopeOutput = response["output"] as? [[String: Any]] ?? []
            if envelopeOutput.isEmpty && !doneItems.isEmpty {
                response["output"] = doneItems
            }
            return response
        }

        /// Consume one SSE event; returns a text delta to surface, or nil.
        mutating func consume(_ event: SSEEvent) -> String? {
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let type = (event.event ?? json["type"] as? String) ?? ""
            switch type {
            case "response.output_text.delta":
                return json["delta"] as? String
            case "response.output_item.done":
                if let item = json["item"] as? [String: Any] {
                    doneItems.append(item)
                }
                return nil
            case "response.completed":
                completedResponse = json["response"] as? [String: Any] ?? [:]
                return nil
            case "response.incomplete" where acceptIncomplete:
                completedResponse = json["response"] as? [String: Any] ?? ["status": "incomplete"]
                return nil
            case "response.failed", "error":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                    ?? json["error"] as? [String: Any]
                failureMessage = error?["message"] as? String ?? json["message"] as? String ?? "response failed"
                failureCode = error?["code"] as? String ?? json["code"] as? String
                return nil
            default:
                return nil
            }
        }
    }

    // MARK: - Internals

    private static func messageItem(role: String, blocks: [[String: Any]]) -> [String: Any] {
        ["type": "message", "role": role, "content": blocks]
    }

    private static func outputText(_ text: String) -> [String: Any] {
        ["type": "output_text", "text": text]
    }

    /// A chat user `content` (plain string, or blocks with `text`/`image_url`) → input blocks.
    private static func userBlocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String {
            return [["type": "input_text", "text": text]]
        }
        guard let blocks = content as? [[String: Any]] else {
            return [["type": "input_text", "text": ""]]
        }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                return ["type": "input_text", "text": block["text"] as? String ?? ""]
            case "image_url":
                guard let url = (block["image_url"] as? [String: Any])?["url"] as? String else { return nil }
                return ["type": "input_image", "image_url": url]
            default:
                return nil
            }
        }
    }
}
