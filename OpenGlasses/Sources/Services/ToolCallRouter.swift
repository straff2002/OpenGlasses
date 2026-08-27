import Foundation

/// Routes Gemini WebSocket tool calls to native tools first, then OpenClaw bridge.
/// Used in Gemini Live mode when Gemini issues function calls over the WebSocket.
@MainActor
class ToolCallRouter {
    private let bridge: OpenClawBridge
    var nativeToolRouter: NativeToolRouter?
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// Two-phase response support (`Config.geminiNonBlockingToolsEnabled`): calls still
    /// running at `ackDelay` get an immediate ack (`willContinue` + SILENT scheduling) so
    /// the model's open transaction closes fast; their final result is then delivered
    /// WHEN_IDLE so the announcement never barges into the user. Fast calls keep the
    /// plain single-response shape.
    private var ackTimers: [String: Task<Void, Never>] = [:]
    private var ackedCallIds: Set<String> = []
    static let ackDelay: Duration = .seconds(1)

    /// Plan BR P1: per-session circuit breaker — bounds runaway tool loops. The session
    /// manager resets its user-turn window and reads `suspendedToolNames` when re-declaring
    /// tools on reconnect.
    private var breaker = ToolCallBreaker()
    var suspendedToolNames: Set<String> { breaker.suspendedTools }

    /// Callback to pause/resume camera streaming during tool execution (prevents instability).
    var onToolExecutionStarted: (() -> Void)?
    var onToolExecutionFinished: (() -> Void)?

    init(bridge: OpenClawBridge) {
        self.bridge = bridge
    }

    /// A user turn breaks the consecutive-call window (wired to input transcription).
    func noteUserTurn() {
        breaker.recordUserTurn()
    }

    func handleToolCall(
        _ call: GeminiFunctionCall,
        sendResponse: @escaping ([String: Any]) -> Void
    ) {
        let callId = call.id
        let callName = call.name

        NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
              callName, callId, String(describing: call.args))

        // Plan BR P1: refuse suspended/runaway calls without executing — the message rides
        // back as the tool error so the model learns in-band and informs the user.
        if case .suspended(let message) = breaker.admit(toolName: callName) {
            NSLog("[ToolCall] Breaker refused %@ (id: %@)", callName, callId)
            sendResponse(buildToolResponse(callId: callId, name: callName, result: .failure(message)))
            return
        }

        // Pause camera/audio streaming during tool execution to prevent instability
        onToolExecutionStarted?()

        if Config.geminiNonBlockingToolsEnabled {
            ackTimers[callId] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.ackDelay)
                guard let self, !Task.isCancelled, self.inFlightTasks[callId] != nil else { return }
                self.ackedCallIds.insert(callId)
                NSLog("[ToolCall] %@ (id: %@) still running — sending non-blocking ack", callName, callId)
                sendResponse(Self.toolResponse(
                    callId: callId, name: callName,
                    payload: ["result": "Still working — the result will follow."],
                    phase: .ack))
            }
        }

        let argsKey = ToolCallBreaker.argsKey(call.args)
        let task = Task { @MainActor in
            // Route through NativeToolRouter first (handles native → MCP → OpenClaw cascade)
            var outcome: ToolExecutionOutcome
            if let router = nativeToolRouter {
                outcome = await router.executeRoot(name: callName, args: call.args)
            } else if Config.isOpenClawAgentActive {
                // Fallback: direct OpenClaw delegation (legacy path). BK P0: only as an active
                // agentic capability — delegateTask itself now fails closed otherwise, but don't
                // route here at all with Agent Mode off.
                let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
                outcome = ToolExecutionOutcome(
                    await bridge.delegateTask(task: taskDesc, toolName: callName))
            } else {
                outcome = .failedBeforeExecution(reason: "Unknown tool '\(callName)'")
            }

            // Resume streaming after tool execution
            self.onToolExecutionFinished?()

            guard !Task.isCancelled else {
                NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
                return
            }

            // Identical-failure tracking: a tripped breaker appends its notice to the error
            // so the model stops retrying instead of hammering the same broken call. An unresolved
            // outcome is left alone — its own copy already forbids the retry, and counting it as a
            // failure would let a slow tool trip the breaker on work that is actually succeeding.
            if let notice = self.breaker.recordOutcome(
                toolName: callName, argsKey: argsKey, success: outcome.isCompleted) {
                switch outcome {
                case .rejected(let reason):
                    outcome = .rejected(reason: "\(reason)\n\(notice)")
                case .failedBeforeExecution(let reason):
                    outcome = .failedBeforeExecution(reason: "\(reason)\n\(notice)")
                case .completed, .outcomeUnknown:
                    break
                }
            }

            NSLog("[ToolCall] Result for %@ (id: %@): %@",
                  callName, callId, String(describing: outcome))

            let response = self.buildToolResponse(callId: callId, name: callName,
                                                  result: outcome.toolResult)
            sendResponse(response)

            self.inFlightTasks.removeValue(forKey: callId)
            self.ackTimers.removeValue(forKey: callId)?.cancel()
        }

        inFlightTasks[callId] = task
    }

    func cancelToolCalls(ids: [String]) {
        for id in ids {
            if let task = inFlightTasks[id] {
                NSLog("[ToolCall] Cancelling in-flight call: %@", id)
                task.cancel()
                inFlightTasks.removeValue(forKey: id)
            }
            ackTimers.removeValue(forKey: id)?.cancel()
            ackedCallIds.remove(id)
        }
        bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
    }

    func cancelAll() {
        for (id, task) in inFlightTasks {
            NSLog("[ToolCall] Cancelling in-flight call: %@", id)
            task.cancel()
        }
        inFlightTasks.removeAll()
        for (_, timer) in ackTimers { timer.cancel() }
        ackTimers.removeAll()
        ackedCallIds.removeAll()
    }

    // MARK: - Private

    private func buildToolResponse(
        callId: String,
        name: String,
        result: ToolResult
    ) -> [String: Any] {
        // Frame untrusted external content (web, OCR, captions, gateway, MCP, …) as data so
        // injected instructions inside it are visibly bounded, not treated as commands.
        let responseValue: [String: Any]
        switch result {
        case .success(let text):
            let isKnownNative = nativeToolRouter?.registry.tool(named: name) != nil
            let framed = PromptInjectionPolicy.isUntrustedOutput(toolName: name, isKnownNativeTool: isKnownNative)
                ? PromptInjectionPolicy.wrap(toolName: name, content: text)
                : text
            responseValue = ["result": framed]
        case .failure(let error):
            responseValue = ["error": error]
        }
        let phase: ResponsePhase = ackedCallIds.remove(callId) != nil ? .finalAfterAck : .direct
        return Self.toolResponse(callId: callId, name: name, payload: responseValue, phase: phase)
    }

    // MARK: - Response shape (pure, testable)

    /// Which leg of the (possibly two-phase) exchange a response is.
    enum ResponsePhase {
        /// The only response for a call that finished fast — plain shape, model handles
        /// delivery normally. Also used whenever the non-blocking flag is off.
        case direct
        /// Early ack for a still-running NON_BLOCKING call: `willContinue` keeps the call
        /// open, SILENT scheduling stops the model narrating the ack.
        case ack
        /// The real result after an ack: WHEN_IDLE scheduling so the announcement waits
        /// for the user's turn to finish instead of interrupting.
        case finalAfterAck
    }

    /// Build the wire shape for one function response. Static + value-in/value-out so
    /// tests can pin the exact payload per phase.
    nonisolated static func toolResponse(
        callId: String,
        name: String,
        payload: [String: Any],
        phase: ResponsePhase
    ) -> [String: Any] {
        var functionResponse: [String: Any] = [
            "id": callId,
            "name": name,
            "response": payload
        ]
        switch phase {
        case .direct:
            break
        case .ack:
            functionResponse["willContinue"] = true
            functionResponse["scheduling"] = "SILENT"
        case .finalAfterAck:
            functionResponse["scheduling"] = "WHEN_IDLE"
        }
        return [
            "toolResponse": [
                "functionResponses": [functionResponse]
            ]
        ]
    }
}
