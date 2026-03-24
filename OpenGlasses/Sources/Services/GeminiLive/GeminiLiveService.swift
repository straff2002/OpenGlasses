import Foundation
import UIKit

/// Connection state for the Gemini Live WebSocket.
enum GeminiConnectionState: Equatable {
    case disconnected
    case connecting
    case settingUp
    case ready
    case error(String)
}

/// WebSocket-based real-time Gemini streaming service.
/// Sends/receives audio (PCM), sends video frames (JPEG), handles tool calls,
/// and supports automatic reconnection with exponential backoff.
@MainActor
class GeminiLiveService: ObservableObject {
    @Published var connectionState: GeminiConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false
    @Published var reconnecting: Bool = false

    // Callbacks
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onToolCall: ((GeminiToolCall) -> Void)?
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?
    var onReconnected: (() -> Void)?

    // Reconnection
    private var intentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let maxBackoffSeconds: Double = 30
    private var reconnectTask: Task<Void, Never>?

    // Latency tracking
    private var lastUserSpeechEnd: Date?
    private var responseLatencyLogged = false

    // Frame tracking
    @Published var videoFramesSent: Int = 0

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private let delegate = WebSocketDelegate()
    private var urlSession: URLSession!

    // Dedicated send queue — keeps JSON serialization, JPEG compression, and base64
    // encoding off the main thread (matches VisionClaw's approach)
    private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)

    // Dynamic configuration for mode/tool setup
    private var systemInstruction: String = ""
    private var toolDeclarations: [[String: Any]] = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Configure the session parameters before connecting.
    /// Call this before `connect()` to set mode-specific instructions and tools.
    func configure(systemInstruction: String, toolDeclarations: [[String: Any]]) {
        self.systemInstruction = systemInstruction
        self.toolDeclarations = toolDeclarations
    }

    // MARK: - Connect / Disconnect

    func connect() async -> Bool {
        guard let url = Config.geminiLiveWebSocketURL else {
            connectionState = .error("No Gemini API key configured")
            return false
        }

        intentionalDisconnect = false
        connectionState = .connecting

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            self.delegate.onOpen = { [weak self] protocol_ in
                guard let self else { return }
                Task { @MainActor in
                    self.connectionState = .settingUp
                    self.sendSetupMessage()
                    self.startReceiving()
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.connectionState = .disconnected
                    self.isModelSpeaking = false
                    let msg = "Connection closed (code \(code.rawValue): \(reasonStr))"
                    self.onDisconnected?(msg)
                    self.scheduleReconnect(reason: msg)
                }
            }

            self.delegate.onError = { [weak self] error in
                guard let self else { return }
                let msg = error?.localizedDescription ?? "Unknown error"
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.connectionState = .error(msg)
                    self.isModelSpeaking = false
                    self.onDisconnected?(msg)
                    self.scheduleReconnect(reason: msg)
                }
            }

            self.webSocketTask = self.urlSession.webSocketTask(with: url)
            self.webSocketTask?.resume()

            // Timeout after 15 seconds
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    self.resolveConnect(success: false)
                    if self.connectionState == .connecting || self.connectionState == .settingUp {
                        self.connectionState = .error("Connection timed out")
                    }
                }
            }
        }

        return result
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        delegate.onOpen = nil
        delegate.onClose = nil
        delegate.onError = nil
        onToolCall = nil
        onToolCallCancellation = nil
        onReconnected = nil
        connectionState = .disconnected
        isModelSpeaking = false
        videoFramesSent = 0
        resolveConnect(success: false)
    }

    // MARK: - Reconnection

    private func scheduleReconnect(reason: String?) {
        guard !intentionalDisconnect else {
            NSLog("[Gemini] Intentional disconnect — not reconnecting")
            return
        }
        guard reconnectAttempts < maxReconnectAttempts else {
            NSLog("[Gemini] Max reconnect attempts (%d) reached — giving up", maxReconnectAttempts)
            connectionState = .error("Connection lost after \(maxReconnectAttempts) reconnect attempts")
            reconnecting = false
            return
        }

        reconnecting = true
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), maxBackoffSeconds)
        NSLog("[Gemini] Reconnect attempt %d/%d in %.0fs (reason: %@)",
              reconnectAttempts, maxReconnectAttempts, delay, reason ?? "unknown")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }

            // Clean up old socket
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil

            let success = await self.connect()
            if success {
                self.reconnectAttempts = 0
                self.reconnecting = false
                NSLog("[Gemini] Reconnected successfully")
                self.onReconnected?()
            }
            // If connect fails, the onClose/onError handlers will trigger another scheduleReconnect
        }
    }

    // MARK: - Send Audio / Video / Tool Response

    func sendAudio(data: Data) {
        guard connectionState == .ready, let task = webSocketTask else { return }
        // Dispatch to send queue to keep base64 encoding off the main thread
        sendQueue.async {
            let base64 = data.base64EncodedString()
            let json: [String: Any] = [
                "realtimeInput": [
                    "audio": [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64
                    ]
                ]
            ]
            Self.sendJSONDirect(json, via: task)
        }
    }

    func sendVideoFrame(image: UIImage) {
        guard connectionState == .ready, let task = webSocketTask else {
            NSLog("[Gemini] sendVideoFrame skipped — state: %@",
                  String(describing: connectionState))
            return
        }
        videoFramesSent += 1
        let count = videoFramesSent
        // Dispatch JPEG compression, base64 encoding, and send to background queue
        sendQueue.async {
            guard let jpegData = image.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality) else {
                NSLog("[Gemini] sendVideoFrame skipped — JPEG conversion failed")
                return
            }
            let base64 = jpegData.base64EncodedString()
            let json: [String: Any] = [
                "realtimeInput": [
                    "video": [
                        "mimeType": "image/jpeg",
                        "data": base64
                    ]
                ]
            ]
            NSLog("[Gemini] Sending video frame #%d (%d KB JPEG)", count, jpegData.count / 1024)
            Self.sendJSONDirect(json, via: task)
        }
    }

    func sendToolResponse(_ response: [String: Any]) {
        guard let task = webSocketTask else { return }
        sendQueue.async {
            Self.sendJSONDirect(response, via: task)
        }
    }

    // MARK: - Private

    private func resolveConnect(success: Bool) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: success)
        }
    }

    private func sendSetupMessage() {
        var toolsArray: [[String: Any]] = []
        if !toolDeclarations.isEmpty {
            toolsArray = [["functionDeclarations": toolDeclarations]]
        }

        let setup: [String: Any] = [
            "setup": [
                "model": Config.geminiLiveModel,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "thinkingConfig": [
                        "thinkingBudget": 0
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": systemInstruction]
                    ]
                ],
                "tools": toolsArray,
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "silenceDurationMs": 500,
                        "prefixPaddingMs": 40
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT",
                    "contextWindowCompression": [
                        "slidingWindow": [
                            "targetTokens": 80000
                        ]
                    ]
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any]
            ]
        ]
        sendJSON(setup)
    }

    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask?.send(.string(string)) { _ in }
    }

    /// Send JSON via a captured URLSessionWebSocketTask reference.
    /// Called from `sendQueue`. URLSessionWebSocketTask.send is thread-safe,
    /// so we send directly without hopping to MainActor (matches VisionClaw's pattern).
    /// The task reference is captured on MainActor before dispatching to sendQueue.
    private static nonisolated func sendJSONDirect(_ json: [String: Any], via task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(string)) { error in
            if let error {
                NSLog("[Gemini] WebSocket send error: %@", error.localizedDescription)
            }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        let reason = error.localizedDescription
                        await MainActor.run {
                            self.resolveConnect(success: false)
                            self.connectionState = .disconnected
                            self.isModelSpeaking = false
                            self.onDisconnected?(reason)
                            self.scheduleReconnect(reason: reason)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Setup complete
        if json["setupComplete"] != nil {
            connectionState = .ready
            resolveConnect(success: true)
            return
        }

        // GoAway — server will close soon
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            let seconds = timeLeft?["seconds"] as? Int ?? 0
            connectionState = .disconnected
            isModelSpeaking = false
            onDisconnected?("Server closing (time left: \(seconds)s)")
            return
        }

        // Tool call from model
        if let toolCall = GeminiToolCall(json: json) {
            NSLog("[Gemini] Tool call received: %d function(s)", toolCall.functionCalls.count)
            onToolCall?(toolCall)
            return
        }

        // Tool call cancellation
        if let cancellation = GeminiToolCallCancellation(json: json) {
            NSLog("[Gemini] Tool call cancellation: %@", cancellation.ids.joined(separator: ", "))
            onToolCallCancellation?(cancellation)
            return
        }

        // Server content (audio, transcriptions, interruptions, turn complete)
        if let serverContent = json["serverContent"] as? [String: Any] {
            // Interruption — user started speaking while model was responding
            if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                isModelSpeaking = false
                onInterrupted?()
                return
            }

            // Model audio/text output
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let mimeType = inlineData["mimeType"] as? String,
                       mimeType.hasPrefix("audio/pcm"),
                       let base64Data = inlineData["data"] as? String,
                       let audioData = Data(base64Encoded: base64Data) {
                        if !isModelSpeaking {
                            isModelSpeaking = true
                            // Log response latency
                            if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                                let latency = Date().timeIntervalSince(speechEnd)
                                NSLog("[Latency] %.0fms (user speech end -> first audio)", latency * 1000)
                                responseLatencyLogged = true
                            }
                        }
                        onAudioReceived?(audioData)
                    } else if let text = part["text"] as? String {
                        NSLog("[Gemini] %@", text)
                    }
                }
            }

            // Turn complete — model finished responding
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                isModelSpeaking = false
                responseLatencyLogged = false
                onTurnComplete?()
            }

            // Input transcription (what the user said)
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                NSLog("[Gemini] You: %@", text)
                lastUserSpeechEnd = Date()
                responseLatencyLogged = false
                onInputTranscription?(text)
            }

            // Output transcription (what the AI said)
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String, !text.isEmpty {
                NSLog("[Gemini] AI: %@", text)
                onOutputTranscription?(text)
            }
        }
    }
}

// MARK: - WebSocket Delegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(`protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onError?(error)
        }
    }
}
