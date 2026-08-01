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

    /// Converts Gemini Live's cumulative `usageMetadata` totals into per-message deltas
    /// for the cost tracker (Plan AU).
    private var usageMeter = CumulativeUsageMeter()

    // Callbacks
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    /// Model text parts (BY P2). Only meaningful for TEXT-modality sessions — the voice session
    /// gets its words back via `onOutputTranscription`.
    var onTextOutput: ((String) -> Void)?
    var onToolCall: ((GeminiToolCall) -> Void)?
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?
    var onReconnected: (() -> Void)?

    // Reconnection
    private var intentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let maxBackoffSeconds: Double = 30
    private var reconnectTask: Task<Void, Never>?
    /// True from the moment a reconnect is scheduled until its task starts running — coalesces the
    /// duplicate `scheduleReconnect` calls that a single failure triggers from close + error +
    /// receive-loop, so `reconnectAttempts` advances once per cycle (Plan BD).
    private var reconnectPending = false
    /// The 15s connect-timeout task; cancelled on resolve so a stale timer can't fail a later
    /// attempt (Plan BD).
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectPolicy: RealtimeReconnect.Policy {
        .init(maxAttempts: maxReconnectAttempts, maxBackoffSeconds: maxBackoffSeconds)
    }
    /// Called when reconnection is exhausted or the session dies terminally — the session manager
    /// plays an audible cue (Plan BD: voice-first apps must not fail silently).
    var onReconnectExhausted: (() -> Void)?

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
    /// BR P3: stale-callback guard — a superseded connection's late callbacks must no-op.
    private var generationGate = ConnectionGenerationGate()
    private var urlSession: URLSession!

    // Dedicated send queue — keeps JSON serialization, JPEG compression, and base64
    // encoding off the main thread (matches VisionClaw's approach)
    private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)

    // Dynamic configuration for mode/tool setup
    private var systemInstruction: String = ""
    private var toolDeclarations: [[String: Any]] = []
    /// `["AUDIO"]` for the voice session; `["TEXT"]` for the translation-caption session (BY P2).
    private var responseModalities: [String] = ["AUDIO"]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Configure the session parameters before connecting.
    /// Call this before `connect()` to set mode-specific instructions and tools.
    func configure(systemInstruction: String, toolDeclarations: [[String: Any]],
                   responseModalities: [String] = ["AUDIO"]) {
        self.systemInstruction = systemInstruction
        self.toolDeclarations = toolDeclarations
        self.responseModalities = responseModalities
    }

    // MARK: - Connect / Disconnect

    func connect() async -> Bool {
        guard let url = Config.geminiLiveWebSocketURL else {
            connectionState = .error("No Gemini API key configured")
            return false
        }

        intentionalDisconnect = false
        let gen = generationGate.advance()
        connectionState = .connecting

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            self.delegate.onOpen = { [weak self] protocol_ in
                guard let self else { return }
                Task { @MainActor in
                    guard self.generationGate.isCurrent(gen) else { return }
                    self.connectionState = .settingUp
                    self.sendSetupMessage()
                    self.startReceiving(generation: gen)
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                Task { @MainActor in
                    guard self.generationGate.isCurrent(gen) else {
                        NSLog("[WS] Ignoring stale close (superseded connection)")
                        return
                    }
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
                    guard self.generationGate.isCurrent(gen) else {
                        NSLog("[WS] Ignoring stale error (superseded connection)")
                        return
                    }
                    self.resolveConnect(success: false)
                    self.connectionState = .error(msg)
                    self.isModelSpeaking = false
                    self.onDisconnected?(msg)
                    self.scheduleReconnect(reason: msg)
                }
            }

            self.webSocketTask = self.urlSession.webSocketTask(with: url)
            self.webSocketTask?.resume()

            // Timeout after 15 seconds. Stored + cancelled on resolve so a stale timer from a
            // prior attempt can't resolve a later attempt's continuation (Plan BD).
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.generationGate.isCurrent(gen) else { return }
                    if self.connectionState == .connecting || self.connectionState == .settingUp {
                        self.connectionState = .error("Connection timed out")
                    }
                    self.resolveConnect(success: false)
                }
            }
        }

        return result
    }

    func disconnect() {
        intentionalDisconnect = true
        _ = generationGate.advance()   // BR P3: outstanding callbacks are stale from here
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        reconnectPending = false
        reconnectAttempts = 0   // a fresh session must not inherit an exhausted counter (Plan BD)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
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
        onTextOutput = nil
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
        // Coalesce the duplicate triggers a single failure fires (close + error + receive-loop):
        // only the first schedules; the rest are no-ops until the pending attempt runs (Plan BD).
        guard !reconnectPending else { return }

        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempts + 1) else {
            NSLog("[Gemini] Max reconnect attempts (%d) reached — giving up", maxReconnectAttempts)
            connectionState = .error("Connection lost after \(maxReconnectAttempts) reconnect attempts")
            reconnecting = false
            onReconnectExhausted?()
            return
        }

        reconnecting = true
        reconnectPending = true
        reconnectAttempts += 1
        NSLog("[Gemini] Reconnect attempt %d/%d in %.0fs (reason: %@)",
              reconnectAttempts, maxReconnectAttempts, delay, reason ?? "unknown")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectPending = false

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
            } else {
                // connect() may have failed via a timeout that fires NO close/error event — the old
                // code stalled here forever. Drive the next attempt ourselves; if a close/error did
                // fire, it already set reconnectPending, so this coalesces to a single reschedule.
                self.scheduleReconnect(reason: "retry failed")
            }
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
        nonisolated(unsafe) let responseCopy = response
        sendQueue.async {
            Self.sendJSONDirect(responseCopy, via: task)
        }
    }

    // MARK: - Mid-session injection (Plan CB)

    /// Put text in front of the model as a user turn. `completeTurn: true` makes the model respond
    /// now; `false` only appends to context and generates NOTHING — a silent failure that presents
    /// as a delivery bug, so pass `false` only for background notes (see `LiveInjectionEnvelope`).
    func sendText(_ text: String, completeTurn: Bool) {
        guard connectionState == .ready, let task = webSocketTask else {
            NSLog("[Gemini] sendText skipped — state: %@", String(describing: connectionState))
            return
        }
        let json = LiveInjectionEnvelope.geminiText(text, completeTurn: completeTurn)
        sendQueue.async { Self.sendJSONDirect(json, via: task) }
    }

    /// Push a full-quality still into the model's view, bypassing the throttled stream path and its
    /// resize/quality-0.5 encode. Pre-encoded JPEG so the sharp bytes go out exactly as captured.
    func sendHighResImage(jpegData: Data) {
        guard connectionState == .ready, let task = webSocketTask else {
            NSLog("[Gemini] sendHighResImage skipped — state: %@", String(describing: connectionState))
            return
        }
        sendQueue.async {
            let json = LiveInjectionEnvelope.geminiImage(base64JPEG: jpegData.base64EncodedString())
            NSLog("[Gemini] Injecting sharp frame (%d KB JPEG)", jpegData.count / 1024)
            Self.sendJSONDirect(json, via: task)
        }
    }

    // MARK: - Private

    private func resolveConnect(success: Bool) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: success)
        }
    }

    private func sendSetupMessage() {
        var toolsArray: [[String: Any]] = []
        if !toolDeclarations.isEmpty {
            // Flag-gated: NON_BLOCKING lets the model keep the conversation going while a
            // tool runs; the router then acks slow calls and defers results WHEN_IDLE
            // (`ToolCallRouter.toolResponse(phase:)`). Off by default — shape change.
            let declarations = Config.geminiNonBlockingToolsEnabled
                ? toolDeclarations.map { decl -> [String: Any] in
                    var d = decl
                    d["behavior"] = "NON_BLOCKING"
                    return d
                }
                : toolDeclarations
            toolsArray = [["functionDeclarations": declarations]]
        }

        var setupBody: [String: Any] = [
            "model": Config.geminiLiveModel,
            "generationConfig": [
                "responseModalities": responseModalities,
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
            "inputAudioTranscription": [:] as [String: Any]
        ]
        // Only a voice session has model audio to transcribe.
        if responseModalities.contains("AUDIO") {
            setupBody["outputAudioTranscription"] = [:] as [String: Any]
        }
        sendJSON(["setup": setupBody])
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

    private func startReceiving(generation: UInt64) {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    let text: String?
                    switch message {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    guard let text else { continue }
                    // Parse JSON + decode audio base64 OFF the main actor (`parse` is nonisolated
                    // async), then apply state/callbacks on main — the old code did both on main for
                    // every message, at 10-25 msgs/sec while the model speaks.
                    if let parsed = await Self.parse(text) {
                        self.handleMessage(parsed)
                    }
                } catch {
                    if !Task.isCancelled {
                        let reason = error.localizedDescription
                        await MainActor.run {
                            guard self.generationGate.isCurrent(generation) else { return }
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

    /// A message parsed off the main actor: the decoded JSON plus any audio chunks already
    /// base64-decoded off-main. `@unchecked Sendable` is safe here because it's a single-owner
    /// handoff — built on a background executor, consumed once on the main actor, never mutated
    /// or shared concurrently.
    private struct ParsedGeminiMessage: @unchecked Sendable {
        let json: [String: Any]
        let audioChunks: [Data]
    }

    /// Parse the raw text and pre-decode audio, entirely off the main actor.
    private nonisolated static func parse(_ text: String) async -> ParsedGeminiMessage? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var chunks: [Data] = []
        if let serverContent = json["serverContent"] as? [String: Any],
           let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.hasPrefix("audio/pcm"),
                   let base64Data = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64Data) {
                    chunks.append(audioData)
                }
            }
        }
        return ParsedGeminiMessage(json: json, audioChunks: chunks)
    }

    private func handleMessage(_ parsed: ParsedGeminiMessage) {
        let json = parsed.json

        // Token usage (cumulative) → record the delta for the cost tracker (Plan AU).
        if let cumulative = RealtimeUsage.geminiCumulative(json) {
            let d = usageMeter.delta(tokensIn: cumulative.tokensIn, tokensOut: cumulative.tokensOut)
            UsageTracker.shared.record(provider: .gemini, model: Config.geminiLiveModel,
                                       tokensIn: d.tokensIn, tokensOut: d.tokensOut)
        }

        // Setup complete
        if json["setupComplete"] != nil {
            connectionState = .ready
            resolveConnect(success: true)
            return
        }

        // GoAway — the server sends this before its session time limit, i.e. on EVERY long session.
        // The old code fired the fatal onDisconnected path (reconnecting == false), so the session
        // manager tore the session down right before the close it should have ridden through. Now we
        // proactively schedule a reconnect so a long conversation survives the server's rotation.
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            let seconds = timeLeft?["seconds"] as? Int ?? 0
            isModelSpeaking = false
            NSLog("[Gemini] goAway received (time left: %ds) — scheduling reconnect", seconds)
            scheduleReconnect(reason: "server rotating connection")   // sets reconnecting = true first
            onDisconnected?("Server rotating connection (time left: \(seconds)s)")
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

            // Model audio output — chunks were base64-decoded off the main actor in `parse`.
            for audioData in parsed.audioChunks {
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
            }

            // Model text output (TEXT-modality sessions consume this; voice sessions just log)
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts where part["inlineData"] == nil {
                    if let text = part["text"] as? String {
                        NSLog("[Gemini] %@", text)
                        onTextOutput?(text)
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
