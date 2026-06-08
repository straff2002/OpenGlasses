import Foundation

/// Routes Gemini WebSocket tool calls to native tools first, then OpenClaw bridge.
/// Used in Gemini Live mode when Gemini issues function calls over the WebSocket.
@MainActor
class ToolCallRouter {
    private let bridge: OpenClawBridge
    var nativeToolRouter: NativeToolRouter?
    private var inFlightTasks: [String: Task<Void, Never>] = [:]

    /// Callback to pause/resume camera streaming during tool execution (prevents instability).
    var onToolExecutionStarted: (() -> Void)?
    var onToolExecutionFinished: (() -> Void)?

    init(bridge: OpenClawBridge) {
        self.bridge = bridge
    }

    func handleToolCall(
        _ call: GeminiFunctionCall,
        sendResponse: @escaping ([String: Any]) -> Void
    ) {
        let callId = call.id
        let callName = call.name

        NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
              callName, callId, String(describing: call.args))

        // Pause camera/audio streaming during tool execution to prevent instability
        onToolExecutionStarted?()

        let task = Task { @MainActor in
            // Route through NativeToolRouter first (handles native → MCP → OpenClaw cascade)
            let result: ToolResult
            if let router = nativeToolRouter {
                result = await router.handleToolCall(name: callName, args: call.args)
            } else {
                // Fallback: direct OpenClaw delegation (legacy path)
                let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
                result = await bridge.delegateTask(task: taskDesc, toolName: callName)
            }

            // Resume streaming after tool execution
            self.onToolExecutionFinished?()

            guard !Task.isCancelled else {
                NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
                return
            }

            NSLog("[ToolCall] Result for %@ (id: %@): %@",
                  callName, callId, String(describing: result))

            let response = self.buildToolResponse(callId: callId, name: callName, result: result)
            sendResponse(response)

            self.inFlightTasks.removeValue(forKey: callId)
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
        }
        bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
    }

    func cancelAll() {
        for (id, task) in inFlightTasks {
            NSLog("[ToolCall] Cancelling in-flight call: %@", id)
            task.cancel()
        }
        inFlightTasks.removeAll()
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
        return [
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": callId,
                        "name": name,
                        "response": responseValue
                    ]
                ]
            ]
        ]
    }
}
