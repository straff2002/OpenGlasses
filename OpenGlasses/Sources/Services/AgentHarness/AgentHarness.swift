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

    /// Dispatch a task with an optional camera still (Plan CN). Defaulted below so adapters that
    /// have no image channel — and every existing test — keep working untouched.
    func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun

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

    /// Plan CN default: an adapter with no image channel simply ignores the attachment rather than
    /// failing the dispatch. Losing the picture degrades the task; refusing it loses the task.
    func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun {
        try await start(prompt: prompt, project: project)
    }
}

/// Errors an adapter surfaces to `AgentSessionService` (mapped to spoken/tool failures).
enum AgentHarnessError: LocalizedError, Equatable {
    case notConfigured(AgentHarnessKind)
    case transport(String)
    /// An HTTP error answer from the endpoint. The **code only** — the response body is endpoint
    /// content and never reaches a spoken line (Plan FE P0 payload hygiene); it is counted in the
    /// privacy log instead.
    case http(Int)
    /// The endpoint answered with a status value we do not recognise (raw label, bounded).
    case unknownStatus(String)
    case unsupported(String)
    case agentModeOff   // BK P0: dispatch is an autonomous action — gated at the service layer

    var errorDescription: String? {
        switch self {
        case .notConfigured(let kind):
            return "\(kind.displayName) isn't configured yet."
        case .transport(let message):
            return message
        case .http(let code):
            return "The agent endpoint returned HTTP \(code)."
        case .unknownStatus(let raw):
            return raw.isEmpty
                ? "The agent endpoint didn't report a status I recognise."
                : "The agent endpoint reported a status I don't recognise: \(raw)."
        case .unsupported(let what):
            return "\(what) isn't supported by this harness yet."
        case .agentModeOff:
            return "Agent Mode is off; remote agent dispatch is disabled."
        }
    }
}
