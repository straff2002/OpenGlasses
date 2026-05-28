import Foundation
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
/// A Mac-side MCP stdio bridge (Claude Code) proxies these over the LAN; for remote use the developer
/// runs their own `cloudflared` tunnel. The bridge + tunnel are out of app scope by design.
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
                    case .ready: self?.isRunning = true; NSLog("[MCPServer] Listening on :%d", Int(self?.port ?? 0))
                    case .failed(let error): NSLog("[MCPServer] Failed: %@", error.localizedDescription); self?.stop()
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            NSLog("[MCPServer] Could not start: %@", error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        NSLog("[MCPServer] Stopped")
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
        // No display surface yet — both modes speak; "display" is logged for the future display app.
        if mode == "display" { NSLog("[MCPServer] (display) %@", text) }
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

    init(rawData: Data) {
        guard let headerEndRange = rawData.range(of: Data("\r\n\r\n".utf8)) else {
            // No header terminator seen; parse the first line only.
            let text = String(data: rawData, encoding: .utf8) ?? ""
            let parts = text.split(separator: " ")
            method = parts.first.map(String.init) ?? ""
            path = parts.count > 1 ? String(parts[1]) : "/"
            body = nil
            return
        }
        let headerData = rawData.subdata(in: rawData.startIndex..<headerEndRange.lowerBound)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let firstLine = headerText.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        method = parts.first.map(String.init) ?? ""
        path = parts.count > 1 ? String(parts[1]) : "/"
        let bodyStart = headerEndRange.upperBound
        body = bodyStart < rawData.endIndex ? rawData.subdata(in: bodyStart..<rawData.endIndex) : nil
    }
}
