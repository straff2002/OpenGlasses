import Foundation

/// The real, phone-only agent harness (Plan N): drives a remote agent through the OpenClaw
/// gateway. Dispatch rides `OpenClawBridge`'s `{type:"req",id,method,params}` transport via an
/// injected `send` closure (AppState wires `OpenClawBridge.agentRequest`; tests inject a mock),
/// so the adapter is testable without a live socket.
///
/// Wire (Plan EH P1): there is no `agent.*` method family on the gateway. A task is one
/// `sessions.send` into a dedicated task session (created on demand), which answers with a
/// `runId`; the run's progress and final text arrive as `chat` events on the bridge socket and
/// are folded into `ChatRunTracker`, which this harness polls through `runState`. Cancellation
/// is `sessions.abort` on that session and run.
struct OpenClawAgentHarness: AgentHarness {
    let kind: AgentHarnessKind = .openclaw
    var displayName: String { kind.displayName }

    /// The session every delegated task runs in — one stable key, so the gateway keeps context
    /// across tasks and `sessions.abort` needs no lookup.
    static let taskSessionKey = "agent:main:glass:tasks"

    /// Sends a gateway request and returns the parsed response. Injected so it's mockable.
    let send: (_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    /// Whether OpenClaw is configured (URL + token). Injected so tests don't touch `Config`.
    let configured: () -> Bool
    /// Terminal-state snapshot for a run the bridge is tracking; nil when unknown.
    let runState: (_ runId: String) async -> ChatRunTracker.RunState?
    /// Poll cadence for `events(for:)`; tests shorten it.
    var pollInterval: TimeInterval = 3

    var isConfigured: Bool { configured() }

    init(send: @escaping (_ method: String, _ params: [String: Any]) async throws -> [String: Any],
         configured: @escaping () -> Bool = { Config.isOpenClawConfigured },
         runState: @escaping (_ runId: String) async -> ChatRunTracker.RunState? = { _ in nil }) {
        self.send = send
        self.configured = configured
        self.runState = runState
    }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        try await start(prompt: prompt, project: project, attachment: nil)
    }

    func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun {
        var message = prompt
        if let project, !project.isEmpty { message = "Project: \(project)\n\n\(prompt)" }
        var attachments: [GatewayAttachment] = []
        if let attachment {
            // Plan CN: the frame rides the schema's `attachments` list; the gateway advertises its
            // per-image ceiling in hello-ok and the bridge drops oversize frames before sending.
            attachments.append(GatewayAttachment(mimeType: "image/jpeg", fileName: "glasses.jpg",
                                                 content: attachment.jpeg))
        }
        let request = GatewayRequestCatalog.sessionsSend(
            key: Self.taskSessionKey, message: message, attachments: attachments,
            idempotencyKey: UUID().uuidString)
        let response = try await send(request.method, request.params)
        if let error = Self.errorMessage(in: response) {
            throw AgentHarnessError.transport(error)
        }
        guard let id = Self.runID(in: response) else {
            throw AgentHarnessError.transport("Gateway did not return a run id.")
        }
        return AgentRun(id: id, harness: .openclaw, prompt: prompt, project: project,
                        status: .running, startedAt: Date())
    }

    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        guard let state = await runState(run.id) else { return .running }
        return Self.status(for: state)
    }

    func cancel(_ run: AgentRun) async throws {
        let request = GatewayRequestCatalog.sessionsAbort(key: Self.taskSessionKey, runId: run.id)
        let response = try await send(request.method, request.params)
        if let error = Self.errorMessage(in: response) { throw AgentHarnessError.transport(error) }
    }

    func respondToInput(_ run: AgentRun, approved: Bool) async throws {
        // Approvals are a first-class gateway surface (`exec.approval.*`) wired in Plan EH P2.
        throw AgentHarnessError.transport("This gateway answers approvals through its own approval surface, which is not wired yet.")
    }

    /// Poll the tracked run until terminal: `.started`, then `.completed` (with the final text)
    /// or `.error`. Cancelled runs complete with an empty result.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        let interval = pollInterval
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    guard let state = await self.runState(run.id), state.isTerminal else { continue }
                    switch state.phase {
                    case .answered(let text):
                        var result = AgentRunResult()
                        result.finalText = text.isEmpty ? nil : text
                        continuation.yield(.completed(result))
                    case .failed(let message):
                        continuation.yield(.error(message ?? "The agent run failed."))
                    case .aborted:
                        continuation.yield(.completed(AgentRunResult()))
                    case .running:
                        continue
                    }
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pure normalization (unit-tested)

    static func status(for state: ChatRunTracker.RunState) -> AgentRunStatus {
        switch state.phase {
        case .running: return .running
        case .answered: return .completed
        case .aborted: return .cancelled
        case .failed: return .failed
        }
    }

    /// Map one gateway event payload to the shared `AgentEvent`, or `nil` for an unknown/ignored
    /// shape. The gateway tags each event with a `kind`; field names mirror the gateway schema.
    static func normalize(_ json: [String: Any]) -> AgentEvent? {
        guard let kind = (json["kind"] ?? json["type"]) as? String else { return nil }
        switch kind {
        case "file_created":
            return (json["path"] as? String).map(AgentEvent.fileCreated)
        case "file_modified":
            return (json["path"] as? String).map(AgentEvent.fileModified)
        case "command":
            guard let command = json["command"] as? String else { return nil }
            return .commandRun(command: command, ok: json["ok"] as? Bool ?? true)
        case "pr_opened":
            return (json["url"] as? String).map(AgentEvent.prOpened)
        case "pushed":
            return .pushed
        case "progress":
            return (json["text"] as? String).map(AgentEvent.progress)
        case "assistant":
            return (json["text"] as? String).map(AgentEvent.assistantText)
        case "awaiting_input":
            return .awaitingInput(prompt: json["prompt"] as? String ?? "The agent needs your confirmation.")
        case "error":
            return .error(json["message"] as? String ?? "Unknown error.")
        case "completed":
            return .completed(result(from: json["result"] as? [String: Any] ?? [:]))
        default:
            return nil
        }
    }

    /// Parse a gateway result payload into an `AgentRunResult`.
    static func result(from json: [String: Any]) -> AgentRunResult {
        var result = AgentRunResult()
        result.filesCreated = json["filesCreated"] as? [String] ?? []
        result.filesModified = json["filesModified"] as? [String] ?? []
        result.commandsRun = json["commandsRun"] as? [String] ?? []
        result.prURL = json["prURL"] as? String
        result.pushed = json["pushed"] as? Bool ?? false
        result.finalText = json["finalText"] as? String
        result.error = json["error"] as? String
        return result
    }

    /// Map a gateway status string to `AgentRunStatus`. Delegates to the shared `AgentRunStatus.parse`
    /// (kept as a named entry point for the adapter's call sites/tests).
    static func parseStatus(_ raw: String?) -> AgentRunStatus? {
        AgentRunStatus.parse(raw)
    }

    /// The gateway's error, whether it came back as a `{ok:false, error:{message}}` frame or a
    /// bare `error` string from a mock.
    static func errorMessage(in response: [String: Any]) -> String? {
        if let error = response["error"] as? String { return error }
        if let error = response["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String) ?? "Gateway error"
        }
        if (response["ok"] as? Bool) == false { return "Gateway refused the request" }
        return nil
    }

    /// Pull a run id out of a gateway response under any of the common keys.
    static func runID(in response: [String: Any]) -> String? {
        for key in ["id", "runId", "run_id"] {
            if let id = response[key] as? String, !id.isEmpty { return id }
        }
        // The real gateway nests it under `payload`; some mocks under `result`.
        for container in ["payload", "result"] {
            if let nested = response[container] as? [String: Any] {
                for key in ["id", "runId", "run_id"] {
                    if let id = nested[key] as? String, !id.isEmpty { return id }
                }
            }
        }
        return nil
    }
}
