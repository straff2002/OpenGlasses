import Foundation

/// One function call the Realtime API asked for.
struct OpenAIRealtimeFunctionCall: Equatable {
    /// The API's own `call_id`, which the output must be returned against.
    let callId: String
    let name: String
    /// The raw JSON string the model streamed. Parsed here, not by the transport.
    let argumentsJSON: String

    /// The arguments as a dictionary, or empty when the model sent nothing parseable.
    ///
    /// A malformed argument object is not a reason to drop the call: the tool sees empty arguments
    /// and answers with its own "what did you mean?" error, which is a sentence the model can act
    /// on, where silence is not.
    var args: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// Routes OpenAI Realtime function calls to the app's native tools (Plan FO P3a).
///
/// The Gemini Live backend has had `ToolCallRouter` since it shipped. This backend had nothing:
/// P0's inventory found no `ToolCallRouter`, no `ToolDeclarations` reference and no
/// `promptContext()` call anywhere in `OpenAIRealtimeSessionManager`, so "Field Assist parity" on
/// this provider was not a deferred state machine — it was wiring tools at all.
///
/// Written as its own type rather than by widening `ToolCallRouter` because the two wire contracts
/// genuinely differ: Gemini's two-phase `willContinue`/`scheduling` ack has no Realtime equivalent
/// (a function output is one `conversation.item.create` followed by a `response.create`), and
/// folding both into one router would have put a Gemini-shaped branch in every Realtime path. What
/// *is* shared is shared: `NativeToolRouter.executeRoot` executes the call, `ToolCallBreaker`
/// bounds a runaway loop, and `PromptInjectionPolicy` frames untrusted output — the three things
/// that decide what actually happens.
@MainActor
final class OpenAIRealtimeToolRouter {

    /// Where a call is executed. Injected so the router is exercisable with a scripted fake.
    var nativeToolRouter: NativeToolRouter?

    /// Send one already-built JSON envelope to the session.
    private let send: ([String: Any]) -> Void

    private var inFlight: [String: Task<Void, Never>] = [:]
    private var breaker = ToolCallBreaker()

    init(send: @escaping ([String: Any]) -> Void) {
        self.send = send
    }

    /// A wearer turn breaks the consecutive-call window, exactly as it does on the Gemini router.
    func noteUserTurn() { breaker.recordUserTurn() }

    func handle(_ call: OpenAIRealtimeFunctionCall) {
        PrivacyLog.toolCallReceived(name: call.name, invocation: call.callId)

        if case .suspended(let message) = breaker.admit(toolName: call.name) {
            PrivacyLog.toolCallRefused(name: call.name, invocation: call.callId)
            respond(callId: call.callId, name: call.name, result: .failure(message))
            return
        }

        let argsKey = ToolCallBreaker.argsKey(call.args)
        let startedAt = Date()
        inFlight[call.callId] = Task { @MainActor [weak self] in
            guard let self else { return }
            var outcome: ToolExecutionOutcome
            if let router = self.nativeToolRouter {
                // The API's own call id, so a redelivered call resolves to the operation that
                // already ran rather than running it twice.
                outcome = await router.executeRoot(name: call.name, args: call.args,
                                                   origin: .model, invocationID: call.callId)
            } else {
                outcome = .failedBeforeExecution(reason: "Unknown tool '\(call.name)'")
            }
            guard !Task.isCancelled else {
                PrivacyLog.toolCallCancelled(invocation: call.callId)
                return
            }
            if let notice = self.breaker.recordOutcome(toolName: call.name, argsKey: argsKey,
                                                       success: outcome.isCompleted) {
                switch outcome {
                case .rejected(let reason): outcome = .rejected(reason: "\(reason)\n\(notice)")
                case .failedBeforeExecution(let reason):
                    outcome = .failedBeforeExecution(reason: "\(reason)\n\(notice)")
                case .completed, .outcomeUnknown: break
                }
            }
            PrivacyLog.toolCallCompleted(
                name: call.name, invocation: call.callId, outcome: outcome.privacyOutcome,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000))
            self.respond(callId: call.callId, name: call.name, result: outcome.toolResult)
            self.inFlight.removeValue(forKey: call.callId)
        }
    }

    func cancelAll() {
        for (id, task) in inFlight {
            PrivacyLog.toolCallCancelled(invocation: id)
            task.cancel()
        }
        inFlight.removeAll()
    }

    private func respond(callId: String, name: String, result: ToolResult) {
        let isKnownNative = nativeToolRouter?.registry.tool(named: name) != nil
        let output: String
        switch result {
        case .success(let text):
            output = PromptInjectionPolicy.isUntrustedOutput(toolName: name,
                                                             isKnownNativeTool: isKnownNative)
                ? PromptInjectionPolicy.wrap(toolName: name, content: text)
                : text
        case .failure(let error):
            output = Self.errorEnvelope(error)
        }
        for message in Self.outputMessages(callId: callId, output: output) { send(message) }
    }

    // MARK: - Wire shape (pure, testable)

    /// A tool failure, as the model sees it. JSON rather than bare prose so a failure reads as a
    /// result and not as a sentence the model might repeat verbatim to the wearer.
    static func errorEnvelope(_ error: String) -> String {
        LiveJobContract.canonicalJSON(["error": error])
    }

    /// The two messages one function result takes on this transport: the output item, then the
    /// request for the model to carry on. Both are needed — `conversation.item.create` alone
    /// appends the result and the model never speaks again, which is the Realtime spelling of the
    /// `turnComplete` trap the injection path already documents.
    static func outputMessages(callId: String, output: String) -> [[String: Any]] {
        [
            ["type": "conversation.item.create",
             "item": ["type": "function_call_output", "call_id": callId, "output": output]],
            ["type": "response.create"],
        ]
    }
}
