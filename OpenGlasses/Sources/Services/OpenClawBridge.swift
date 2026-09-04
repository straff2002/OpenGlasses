import Foundation

// MARK: - Connection Types

enum OpenClawConnectionMode: String, CaseIterable {
    case lan = "lan"
    case tunnel = "tunnel"
    case auto = "auto"

    var displayName: String {
        switch self {
        case .lan: return "LAN (Local Network)"
        case .tunnel: return "Tunnel (Remote)"
        case .auto: return "Auto (try LAN first)"
        }
    }
}

enum OpenClawConnectionState: Equatable {
    case notConfigured
    case checking
    case connected
    case unreachable(String)
}

enum ResolvedConnection: Equatable {
    case lan
    case tunnel

    var label: String {
        switch self {
        case .lan: return "LAN"
        case .tunnel: return "Tunnel"
        }
    }
}

// MARK: - OpenClaw Bridge

/// Client for the OpenClaw gateway. Uses /health for status checks and the gateway WebSocket
/// protocol (v4) for chat / task delegation.
///
/// Plan EH P1 wire contract: every outbound request is built by `GatewayRequestCatalog` (the
/// gateway's schemas are closed objects — an unknown key is a rejected frame); the connect
/// handshake is `OpenClawConnectParams`; the `hello-ok` reply's method catalog gates what we
/// call; and a delegated task's answer is correlated by `runId` through `ChatRunTracker`, since
/// `sessions.send` only acknowledges and the reply arrives later as `chat` events.
@MainActor
class OpenClawBridge: ObservableObject {
    @Published var lastToolCallStatus: ToolCallStatus = .idle
    @Published var connectionState: OpenClawConnectionState = .notConfigured
    @Published var resolvedConnection: ResolvedConnection?
    /// Which gateway we're currently connected to (nil = legacy single config).
    @Published var activeGatewayName: String?
    /// Tools currently available on the connected gateway (populated at connect time).
    @Published var availableGatewayTools: [[String: String]] = []
    /// Whether session compaction has occurred (gateway trimmed context).
    @Published var sessionCompacted: Bool = false
    /// The gateway's `hello-ok` for the live socket — its method/event catalog and policy.
    /// Nil before connect, and on a pre-2.0 gateway that answers a bare `{ok:true}`.
    @Published private(set) var gatewayHello: GatewayHello?

    private let pingSession: URLSession
    private let lanPingSession: URLSession
    private var sessionKey: String

    /// Cached resolved endpoint for the session
    private var cachedEndpoint: String?
    /// The gateway config that resolved to the cached endpoint
    private var activeGateway: GatewayConfig?

    /// The chat socket (challenge → connect → hello-ok, then request/response + events).
    private let socketFactory: GatewaySocketFactory
    private var socket: GatewaySocket?
    private var wsConnected = false
    /// An in-flight request: the method it asked for, kept alongside the waiter so the receive
    /// loop can act on the response before the caller is resumed.
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var pendingResponses: [String: PendingRequest] = [:]

    /// Correlates `chat` events with the requests that started them.
    let runTracker = ChatRunTracker()
    /// How long `delegateTask` waits for the run's final text before parking the run. A parked
    /// run's answer still arrives — through `onLateResult` — it is never dropped.
    var replyTimeout: TimeInterval = 120

    /// Callback for streaming partial content chunks from long gateway tasks.
    /// Called on main actor with each text chunk as it arrives.
    var onStreamChunk: ((String) -> Void)?
    var onGatewayConnected: (() -> Void)?
    /// A run the wearer stopped waiting on has answered. The text is the answer to a question
    /// they asked, not unsolicited news — the caller announces it, it does not triage it.
    var onLateResult: ((String) -> Void)?
    /// Raw `agent` events (tool activity, run lifecycle) for consumers that want them.
    var onAgentEvent: (([String: Any]) -> Void)?

    init(socketFactory: @escaping GatewaySocketFactory = URLSessionGatewaySocket.make) {
        let pingConfig = URLSessionConfiguration.default
        pingConfig.timeoutIntervalForRequest = 10
        self.pingSession = URLSession(configuration: pingConfig)

        let lanPingConfig = URLSessionConfiguration.default
        lanPingConfig.timeoutIntervalForRequest = 2
        self.lanPingSession = URLSession(configuration: lanPingConfig)

        self.socketFactory = socketFactory
        self.sessionKey = OpenClawBridge.newSessionKey()
    }

    /// BR P4: the gateway session key in use (stable across Live sessions; rotates only on
    /// deliberate `resetSession()`). Exposed read-only for tests/diagnostics.
    var currentSessionKey: String { sessionKey }

    /// Whether the connected gateway advertises `method`. Unknown catalog (not yet connected, or
    /// a pre-2.0 gateway) means "try it" — the gateway's own error is then the honest answer.
    func supports(_ method: String) -> Bool {
        gatewayHello?.supports(method) ?? true
    }

    // MARK: - Endpoint Resolution (Multi-Gateway)

    func resolveEndpoint() async -> String {
        if let cached = cachedEndpoint {
            return cached
        }

        // Try multi-gateway configs first (in priority order)
        let gateways = Config.enabledGateways
        if !gateways.isEmpty {
            for gateway in gateways {
                if let endpoint = await resolveGateway(gateway) {
                    cachedEndpoint = endpoint
                    activeGateway = gateway
                    activeGatewayName = gateway.name
                    PrivacyLog.gatewayConnection(.endpointResolved, transport: currentTransport,
                                                 peer: PrivateIdentifier(gateway.id))
                    return endpoint
                }
            }
            // None reachable — use first gateway's best guess
            let first = gateways[0]
            let fallback = !first.tunnelURL.isEmpty ? first.tunnelURL : first.lanURL
            cachedEndpoint = fallback
            activeGateway = first
            activeGatewayName = first.name
            PrivacyLog.gatewayConnection(.endpointUnreachable, peer: PrivateIdentifier(first.id))
            return fallback
        }

        // Legacy single-gateway config
        return await resolveLegacyEndpoint()
    }

    /// Resolve a single gateway config — try LAN then tunnel based on its connection mode.
    private func resolveGateway(_ gateway: GatewayConfig) async -> String? {
        let lanURL = gateway.lanURL
        let tunnelURL = gateway.tunnelURL

        switch gateway.connectionModeEnum {
        case .lan:
            guard !lanURL.isEmpty else { return nil }
            resolvedConnection = .lan
            return lanURL
        case .tunnel:
            guard !tunnelURL.isEmpty else { return nil }
            resolvedConnection = .tunnel
            return tunnelURL
        case .auto:
            if !lanURL.isEmpty, await isReachable(baseURL: lanURL, token: gateway.token,
                                                  session: lanPingSession, transport: .lan) {
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: gateway.token,
                                                    session: pingSession, transport: .tunnel) {
                resolvedConnection = .tunnel
                return tunnelURL
            }
            return nil  // This gateway isn't reachable — try next one
        }
    }

    /// Legacy: resolve from the single Config.openClaw* properties.
    private func resolveLegacyEndpoint() async -> String {
        let mode = Config.openClawConnectionMode
        let lanHost = Config.openClawLanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lanURL = "\(lanHost):\(Config.openClawPort)"
        let tunnelURL = Config.openClawTunnelHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch mode {
        case .lan:
            cachedEndpoint = lanURL
            resolvedConnection = .lan
            return lanURL
        case .tunnel:
            cachedEndpoint = tunnelURL
            resolvedConnection = .tunnel
            return tunnelURL
        case .auto:
            if await isReachable(baseURL: lanURL, token: Config.openClawGatewayToken,
                                 session: lanPingSession, transport: .lan) {
                cachedEndpoint = lanURL
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: Config.openClawGatewayToken,
                                                     session: pingSession, transport: .tunnel) {
                cachedEndpoint = tunnelURL
                resolvedConnection = .tunnel
                return tunnelURL
            }
            let fallback = !tunnelURL.isEmpty ? tunnelURL : lanURL
            cachedEndpoint = fallback
            resolvedConnection = !tunnelURL.isEmpty ? .tunnel : .lan
            return fallback
        }
    }

    func clearCachedEndpoint() {
        cachedEndpoint = nil
        activeGateway = nil
        activeGatewayName = nil
        resolvedConnection = nil
        disconnectWebSocket()
    }

    /// Consecutive WebSocket failures since the last successful connect. The resolved endpoint
    /// is cached forever on success, so a candidate that later dies (left the LAN, tunnel
    /// restarted) would otherwise be hammered until app restart — "persistent gateway offline".
    /// After a few failures in a row, drop the cache so the next attempt re-probes all
    /// candidates (LAN → tunnel failover).
    private var consecutiveWSFailures = 0
    private static let maxWSFailuresBeforeEndpointReset = 3

    private func noteWSFailure() {
        consecutiveWSFailures += 1
        guard consecutiveWSFailures >= Self.maxWSFailuresBeforeEndpointReset else { return }
        PrivacyLog.gatewayConnection(.endpointCacheDropped, count: consecutiveWSFailures)
        consecutiveWSFailures = 0
        cachedEndpoint = nil
        resolvedConnection = nil
    }

    /// The active gateway's credential: a per-device token issued at pairing beats the shared
    /// token; the legacy single-gateway token is the fallback.
    var activeToken: String {
        if let gateway = activeGateway {
            return GatewayAuthSelector.credential(deviceToken: gateway.deviceToken,
                                                  setupCode: gateway.setupCode,
                                                  sharedToken: gateway.token)
        }
        return Config.openClawGatewayToken
    }

    /// The leg the bridge currently believes it is on, for logging. `unknown` until resolution.
    private var currentTransport: PrivacyLog.GatewayTransport {
        switch resolvedConnection {
        case .lan: return .lan
        case .tunnel: return .tunnel
        case nil: return .unknown
        }
    }

    /// Check reachability using /health endpoint
    private func isReachable(baseURL: String, token: String? = nil, session: URLSession,
                             transport: PrivacyLog.GatewayTransport = .unknown) async -> Bool {
        let normalized = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalized)/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let authToken = token ?? activeToken
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let healthy = (200...299).contains(http.statusCode)
                PrivacyLog.gatewayHealth(transport, reachable: healthy, status: http.statusCode)
                return healthy
            }
        } catch {
            PrivacyLog.gatewayFailed(.health, SafeErrorSummary(error))
        }
        return false
    }

    // MARK: - Connection Check

    func checkConnection() async {
        guard Config.isAnyGatewayConfigured else {
            connectionState = .notConfigured
            return
        }
        connectionState = .checking
        let endpoint = await resolveEndpoint()
        let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint

        guard let url = URL(string: "\(normalized)/health") else {
            connectionState = .unreachable("Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(activeToken)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await pingSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                let healthy = (200...299).contains(http.statusCode)
                PrivacyLog.gatewayHealth(currentTransport, reachable: healthy, status: http.statusCode)
                if healthy {
                    connectionState = .connected
                    return
                }
                connectionState = .unreachable("HTTP \(http.statusCode)")
                return
            }
        } catch {
            PrivacyLog.gatewayFailed(.health, SafeErrorSummary(error))
        }
        connectionState = .unreachable("Gateway not responding")
    }

    // MARK: - Session Management

    /// BR P4: rotate to a fresh gateway context — a *deliberate* act (user-initiated
    /// "start fresh"), no longer called automatically per Live session. The generation is
    /// persisted and monotonic, so fragmentation is bounded by explicit resets instead of
    /// growing one dead session per conversation.
    func resetSession() {
        let next = UserDefaults.standard.integer(forKey: Self.sessionGenerationKey) + 1
        UserDefaults.standard.set(next, forKey: Self.sessionGenerationKey)
        sessionKey = Self.newSessionKey()
        PrivacyLog.gatewayConnection(.sessionRotated, count: next)
    }

    nonisolated static let messageChannel = "glass"
    private static let sessionGenerationKey = "openClawSessionGeneration"

    /// BR P4: stable key so gateway-side context persists across Live sessions (the old
    /// timestamp suffix fragmented the gateway's session list and made the agent amnesiac
    /// every conversation). Generation 0 is the bare stable key.
    private static func newSessionKey() -> String {
        let generation = UserDefaults.standard.integer(forKey: sessionGenerationKey)
        return generation == 0 ? "agent:main:glass" : "agent:main:glass:\(generation)"
    }

    // MARK: - WebSocket Chat

    /// Ensure the socket is connected and authenticated: challenge → connect → hello-ok.
    private func ensureWebSocket() async throws {
        if wsConnected, socket != nil { return }

        let endpoint = await resolveEndpoint()
        let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let wsURL = normalized
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let token = activeToken

        // Token is presented in the `connect` handshake below, not in the URL query string —
        // this keeps the credential out of device, proxy, and server access logs.
        guard let url = URL(string: "\(wsURL)/ws") else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"])
        }

        PrivacyLog.gatewayConnection(.connecting, transport: currentTransport)
        var request = URLRequest(url: url)
        // The gateway reads this header on its HTTP routes only; on the socket it is inert.
        // Kept so an HTTP-side session listing still classes these as "glass" if that changes.
        request.setValue(OpenClawBridge.messageChannel, forHTTPHeaderField: "x-openclaw-message-channel")
        let socket = socketFactory(request)
        self.socket = socket

        // The gateway speaks first: `connect.challenge` carries the nonce we sign into the
        // device-identity block and the timestamp we sign *at*. Signing our own clock instead
        // fails on any gateway more than two minutes off from the phone.
        let challengeText = try await socket.receive()
        var challenge: GatewayChallenge?
        if let data = challengeText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            challenge = GatewayChallenge.parse(event: json)
        }
        PrivacyLog.gatewayConnection(.challengeReceived)

        let connectId = UUID().uuidString
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": OpenClawConnectParams.build(
                displayName: "OpenGlasses",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                token: token,
                role: .operator,
                challenge: challenge,
                pairedDeviceId: activeGateway.map { Config.deviceId(forGateway: $0.id) }
            )
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectMsg)
        let connectJSON = String(data: connectData, encoding: .utf8)!
        // The handshake body carries the gateway token and the signed device-identity block;
        // nothing about the frame is loggable, so only the fact that it was sent is.
        PrivacyLog.gatewayConnection(.handshakeSent, count: connectJSON.count)
        try await socket.send(connectJSON)

        let response = try await socket.receive()
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            PrivacyLog.gatewayConnection(.authRejected)
            noteWSFailure()
            throw NSError(domain: "OpenClaw", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebSocket auth failed: unreadable reply"])
        }
        let outcome = PairingResponseInterpreter.interpretResponse(json)
        guard outcome.status == .paired else {
            PrivacyLog.gatewayConnection(outcome.status == .waitingApproval ? .pairingPending : .authRejected)
            noteWSFailure()
            let reason: String
            switch outcome.status {
            case .waitingApproval: reason = "Waiting for this device to be approved on the gateway."
            case .error(let message): reason = message
            default: reason = "Gateway refused the connection."
            }
            throw NSError(domain: "OpenClaw", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebSocket auth failed: \(reason)"])
        }

        gatewayHello = outcome.hello
        if let token = outcome.deviceToken, let gateway = activeGateway {
            Config.setDeviceCredentials(gatewayId: gateway.id, deviceToken: token)
            PrivacyLog.gatewayConnection(.devicePaired, peer: PrivateIdentifier(gateway.id))
        }
        if let hello = outcome.hello {
            PrivacyLog.gatewayConnection(.helloReceived, count: hello.methods.count,
                                         detail: PrivacyToken(hello.role))
        }
        wsConnected = true
        sessionCompacted = false
        consecutiveWSFailures = 0
        PrivacyLog.gatewayConnection(.connected, transport: currentTransport)
        startReceiveLoop(on: socket)

        // Query available tools from gateway (fire-and-forget, non-blocking)
        Task { await queryAvailableTools() }
        onGatewayConnected?()
    }

    /// Background receive loop — routes responses to pending continuations and events to their
    /// consumers. `chat` events feed the run tracker; `agent` events are handed on raw.
    private func startReceiveLoop(on socket: GatewaySocket) {
        Task { [weak self] in
            while let self, self.socket === socket, self.wsConnected {
                do {
                    let text = try await socket.receive()
                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self.route(frame: json, rawText: text)
                } catch {
                    PrivacyLog.gatewayFailed(.receive, SafeErrorSummary(error))
                    guard self.socket === socket else { return }
                    self.wsConnected = false
                    // Fail all pending requests
                    for (_, pending) in self.pendingResponses {
                        pending.continuation.resume(throwing: error)
                    }
                    self.pendingResponses.removeAll()
                    break
                }
            }
        }
    }

    private func route(frame json: [String: Any], rawText: String) {
        switch json["type"] as? String {
        case "res":
            if let id = json["id"] as? String, let pending = pendingResponses.removeValue(forKey: id) {
                // Track a started run here, not where the caller resumes: the caller wakes on a
                // later turn of this actor, and the run's `chat` events are routed in between.
                // A run that finishes fast would otherwise reach the tracker as an unknown run,
                // its terminal state dropped and its waiter left to time out.
                if GatewayWire.runStartingMethods.contains(pending.method),
                   let runId = (json["payload"] as? [String: Any])?["runId"] as? String, !runId.isEmpty {
                    runTracker.register(runId: runId)
                }
                pending.continuation.resume(returning: rawText)
            }
        case "event":
            let event = json["event"] as? String ?? ""
            let payload = json["payload"] as? [String: Any] ?? [:]
            switch event {
            case "chat":
                handleChatEvent(payload)
            case "agent":
                onAgentEvent?(payload)
            default:
                break // heartbeat/cron/pairing events are the event client's business
            }
        default:
            break
        }
    }

    private func handleChatEvent(_ payload: [String: Any]) {
        guard let update = runTracker.handle(payload: payload) else { return }
        switch update {
        case .chunk(_, let text):
            onStreamChunk?(text)
        case .lateAnswer(_, let text):
            // The answer is the wearer's content; only its size is recorded.
            PrivacyLog.gatewayNotification(.lateResult, characters: text.count)
            onLateResult?(text)
        case .completed, .unknownRun:
            break
        }
    }

    /// Send a WebSocket request and wait for the matching response
    /// Public entry point for the Remote Agent Harness (Plan N) to issue requests over the same
    /// WebSocket transport. A thin pass-through to `sendRequest` so the harness adapter doesn't
    /// reach into the bridge's internals. Runs started here are tracked so the harness can poll
    /// their state through `runTracker`.
    func agentRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        // BK P0: gate at the service layer, not just at the tool layer. This public pass-through
        // to `sendRequest` is otherwise an ungated hole of the same shape as `delegateTask`.
        guard Config.agentModeEnabled else {
            throw NSError(domain: "OpenClaw", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Agent mode not enabled"])
        }
        guard !GatewayWire.removedMethods.contains(method) else {
            throw NSError(domain: "OpenClaw", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "This gateway has no \(method) method"])
        }
        let response = try await sendRequest(method: method, params: params)
        if method == "sessions.send" || method == "chat.send",
           let payload = response["payload"] as? [String: Any],
           let runId = payload["runId"] as? String {
            runTracker.register(runId: runId)
        }
        return response
    }

    /// Send a catalog-built request. Reports `unsupported` without a round trip when the
    /// gateway's hello-ok catalog lacks the method.
    private func send(_ request: GatewayRequest) async throws -> [String: Any] {
        try await ensureWebSocket()
        guard supports(request.method) else {
            PrivacyLog.gatewayOperation(request.method, outcome: .unsupported)
            throw NSError(domain: "OpenClaw", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "The gateway does not offer \(request.method)"])
        }
        return try await sendRequest(method: request.method, params: request.params)
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureWebSocket()
        guard let socket else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "No WebSocket"])
        }

        let reqId = UUID().uuidString
        let msg: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: msg)
        let text = String(data: data, encoding: .utf8)!

        // Register the continuation BEFORE the frame leaves: the receive loop runs on this
        // actor too, and a gateway that answers within the same turn (or a scripted one that
        // answers synchronously) would otherwise route the reply before anyone was waiting.
        let responseText: String = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[reqId] = PendingRequest(method: method, continuation: continuation)

            Task {
                do {
                    try await socket.send(text)
                } catch {
                    await MainActor.run {
                        if let pending = self.pendingResponses.removeValue(forKey: reqId) {
                            pending.continuation.resume(throwing: error)
                        }
                    }
                }
            }

            // Timeout after 120s
            Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await MainActor.run {
                    if let pending = self.pendingResponses.removeValue(forKey: reqId) {
                        pending.continuation.resume(throwing: NSError(domain: "OpenClaw", code: -3, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
                    }
                }
            }
        }

        guard let responseData = responseText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw NSError(domain: "OpenClaw", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        return json
    }

    func disconnectWebSocket() {
        wsConnected = false
        socket?.cancel()
        socket = nil
        gatewayHello = nil
        for (_, pending) in pendingResponses {
            pending.continuation.resume(throwing: NSError(domain: "OpenClaw", code: -5, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        }
        pendingResponses.removeAll()
    }

    private static func errorMessage(_ response: [String: Any]) -> String {
        let error = response["error"] as? [String: Any]
        return error?["message"] as? String ?? error?["code"] as? String ?? "Unknown error"
    }

    // MARK: - Tool Visibility

    /// Query the tools the gateway will actually offer this session, so the system prompt only
    /// references live capabilities. `tools.effective` is session-filtered; `tools.catalog` is
    /// the fallback on gateways without it.
    private func queryAvailableTools() async {
        guard Config.agentModeEnabled else { return }
        let request = supports("tools.effective")
            ? GatewayRequestCatalog.toolsEffective(sessionKey: sessionKey)
            : GatewayRequestCatalog.toolsCatalog()
        do {
            let response = try await send(request)
            if let ok = response["ok"] as? Bool, ok, let payload = response["payload"] as? [String: Any] {
                availableGatewayTools = GatewayRequestCatalog.toolRows(from: payload)
                PrivacyLog.gatewayOperation(request.method, outcome: .succeeded, count: availableGatewayTools.count)
            } else {
                PrivacyLog.gatewayOperation(request.method, outcome: .rejected)
            }
        } catch {
            PrivacyLog.gatewayOperation(request.method, outcome: .failed)
            PrivacyLog.gatewayFailed(.request, SafeErrorSummary(error))
        }
    }

    /// Names of tools currently available on the gateway.
    var availableToolNames: [String] {
        availableGatewayTools.compactMap { $0["name"] }
    }

    // MARK: - Cron Job Management

    /// Create a cron job on the gateway. Requires agentModeEnabled.
    func createCronJob(expression: String, task: String, context: String? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        let name = String(task.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GatewayRequestCatalog.cronAdd(
            name: name.isEmpty ? "Glasses task" : name, message: task,
            schedule: .cron(expr: expression, tz: TimeZone.current.identifier), description: context)
        do {
            let response = try await send(request)
            if let ok = response["ok"] as? Bool, ok {
                let payload = response["payload"] as? [String: Any]
                let id = payload?["id"] as? String ?? (payload?["job"] as? [String: Any])?["id"] as? String ?? "unknown"
                PrivacyLog.gatewayOperation(request.method, outcome: .succeeded)
                return .success("Cron job created (id: \(id))")
            }
            return .failure("Cron create failed: \(Self.errorMessage(response))")
        } catch {
            return .failure("Cron create error: \(error.localizedDescription)")
        }
    }

    /// Update an existing cron job on the gateway.
    func updateCronJob(id: String, expression: String? = nil, task: String? = nil, enabled: Bool? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var patch = GatewayCronPatch()
        if let expression { patch.schedule = .cron(expr: expression, tz: TimeZone.current.identifier) }
        if let task { patch.message = task }
        if let enabled { patch.enabled = enabled }
        do {
            let response = try await send(GatewayRequestCatalog.cronUpdate(id: id, patch: patch))
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job updated")
            }
            return .failure("Cron update failed: \(Self.errorMessage(response))")
        } catch {
            return .failure("Cron update error: \(error.localizedDescription)")
        }
    }

    /// Delete a cron job on the gateway.
    func deleteCronJob(id: String) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await send(GatewayRequestCatalog.cronRemove(id: id))
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job deleted")
            }
            return .failure("Cron delete failed: \(Self.errorMessage(response))")
        } catch {
            return .failure("Cron delete error: \(error.localizedDescription)")
        }
    }

    /// List cron jobs on the gateway.
    func listCronJobs() async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await send(GatewayRequestCatalog.cronList())
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any] {
                let rows = GatewayRequestCatalog.cronRows(from: payload)
                return .success(rows.isEmpty ? "No cron jobs" : rows.joined(separator: "\n"))
            }
            return .success("No cron jobs")
        } catch {
            return .failure("Cron list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Gateway Memory (read-only on the wire)

    /// Search the gateway's memory index.
    func queryMemory(query: String, limit: Int = 5) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await send(GatewayRequestCatalog.memorySearch(query: query, maxResults: limit))
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any] {
                let texts = GatewayRequestCatalog.memoryTexts(from: payload)
                return .success(texts.isEmpty ? "No memory results" : texts.joined(separator: "\n---\n"))
            }
            return .success("No memory results")
        } catch {
            return .failure("Memory query error: \(error.localizedDescription)")
        }
    }

    /// The gateway exposes no memory *write* method — memory is the agent's own, consolidated on
    /// its side — so this reports honestly rather than inventing a frame. On-device memory
    /// (BrainStore) stays native-first regardless.
    func storeMemory(content: String, metadata: [String: String]? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        PrivacyLog.gatewayOperation("memory.store", outcome: .unsupported)
        return .failure("This gateway has no memory store method; memories stay on the phone.")
    }

    // MARK: - Task Delegation

    /// Send a task to the OpenClaw gateway and wait for the run's answer.
    /// Optionally includes an image (e.g. from glasses camera) as a JPEG attachment.
    func delegateTask(
        task: String,
        toolName: String = "execute",
        imageData: Data? = nil
    ) async -> ToolResult {
        // BK P0: the one gateway method that actually ships a task must honour the Agent-Mode gate
        // like its nine siblings — otherwise `execute` is reachable (and unconfirmed) from ordinary
        // or prompt-injected conversation while Agent Mode is off.
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        lastToolCallStatus = .executing(toolName)

        do {
            try await ensureWebSocket()
            var attachments: [GatewayAttachment] = []
            if let imageData {
                let attachment = GatewayAttachment(mimeType: "image/jpeg", fileName: "glasses.jpg", content: imageData)
                if attachment.fits(gatewayHello) {
                    attachments.append(attachment)
                } else {
                    // Over the gateway's advertised ceiling: send the words, not a rejected frame.
                    PrivacyLog.gatewayOperation("attachment", outcome: .rejected, count: imageData.count)
                }
            }
            let request = GatewayRequestCatalog.sessionsSend(
                key: sessionKey, message: task, agentId: "main", attachments: attachments,
                idempotencyKey: UUID().uuidString)
            let response = try await sendRequest(method: request.method, params: request.params)

            guard response["ok"] as? Bool ?? false else {
                let error = response["error"] as? [String: Any]
                let code = error?["code"] as? String ?? "unknown"
                let message = error?["message"] as? String ?? "Unknown error"
                // The gateway's `message` is free-form prose about the failed task; the `code` is
                // its machine vocabulary and is the only half that can be summarised.
                PrivacyLog.gatewayOperation(request.method, outcome: .rejected)
                PrivacyLog.gatewayFailed(.request, .remote(code: code))

                if message.contains("missing scope") {
                    lastToolCallStatus = .failed(toolName, "Token needs write permissions")
                    return .failure("Gateway token needs operator.write scope. Update the token permissions in OpenClaw settings.")
                }
                lastToolCallStatus = .failed(toolName, message)
                return .failure("Gateway error: \(message)")
            }

            let payload = response["payload"] as? [String: Any] ?? [:]
            guard let runId = payload["runId"] as? String, !runId.isEmpty else {
                // A gateway that answers inline (pre-2.0 shape) — take the text as the result.
                if let content = payload["content"] as? String {
                    PrivacyLog.gatewayOperation(request.method, outcome: .succeeded, characters: content.count)
                    lastToolCallStatus = .completed(toolName)
                    return .success(content)
                }
                lastToolCallStatus = .completed(toolName)
                return .success("OK")
            }

            runTracker.register(runId: runId)
            let outcome = await waitForReply(runId: runId)
            switch outcome {
            case .answered(let text):
                // The content is the agent's answer to the wearer — user content. Only its
                // size is recorded, which is what a truncation or empty-reply report needs.
                PrivacyLog.gatewayOperation(request.method, outcome: .succeeded, characters: text.count)
                lastToolCallStatus = .completed(toolName)
                return .success(text.isEmpty ? "OK" : text)
            case .aborted:
                PrivacyLog.gatewayOperation(request.method, outcome: .rejected)
                lastToolCallStatus = .failed(toolName, "Run aborted")
                return .failure("The gateway stopped the task before it finished.")
            case .failed(let message):
                PrivacyLog.gatewayOperation(request.method, outcome: .failed)
                lastToolCallStatus = .failed(toolName, message ?? "Run failed")
                return .failure("Gateway error: \(message ?? "the task failed")")
            case .timedOut:
                // Parked, not dropped: the run is still tracked and its answer will be announced
                // through `onLateResult` when it arrives.
                PrivacyLog.gatewayOperation(request.method, outcome: .succeeded)
                lastToolCallStatus = .completed(toolName)
                return .success("The gateway accepted the task and is still working on it. The answer will be announced when it arrives; do not invent one now.")
            }
        } catch {
            PrivacyLog.gatewayOperation("sessions.send", outcome: .failed)
            PrivacyLog.gatewayFailed(.request, SafeErrorSummary(error))
            // Reconnect on next attempt
            disconnectWebSocket()
            lastToolCallStatus = .failed(toolName, error.localizedDescription)
            return .failure("Gateway error: \(error.localizedDescription)")
        }
    }

    /// Wait for a run's terminal `chat` event, parking it after `replyTimeout`.
    private func waitForReply(runId: String) async -> ChatRunTracker.Outcome {
        let timeoutTask = Task { [replyTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(replyTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self.runTracker.park(runId: runId) }
        }
        let outcome = await runTracker.wait(runId: runId)
        timeoutTask.cancel()
        return outcome
    }
}
