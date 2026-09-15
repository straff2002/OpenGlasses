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
    let kind: AgentHarnessKind
    let config: CustomHarnessConfig
    var session: URLSession = .shared
    /// Bounded retry/backoff + unknown-status tolerance for `events(for:)` (Plan FE P0).
    var policy: AgentPollingPolicy = .default
    /// Injected so tests drive the poll loop without waiting out a single real tick.
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    private let displayNameOverride: String?
    private let isConfiguredOverride: Bool?

    /// - Parameters:
    ///   - kind: the harness identity. Defaults to `.custom`; the Codex / Claude Code presets pass
    ///     `.codexCloud` / `.claudeRemote` so dispatched runs are tagged correctly.
    ///   - displayName / isConfigured: optional overrides for the preset-backed harnesses (whose
    ///     readiness is gated on a token, not just the start URL).
    init(kind: AgentHarnessKind = .custom,
         config: CustomHarnessConfig,
         displayName: String? = nil,
         isConfigured: Bool? = nil,
         session: URLSession = .shared) {
        self.kind = kind
        self.config = config
        self.displayNameOverride = displayName
        self.isConfiguredOverride = isConfigured
        self.session = session
    }

    var displayName: String {
        if let displayNameOverride { return displayNameOverride }
        return config.name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : config.name
    }
    var isConfigured: Bool { isConfiguredOverride ?? config.isConfigured }

    // MARK: - AgentHarness

    func start(prompt: String, project: String?) async throws -> AgentRun {
        try await start(prompt: prompt, project: project, attachment: nil)
    }

    func start(prompt: String, project: String?, attachment: AgentTaskAttachment?) async throws -> AgentRun {
        guard let request = config.startRequest(prompt: prompt, project: project, attachment: attachment) else {
            throw AgentHarnessError.notConfigured(kind)
        }
        let json = try await sendJSON(request)
        guard let id = JSONPath.string(at: config.idPath, in: json) else {
            throw AgentHarnessError.transport("Response had no run id at '\(config.idPath)'.")
        }
        let status = AgentRunStatus.parse(JSONPath.string(at: config.statusPath, in: json)) ?? .running
        return AgentRun(id: id, harness: kind, prompt: prompt, project: project,
                        status: status, startedAt: Date())
    }

    /// One status GET, carrying **both** the lifecycle status and the mapped result — richer
    /// reporting at exactly the request volume we had before (Plan FE P0).
    struct Poll: Equatable {
        /// `nil` when the endpoint's status value is one we don't recognise (or absent).
        let status: AgentRunStatus?
        /// The raw label, sanitised and bounded, for an honest "it said X" report.
        let rawStatus: String
        let result: AgentRunResult
    }

    func poll(_ run: AgentRun) async throws -> Poll {
        guard let request = config.statusRequest(runID: run.id) else {
            throw AgentHarnessError.unsupported("Status polling")
        }
        let json = try await sendJSON(request)
        let raw = JSONPath.string(at: config.statusPath, in: json)
        return Poll(status: AgentRunStatus.parse(raw),
                    rawStatus: AgentResultMapping.statusLabel(raw),
                    result: AgentResultMapping.result(from: json, config: config))
    }

    /// Current status for an explicit query. An unrecognised value throws rather than defaulting to
    /// `.running`: claiming a run is working because we couldn't read its status is the bug this
    /// phase removes.
    func status(_ run: AgentRun) async throws -> AgentRunStatus {
        let poll = try await self.poll(run)
        guard let status = poll.status else {
            throw AgentHarnessError.unknownStatus(poll.rawStatus)
        }
        return status
    }

    func cancel(_ run: AgentRun) async throws {
        guard let request = config.cancelRequest(runID: run.id) else {
            throw AgentHarnessError.unsupported("Cancel")
        }
        _ = try await sendJSON(request)
    }

    /// Status-poll event stream (no assumed push channel for an arbitrary endpoint). Emits
    /// `.started`, then polls until the run reaches a terminal state — `.completed`, `.failed` or
    /// `.cancelled`, each carrying whatever the endpoint reported — or until we lose contact, which
    /// is emitted as `.connection(.lost(…))` and is explicitly *not* a verdict on the run.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        let policy = self.policy
        let sleeper = self.sleeper
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(run))
                guard config.statusRequest(runID: run.id) != nil else {
                    // Nothing to poll: say so once instead of pretending to follow the run.
                    continuation.yield(.connection(.lost(.noStatusEndpoint)))
                    continuation.finish()
                    return
                }
                continuation.yield(.connection(.connected))

                var failures = 0
                var unknownTicks = 0
                var delay = policy.interval

                poll: while !Task.isCancelled {
                    await sleeper(delay)
                    guard !Task.isCancelled else { break }
                    delay = policy.interval

                    do {
                        let outcome = try await self.poll(run)
                        let wasDegraded = failures > 0
                        failures = 0

                        guard let status = outcome.status else {
                            // Unknown status: keep watching, but only for a bounded while, and
                            // never claim the run is "working" on the strength of it.
                            unknownTicks += 1
                            if unknownTicks >= policy.maxUnknownStatusTicks {
                                continuation.yield(.connection(.lost(.unknownStatus(outcome.rawStatus))))
                                break poll
                            }
                            continue
                        }
                        unknownTicks = 0
                        if wasDegraded { continuation.yield(.connection(.connected)) }

                        switch status {
                        case .completed: continuation.yield(.completed(outcome.result))
                        case .failed:    continuation.yield(.failed(outcome.result))
                        case .cancelled: continuation.yield(.cancelled(outcome.result))
                        case .queued, .running, .awaitingInput: continue
                        }
                        break poll
                    } catch {
                        if let loss = Self.fatalLoss(for: error) {
                            continuation.yield(.connection(.lost(loss)))
                            break poll
                        }
                        failures += 1
                        switch policy.decide(afterFailureCount: failures) {
                        case .giveUp(let attempts):
                            continuation.yield(.connection(.lost(.network(attempts: attempts))))
                            break poll
                        case .retry(let attempt, let after):
                            delay = after
                            continuation.yield(.connection(.reconnecting(attempt: attempt,
                                                                         nextRetryIn: after)))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether a poll error ends the watch outright. Everything else — a dropped connection, a
    /// timeout, a 503 — is transient until the bounded retries run out.
    static func fatalLoss(for error: Error) -> AgentContactLoss? {
        guard let harnessError = error as? AgentHarnessError else { return nil }
        switch harnessError {
        case .http(let code):
            if AgentPollingPolicy.isAuthFailure(httpStatus: code) { return .auth(status: code) }
            return AgentPollingPolicy.isRetryable(httpStatus: code) ? nil : .endpoint(status: code)
        case .unsupported:
            return .noStatusEndpoint       // no status URL template — polling can never work
        case .notConfigured, .transport, .unknownStatus, .agentModeOff:
            return nil                      // transient until the bounded retries run out
        }
    }

    // MARK: - HTTP

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        // The start/status URLs come from a user-supplied harness config, so they get the same
        // scheme, credential and cleartext rules as any other endpoint.
        try MedicalEgressGuard.check(.customAgentHarness)
        guard let url = request.url,
              (try? EndpointPolicy.require(url: url, for: .customAgentHarness)) != nil else {
            throw AgentHarnessError.transport("The harness URL is not a permitted endpoint.")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // The body is endpoint-authored content; it used to ride the spoken error verbatim.
            // Only the code is user-facing now, and the body is counted, not quoted.
            PrivacyLog.agent(.session, .endpointRefused,
                             characters: data.count, error: .http(status: http.statusCode))
            throw AgentHarnessError.http(http.statusCode)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
