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

    func respondToInput(_ run: AgentRun, reply: AgentReply) async throws {
        // Approvals are a first-class gateway surface (`exec.approval.*`), wired in its own plan.
        // Until then this is honestly unsupported rather than quietly accepted: the wearer hears
        // that the answer did not go anywhere, and the run's status stays whatever the gateway says.
        throw AgentHarnessError.replyUnsupported(reply.body)
    }

    /// Poll the tracked run until terminal: `.started`, then `.completed` (with the final text),
    /// `.error`, or `.cancelled` for an aborted run — which `status(for:)` already called
    /// `.cancelled`, while the stream quietly reported it as a successful completion (Plan FE P0).
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
                        if let final = AgentResultMapping.sanitized(
                            text, limit: AgentResultMapping.maxFinalTextLength) {
                            result.finalText = final
                            result.reported.insert(.finalText)
                        }
                        continuation.yield(.completed(result))
                    case .failed(let message):
                        continuation.yield(.error(message ?? "The agent run failed."))
                    case .aborted:
                        continuation.yield(.cancelled(AgentRunResult()))
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
    /// - Parameters:
    ///   - runID: the run the event belongs to, so a question carries its run.
    ///   - sequence: arrival order, used only to derive an id for a question the gateway did not
    ///     name (Plan FE P1).
    static func normalize(_ json: [String: Any], runID: String = "", sequence: Int = 0) -> AgentEvent? {
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
            let prompt = AgentResultMapping.sanitized(json["prompt"] as? String,
                                                      limit: AgentResultMapping.maxPromptLength)
                ?? "The agent needs your confirmation."
            let explicit = AgentResultMapping.sanitized(
                (json["questionId"] ?? json["question_id"] ?? json["id"]) as? String,
                limit: AgentResultMapping.maxItemLength)
            let revision = (json["revision"] ?? json["questionRevision"]) as? Int ?? 0
            return .awaitingInput(AgentQuestion(
                id: explicit ?? AgentQuestion.derivedID(runID: runID, prompt: prompt, sequence: sequence),
                revision: revision,
                kind: AgentQuestion.kind(fromLabel: json["kind"] as? String ?? json["questionKind"] as? String,
                                         prompt: prompt),
                prompt: prompt,
                runID: runID))
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
        // Present-or-absent matters as much as the value: a key the gateway omitted is unknown,
        // and only a key it actually sent joins `reported` (Plan FE P0).
        if let created = json["filesCreated"] as? [String] {
            result.filesCreated = created
            result.reported.insert(.filesCreated)
        }
        if let modified = json["filesModified"] as? [String] {
            result.filesModified = modified
            result.reported.insert(.filesModified)
        }
        if let commands = json["commandsRun"] as? [String] {
            result.commandsRun = commands
            result.reported.insert(.commandsRun)
        }
        if let url = json["prURL"] as? String {
            result.prURL = AgentResultMapping.webURL(url)
            result.reported.insert(.prURL)
        }
        if let pushed = json["pushed"] as? Bool {
            result.pushed = pushed
            result.reported.insert(.pushed)
        }
        if let text = AgentResultMapping.sanitized(json["finalText"] as? String,
                                                   limit: AgentResultMapping.maxFinalTextLength) {
            result.finalText = text
            result.reported.insert(.finalText)
        }
        if let message = AgentResultMapping.sanitized(json["error"] as? String,
                                                      limit: AgentResultMapping.maxItemLength) {
            result.error = message
            result.reported.insert(.error)
        }
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
