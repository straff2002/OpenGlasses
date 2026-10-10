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
