import Foundation

/// WebSocket client for receiving proactive notifications from OpenClaw.
/// Connects to the OpenClaw gateway's WebSocket endpoint, authenticates,
/// and listens for heartbeat/cron events to speak through TTS.
class OpenClawEventClient {
    var onNotification: ((String) -> Void)?
    /// Surfaces live pairing/connection state to the gateway settings UI.
    var onPairingStatusChange: ((PairingStatus) -> Void)?
    /// Remote invoke (Plan BH): an unsolicited server→client request frame arrived. The handler
    /// produces exactly one reply frame and passes it to the completion for sending.
    var onRemoteRequest: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30
    /// The gateway resolved for the current connection — its credential drives the handshake.
    private var currentGateway: GatewayConfig?
    /// Nonce from the gateway's `connect.challenge` — signed into the device-identity block so
    /// remote gateways grant real scopes (token-only connects can be granted zero scopes).
    private var challengeNonce: String?

    func connect() {
        // BK P0: listening for inbound gateway events and feeding them to the triage LLM is itself
        // an autonomous background action on untrusted content — gate the whole loop on Agent Mode,
        // not just the outbound `delegateTask` leg it can reach.
        guard Config.isOpenClawAgentActive else {
            PrivacyLog.gatewayConnection(.inactive)
            return
        }
        shouldReconnect = true
        reconnectDelay = 2
        establishConnection()
    }

    func disconnect() {
        sendDeviceEvent(type: "connection", payload: ["status": "disconnected"])
        shouldReconnect = false
        isConnected = false
        challengeNonce = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        onPairingStatusChange?(.disconnected)
        PrivacyLog.gatewayConnection(.disconnected)
    }

    /// Begin device pairing with a setup code: store it on the active gateway and reconnect, so
    /// the handshake presents the bootstrap token. The gateway returns a per-device token once
    /// the device is approved (captured in `handleConnectResponse` / the `device.paired` event).
    func startPairing(setupCode: String) {
        guard let gateway = Self.activeGateway() else {
            onPairingStatusChange?(.error("No gateway configured"))
            return
        }
        Config.setGatewaySetupCode(gatewayId: gateway.id, setupCode: setupCode)
        disconnect()
        connect()
    }

    // MARK: - Private

    private func establishConnection() {
        // Use the new multi-gateway config; fall back to legacy if needed
        guard let gateway = Self.activeGateway() else {
            PrivacyLog.gatewayConnection(.notConfigured)
            return
        }
        currentGateway = gateway
        onPairingStatusChange?(.connecting)

        let wsURL = Self.webSocketURL(for: gateway)
        guard let url = URL(string: wsURL) else {
            PrivacyLog.gatewayConnection(.endpointMalformed, peer: PrivateIdentifier(gateway.id))
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        // BR P4: same channel classification as the bridge socket.
        var request = URLRequest(url: url)
        request.setValue(OpenClawBridge.messageChannel, forHTTPHeaderField: "x-openclaw-message-channel")
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()

        PrivacyLog.gatewayConnection(.connecting, transport: Self.transport(for: gateway),
                                     peer: PrivateIdentifier(gateway.id))
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

    /// Which leg `webSocketURL(for:)` will pick — mirrors its branch, for logging only.
    private static func transport(for gateway: GatewayConfig) -> PrivacyLog.GatewayTransport {
        switch gateway.connectionModeEnum {
        case .tunnel: return .tunnel
        case .lan: return .lan
        case .auto: return gateway.tunnelHost.isEmpty ? .lan : .tunnel
        }
    }

    // The gateway token is presented in the `connect` handshake (see `sendConnectHandshake`),
    // never in the URL — keeping it out of the query string prevents it leaking into device,
    // proxy, and server access logs.
    private static func tunnelWebSocketURL(for gateway: GatewayConfig) -> String {
        let base = gateway.tunnelHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return "\(base)/ws"
    }

    private static func lanWebSocketURL(for gateway: GatewayConfig) -> String {
        let host = gateway.lanHost
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        return "ws://\(host):\(gateway.port)/ws"
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
                PrivacyLog.gatewayFailed(.receive, SafeErrorSummary(error))
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
            handleConnectResponse(json)
        } else if type == "req" {
            handleRequestFrame(json)
        }
    }

    /// Remote invoke (Plan BH): an unsolicited server→client request. The wired handler owns
    /// parse/policy/execute and always produces exactly one reply frame; with no handler wired
    /// we still answer (unsupported) rather than leave the gateway hanging.
    private func handleRequestFrame(_ json: [String: Any]) {
        guard let handler = onRemoteRequest else {
            if let request = RemoteCommandParser.parse(json) {
                sendFrame(RemoteInvokeReply.unsupported(id: request.id, action: "remote_invoke"))
            }
            return
        }
        handler(json) { [weak self] reply in
            self?.sendFrame(reply)
        }
    }

    private func sendFrame(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error {
                PrivacyLog.gatewayFailed(.send, SafeErrorSummary(error))
            }
        }
    }

    /// Fire-and-forget `device.event` push (Plan BH follow-up): tell the gateway-side agent
    /// something changed on the device without being asked — connection state, glasses
    /// attach/detach, battery. The request/reply invoke path stays unchanged; this is the
    /// outbound half of the bidirectional terminal. No-op unless the socket is authenticated.
    func sendDeviceEvent(type: String, payload: [String: Any]) {
        guard isConnected else { return }
        var body: [String: Any] = [
            "type": type,
            "timestamp": Int(Date().timeIntervalSince1970),
        ]
        if !payload.isEmpty { body["data"] = payload }
        sendFrame([
            "type": "event",
            "event": "device.event",
            "payload": body,
        ])
        PrivacyLog.gatewayConnection(.deviceEventSent, detail: PrivacyToken(type))
    }

    /// Map a connect `res` to a pairing outcome: persist a freshly-issued device token, update
    /// connection state, and surface the status. Pure interpretation lives in
    /// `PairingResponseInterpreter`; this applies its side effects.
    private func handleConnectResponse(_ json: [String: Any]) {
        let outcome = PairingResponseInterpreter.interpretResponse(json)

        if let token = outcome.deviceToken, let gatewayId = currentGateway?.id {
            Config.setDeviceCredentials(gatewayId: gatewayId, deviceToken: token)
            PrivacyLog.gatewayConnection(.devicePaired, peer: PrivateIdentifier(gatewayId))
        }

        switch outcome.status {
        case .paired:
            isConnected = true
            reconnectDelay = 2
            PrivacyLog.gatewayConnection(.connected)
            sendDeviceEvent(type: "connection", payload: ["status": "connected"])
        case .waitingApproval:
            PrivacyLog.gatewayConnection(.pairingPending)
        case .error:
            // The interpreter's message and the raw frame are both the gateway's own prose —
            // the frame additionally echoes the credential we just presented.
            PrivacyLog.gatewayConnection(.authRejected)
        case .disconnected, .connecting:
            break
        }
        onPairingStatusChange?(outcome.status)
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch event {
        case "connect.challenge":
            challengeNonce = payload["nonce"] as? String
            sendConnectHandshake()
        case "device.paired":
            if let outcome = PairingResponseInterpreter.interpretPairedEvent(payload),
               let token = outcome.deviceToken, let gatewayId = currentGateway?.id {
                Config.setDeviceCredentials(gatewayId: gatewayId, deviceToken: token)
                PrivacyLog.gatewayConnection(.devicePaired, peer: PrivateIdentifier(gatewayId))
                onPairingStatusChange?(.paired)
            }
        case "heartbeat":
            handleHeartbeatEvent(payload)
        case "cron":
            handleCronEvent(payload)
        default:
            break
        }
    }

    private func sendConnectHandshake() {
        // Present the ACTIVE gateway's credential (device token > bootstrap > shared token),
        // not the legacy global token — this both fixes wrong-credential sends on multi-gateway
        // setups and enables device pairing. Falls back to the global token if no gateway was
        // resolved, so the default path is unchanged.
        let token: String
        var deviceId = ""
        if let gateway = currentGateway {
            token = GatewayAuthSelector.credential(
                deviceToken: gateway.deviceToken,
                setupCode: gateway.setupCode,
                sharedToken: gateway.token
            )
            deviceId = Config.deviceId(forGateway: gateway.id)
        } else {
            token = Config.openClawGatewayToken
        }

        // Shared builder (protocol v3/v4): role/scopes, capability advertisement, and — when the
        // gateway issued a challenge nonce — the signed Ed25519 device-identity block.
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "connect",
            "params": OpenClawConnectParams.build(
                clientId: "gateway-client",
                displayName: "OpenGlasses",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                token: token,
                challengeNonce: challengeNonce,
                pairedDeviceId: deviceId.isEmpty ? nil : deviceId
            )
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
              let string = String(data: data, encoding: .utf8) else { return }
        PrivacyLog.gatewayConnection(.handshakeSent)
        webSocketTask?.send(.string(string)) { error in
            if let error {
                PrivacyLog.gatewayFailed(.handshake, SafeErrorSummary(error))
            }
        }
    }

    private func handleHeartbeatEvent(_ payload: [String: Any]) {
        let status = payload["status"] as? String ?? ""
        guard status == "sent",
              let preview = payload["preview"] as? String, !preview.isEmpty else { return }

        let silent = payload["silent"] as? Bool ?? false
        guard !silent else { return }

        // The preview is spoken to the wearer; it is the notification's content, not metadata.
        PrivacyLog.gatewayNotification(.heartbeat, characters: preview.count)
        onNotification?(preview)
    }

    private func handleCronEvent(_ payload: [String: Any]) {
        let action = payload["action"] as? String ?? ""
        guard action == "finished" else { return }

        let summary = payload["summary"] as? String
            ?? payload["result"] as? String
            ?? ""
        guard !summary.isEmpty else { return }

        PrivacyLog.gatewayNotification(.cronResult, characters: summary.count)
        onNotification?(summary)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        // Jitter (±20%) so a fleet of clients doesn't stampede a recovering gateway in lockstep.
        // The socket is load-bearing for inbound remote invoke (Plan BH), so we keep retrying
        // forever — but connection state is surfaced via `onPairingStatusChange`, never silent.
        let delay = reconnectDelay * Double.random(in: 0.8...1.2)
        PrivacyLog.gatewayReconnectScheduled(delaySeconds: delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.establishConnection()
        }
    }
}
