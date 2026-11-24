import Foundation

/// The GGUF tool turn's text, pure (Plan MQ P2): what the GGUF backend hands llama.cpp's
/// `common/chat` to render, and how it reads back what `common/chat` parsed. No engine here, so
/// every shape is checked headlessly; the C++ side is reached through `LlamaEngine`.
///
/// ### Why JSON
/// `common/chat` takes OpenAI-style messages and tools and answers with a render (the prompt, the
/// family's format, the lazy grammar and its triggers, the tokens it needs rendered, its parser)
/// and later with a parsed message. Passing those as JSON text keeps the C bridge to a handful of
/// functions, and every key is one `common/chat` already defines.
///
/// ### The transcript
/// The tool loop's messages go in as the OpenAI shapes `common/chat` maps onto each family's
/// template: an assistant call carries `tool_calls` (`{"type": "function", "id", "function":
/// {"name", "arguments"}}`, arguments as JSON text) and a result is a `tool` message with
/// `tool_call_id` and `name`. Those are the keys MLX's path writes (`LocalToolTranscript`), so the
/// two runtimes hand a template the same conversation.
enum LlamaToolChat {

    // MARK: - Request

    /// The render request for one pass. `tools` are `OnDeviceToolSchema.localToolSpec`s (already
    /// in OpenAI's function shape), in the order given; empty withholds them. Thinking is off on a
    /// tool turn, as on MLX. Calls may come several to a generation: the loop runs each in order.
    static func requestJSON(system: String, messages: [LocalToolLoop.Message], tools: [[String: Any]],
                            thinkingOff: Bool, now: Date? = nil) -> String {
        var oai: [[String: Any]] = []
        if !system.isEmpty { oai.append(["role": "system", "content": system]) }
        oai.append(contentsOf: messages.map(message))
        var request: [String: Any] = [
            "messages": oai,
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "enable_thinking": !thinkingOff,
            "add_generation_prompt": true,
            "reasoning_format": "auto",
        ]
        if !tools.isEmpty { request["tools"] = tools }
        if let now { request["now"] = Int(now.timeIntervalSince1970) }
        return json(request)
    }

    /// One loop message in OpenAI's shape.
    static func message(_ message: LocalToolLoop.Message) -> [String: Any] {
        var raw: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        switch message.role {
        case .assistant:
            if let id = message.toolCallID, let name = message.toolName {
                raw["tool_calls"] = [[
                    "type": "function",
                    "id": id,
                    "function": ["name": name, "arguments": message.toolArguments ?? "{}"],
                ]]
            }
        case .tool:
            if let id = message.toolCallID { raw["tool_call_id"] = id }
            if let name = message.toolName { raw["name"] = name }
        case .user:
            break
        }
        return raw
    }

    // MARK: - Render

    /// What `common/chat` made of a request.
    struct Render: Decodable, Equatable {
        struct Trigger: Decodable, Equatable {
            let type: Int
            let value: String
        }

        let prompt: String
        /// `common_chat_format`, and its name (`peg-gemma4`, `peg-native` …) — a fact about the
        /// template, safe to log as a token.
        let format: Int
        let formatName: String
        let grammar: String
        let grammarLazy: Bool
        let grammarTriggers: [Trigger]
        /// Control tokens the parser needs to see as text (the family's call markers).
        let preservedTokens: [String]
        let additionalStops: [String]
        let generationPrompt: String
        let toolsRendered: Bool

        enum CodingKeys: String, CodingKey {
            case prompt, format, grammar
            case formatName = "format_name"
            case grammarLazy = "grammar_lazy"
            case grammarTriggers = "grammar_triggers"
            case preservedTokens = "preserved_tokens"
            case additionalStops = "additional_stops"
            case generationPrompt = "generation_prompt"
            case toolsRendered = "tools_rendered"
        }

        /// A lazy grammar with something to wake it: what the sampler applies.
        var constrainsCalls: Bool { grammarLazy && !grammar.isEmpty && !grammarTriggers.isEmpty }
    }

    static func render(_ json: String) throws -> Render {
        guard let data = json.data(using: .utf8) else { throw LlamaEngineError.templateFailed }
        return try JSONDecoder().decode(Render.self, from: data)
    }

    // MARK: - Parse

    /// A completion as the loop takes it.
    struct Parsed: Equatable {
        /// The reply, with every call and the family's markers taken out.
        let content: String
        /// Calls whose arguments are a JSON object, canonical (sorted keys), in order.
        let calls: [LocalToolCallEvent]
        /// Calls the parser found whose name was empty or whose arguments were not a whole JSON
        /// object — a call cut off by the token cap, say. Never run, never spoken; counted.
        let malformedCalls: Int
    }

    private struct RawParsed: Decodable {
        struct Call: Decodable {
            let name: String
            let arguments: String
        }

        let content: String
        let toolCalls: [Call]

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    /// Reads `common/chat`'s parsed message. A call is kept only when it has a name and its
    /// arguments parse as one JSON object: the parser is lenient by design (it reads unfinished
    /// output for streaming), so a call cut short arrives with half its arguments, and a call
    /// that does not parse is never a call (as `LocalOutputPolicy` has it for MLX).
    static func parsed(_ json: String) throws -> Parsed {
        guard let data = json.data(using: .utf8) else { throw LlamaEngineError.parseFailed }
        let raw = try JSONDecoder().decode(RawParsed.self, from: data)
        var calls: [LocalToolCallEvent] = []
        var malformed = 0
        for call in raw.toolCalls {
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let argumentData = call.arguments.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] else {
                malformed += 1
                continue
            }
            calls.append(LocalToolCallEvent(name: name, arguments: object))
        }
        return Parsed(content: raw.content, calls: calls, malformedCalls: malformed)
    }

    /// The part of a streamed preview that is new: what `current` adds to `shown`. A partial parse
    /// can revise text it already returned (a run of characters that turned into a call marker),
    /// and a preview can't take words back, so a revision shows nothing until it extends again.
    static func previewDelta(shown: String, current: String) -> String {
        guard current.count > shown.count, current.hasPrefix(shown) else { return "" }
        return String(current.dropFirst(shown.count))
    }

    // MARK: - JSON

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Which of the cached tokens a new prompt can keep (Plan MQ H3). Pure.
///
/// The GGUF backend used to clear the KV cache before every generation, so each turn re-read its
/// whole prompt. A Field Assist job sends the same system prompt and job tier turn after turn, and
/// each round of a tool loop repeats the whole prompt plus a call and its result: everything up to
/// where the new prompt departs from what the cache holds is already computed.
enum LlamaPromptCache {

    /// The tokens to keep: the longest common prefix of what the cache holds and the new prompt,
    /// less one when the prompt is entirely cached, because the sampler needs the last prompt
    /// token's logits and only a decode produces them.
    static func reusablePrefix(cached: [LlamaToken], prompt: [LlamaToken]) -> Int {
        var shared = 0
        let limit = min(cached.count, prompt.count)
        while shared < limit, cached[shared] == prompt[shared] { shared += 1 }
        return min(shared, max(0, prompt.count - 1))
    }

    // MARK: - Prefix snapshots (Plan MQ, a cache that cannot be cut back)

    /// What the stable start is found against: the same system prompt and tools rendered over one
    /// user message holding only this, a private-use character no turn starts with. A tokenizer
    /// merges nothing across it, so the render's tokens part from a real prompt's exactly where the
    /// first conversation message's own words begin.
    static let stableStartProbe = "\u{E000}"

    /// A snapshot shorter than this is not worth its copy.
    static let minimumSnapshotTokens = 64

    /// Where `prompt`'s stable start ends: the tokens it shares with `probe`, the render of its own
    /// system prompt and tools over `stableStartProbe` — the system/tools section, up to where the
    /// first message's words begin. Less one when that is the whole prompt, as `reusablePrefix`.
    static func stableStart(prompt: [LlamaToken], probe: [LlamaToken]) -> Int {
        var shared = 0
        let limit = min(probe.count, prompt.count)
        while shared < limit, probe[shared] == prompt[shared] { shared += 1 }
        return min(shared, max(0, prompt.count - 1))
    }

    /// What to do with the one snapshot before a prompt's prefill.
    struct SnapshotStep: Equatable {
        /// The snapshot holds the prompt's first tokens: restore it and prefill from its end.
        let restore: Bool
        /// Where the prefill starts when the restore works.
        let resumeAt: Int
        /// Save a new snapshot once the prefill reaches this position (replacing the old one), or
        /// nil to keep what there is.
        let saveAt: Int?
    }

    /// The snapshot is restored when the prompt begins with exactly its tokens and runs past them
    /// (the sampler needs a decoded token's logits). A new one is saved at the prompt's stable start
    /// when nothing was restored, or when that start runs past the restored one: one snapshot,
    /// replaced when the start changes. A stable start under `minimumTokens` is not saved.
    static func snapshotStep(snapshot: [LlamaToken]?, prompt: [LlamaToken], stableStart: Int?,
                             minimumTokens: Int = minimumSnapshotTokens) -> SnapshotStep {
        let target = stableStart.map { min($0, max(0, prompt.count - 1)) }.flatMap { $0 >= minimumTokens ? $0 : nil }
        if let snapshot, !snapshot.isEmpty, snapshot.count < prompt.count, prompt.starts(with: snapshot) {
            let grow = target.flatMap { $0 > snapshot.count ? $0 : nil }
            return SnapshotStep(restore: true, resumeAt: snapshot.count, saveAt: grow)
        }
        return SnapshotStep(restore: false, resumeAt: 0, saveAt: target)
    }
}
