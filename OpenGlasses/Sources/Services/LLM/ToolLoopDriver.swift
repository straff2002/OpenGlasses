import Foundation

// MARK: - Provider-neutral tool-loop primitives (Plan BG P3)
//
// The Anthropic, OpenAI-compatible, and Gemini send paths were four near-identical copies of the
// same tool-execution loop — request → parse → dispatch tools → append results → repeat until the
// model stops calling tools or the iteration cap is hit. Every tool-loop fix (Plan BF history
// hygiene, yield-to-human, malformed-arg handling) had to be made in each copy. This file holds the
// single shared loop (`runToolLoop`) and the single shared tool-dispatch step (`ToolDispatcher`);
// each provider now supplies only its wire-format translation via a `ProviderLoopAdapter`.

/// A tool call the model requested, normalised across providers.
struct ToolInvocation {
    /// Anthropic `tool_use.id` / OpenAI `tool_call.id`. Gemini is name-keyed, so `nil` there.
    let id: String?
    let name: String
    /// Parsed arguments. `nil` means the arguments failed to parse — the dispatcher returns a
    /// correctable parse error instead of executing the tool (preserves the OpenAI-path behaviour).
    let arguments: [String: Any]?
    /// The original argument string, when the provider delivered one (OpenAI). Used for the
    /// OpenClaw bridge fallback (`task`) and error messages.
    let rawArguments: String?

    init(id: String?, name: String, arguments: [String: Any]?, rawArguments: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.rawArguments = rawArguments
    }
}

/// One model turn as the driver sees it.
struct AssistantTurn {
    /// Concatenated text blocks (the final answer when `toolCalls` is empty).
    let text: String
    /// The tool calls the model requested this turn — empty means it produced a final answer.
    let toolCalls: [ToolInvocation]
    /// Opaque provider payload (Anthropic content blocks / OpenAI message dict / Gemini parts) that
    /// the adapter appends to history verbatim. The driver never inspects it.
    let payload: Any?

    init(text: String, toolCalls: [ToolInvocation] = [], payload: Any? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.payload = payload
    }
}

/// The result of dispatching one tool call.
struct ToolDispatchOutcome {
    let invocation: ToolInvocation
    let result: ToolResult
    /// Non-nil when this was a successful `yield_to_human` — the loop returns this to hand control
    /// back to the user.
    let yieldReason: String?
}

/// Runs a single tool call: parses guard, executes via the injected executor, tracks status, and
/// detects `yield_to_human`. Provider-neutral and free of `LLMService`, so it is unit-testable with
/// a mock executor.
struct ToolDispatcher {
    /// Executes a well-formed native/gateway tool call. `rawArguments` is the original arg string
    /// (OpenAI) for the bridge `task` fallback.
    let execute: (_ name: String, _ args: [String: Any], _ rawArguments: String?) async -> ToolResult
    /// Reports status transitions (executing → completed/failed) to the UI.
    let onStatus: (ToolCallStatus) -> Void

    func dispatch(_ invocation: ToolInvocation) async -> ToolDispatchOutcome {
        onStatus(.executing(invocation.name))
        let result: ToolResult
        if let args = invocation.arguments {
            result = await execute(invocation.name, args, invocation.rawArguments)
        } else {
            result = .failure("Could not parse the arguments for '\(invocation.name)' as JSON. Re-issue the call with valid JSON arguments.")
        }
        onStatus(result.isSuccess ? .completed(invocation.name) : .failed(invocation.name, "Failed"))
        return ToolDispatchOutcome(
            invocation: invocation,
            result: result,
            yieldReason: Self.yieldReason(name: invocation.name, result: result)
        )
    }

    /// A successful `yield_to_human` result carries `YIELD_TO_HUMAN: <reason>` — extract the reason
    /// so the loop can break and speak it. Returns `nil` for every other call.
    static func yieldReason(name: String, result: ToolResult) -> String? {
        guard name == "yield_to_human",
              case .success(let text) = result,
              text.hasPrefix("YIELD_TO_HUMAN:") else { return nil }
        return text
            .replacingOccurrences(of: "YIELD_TO_HUMAN: ", with: "")
            .replacingOccurrences(of: "\nWaiting for you to say \"done\" or \"continue\" when ready.", with: "")
    }
}

/// Per-provider wire-format translation the shared loop drives. Everything here is closures so an
/// adapter can capture the live `LLMService` (history, config, streaming helpers) without moving
/// that state into new types — while the loop itself stays provider-neutral and testable.
struct ProviderLoopAdapter {
    /// Provider name for error messages (e.g. "Anthropic").
    let label: String
    /// Shared dispatcher (built once per send with the provider's executor).
    let dispatcher: ToolDispatcher
    /// Perform one request against the current history and parse the model's turn.
    let performTurn: () async throws -> AssistantTurn
    /// Append the assistant's tool-calling message to history (provider wire shape).
    let appendAssistantToolCall: (AssistantTurn) -> Void
    /// Append the results of this iteration's tool calls to history. Anthropic/OpenAI append one
    /// message per result; Gemini batches them into a single `function` message.
    let appendToolResults: ([ToolDispatchOutcome]) -> Void
    /// Append the final assistant text to history and return it; throw if empty.
    let finalize: (AssistantTurn) throws -> String
}

/// The single shared tool-execution loop. Iterates up to `maxIterations`: performs a turn, and if
/// the model called tools, appends the assistant message, dispatches each call, appends the results,
/// and loops; otherwise finalises and returns the answer. Breaks early on `yield_to_human`.
///
/// `@MainActor` because it drives `LLMService`'s published `toolCallStatus` and history through the
/// adapter closures; it is still testable by passing a synthetic adapter with an in-memory history.
@MainActor
func runToolLoop(
    maxIterations: Int,
    adapter: ProviderLoopAdapter,
    setStatus: (ToolCallStatus) -> Void
) async throws -> String {
    for _ in 0..<maxIterations {
        try Task.checkCancellation()
        let turn = try await adapter.performTurn()

        if turn.toolCalls.isEmpty {
            let text = try adapter.finalize(turn)
            setStatus(.idle)
            return text
        }

        adapter.appendAssistantToolCall(turn)

        // Plan CU P1: one round trip's execution, held apart from the model's own time. With 36+
        // native tools behind this loop, a turn that spent four seconds inside a HomeKit call
        // otherwise reports four seconds of model latency and we go and optimise the model. The
        // `defer` covers the yield-to-human return below as well as the normal exit.
        let toolsStartedAt = Date()
        defer { TurnRecorder.addToolTime(since: toolsStartedAt) }

        var outcomes: [ToolDispatchOutcome] = []
        for call in turn.toolCalls {
            let outcome = await adapter.dispatcher.dispatch(call)
            outcomes.append(outcome)
            if let reason = outcome.yieldReason {
                adapter.appendToolResults(outcomes)
                setStatus(.yielded(call.name))
                NSLog("[LLMService] Yielding to human: %@", reason)
                return reason
            }
        }
        adapter.appendToolResults(outcomes)
    }

    setStatus(.idle)
    throw LLMError.invalidResponse("\(adapter.label) (tool call loop exceeded)")
}
