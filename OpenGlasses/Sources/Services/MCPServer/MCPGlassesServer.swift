import Foundation
import CryptoKit
import Network
import UIKit

/// Local HTTP server (Plan E) that lets a Claude Code session on the same LAN "see through" the
/// glasses. Developer-only — gated behind `agentModeEnabled` + `mcpServerEnabled`.
///
/// Exposes three REST endpoints on port 8765, mirroring the planned MCP tools:
///   - `GET  /see_glasses`     → `{ image_b64, timestamp }` — latest camera frame
///   - `GET  /glasses_status`  → `{ connected, frame_age_ms, last_frame_iso }`
///   - `POST /send_to_glasses` → body `{ text, mode: "tts"|"display" }` → speaks/logs, returns `{ ok }`
///
/// Every request must carry `Authorization: Bearer <token>` (Plan BC) — the token is generated per
/// enable and shown in Settings. Without it these endpoints would be an unauthenticated LAN camera
/// feed to anyone on the same Wi-Fi.
///
/// A Mac-side MCP stdio bridge (Claude Code) proxies these over the LAN. The bridge is out of app
/// scope by design.
@MainActor
final class MCPGlassesServer: ObservableObject {
    static let shared = MCPGlassesServer()

    @Published private(set) var isRunning = false
    let port: UInt16 = 8765

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private weak var camera: CameraService?
    private weak var tts: TextToSpeechService?

    /// Min interval a frame is reused, so a tight Claude Code poll loop can't blow up tokens.
    private var lastServedFrameAt: Date?

    /// Bearer token required on every request. Kept in the Keychain (this-device-only) and
    /// regenerated whenever the server is started without one.
    private static let tokenKey = "mcpServerBearerToken"

    /// The current access token, generating and persisting one on first read.
    var accessToken: String {
        if let existing = KeychainService.string(for: Self.tokenKey), !existing.isEmpty {
            return existing
        }
        let token = Self.generateToken()
        KeychainService.setString(token, for: Self.tokenKey)
        return token
    }

    /// Rotate the token (invalidates any existing bridge configuration).
    @discardableResult
    func regenerateToken() -> String {
        let token = Self.generateToken()
        KeychainService.setString(token, for: Self.tokenKey)
        return token
    }

    private static func generateToken() -> String {
        // 256 bits, URL-safe.
        let raw = SymmetricKey(size: .bits256)
        return raw.withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private init() {}

    func configure(camera: CameraService, tts: TextToSpeechService) {
        self.camera = camera
        self.tts = tts
    }

    // MARK: - Lifecycle

    /// Start the server if the dev gates are on. No-op otherwise.
    func startIfEnabled() {
        guard Config.agentModeEnabled, Config.mcpServerEnabled else { return }
        start()
    }

    func start() {
        guard listener == nil else { return }
        _ = accessToken   // ensure a token exists before we accept connections
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        PrivacyLog.mcpServer(.listening, port: Int(self?.port ?? 0))
                    case .failed(let error):
                        PrivacyLog.mcpServer(.startFailed, error: SafeErrorSummary(error))
                        self?.stop()
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            PrivacyLog.mcpServer(.startFailed, error: SafeErrorSummary(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        PrivacyLog.mcpServer(.stopped)
    }

    func toggle(camera: CameraService, tts: TextToSpeechService) {
        configure(camera: camera, tts: tts)
        isRunning ? stop() : start()
    }

    /// Best-effort LAN address for display in Settings (e.g. "192.168.1.42").
    static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }

    // MARK: - Connection handling

    private nonisolated func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            let request = HTTPRequest(rawData: data)
            Task { @MainActor in
                let response = await self.route(request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            _ = isComplete
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> Data {
        guard Self.isAuthorized(bearer: request.bearerToken, expected: accessToken) else {
            // The path arrives from the network, so it is classified rather than quoted: an
            // unauthorised caller chooses it, and a scanner's path is attacker-supplied text.
            PrivacyLog.mcpServer(.requestRejected, route: Self.route(for: request.path))
            return Self.httpResponse(status: "401 Unauthorized",
                                     json: ["error": "missing or invalid bearer token"])
        }
        switch (request.method, request.path) {
        case ("GET", "/see_glasses"):
            return seeGlasses()
        case ("GET", "/glasses_status"):
            return glassesStatus()
        case ("POST", "/send_to_glasses"):
            return await sendToGlasses(body: request.body)
        default:
            return Self.httpResponse(status: "404 Not Found", json: ["error": "unknown endpoint"])
        }
    }

    /// Classify a request path into the fixed endpoint set, for logging. Anything else is
    /// `unknown` — the raw path never leaves this function.
    static func route(for path: String) -> PrivacyLog.MCPRoute {
        switch path {
        case "/see_glasses": return .seeGlasses
        case "/glasses_status": return .glassesStatus
        case "/send_to_glasses": return .sendToGlasses
        default: return .unknown
        }
    }

    /// Constant-time bearer-token comparison. Pure — unit-tested without a live socket.
    static func isAuthorized(bearer: String?, expected: String) -> Bool {
        guard !expected.isEmpty, let bearer, !bearer.isEmpty else { return false }
        let a = Data(bearer.utf8), b = Data(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private func seeGlasses() -> Data {
        guard let frame = camera?.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.7) else {
            return Self.httpResponse(status: "503 Service Unavailable", json: ["error": "no frame available"])
        }
        lastServedFrameAt = Date()
        return Self.httpResponse(status: "200 OK", json: [
            "image_b64": jpeg.base64EncodedString(),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
    }

    private func glassesStatus() -> Data {
        let hasFrame = camera?.latestFrame != nil
        var payload: [String: Any] = ["connected": hasFrame]
        if let served = lastServedFrameAt {
            payload["frame_age_ms"] = Int(Date().timeIntervalSince(served) * 1000)
            payload["last_frame_iso"] = ISO8601DateFormatter().string(from: served)
        }
        return Self.httpResponse(status: "200 OK", json: payload)
    }

    private func sendToGlasses(body: Data?) async -> Data {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String, !text.isEmpty else {
            return Self.httpResponse(status: "400 Bad Request", json: ["error": "expected {text, mode}"])
        }
        let mode = (json["mode"] as? String) ?? "tts"
        // No display surface yet — both modes speak. The "display" text used to be logged whole;
        // it is a message a LAN peer sends to the wearer, so only the fact is recorded.
        if mode == "display" { PrivacyLog.mcpServer(.forwardUnsupported, route: .sendToGlasses) }
        await tts?.speak(text, urgency: .low)
        return Self.httpResponse(status: "200 OK", json: ["ok": true, "mode": mode])
    }

    // MARK: - HTTP helpers

    private static func httpResponse(status: String, json: [String: Any]) -> Data {
        let bodyData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(bodyData)
        return out
    }
}

/// Minimal HTTP request parser — enough for the small GET/POST surface above.
private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data?
    /// The token from an `Authorization: Bearer <token>` header, if present.
    let bearerToken: String?

    init(rawData: Data) {
        guard let headerEndRange = rawData.range(of: Data("\r\n\r\n".utf8)) else {
            // No header terminator seen; parse the first line only.
            let text = String(data: rawData, encoding: .utf8) ?? ""
            let parts = text.split(separator: " ")
            method = parts.first.map(String.init) ?? ""
            path = parts.count > 1 ? String(parts[1]) : "/"
            body = nil
            bearerToken = nil
            return
        }
        let headerData = rawData.subdata(in: rawData.startIndex..<headerEndRange.lowerBound)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerText.split(separator: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.split(separator: " ")
        method = parts.first.map(String.init) ?? ""
        path = parts.count > 1 ? String(parts[1]) : "/"
        bearerToken = Self.parseBearer(lines: lines.dropFirst())
        let bodyStart = headerEndRange.upperBound
        body = bodyStart < rawData.endIndex ? rawData.subdata(in: bodyStart..<rawData.endIndex) : nil
    }

    private static func parseBearer(lines: ArraySlice<Substring>) -> String? {
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "authorization" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bearer ") {
                return String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
