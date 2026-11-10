import Foundation

/// The conversation history is one array shared by every provider, and each provider's path
/// appends messages in its own wire shape: Anthropic's content blocks (`tool_use` in the assistant
/// message, `tool_result` blocks in a user message), the OpenAI chat shape (assistant `tool_calls`,
/// `role: "tool"` results, `image_url` blocks — also what the ChatGPT backend's history is kept in),
/// and Gemini's `parts` (`functionCall`, `role: "function"` with `functionResponse`, `inlineData`).
///
/// A conversation can change provider between turns: a photo turn goes to the chosen Vision model
/// while the rest stays on the assistant (Plan KA), the cascade hops, or the wearer picks another
/// model. The next request then carries messages another provider wrote, and sent raw they are
/// refused — a ChatGPT turn's tool result reached Anthropic as `role: "tool"` and the photo turn
/// came back `400 Unexpected role "tool"`. This converts, for one request, every message the
/// target cannot read into the target's shape, and leaves every message it can read exactly as it
/// is (a thinking signature, Responses replay items, a Gemini thought signature are never
/// re-synthesised).
///
/// - Anthropic and the OpenAI chat shape take a converted exchange as a real tool exchange: a call
///   becomes `tool_use` or `tool_calls`, its result `tool_result` or a `tool` message, paired by id
///   (positionally where the source gave none). A call left without a result gets the synthetic
///   interrupted result; a result whose call is not in the request becomes plain user text, so a
///   request never pairs a result with nothing.
/// - Gemini takes a foreign exchange as text: its function calls carry thought signatures that
///   cannot be made up, so a call reads "[Used the … tool with …]" and its result "[… returned: …]".
///
/// Request-time only: the stored history keeps the shapes it was written in, so every index into
/// it (the job's floor, a turn's start, the timeline's readings) still holds. Pure.
enum CrossProviderHistory {

    /// The history shapes a request can be sent in.
    enum Shape: String {
        case anthropic, openAIChat, gemini
    }

    /// The shape `provider`'s request is built in, or nil for the on-device paths, which build
    /// their own transcript from the history.
    static func shape(for provider: LLMProvider) -> Shape? {
        switch provider {
        case .anthropic:
            return .anthropic
        case .gemini, .geminiVertex:
            return .gemini
        case .chatgpt, .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return .openAIChat
        case .local, .appleOnDevice:
            return nil
        }
    }

    /// The history converted for one request in `shape`, and how many of its messages were not in
    /// that shape (zero means the history is returned exactly as given).
    static func normalised(_ history: [[String: Any]], for shape: Shape) -> (history: [[String: Any]], converted: Int) {
        let foreign = history.reduce(0) { $0 + (isNative($1, for: shape) ? 0 : 1) }
        guard foreign > 0 else { return (history, 0) }
        return (lower(lift(history, for: shape), to: shape), foreign)
    }

    /// The history converted for one request in `shape`.
    static func normalisedHistory(_ history: [[String: Any]], for shape: Shape) -> [[String: Any]] {
        normalised(history, for: shape).history
    }

    // MARK: - Which messages the target reads as they are

    private static let anthropicBlockTypes: Set<String> = [
        "text", "image", "document", "tool_use", "tool_result", "thinking", "redacted_thinking",
        // Plan KZ: the provider's own web search, replayed unchanged within the turn that ran it
        // (`HistoryHygiene.stripProviderSearchBlocks` takes them out when it ends).
        "server_tool_use", "web_search_tool_result",
    ]
    private static let openAIBlockTypes: Set<String> = ["text", "image_url"]

    /// Whether `message` is already in `shape` and goes into the request untouched.
    static func isNative(_ message: [String: Any], for shape: Shape) -> Bool {
        let role = message["role"] as? String ?? "user"
        let content = message["content"]
        switch shape {
        case .anthropic:
            guard ["user", "assistant", "system"].contains(role),
                  message["parts"] == nil, message["tool_calls"] == nil,
                  message[ResponsesTranslator.rawOutputItemsKey] == nil else { return false }
            if let text = content as? String {
                // The service refuses an empty message; the ChatGPT path can store one.
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard let blocks = content as? [[String: Any]], !blocks.isEmpty else { return false }
            return blocks.allSatisfy { block in
                guard let type = block["type"] as? String, anthropicBlockTypes.contains(type) else { return false }
                return type != "image" || block["source"] != nil
            }
        case .openAIChat:
            guard ["user", "assistant", "system", "developer", "tool"].contains(role),
                  message["parts"] == nil else { return false }
            if content == nil || content is String || content is NSNull { return true }
            // The chat paths write an assistant's text as a string; blocks there are Anthropic's,
            // and the Responses input reads only a string.
            guard role != "assistant", let blocks = content as? [[String: Any]] else { return false }
            return blocks.allSatisfy { openAIBlockTypes.contains($0["type"] as? String ?? "") }
        case .gemini:
            if message["parts"] is [[String: Any]] {
                return ["user", "model", "assistant", "function"].contains(role)
            }
            return ["user", "model", "assistant"].contains(role)
                && message["tool_calls"] == nil && content is String
        }
    }

    // MARK: - The neutral form

    struct Image {
        var base64: String?
        var mediaType: String
        var url: String?
    }

    enum Part {
        case text(String)
        case image(Image)
    }

    struct Call {
        var id: String
        var name: String
        var input: [String: Any]
    }

    struct Result {
        var id: String
        var name: String?
        var text: String
        var images: [Image] = []
        var isError = false
    }

    enum Item {
        case native([String: Any])
        case user([Part])
        case assistant(text: String, calls: [Call])
        case results([Result])
    }

    // MARK: - Lifting

    private static func lift(_ history: [[String: Any]], for shape: Shape) -> [Item] {
        var items: [Item] = []
        for message in history {
            if isNative(message, for: shape) {
                items.append(.native(message))
                continue
            }
            for item in liftForeign(message) {
                // A tool's photo travels in the message after its result (the chat and Gemini
                // paths both write it so); it belongs to that result.
                if case .user(let parts) = item, isAttachmentFollowUp(parts),
                   case .results(var results)? = items.last, !results.isEmpty {
                    results[results.count - 1].images += parts.compactMap { part -> Image? in
                        if case .image(let image) = part { return image }
                        return nil
                    }
                    items[items.count - 1] = .results(results)
                    continue
                }
                items.append(item)
            }
        }
        return items
    }

    private static func liftForeign(_ message: [String: Any]) -> [Item] {
        let role = message["role"] as? String ?? "user"
        if let parts = message["parts"] as? [[String: Any]] {
            return liftGemini(role: role, parts: parts)
        }
        switch role {
        case "tool", "function":
            return [.results([Result(id: message["tool_call_id"] as? String ?? "", name: message["name"] as? String,
                                     text: text(of: message["content"]))])]
        case "assistant", "model":
            var calls: [Call] = []
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    calls.append(Call(id: call["id"] as? String ?? "", name: function["name"] as? String ?? "",
                                      input: arguments(function["arguments"])))
                }
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_use" {
                    calls.append(Call(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                      input: arguments(block["input"])))
                }
            }
            return [.assistant(text: text(of: message["content"]), calls: calls)]
        default:
            guard let blocks = message["content"] as? [[String: Any]] else {
                return [.user([.text(message["content"] as? String ?? "")])]
            }
            var results: [Result] = []
            var parts: [Part] = []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    var result = Result(id: block["tool_use_id"] as? String ?? "", name: nil,
                                        text: text(of: block["content"]),
                                        isError: block["is_error"] as? Bool ?? false)
                    if let nested = block["content"] as? [[String: Any]] {
                        result.images = nested.compactMap(image(in:))
                    }
                    results.append(result)
                case "text":
                    parts.append(.text(block["text"] as? String ?? ""))
                default:
                    if let image = image(in: block) { parts.append(.image(image)) }
                }
            }
            var items: [Item] = []
            if !results.isEmpty { items.append(.results(results)) }
            if !parts.isEmpty { items.append(.user(parts)) }
            return items
        }
    }

    private static func liftGemini(role: String, parts: [[String: Any]]) -> [Item] {
        switch role {
        case "model", "assistant":
            let text = parts.filter { $0["thought"] as? Bool != true }
                .compactMap { $0["text"] as? String }.joined()
            let calls = parts.compactMap { part -> Call? in
                guard let call = part["functionCall"] as? [String: Any] else { return nil }
                return Call(id: call["id"] as? String ?? "", name: call["name"] as? String ?? "",
                            input: arguments(call["args"]))
            }
            return [.assistant(text: text, calls: calls)]
        case "function":
            let results = parts.compactMap { part -> Result? in
                guard let response = part["functionResponse"] as? [String: Any] else { return nil }
                let body = response["response"] as? [String: Any] ?? [:]
                let text = body["result"] as? String ?? body["error"] as? String ?? json(body)
                return Result(id: response["id"] as? String ?? "", name: response["name"] as? String,
                              text: text, isError: body["error"] != nil)
            }
            return results.isEmpty ? [] : [.results(results)]
        default:
            let lifted = parts.compactMap { part -> Part? in
                if let text = part["text"] as? String { return .text(text) }
                if let inline = part["inlineData"] as? [String: Any], let data = inline["data"] as? String {
                    return .image(Image(base64: data, mediaType: inline["mimeType"] as? String ?? "image/jpeg"))
                }
                return nil
            }
            return [.user(lifted)]
        }
    }

    /// A message that only carries a tool's photo: its caption and the image.
    private static func isAttachmentFollowUp(_ parts: [Part]) -> Bool {
        let caption = ToolResultImage.attachmentCaption(toolName: "")
        let prefix = String(caption.prefix(while: { $0 != "]" }).dropLast(1))
        var sawImage = false
        for part in parts {
            switch part {
            case .image: sawImage = true
            case .text(let text): if !text.hasPrefix(prefix) { return false }
            }
        }
        return sawImage
    }

    private static func image(in block: [String: Any]) -> Image? {
        switch block["type"] as? String {
        case "image":
            guard let source = block["source"] as? [String: Any] else { return nil }
            if let data = source["data"] as? String {
                return Image(base64: data, mediaType: source["media_type"] as? String ?? "image/jpeg")
            }
            return (source["url"] as? String).map { Image(base64: nil, mediaType: "image/jpeg", url: $0) }
        case "image_url":
            guard let url = (block["image_url"] as? [String: Any])?["url"] as? String ?? block["image_url"] as? String
            else { return nil }
            return dataURLImage(url) ?? Image(base64: nil, mediaType: "image/jpeg", url: url)
        default:
            return nil
        }
    }

    /// `data:image/jpeg;base64,…` as its media type and payload.
    private static func dataURLImage(_ url: String) -> Image? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let mediaType = header.split(separator: ";").first.map(String.init) ?? "image/jpeg"
        return Image(base64: String(url[url.index(after: comma)...]), mediaType: mediaType.isEmpty ? "image/jpeg" : mediaType)
    }

    /// The text in a message's or a block's content: the string, or its text blocks joined.
    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.filter { ($0["type"] as? String ?? "text") == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A call's arguments as an object: a JSON string parsed, an object kept; anything else kept
    /// under `arguments` so nothing the model sent is lost.
    private static func arguments(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String else { return [:] }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        if let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        return ["arguments": string]
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    // MARK: - Lowering

    /// The calls of the last converted assistant message still waiting for their results, and what
    /// is held back until the exchange closes: results come first, then their photos and anything
    /// left over, so the target sees the exchange whole.
    private struct Exchange {
        var pending: [Call] = []
        var heldResults: [[String: Any]] = []
        var heldAfter: [[String: Any]] = []
        var names: [String: String] = [:]
        var generated = 0

        /// The call `result` answers, taken off the pending list: by id, or — where the source gave
        /// none — the first pending call of that name, then the first pending call.
        mutating func take(_ result: Result, sanitise: (String) -> String) -> Call? {
            let index: Int?
            if !result.id.isEmpty {
                let wanted = sanitise(result.id)
                index = pending.firstIndex { $0.id == wanted }
            } else if let name = result.name, let named = pending.firstIndex(where: { $0.name == name }) {
                index = named
            } else {
                index = pending.isEmpty ? nil : 0
            }
            guard let index else { return nil }
            return pending.remove(at: index)
        }
    }

    private static func lower(_ items: [Item], to shape: Shape) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var exchange = Exchange()
        let sanitise: (String) -> String = shape == .anthropic ? anthropicID : { $0 }

        func close() {
            for call in exchange.pending {
                exchange.heldResults.append(contentsOf: resultMessages(
                    Result(id: call.id, name: call.name, text: HistoryHygiene.interruptedToolResult, isError: true),
                    callID: call.id, shape: shape, isSynthetic: true))
            }
            exchange.pending = []
            switch shape {
            case .anthropic:
                // One user message holds every result of the assistant turn before it.
                let blocks = exchange.heldResults.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                if !blocks.isEmpty { out.append(["role": "user", "content": blocks]) }
            case .openAIChat, .gemini:
                out.append(contentsOf: exchange.heldResults)
            }
            out.append(contentsOf: exchange.heldAfter)
            exchange.heldResults = []
            exchange.heldAfter = []
        }

        for item in items {
            if case .results = item {} else { close() }
            switch item {
            case .native(let message):
                var message = message
                if shape != .openAIChat { message.removeValue(forKey: ResponsesTranslator.rawOutputItemsKey) }
                out.append(message)
            case .user(let parts):
                if let message = userMessage(parts, shape: shape) { out.append(message) }
            case .assistant(let text, let calls):
                var resolved: [Call] = []
                for call in calls {
                    var call = call
                    if call.id.isEmpty {
                        exchange.generated += 1
                        call.id = "call_converted_\(exchange.generated)"
                    } else {
                        call.id = sanitise(call.id)
                    }
                    exchange.names[call.id] = call.name
                    resolved.append(call)
                }
                guard let message = assistantMessage(text: text, calls: resolved, shape: shape) else { continue }
                out.append(message)
                // Gemini reads a foreign exchange as text: nothing waits for a result there.
                exchange.pending = shape == .gemini ? [] : resolved
            case .results(let results):
                for var result in results {
                    if shape == .gemini {
                        if result.name == nil { result.name = exchange.names[sanitise(result.id)] }
                        out.append(contentsOf: resultMessages(result, callID: result.id, shape: shape, isSynthetic: false))
                        continue
                    }
                    if let call = exchange.take(result, sanitise: sanitise) {
                        result.name = result.name ?? call.name
                        let messages = resultMessages(result, callID: call.id, shape: shape, isSynthetic: false)
                        exchange.heldResults.append(contentsOf: messages.filter { isResultMessage($0, shape: shape) })
                        exchange.heldAfter.append(contentsOf: messages.filter { !isResultMessage($0, shape: shape) })
                    } else {
                        // A result whose call is not in this request: what it said, as plain text.
                        if result.name == nil { result.name = exchange.names[sanitise(result.id)] }
                        let orphan = orphanText(result)
                        exchange.heldAfter.append(userMessage([.text(orphan)] + result.images.map(Part.image),
                                                              shape: shape) ?? ["role": "user", "content": orphan])
                    }
                }
            }
        }
        close()
        return out
    }

    private static func isResultMessage(_ message: [String: Any], shape: Shape) -> Bool {
        switch shape {
        case .anthropic:
            return (message["content"] as? [[String: Any]])?.first?["type"] as? String == "tool_result"
        case .openAIChat:
            return message["role"] as? String == "tool"
        case .gemini:
            return true
        }
    }

    private static func userMessage(_ parts: [Part], shape: Shape) -> [String: Any]? {
        let kept = parts.filter {
            if case .text(let text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
        guard !kept.isEmpty else { return nil }
        switch shape {
        case .anthropic:
            if kept.count == 1, case .text(let text) = kept[0] { return ["role": "user", "content": text] }
            return ["role": "user", "content": kept.map(anthropicBlock)]
        case .openAIChat:
            if kept.count == 1, case .text(let text) = kept[0] { return ["role": "user", "content": text] }
            return ["role": "user", "content": kept.map(openAIBlock)]
        case .gemini:
            if kept.count == 1, case .text(let text) = kept[0] { return ["role": "user", "content": text] }
            return ["role": "user", "parts": kept.map(geminiPart)]
        }
    }

    private static func assistantMessage(text: String, calls: [Call], shape: Shape) -> [String: Any]? {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !calls.isEmpty else { return nil }
        switch shape {
        case .anthropic:
            if calls.isEmpty { return ["role": "assistant", "content": text] }
            var blocks: [[String: Any]] = hasText ? [["type": "text", "text": text]] : []
            blocks += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
            return ["role": "assistant", "content": blocks]
        case .openAIChat:
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                message["tool_calls"] = calls.map { call -> [String: Any] in
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": json(call.input)]]
                }
            }
            return message
        case .gemini:
            let lines = (hasText ? [text] : []) + calls.map { "[Used the \($0.name) tool with \(json($0.input))]" }
            return ["role": "model", "parts": [["text": lines.joined(separator: "\n")]]]
        }
    }

    /// The messages one result becomes: the result itself, then (on the chat shape and Gemini)
    /// its photos in a user message after it.
    private static func resultMessages(_ result: Result, callID: String, shape: Shape,
                                       isSynthetic: Bool) -> [[String: Any]] {
        let text = result.text.isEmpty ? "(no output)" : result.text
        switch shape {
        case .anthropic:
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": callID, "content": text]
            if !result.images.isEmpty {
                block["content"] = [["type": "text", "text": text]] + result.images.map { anthropicBlock(.image($0)) }
            }
            if result.isError && !isSynthetic { block["is_error"] = true }
            return [["role": "user", "content": [block]]]
        case .openAIChat:
            var messages: [[String: Any]] = [["role": "tool", "tool_call_id": callID, "content": text]]
            if !result.images.isEmpty {
                let caption = ToolResultImage.attachmentCaption(toolName: result.name ?? "the tool")
                messages.append(["role": "user", "content": [openAIBlock(.text(caption))]
                                    + result.images.map { openAIBlock(.image($0)) }])
            }
            return messages
        case .gemini:
            let line = "[\(result.name.map { "The \($0) tool" } ?? "A tool") returned: \(text)]"
            return [["role": "user", "parts": [["text": line]] + result.images.map { geminiPart(.image($0)) }]]
        }
    }

    private static func orphanText(_ result: Result) -> String {
        "[Earlier result from \(result.name.map { "the \($0) tool" } ?? "a tool"): \(result.text.isEmpty ? "(no output)" : result.text)]"
    }

    private static func anthropicBlock(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let image):
            if let data = image.base64 {
                return ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": data]]
            }
            return ["type": "image", "source": ["type": "url", "url": image.url ?? ""]]
        }
    }

    private static func openAIBlock(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let image):
            let url = image.base64.map { "data:\(image.mediaType);base64,\($0)" } ?? image.url ?? ""
            return ["type": "image_url", "image_url": ["url": url]]
        }
    }

    private static func geminiPart(_ part: Part) -> [String: Any] {
        switch part {
        case .text(let text):
            return ["text": text]
        case .image(let image):
            if let data = image.base64 {
                return ["inlineData": ["mimeType": image.mediaType, "data": data]]
            }
            return ["text": "[image: \(image.url ?? "")]"]
        }
    }

    /// Anthropic's tool ids allow letters, digits, `_` and `-`; anything else becomes `_`, the
    /// same way for a call and its result.
    static func anthropicID(_ id: String) -> String {
        let mapped = id.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let allowed = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
                || value == 95 || value == 45
            return allowed ? Character(scalar) : "_"
        }
        return String(mapped)
    }
}
