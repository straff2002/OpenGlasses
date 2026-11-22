import Foundation

/// The two halves of a Gemini `generateContent` function call that the tool loop touches: reading
/// a `functionCall` part, and writing the `functionResponse` part that answers it.
///
/// Gemini 3 models always return an `id` on a function call, and Google's function-calling guide
/// and 3.8 Flash migration notes (read 2026-10-10) say each `functionResponse` should carry that
/// `id` beside the `name`, so a result is matched to its call rather than to its position. The API
/// reference marks both `id` fields optional, so a model that sends none (2.x) is answered by name
/// alone, as before.
///
/// Pure, so the shape is table-tested without a request.
enum GeminiFunctionCalling {

    /// The invocation for one `functionCall` object. `args` is optional in the API: a call to a
    /// tool that takes no arguments can arrive without it, and is run with none rather than dropped.
    static func invocation(name: String, call: [String: Any]) -> ToolInvocation {
        let callID = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ToolInvocation(id: nil, name: name,
                              arguments: call["args"] as? [String: Any] ?? [:],
                              responseID: callID)
    }

    /// The `functionResponse` part for a finished call: the call's `name`, its `id` when the model
    /// gave one, and the result.
    static func responsePart(for invocation: ToolInvocation, response: [String: Any]) -> [String: Any] {
        var functionResponse: [String: Any] = ["name": invocation.name, "response": response]
        if let callID = invocation.responseID {
            functionResponse["id"] = callID
        }
        return ["functionResponse": functionResponse]
    }
}

// MARK: - Built-in tools beside function declarations

extension GeminiFunctionCalling {

    /// The request's `toolConfig` for a set of `tools`, or nil when none is needed.
    ///
    /// Google's "Combine built-in tools and function calling" guide (read 2026-11-23) makes a
    /// built-in tool (`google_search`) beside `functionDeclarations` in one request depend on
    /// `toolConfig.includeServerSideToolInvocations`, in `VALIDATED` mode (`AUTO` is not supported
    /// with it). Without the flag Gemini 3 refuses the whole request with a 400 ("Please enable
    /// tool_config.include_server_side_tool_invocations to use Built-in tools with Function
    /// calling", support report, build 737), so every turn failed whenever Google Search grounding
    /// rode with the app's tools.
    ///
    /// `withholdingCalls` is the wrap-up round, which offers no function call (`NONE`).
    static func toolConfig(tools: [[String: Any]], withholdingCalls: Bool) -> [String: Any]? {
        let declaresFunctions = tools.contains { $0["functionDeclarations"] != nil }
        let carriesBuiltIn = tools.contains { $0["functionDeclarations"] == nil }
        var config: [String: Any] = [:]
        if withholdingCalls, !tools.isEmpty {
            config["functionCallingConfig"] = ["mode": "NONE"]
        } else if carriesBuiltIn {
            config["functionCallingConfig"] = ["mode": "VALIDATED"]
        }
        if declaresFunctions, carriesBuiltIn {
            config["includeServerSideToolInvocations"] = true
        }
        return config.isEmpty ? nil : config
    }

    /// Whether a `toolConfig` asks Gemini to return its own tool invocations.
    static func includesServerSideInvocations(_ toolConfig: [String: Any]?) -> Bool {
        toolConfig?["includeServerSideToolInvocations"] as? Bool == true
    }

    /// `contents` without the `toolCall` / `toolResponse` parts a combined request returns.
    ///
    /// With the flag on, the model turn is echoed back exactly as given (the guide requires every
    /// part and its thought signature), so this is applied only to a request that does *not* set
    /// it: a later plain turn, or a round whose search was dropped mid-turn. Those parts are the
    /// server's record of its own search, and a request without the flag has no use for them. A
    /// turn left with no parts is dropped, since an empty `parts` list is a 400.
    static func withoutServerSideToolParts(_ contents: [[String: Any]]) -> [[String: Any]] {
        contents.compactMap { entry in
            guard let parts = entry["parts"] as? [[String: Any]],
                  parts.contains(where: isServerSidePart) else { return entry }
            let kept = parts.filter { !isServerSidePart($0) }
            guard !kept.isEmpty else { return nil }
            var entry = entry
            entry["parts"] = kept
            return entry
        }
    }

    private static func isServerSidePart(_ part: [String: Any]) -> Bool {
        part["toolCall"] != nil || part["toolResponse"] != nil
    }
}
