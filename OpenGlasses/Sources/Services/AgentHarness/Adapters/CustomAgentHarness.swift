import Foundation

/// Generic HTTP agent harness (Plan N, Phase 2): drives any user-supplied endpoint described by a
/// `CustomHarnessConfig` — POST to start, GET to poll status, optional POST to cancel — mapping the
/// responses through `JSONPath`. Same opt-in spirit as a custom MCP server: supported, never
/// required, and entirely phone-only (we connect to a URL the user already runs).
///
/// The request building + response parsing live in `CustomHarnessConfig`/`JSONPath` (pure, tested);
/// this adapter is the thin async layer. `session` is injectable so tests exercise the HTTP shape
/// through a `URLProtocol` stub.
struct CustomAgentHarness: AgentHarness {
    let kind: AgentHarnessKind = .custom
    let config: CustomHarnessConfig
    var session: URLSession = .shared

    init(config: CustomHarnessConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var displayName: String {
        config.name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : config.name
    }
    var isConfigured: Bool { config.isConfigured }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        guard let request = config.startRequest(prompt: prompt, project: project) else {
            throw AgentHarnessError.notConfigured(.custom)
        }
        let json = try await sendJSON(request)
        guard let id = JSONPath.string(at: config.idPath, in: json) else {
            throw AgentHarnessError.transport("Response had no run id at '\(config.idPath)'.")
        }
        let status = AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
        return AgentRun(id: id, harness: .custom, prompt: prompt, project: project,
                        status: status, startedAt: Date())
    }

    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        guard let request = config.statusRequest(runID: run.id) else { return .running }
        let json = try await sendJSON(request)
        return AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
    }

    func cancel(_ run: AgentRun) async throws {
        guard let request = config.cancelRequest(runID: run.id) else {
            throw AgentHarnessError.unsupported("Cancel")
        }
        _ = try await sendJSON(request)
    }

    /// Status-poll event stream (no assumed push channel for an arbitrary endpoint). Emits
    /// `.started`, then polls until terminal and emits `.completed`/`.error`.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { break }
                    let status = (try? await self.status(run)) ?? .running
                    if status.isTerminal {
                        continuation.yield(status == .failed ? .error("The agent run failed.")
                                                             : .completed(AgentRunResult()))
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - HTTP

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AgentHarnessError.transport("HTTP \(http.statusCode): \(String(body.prefix(160)))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
