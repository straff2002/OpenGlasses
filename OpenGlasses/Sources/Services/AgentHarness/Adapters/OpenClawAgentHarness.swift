import Foundation

/// The real, phone-only agent harness (Plan N): drives a remote coding agent through the OpenClaw
/// gateway. Dispatch rides `OpenClawBridge`'s JSON-RPC-ish `{type:"req",id,method,params}` transport
/// via an injected `send` closure (AppState wires `OpenClawBridge.agentRequest`; tests inject a
/// mock), so the adapter is testable without a live socket.
///
/// The valuable, deterministic, *tested* unit is `normalize(_:)` — gateway event JSON → the shared
/// `AgentEvent`. The live event *stream* (subscribing to the gateway's per-run events) and the
/// gateway-side `agent.*` methods are the deferred integration: they need a running gateway that
/// exposes `agent.start`/`agent.status`/`agent.cancel`. Until then this drives a status-poll loop.
struct OpenClawAgentHarness: AgentHarness {
    let kind: AgentHarnessKind = .openclaw
    var displayName: String { kind.displayName }

    /// Sends a gateway request and returns the parsed response. Injected so it's mockable.
    let send: (_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    /// Whether OpenClaw is configured (URL + token). Injected so tests don't touch `Config`.
    let configured: () -> Bool

    var isConfigured: Bool { configured() }

    init(send: @escaping (_ method: String, _ params: [String: Any]) async throws -> [String: Any],
         configured: @escaping () -> Bool = { Config.isOpenClawConfigured }) {
        self.send = send
        self.configured = configured
    }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        var params: [String: Any] = ["prompt": prompt]
        if let project { params["project"] = project }
        let response = try await send("agent.start", params)
        if let error = response["error"] as? String {
            throw AgentHarnessError.transport(error)
        }
        guard let id = Self.runID(in: response) else {
            throw AgentHarnessError.transport("Gateway did not return a run id.")
        }
        let status = Self.parseStatus(response["status"] as? String) ?? .running
        return AgentRun(id: id, harness: .openclaw, prompt: prompt, project: project,
                        status: status, startedAt: Date())
    }

    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        let response = try await send("agent.status", ["id": run.id])
        return Self.parseStatus(response["status"] as? String) ?? .running
    }

    func cancel(_ run: AgentRun) async throws {
        _ = try await send("agent.cancel", ["id": run.id])
    }

    func respondToInput(_ run: AgentRun, approved: Bool) async throws {
        _ = try await send("agent.respond", ["id": run.id, "approved": approved])
    }

    /// Status-poll event stream (Phase 1). Emits `.started`, then polls `agent.status` until terminal
    /// and emits `.completed`/`.error`. The richer per-file/-command event stream from the gateway is
    /// deferred — `normalize(_:)` is ready to map it when the gateway exposes it.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { break }
                    let status = (try? await self.status(run)) ?? .running
                    if status.isTerminal {
                        if status == .failed {
                            continuation.yield(.error("The agent run failed."))
                        } else {
                            continuation.yield(.completed(AgentRunResult()))
                        }
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pure normalization (unit-tested)

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

    /// Pull a run id out of a gateway response under any of the common keys.
    static func runID(in response: [String: Any]) -> String? {
        for key in ["id", "runId", "run_id"] {
            if let id = response[key] as? String, !id.isEmpty { return id }
        }
        // Some gateways nest the result.
        if let result = response["result"] as? [String: Any] {
            for key in ["id", "runId", "run_id"] {
                if let id = result[key] as? String, !id.isEmpty { return id }
            }
        }
        return nil
    }
}
