import Foundation

/// One remote agent backend, behind a uniform interface (Plan N). Mirrors how `LLMProvider`
/// abstracts LLM backends: the rest of the app dispatches/cancels/streams against this protocol and
/// never knows which harness ran. Adapters own the native protocol translation; everything above
/// them works in `AgentEvent`/`AgentRunResult`.
protocol AgentHarness {
    var kind: AgentHarnessKind { get }
    var displayName: String { get }

    /// Whether the credentials/endpoint needed to run are present. The registry lists only
    /// configured harnesses, and the tool refuses to dispatch to an unconfigured one.
    var isConfigured: Bool { get }

    /// Dispatch a task. Returns the created run (typically `.queued`/`.running`).
    func start(prompt: String, project: String?) async throws -> AgentRun

    /// Normalized event stream for a run — stream- or poll-backed by the adapter.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent>

    /// Current status (for an explicit "agent status" query).
    func status(_ run: AgentRun) async throws -> AgentRunStatus

    /// Request cancellation of a run.
    func cancel(_ run: AgentRun) async throws

    /// Answer an `awaitingInput` confirmation (e.g. approve a push). Default no-op for harnesses
    /// that don't support interactive confirmation.
    func respondToInput(_ run: AgentRun, approved: Bool) async throws
}

extension AgentHarness {
    func respondToInput(_ run: AgentRun, approved: Bool) async throws {}
}

/// Errors an adapter surfaces to `AgentSessionService` (mapped to spoken/tool failures).
enum AgentHarnessError: LocalizedError, Equatable {
    case notConfigured(AgentHarnessKind)
    case transport(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let kind):
            return "\(kind.displayName) isn't configured yet."
        case .transport(let message):
            return message
        case .unsupported(let what):
            return "\(what) isn't supported by this harness yet."
        }
    }
}
