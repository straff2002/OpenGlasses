import Foundation
import Combine
import UIKit
import os.lock

/// Lightweight WebRTC-style browser streaming via WebSocket signaling.
/// Converts camera frames to MJPEG and streams them to connected web browsers.
///
/// Architecture:
/// - Runs a local WebSocket relay: phone pushes JPEG frames to the signaling server
/// - A companion web page connects to the same server and displays the stream
/// - Uses a free signaling relay (configurable) so no server setup needed
///
/// For production, this could be upgraded to proper WebRTC with LiveKit or similar.
@MainActor
class WebRTCStreamingService: ObservableObject {
    @Published var isStreaming: Bool = false
    @Published var viewerCount: Int = 0
    @Published var streamURL: String = ""
    @Published var errorMessage: String?

    /// JPEG quality for streamed frames (0.0 - 1.0). Read from the nonisolated send path, so
    /// `nonisolated(unsafe)` — set once at configuration, not mutated mid-stream.
    nonisolated(unsafe) var jpegQuality: CGFloat = 0.4

    /// Target FPS for the stream
    var targetFPS: Double = 15.0

    private var webSocket: URLSessionWebSocketTask?
    /// One reused session for the whole stream (incl. reconnects), invalidated on stop — the old
    /// code created a fresh URLSession per connect and never invalidated it, leaking a session pool
    /// on every reconnect.
    private var urlSession: URLSession?
    private var frameSubscription: AnyCancellable?
    private var heartbeatTask: Task<Void, Never>?
    private var roomId: String = ""
    /// Read/written only from the throttle sink's serial queue (see `startStreaming`).
    nonisolated(unsafe) private var lastFrameTime: Date = .distantPast
    /// Simple backpressure: drop a frame if the previous send hasn't completed, so a slow link
    /// can't queue frames unboundedly inside URLSession.
    private let sendGate = OSAllocatedUnfairLock(initialState: false)   // true == a send is in flight

    /// The signaling server URL. Users can set up their own or use a public relay.
    private var signalingURL: String {
        Config.webRTCSignalingURL
    }

    // MARK: - Public API

    /// Start streaming camera frames to the signaling server.
    /// Returns a URL that can be shared with viewers.
    func startStreaming(framePublisher: PassthroughSubject<UIImage, Never>) -> String {
        guard !isStreaming else { return streamURL }

        // Generate a random room ID
        roomId = generateRoomId()
        let viewerURL = "\(Config.webRTCViewerBaseURL)?room=\(roomId)"
        streamURL = viewerURL

        // Connect to signaling server
        connectWebSocket()

        // Subscribe to frame publisher
        let interval = 1.0 / targetFPS
        frameSubscription = framePublisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] image in
                guard let self = self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastFrameTime) >= interval else { return }
                self.lastFrameTime = now
                self.sendFrame(image)
            }

        isStreaming = true
        errorMessage = nil

        // Start heartbeat to maintain connection and track viewers
        startHeartbeat()

        // The viewer URL embeds the room code — a bearer capability to the wearer's live
        // camera. It is handed to the user, never to a log.
        PrivacyLog.stream(.viewerBroadcast, .started)
        return viewerURL
    }

    func stopStreaming() {
        frameSubscription?.cancel()
        frameSubscription = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Send stop message
        if let ws = webSocket {
            let stopMsg: [String: Any] = ["type": "stream_stop", "room": roomId]
            if let data = try? JSONSerialization.data(withJSONObject: stopMsg),
               let str = String(data: data, encoding: .utf8) {
                ws.send(.string(str)) { _ in }
            }
            ws.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sendGate.withLock { $0 = false }

        isStreaming = false
        viewerCount = 0
        streamURL = ""
        roomId = ""

        PrivacyLog.stream(.viewerBroadcast, .stopped)
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket() {
        guard let url = URL(string: "\(signalingURL)?role=streamer&room=\(roomId)") else {
            errorMessage = "Invalid signaling URL"
            return
        }

        if urlSession == nil {
            urlSession = URLSession(configuration: .default)
        }
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        receiveMessages()

        // Send initial handshake
        let hello: [String: Any] = [
            "type": "stream_start",
            "room": roomId,
            "format": "mjpeg",
            "fps": targetFPS
        ]
        sendJSON(hello)
    }

    private func receiveMessages() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.receiveMessages() // Continue listening
                case .failure(let error):
                    PrivacyLog.stream(.viewerBroadcast, .receiveFailed, error: SafeErrorSummary(error))
                    if self?.isStreaming == true {
                        // Attempt reconnect
                        self?.reconnect()
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }

            switch type {
            case "viewer_count":
                viewerCount = json["count"] as? Int ?? 0
            case "viewer_joined":
                viewerCount += 1
                PrivacyLog.stream(.viewerBroadcast, .viewerJoined, count: viewerCount)
            case "viewer_left":
                viewerCount = max(0, viewerCount - 1)
                PrivacyLog.stream(.viewerBroadcast, .viewerLeft, count: viewerCount)
            case "error":
                errorMessage = json["message"] as? String ?? "Unknown error"
            default:
                break
            }
        case .data:
            break // Binary messages not expected from server
        @unknown default:
            break
        }
    }

    private func reconnect() {
        webSocket?.cancel(with: .abnormalClosure, reason: nil)
        webSocket = nil

        // Wait briefly then reconnect
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if isStreaming {
                connectWebSocket()
            }
        }
    }

    // MARK: - Frame Sending

    private nonisolated func sendFrame(_ image: UIImage) {
        // Backpressure: if the previous frame's send hasn't completed, drop this one rather than
        // letting frames queue unboundedly inside URLSession on a slow link.
        let busy = sendGate.withLock { inFlight -> Bool in
            if inFlight { return true }
            inFlight = true
            return false
        }
        guard !busy else { return }

        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else {
            sendGate.withLock { $0 = false }
            return
        }

        // Build ONLY the payload we'll actually send (the old code base64+JSON-encoded every frame
        // and then discarded it for the binary path).
        let message: URLSessionWebSocketTask.Message
        if WebRTCFrameEncoder.shouldSendBinary(jpegByteCount: jpegData.count) {
            message = .data(WebRTCFrameEncoder.binaryMessage(jpegData))
        } else {
            let frameMsg: [String: Any] = [
                "type": "frame",
                "data": jpegData.base64EncodedString(),
                "timestamp": Date().timeIntervalSince1970
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: frameMsg),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                sendGate.withLock { $0 = false }
                return
            }
            message = .string(jsonStr)
        }

        Task { @MainActor [weak self] in
            guard let self, let ws = self.webSocket else {
                self?.sendGate.withLock { $0 = false }
                return
            }
            ws.send(message) { [weak self] error in
                self?.sendGate.withLock { $0 = false }
                if let error { PrivacyLog.stream(.viewerBroadcast, .sendFailed, error: SafeErrorSummary(error)) }
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask = Task {
            while !Task.isCancelled && isStreaming {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                let ping: [String: Any] = ["type": "heartbeat", "room": roomId]
                sendJSON(ping)
            }
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { error in
            if let error = error {
                PrivacyLog.stream(.viewerBroadcast, .sendFailed, error: SafeErrorSummary(error))
            }
        }
    }

    private func generateRoomId() -> String {
        // A viewer who knows the room code can watch the live stream, so the code must be
        // unguessable rather than a short slug: 128 bits of cryptographic randomness,
        // URL-safe base64. Replaces the old 6-char alphanumeric code (~31 bits, brute-forceable).
        return SecureToken.urlSafe(byteCount: 16)
    }
}
