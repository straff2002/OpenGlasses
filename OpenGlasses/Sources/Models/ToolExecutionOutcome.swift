import Foundation

/// What a caller may safely do next, as a value rather than as prose the model has to interpret.
///
/// The wire text already tells the model what happened, but the tool-loop driver, the live-session
/// circuit breaker, and (in a later phase) the operation journal all need the same fact without
/// parsing English.
enum ToolRetryDisposition: String, Sendable, Equatable {
    /// Nothing happened, and repeating the call is safe.
    case safeToRetry
    /// Nothing happened, and repeating it will be turned down the same way.
    case retryWillBeRefused
    /// The effect may already have landed. Never repeat this automatically.
    case unsafeToRetry
}

/// The result of taking one resolved call through the execution authority.
///
/// The old success/failure pair could not tell "we know it didn't happen" apart from "we stopped
/// waiting and it may still land", so a timeout reported a side-effecting call as failed and both
/// the model and the user were free to retry it — duplicating the message, the unlock, the export.
/// `outcomeUnknown` is the case that shape was missing.
enum ToolExecutionOutcome: Sendable, Equatable {
    /// Authoritative success; `value` is the tool's own output.
    case completed(String)
    /// Policy prevented execution — refused, blocked, held, or declined at the confirmation gate.
    case rejected(reason: String)
    /// Authoritative failure with no side effect: the tool was never found, never reached, or
    /// failed outright before doing anything.
    case failedBeforeExecution(reason: String)
    /// Execution began and may still land. `operationID` is the invocation that started it, which
    /// is what a durable operation journal keys off later.
    case outcomeUnknown(operationID: String, message: String)

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    /// The machine-readable half of the answer.
    var retryDisposition: ToolRetryDisposition {
        switch self {
        case .completed: return .safeToRetry
        case .rejected: return .retryWillBeRefused
        case .failedBeforeExecution: return .safeToRetry
        case .outcomeUnknown: return .unsafeToRetry
        }
    }

    /// The text a provider wire carries — the tool's output, or the reason it has instead.
    var text: String {
        switch self {
        case .completed(let value): return value
        case .rejected(let reason): return reason
        case .failedBeforeExecution(let reason): return reason
        case .outcomeUnknown(_, let message): return message
        }
    }

    /// The wire shape the provider adapters have always spoken. Only `completed` is a success:
    /// everything else reaches the model as an error it is told, in the text, not to retry.
    var toolResult: ToolResult {
        isCompleted ? .success(text) : .failure(text)
    }

    /// Lift a result that came back from a path with no outcome typing of its own (the gateway
    /// bridge, a breaker refusal). Such a path answers authoritatively or not at all, so its failure
    /// is a real failure — the uncertain case is only ever produced where the uncertainty is known.
    init(_ result: ToolResult) {
        switch result {
        case .success(let value): self = .completed(value)
        case .failure(let reason): self = .failedBeforeExecution(reason: reason)
        }
    }

    // MARK: - Copy

    /// What the model is told when the wait ran out on work that may still land. It must read as
    /// "unknown", never as "failed" — a model told a send failed will offer to send it again.
    static func timedOutUnknown(tool: String, seconds: Int) -> String {
        "'\(tool)' timed out after \(seconds)s. It was NOT cancelled and may still complete, so "
            + "whether it took effect is unknown. Do NOT retry it or call anything equivalent. Tell "
            + "the user you're not sure it went through and that you're checking."
    }

    /// What the model is told when the wait ran out on a read, which leaves nothing behind.
    static func timedOutRead(tool: String, seconds: Int) -> String {
        "'\(tool)' timed out after \(seconds)s and was stopped; it had no effect. You may try again "
            + "or answer without it."
    }

    /// The user-facing line for an uncertain outcome — short, plain, and honest that we're still
    /// finding out. Nil for every other case, which the existing status text already covers.
    var userFacingStatus: String? {
        guard case .outcomeUnknown = self else { return nil }
        return "Status unknown — checking"
    }
}

/// Thrown by a tool that composed another call and cannot answer for how it ended.
///
/// A `NativeTool` returns a `String`, so a composing wrapper would otherwise have to flatten an
/// uncertain child outcome into its own successful return value — turning "this may still land"
/// into "this is what happened". Throwing it lets the router re-raise the child's outcome as the
/// parent's own.
struct RelayedToolOutcome: Error {
    let outcome: ToolExecutionOutcome
}
