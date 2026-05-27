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
                    NSLog("[Gateway] Resolved %@ (%@) → %@", gateway.name, gateway.gatewayProvider.displayName, endpoint)
                    return endpoint
                }
            }
            // None reachable — use first gateway's best guess
            let first = gateways[0]
            let fallback = !first.tunnelURL.isEmpty ? first.tunnelURL : first.lanURL
            cachedEndpoint = fallback
            activeGateway = first
            activeGatewayName = first.name
            NSLog("[Gateway] None reachable, falling back to %@ → %@", first.name, fallback)
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
            if !lanURL.isEmpty, await isReachable(baseURL: lanURL, token: gateway.token, session: lanPingSession) {
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: gateway.token, session: pingSession) {
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
            if await isReachable(baseURL: lanURL, token: Config.openClawGatewayToken, session: lanPingSession) {
                cachedEndpoint = lanURL
                resolvedConnection = .lan
                return lanURL
            }
            if !tunnelURL.isEmpty, await isReachable(baseURL: tunnelURL, token: Config.openClawGatewayToken, session: pingSession) {
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
                NSLog("[Gateway] Failing over from %@ to %@", current.name, next.name)
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

    /// The active gateway's token, or the legacy token.
    var activeToken: String {
        activeGateway?.token ?? Config.openClawGatewayToken
    }

    /// Check reachability using /health endpoint
    private func isReachable(baseURL: String, token: String? = nil, session: URLSession) async -> Bool {
        let normalized = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(normalized)/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let authToken = token ?? activeToken
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("[OpenClaw] Health %@ → HTTP %d (%@)", url.absoluteString, http.statusCode, String(body.prefix(100)))
                return (200...299).contains(http.statusCode)
            }
        } catch {
            NSLog("[OpenClaw] Health %@ failed: %@", url.absoluteString, error.localizedDescription)
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
            let (data, response) = try await pingSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("[OpenClaw] Health %@ → HTTP %d (%@)", url.absoluteString, http.statusCode, body)
                if (200...299).contains(http.statusCode) {
                    connectionState = .connected
                    NSLog("[OpenClaw] Gateway connected via %@", resolvedConnection?.label ?? "unknown")
                    return
                }
                connectionState = .unreachable("HTTP \(http.statusCode)")
                return
            }
        } catch {
            NSLog("[OpenClaw] Health check failed: %@", error.localizedDescription)
        }
        connectionState = .unreachable("Gateway not responding")
    }

    // MARK: - Session Management

    func resetSession() {
        sessionKey = OpenClawBridge.newSessionKey()
        NSLog("[OpenClaw] New session: %@", sessionKey)
    }

    private static func newSessionKey() -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return "agent:main:glass:\(ts)"
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

        guard let url = URL(string: "\(wsURL)/ws?token=\(token)") else {
            throw NSError(domain: "OpenClaw", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"])
        }

        NSLog("[OpenClaw] WS connecting to %@", url.absoluteString)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        wsSession = URLSession(configuration: config)

        // Build request with X-Scopes header (OpenClaw protocol v3 requirement)
        var request = URLRequest(url: url)
        request.setValue("chat,skills,sessions,config,tools", forHTTPHeaderField: "X-Scopes")
        webSocketTask = wsSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Wait for connect.challenge
        let challengeMsg = try await receiveMessage()
        NSLog("[OpenClaw] WS received: %@", String(challengeMsg.prefix(100)))

        // Send connect handshake — register as "node" with device capabilities
        let connectId = UUID().uuidString
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "gateway-client",
                    "displayName": "OpenGlasses",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                    "platform": "ios",
                    "mode": "node"
                ] as [String: Any],
                "auth": [
                    "token": token
                ]
            ] as [String: Any]
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectMsg)
        let connectJSON = String(data: connectData, encoding: .utf8)!
        NSLog("[OpenClawWS] Sending connect: %@", String(connectJSON.prefix(500)))
        try await webSocketTask!.send(.string(connectJSON))

        // Wait for connect response
        let response = try await receiveMessage()
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ok = json["ok"] as? Bool, ok {
            wsConnected = true
            sessionCompacted = false
            NSLog("[OpenClaw] WS connected as node with capabilities")
            startReceiveLoop()

            // Query available tools from gateway (fire-and-forget, non-blocking)
            Task { await queryAvailableTools() }
            onGatewayConnected?()
        } else {
            NSLog("[OpenClaw] WS connect failed: %@", String(response.prefix(300)))
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
                                NSLog("[OpenClaw] Session compacted by gateway")
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
                    NSLog("[OpenClaw] WS receive error: %@", error.localizedDescription)
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
                NSLog("[OpenClaw] Gateway has %d tools available", tools.count)
            } else {
                // Gateway may not support tools.available — not an error
                NSLog("[OpenClaw] tools.available not supported or empty")
            }
        } catch {
            NSLog("[OpenClaw] tools.available query failed: %@", error.localizedDescription)
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
                NSLog("[OpenClaw] Cron job created: %@", id)
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
                    NSLog("[OpenClaw] Task result: %@", String(content.prefix(200)))
                    lastToolCallStatus = .completed(toolName)
                    return .success(content)
                }
                // Some responses just acknowledge the send — the actual result comes via events
                if let payload = response["payload"] as? [String: Any],
                   let runId = payload["runId"] as? String {
                    NSLog("[OpenClaw] Task dispatched, runId: %@", runId)
                    lastToolCallStatus = .completed(toolName)
                    return .success("Task dispatched (runId: \(runId))")
                }
                lastToolCallStatus = .completed(toolName)
                return .success("OK")
            } else {
                let error = response["error"] as? [String: Any]
                let code = error?["code"] as? String ?? "unknown"
                let message = error?["message"] as? String ?? "Unknown error"
                NSLog("[OpenClaw] Task failed: %@ - %@", code, message)

                if message.contains("missing scope") {
                    lastToolCallStatus = .failed(toolName, "Token needs write permissions")
                    return .failure("Gateway token needs operator.write scope. Update the token permissions in OpenClaw settings.")
                }

                lastToolCallStatus = .failed(toolName, message)
                return .failure("Gateway error: \(message)")
            }
        } catch {
            NSLog("[OpenClaw] Task error: %@", error.localizedDescription)
            // Reconnect on next attempt
            disconnectWebSocket()
            lastToolCallStatus = .failed(toolName, error.localizedDescription)
            return .failure("Gateway error: \(error.localizedDescription)")
        }
    }
}
