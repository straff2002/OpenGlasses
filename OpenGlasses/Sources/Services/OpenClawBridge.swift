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

/// Client for the OpenClaw gateway. Uses /health for status checks and
/// WebSocket protocol v3 (sessions.send) for chat / task delegation.
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

    private let pingSession: URLSession
    private let lanPingSession: URLSession
    private var sessionKey: String

    /// Cached resolved endpoint for the session
    private var cachedEndpoint: String?
    /// The gateway config that resolved to the cached endpoint
    private var activeGateway: GatewayConfig?

    /// WebSocket for chat (sessions.send)
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var wsConnected = false
    private var pendingResponses: [String: CheckedContinuation<String, Error>] = [:]

    /// Callback for streaming partial content chunks from long gateway tasks.
    /// Called on main actor with each text chunk as it arrives.
    var onStreamChunk: ((String) -> Void)?
    var onGatewayConnected: (() -> Void)?

    init() {
        let pingConfig = URLSessionConfiguration.default
        pingConfig.timeoutIntervalForRequest = 10
        self.pingSession = URLSession(configuration: pingConfig)

        let lanPingConfig = URLSessionConfiguration.default
        lanPingConfig.timeoutIntervalForRequest = 2
        self.lanPingSession = URLSession(configuration: lanPingConfig)

        self.sessionKey = OpenClawBridge.newSessionKey()
    }

    /// BR P4: the gateway session key in use (stable across Live sessions; rotates only on
    /// deliberate `resetSession()`). Exposed read-only for tests/diagnostics.
    var currentSessionKey: String { sessionKey }

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

    private func alternateEndpoint() -> String? {
        // Multi-gateway: try the next gateway in priority order
        if let current = activeGateway {
            let gateways = Config.enabledGateways
            if let idx = gateways.firstIndex(where: { $0.id == current.id }),
               idx + 1 < gateways.count {
                let next = gateways[idx + 1]
                let url = !next.tunnelURL.isEmpty ? next.tunnelURL : next.lanURL
                PrivacyLog.gatewayConnection(.failover, peer: PrivateIdentifier(next.id))
                return url
            }
        }

        // Legacy fallback
        guard Config.openClawConnectionMode == .auto else { return nil }
        let lanHost = Config.openClawLanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lanURL = "\(lanHost):\(Config.openClawPort)"
        let tunnelURL = Config.openClawTunnelHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cachedEndpoint == lanURL, !tunnelURL.isEmpty { return tunnelURL }
        if cachedEndpoint == tunnelURL { return lanURL }
        return nil
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

    /// The active gateway's token, or the legacy token.
    var activeToken: String {
        activeGateway?.token ?? Config.openClawGatewayToken
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

    /// Ensure WebSocket is connected and authenticated
    private func ensureWebSocket() async throws {
        if wsConnected, webSocketTask != nil { return }

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
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        wsSession = URLSession(configuration: config)

        // Build request with X-Scopes header (OpenClaw protocol v3 requirement)
        var request = URLRequest(url: url)
        request.setValue("chat,skills,sessions,config,tools", forHTTPHeaderField: "X-Scopes")
        // BR P4: classify our sessions as channel "glass" in the gateway's sessions_list
        // (without this they appear as generic webchat and channel-scoped status checks
        // can't find them).
        request.setValue(OpenClawBridge.messageChannel, forHTTPHeaderField: "x-openclaw-message-channel")
        webSocketTask = wsSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Wait for connect.challenge and pull its nonce — signing it into the device-identity
        // block is what earns real scopes on remote gateways (token-only can be zero-scoped).
        let challengeMsg = try await receiveMessage()
        PrivacyLog.gatewayConnection(.challengeReceived)
        var challengeNonce: String?
        if let data = challengeMsg.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any] {
            challengeNonce = payload["nonce"] as? String
        }

        // Send connect handshake — register as "node" via the shared params builder (protocol
        // v3/v4, role/scopes, capability advertisement, signed device identity when challenged).
        let connectId = UUID().uuidString
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": OpenClawConnectParams.build(
                clientId: "gateway-client",
                displayName: "OpenGlasses",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                token: token,
                challengeNonce: challengeNonce
            )
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectMsg)
        let connectJSON = String(data: connectData, encoding: .utf8)!
        // The handshake body carries the gateway token and the signed device-identity block.
        // `LogRedaction` masked two token shapes of it and let the rest through; nothing about
        // the frame is loggable, so only the fact that it was sent is.
        PrivacyLog.gatewayConnection(.handshakeSent, count: connectJSON.count)
        try await webSocketTask!.send(.string(connectJSON))

        // Wait for connect response
        let response = try await receiveMessage()
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, ok {
            wsConnected = true
            sessionCompacted = false
            consecutiveWSFailures = 0
            PrivacyLog.gatewayConnection(.connected, transport: currentTransport)
            startReceiveLoop()

            // Query available tools from gateway (fire-and-forget, non-blocking)
            Task { await queryAvailableTools() }
            onGatewayConnected?()
        } else {
            PrivacyLog.gatewayConnection(.authRejected)
            noteWSFailure()
            throw NSError(domain: "OpenClaw", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebSocket auth failed: \(String(response.prefix(200)))"])
        }
    }

    private func receiveMessage() async throws -> String {
        guard let task = webSocketTask else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "No WebSocket"])
        }
        let msg = try await task.receive()
        switch msg {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    /// Background receive loop — routes responses to pending continuations
    private func startReceiveLoop() {
        Task { [weak self] in
            while let self, let task = self.webSocketTask, self.wsConnected {
                do {
                    let msg = try await task.receive()
                    let text: String
                    switch msg {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }

                    guard let data = text.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    let type = json["type"] as? String ?? ""

                    if type == "res", let id = json["id"] as? String {
                        // Route to pending request
                        await MainActor.run {
                            if let cont = self.pendingResponses.removeValue(forKey: id) {
                                cont.resume(returning: text)
                            }
                        }
                    } else if type == "event" {
                        let event = json["event"] as? String ?? ""
                        let payload = json["payload"] as? [String: Any] ?? [:]

                        switch event {
                        case "session.compacted", "session.truncated":
                            await MainActor.run {
                                self.sessionCompacted = true
                                PrivacyLog.gatewayConnection(.sessionCompacted)
                            }
                        case "session.chunk", "stream.chunk":
                            // Streaming partial result — forward to TTS for early speech
                            if let chunk = payload["content"] as? String, !chunk.isEmpty {
                                await MainActor.run {
                                    self.onStreamChunk?(chunk)
                                }
                            }
                        default:
                            break // Other events handled by OpenClawEventClient
                        }
                    }
                } catch {
                    PrivacyLog.gatewayFailed(.receive, SafeErrorSummary(error))
                    await MainActor.run {
                        self.wsConnected = false
                        // Fail all pending requests
                        for (_, cont) in self.pendingResponses {
                            cont.resume(throwing: error)
                        }
                        self.pendingResponses.removeAll()
                    }
                    break
                }
            }
        }
    }

    /// Send a WebSocket request and wait for the matching response
    /// Public entry point for the Remote Agent Harness (Plan N) to issue `agent.*` requests over the
    /// same WebSocket transport. A thin pass-through to `sendRequest` so the harness adapter doesn't
    /// reach into the bridge's internals.
    func agentRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        // BK P0: gate at the service layer, not just at the tool layer. This public pass-through
        // to `sendRequest` is otherwise an ungated hole of the same shape as `delegateTask`.
        guard Config.agentModeEnabled else {
            throw NSError(domain: "OpenClaw", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Agent mode not enabled"])
        }
        return try await sendRequest(method: method, params: params)
    }

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureWebSocket()
        guard let task = webSocketTask else {
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
        try await task.send(.string(String(data: data, encoding: .utf8)!))

        // Wait for response with timeout
        let responseText: String = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[reqId] = continuation

            // Timeout after 120s
            Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await MainActor.run {
                    if let cont = self.pendingResponses.removeValue(forKey: reqId) {
                        cont.resume(throwing: NSError(domain: "OpenClaw", code: -3, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
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
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        for (_, cont) in pendingResponses {
            cont.resume(throwing: NSError(domain: "OpenClaw", code: -5, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        }
        pendingResponses.removeAll()
    }

    // MARK: - Tool Visibility

    /// Query available tools from the gateway at connect time.
    /// Populates `availableGatewayTools` so the system prompt only references live capabilities.
    private func queryAvailableTools() async {
        guard Config.agentModeEnabled else { return }
        do {
            let response = try await sendRequest(method: "tools.available", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let tools = payload["tools"] as? [[String: String]] {
                availableGatewayTools = tools
                PrivacyLog.gatewayOperation("tools.available", outcome: .succeeded, count: tools.count)
            } else {
                // Gateway may not support tools.available — not an error
                PrivacyLog.gatewayOperation("tools.available", outcome: .unsupported)
            }
        } catch {
            PrivacyLog.gatewayOperation("tools.available", outcome: .failed)
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
        var params: [String: Any] = [
            "expression": expression,
            "task": task
        ]
        if let context { params["context"] = context }
        do {
            let response = try await sendRequest(method: "cron.create", params: params)
            if let ok = response["ok"] as? Bool, ok {
                let payload = response["payload"] as? [String: Any]
                let id = payload?["id"] as? String ?? "unknown"
                PrivacyLog.gatewayOperation("cron.create", outcome: .succeeded)
                return .success("Cron job created (id: \(id))")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron create failed: \(msg)")
        } catch {
            return .failure("Cron create error: \(error.localizedDescription)")
        }
    }

    /// Update an existing cron job on the gateway.
    func updateCronJob(id: String, expression: String? = nil, task: String? = nil, enabled: Bool? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var params: [String: Any] = ["id": id]
        if let expression { params["expression"] = expression }
        if let task { params["task"] = task }
        if let enabled { params["enabled"] = enabled }
        do {
            let response = try await sendRequest(method: "cron.update", params: params)
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job updated")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron update failed: \(msg)")
        } catch {
            return .failure("Cron update error: \(error.localizedDescription)")
        }
    }

    /// Delete a cron job on the gateway.
    func deleteCronJob(id: String) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "cron.delete", params: ["id": id])
            if let ok = response["ok"] as? Bool, ok {
                return .success("Cron job deleted")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Cron delete failed: \(msg)")
        } catch {
            return .failure("Cron delete error: \(error.localizedDescription)")
        }
    }

    /// List cron jobs on the gateway.
    func listCronJobs() async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "cron.list", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let jobs = payload["jobs"] as? [[String: Any]] {
                let descriptions = jobs.map { job -> String in
                    let id = job["id"] as? String ?? "?"
                    let expr = job["expression"] as? String ?? "?"
                    let task = job["task"] as? String ?? "?"
                    let enabled = job["enabled"] as? Bool ?? true
                    return "\(enabled ? "+" : "-") [\(id)] \(expr): \(task)"
                }
                return .success(descriptions.joined(separator: "\n"))
            }
            return .success("No cron jobs")
        } catch {
            return .failure("Cron list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Gateway Memory (Embeddings)

    /// Query the gateway's long-term memory via embeddings.
    func queryMemory(query: String, limit: Int = 5) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "memory.query", params: [
                "query": query,
                "limit": limit
            ])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let results = payload["results"] as? [[String: Any]] {
                let texts = results.compactMap { $0["content"] as? String }
                return .success(texts.joined(separator: "\n---\n"))
            }
            return .success("No memory results")
        } catch {
            return .failure("Memory query error: \(error.localizedDescription)")
        }
    }

    /// Store a memory in the gateway's embedding store.
    func storeMemory(content: String, metadata: [String: String]? = nil) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        var params: [String: Any] = ["content": content]
        if let metadata { params["metadata"] = metadata }
        do {
            let response = try await sendRequest(method: "memory.store", params: params)
            if let ok = response["ok"] as? Bool, ok {
                return .success("Memory stored")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Memory store failed: \(msg)")
        } catch {
            return .failure("Memory store error: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Routing via Gateway

    /// Route a message through the gateway's channel abstraction.
    func routeMessage(channel: String, recipient: String, message: String) async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "channels.send", params: [
                "channel": channel,
                "recipient": recipient,
                "message": message
            ])
            if let ok = response["ok"] as? Bool, ok {
                return .success("Message sent via \(channel)")
            }
            let msg = (response["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            return .failure("Message routing failed: \(msg)")
        } catch {
            return .failure("Message routing error: \(error.localizedDescription)")
        }
    }

    /// List available messaging channels on the gateway.
    func listChannels() async -> ToolResult {
        guard Config.agentModeEnabled else { return .failure("Agent mode not enabled") }
        do {
            let response = try await sendRequest(method: "channels.list", params: [:])
            if let ok = response["ok"] as? Bool, ok,
               let payload = response["payload"] as? [String: Any],
               let channels = payload["channels"] as? [[String: Any]] {
                let names = channels.compactMap { $0["name"] as? String }
                return .success("Available channels: \(names.joined(separator: ", "))")
            }
            return .success("No channels available")
        } catch {
            return .failure("Channel list error: \(error.localizedDescription)")
        }
    }

    // MARK: - Task Delegation

    /// Send a task to the OpenClaw gateway via WebSocket sessions.send.
    /// Optionally includes an image (e.g. from glasses camera) as base64 JPEG.
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
            var params: [String: Any] = [
                "agentId": "main",
                "sessionKey": sessionKey,
                "text": task
            ]
            if let imageData = imageData {
                params["imageBase64"] = imageData.base64EncodedString()
                params["imageMimeType"] = "image/jpeg"
            }
            let response = try await sendRequest(method: "sessions.send", params: params)

            let ok = response["ok"] as? Bool ?? false
            if ok {
                // Extract result — sessions.send may return the run result directly
                if let payload = response["payload"] as? [String: Any],
                   let content = payload["content"] as? String {
                    // The content is the agent's answer to the wearer — user content. Only its
                    // size is recorded, which is what a truncation or empty-reply report needs.
                    PrivacyLog.gatewayOperation("sessions.send", outcome: .succeeded,
                                                characters: content.count)
                    lastToolCallStatus = .completed(toolName)
                    return .success(content)
                }
                // Some responses just acknowledge the send — the actual result comes via events
                if let payload = response["payload"] as? [String: Any],
                   let runId = payload["runId"] as? String {
                    PrivacyLog.gatewayOperation("sessions.send", outcome: .succeeded)
                    lastToolCallStatus = .completed(toolName)
                    return .success("Task dispatched (runId: \(runId))")
                }
                lastToolCallStatus = .completed(toolName)
                return .success("OK")
            } else {
                let error = response["error"] as? [String: Any]
                let code = error?["code"] as? String ?? "unknown"
                let message = error?["message"] as? String ?? "Unknown error"
                // The gateway's `message` is free-form prose about the failed task; the `code` is
                // its machine vocabulary and is the only half that can be summarised.
                PrivacyLog.gatewayOperation("sessions.send", outcome: .rejected)
                PrivacyLog.gatewayFailed(.request, .remote(code: code))

                if message.contains("missing scope") {
                    lastToolCallStatus = .failed(toolName, "Token needs write permissions")
                    return .failure("Gateway token needs operator.write scope. Update the token permissions in OpenClaw settings.")
                }

                lastToolCallStatus = .failed(toolName, message)
                return .failure("Gateway error: \(message)")
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
}
