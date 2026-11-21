import Foundation

/// How a native tool turn's transcript reaches a downloaded model's chat template (Plan MQ P1).
/// Pure: no MLX, so every shape is checked headlessly.
///
/// Two renderings:
/// - **Structured**, for a template that renders tools: an assistant call carries `tool_calls`
///   (`{"type": "function", "id", "function": {"name", "arguments"}}`) and a result is a `tool`
///   message with `tool_call_id` and `name` — the keys mlx-swift-lm's own `MessageGenerator` writes,
///   so a template that reads them sees what it was trained on.
/// - **Flattened**, when the runtime inferred no tool-call format (or the template could not be
///   rendered): the call written back as the Hermes frame the fallback instruction asks for, and
///   the result as a user message, as the single-shot path has always sent it. Lossy on purpose,
///   and only on the fallback.
enum LocalToolTranscript {

    /// One message as a template dictionary.
    static func rawMessage(_ message: LocalToolLoop.Message) -> [String: any Sendable] {
        var raw: [String: any Sendable] = ["role": message.role.rawValue, "content": message.content]
        switch message.role {
        case .assistant:
            if let id = message.toolCallID, let name = message.toolName {
                raw["tool_calls"] = [[
                    "type": "function",
                    "id": id,
                    "function": [
                        "name": name,
                        "arguments": sendableObject(json: message.toolArguments ?? "{}"),
                    ] as [String: any Sendable],
                ] as [String: any Sendable]] as [any Sendable]
            }
        case .tool:
            if let id = message.toolCallID { raw["tool_call_id"] = id }
            if let name = message.toolName { raw["name"] = name }
        case .user:
            break
        }
        return raw
    }

    /// Messages for a template that does not render tool calls: the call as Hermes text, the result
    /// as the user-role line the single-shot path sends.
    static func flattened(_ messages: [LocalToolLoop.Message]) -> [(role: String, content: String)] {
        messages.map { message in
            switch message.role {
            case .user:
                return (role: "user", content: message.content)
            case .assistant:
                guard let name = message.toolName else { return (role: "assistant", content: message.content) }
                let frame = "<tool_call>{\"name\": \"\(name)\", \"arguments\": \(message.toolArguments ?? "{}")}</tool_call>"
                return (role: "assistant", content: message.content.isEmpty ? frame : message.content + "\n" + frame)
            case .tool:
                return (role: "user", content: "Tool '\(message.toolName ?? "tool")' returned: \(message.content)")
            }
        }
    }

    /// A tool spec (`OnDeviceToolSchema.localToolSpec`) in the shape the tokenizer takes.
    static func sendableSpec(_ spec: [String: Any]) -> [String: any Sendable] {
        (sendable(spec) as? [String: any Sendable]) ?? [:]
    }

    /// The template's extra variables for a tool turn.
    static func templateContext(thinkingOff: Bool) -> [String: any Sendable]? {
        thinkingOff ? ["enable_thinking": false] : nil
    }

    // MARK: - JSON to Sendable

    static func sendableObject(json: String) -> [String: any Sendable] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return (sendable(object) as? [String: any Sendable]) ?? [:]
    }

    /// Foundation JSON (`JSONSerialization` output or a literal dictionary) as Sendable values. A
    /// boolean stays a boolean: `NSNumber` is checked for its boolean type first.
    static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sendable($0) } as [String: any Sendable]
        case let array as [Any]:
            return array.map { sendable($0) } as [any Sendable]
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if CFNumberIsFloatType(number) { return number.doubleValue }
            return number.intValue
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        default:
            return String(describing: value)
        }
    }
}
