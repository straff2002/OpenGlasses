import Foundation

/// WebSocket client for receiving proactive notifications from OpenClaw.
/// Connects to the OpenClaw gateway's WebSocket endpoint, authenticates,
/// and listens for heartbeat/cron events to speak through TTS.
class OpenClawEventClient {
    var onNotification: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30

    func connect() {
        guard Config.isOpenClawConfigured else {
            NSLog("[OpenClawWS] Not configured, skipping")
            return
        }
        shouldReconnect = true
        reconnectDelay = 2
        establishConnection()
    }

    func disconnect() {
        shouldReconnect = false
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        NSLog("[OpenClawWS] Disconnected")
    }

    // MARK: - Private

    private func establishConnection() {
        // Use the new multi-gateway config; fall back to legacy if needed
        guard let gateway = Self.activeGateway() else {
            NSLog("[OpenClawWS] No configured gateway found, skipping")
            return
        }

        let wsURL = Self.webSocketURL(for: gateway)
        guard let url = URL(string: wsURL) else {
            NSLog("[OpenClawWS] Invalid URL: %@", wsURL)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        NSLog("[OpenClawWS] Connecting to %@ (gateway: %@)", url.absoluteString, gateway.name)
        startReceiving()
    }

    /// Find the first enabled gateway that uses the OpenClaw WebSocket protocol.
    private static func activeGateway() -> GatewayConfig? {
        let gateways = Config.enabledGateways
        if let gw = gateways.first(where: { $0.gatewayProvider.usesOpenClawProtocol && $0.isConfigured }) {
            return gw
        }
        // Fall back to legacy single-gateway config
        if Config.openClawEnabled && !Config.openClawGatewayToken.isEmpty {
            return GatewayConfig(
                id: "legacy",
                name: "Legacy OpenClaw",
                provider: GatewayProvider.openclaw.rawValue,
                lanHost: Config.openClawLanHost,
                port: Config.openClawPort,
                tunnelHost: Config.openClawTunnelHost,
                token: Config.openClawGatewayToken,
                connectionMode: Config.openClawConnectionMode.rawValue,
                enabled: true,
                priority: 0
            )
        }
        return nil
    }

    /// Build a WebSocket URL from a gateway config.
    private static func webSocketURL(for gateway: GatewayConfig) -> String {
        let mode = gateway.connectionModeEnum
        switch mode {
        case .tunnel:
            return tunnelWebSocketURL(for: gateway)
        case .lan:
            return lanWebSocketURL(for: gateway)
        case .auto:
            if !gateway.tunnelHost.isEmpty {
                return tunnelWebSocketURL(for: gateway)
            }
            return lanWebSocketURL(for: gateway)
        }
    }

    private static func tunnelWebSocketURL(for gateway: GatewayConfig) -> String {
        let base = gateway.tunnelHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return "\(base)/ws?token=\(gateway.token)"
    }

    private static func lanWebSocketURL(for gateway: GatewayConfig) -> String {
        let host = gateway.lanHost
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        return "ws://\(host):\(gateway.port)/ws?token=\(gateway.token)"
    }

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiving()
            case .failure(let error):
                NSLog("[OpenClawWS] Receive error: %@", error.localizedDescription)
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "event" {
            handleEvent(json)
        } else if type == "res" {
            let ok = json["ok"] as? Bool ?? false
            if ok {
                NSLog("[OpenClawWS] Connected and authenticated")
                isConnected = true
                reconnectDelay = 2
            } else {
                let error = json["error"] as? [String: Any]
                let msg = error?["message"] as? String ?? "unknown"
                let code = error?["code"] as? Int
                NSLog("[OpenClawWS] Connect failed: %@ (code: %@, full response: %@)", msg, code.map { "\($0)" } ?? "nil", text)
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch event {
        case "connect.challenge":
            sendConnectHandshake()
        case "heartbeat":
            handleHeartbeatEvent(payload)
        case "cron":
            handleCronEvent(payload)
        default:
            break
        }
    }

    private func sendConnectHandshake() {
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
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
                    "token": Config.openClawGatewayToken
                ]
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error {
                NSLog("[OpenClawWS] Handshake send error: %@", error.localizedDescription)
            }
        }
    }

    private func handleHeartbeatEvent(_ payload: [String: Any]) {
        let status = payload["status"] as? String ?? ""
        guard status == "sent",
              let preview = payload["preview"] as? String, !preview.isEmpty else { return }

        let silent = payload["silent"] as? Bool ?? false
        guard !silent else { return }

        NSLog("[OpenClawWS] Heartbeat notification: %@", String(preview.prefix(100)))
        onNotification?(preview)
    }

    private func handleCronEvent(_ payload: [String: Any]) {
        let action = payload["action"] as? String ?? ""
        guard action == "finished" else { return }

        let summary = payload["summary"] as? String
            ?? payload["result"] as? String
            ?? ""
        guard !summary.isEmpty else { return }

        NSLog("[OpenClawWS] Cron result (%d chars): %@", summary.count, String(summary.prefix(100)))
        onNotification?(summary)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        NSLog("[OpenClawWS] Reconnecting in %.0fs", reconnectDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.establishConnection()
        }
    }
}
