import Foundation
import UIKit

/// Connection state for the OpenAI Realtime WebSocket.
enum OpenAIRealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case settingUp
    case ready
    case error(String)
}

extension OpenAIRealtimeConnectionState {
    /// The state's name for a log line. `.error` collapses to the bare case: its payload is a
    /// server-supplied message, which is user-content class.
    var privacyToken: PrivacyToken {
        switch self {
        case .disconnected: return PrivacyToken("disconnected")
        case .connecting: return PrivacyToken("connecting")
        case .settingUp: return PrivacyToken("settingUp")
        case .ready: return PrivacyToken("ready")
        case .error: return PrivacyToken("error")
        }
    }
}

/// WebSocket-based OpenAI Realtime API service.
/// Sends/receives audio (PCM16 24kHz), sends images, handles tool calls,
/// and supports automatic reconnection with exponential backoff.
@MainActor
class OpenAIRealtimeService: ObservableObject {
    @Published var connectionState: OpenAIRealtimeConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false
    @Published var reconnecting: Bool = false
    /// Server VAD's view of the wearer: true between `speech_started` and `speech_stopped`.
    /// Read by the injection admission gate — a turn injected mid-utterance is a turn the server
    /// is about to interrupt.
    @Published private(set) var isUserSpeaking: Bool = false

    // Callbacks
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onReconnected: (() -> Void)?

    // Reconnection
    private var intentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let maxBackoffSeconds: Double = 30
    private var reconnectTask: Task<Void, Never>?
    /// Coalesces duplicate `scheduleReconnect` triggers for one failure (Plan BD).
    private var reconnectPending = false
    /// Connect-timeout task, cancelled on resolve so a stale timer can't fail a later attempt.
    private var connectTimeoutTask: Task<Void, Never>?
    private var reconnectPolicy: RealtimeReconnect.Policy {
        .init(maxAttempts: maxReconnectAttempts, maxBackoffSeconds: maxBackoffSeconds)
    }
    /// Terminal-death cue hook (Plan BD) — the session manager plays an audible cue.
    var onReconnectExhausted: (() -> Void)?

    // Latency tracking
    private var lastUserSpeechEnd: Date?
    private var responseLatencyLogged = false

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private let delegate = OpenAIWebSocketDelegate()
    /// BR P3: stale-callback guard — a superseded connection's late callbacks must no-op.
    private var generationGate = ConnectionGenerationGate()
    private var urlSession: URLSession!

    // Send queue — keeps base64 encoding off the main thread
    private let sendQueue = DispatchQueue(label: "openai.realtime.send", qos: .userInitiated)

    // Session configuration
    private var systemInstruction: String = ""
    private var apiKey: String = ""
    private var model: String = ""

    // Track current response for interruption
    private var currentResponseId: String?
    /// The conversation item currently streaming audio (from `response.audio.delta`), so a
    /// barge-in can truncate exactly that item (CJ item 6).
    private var currentAudioItemId: String?
    private var currentAudioContentIndex = 0
    /// Confirmed-played milliseconds of the current response's audio — wired by the session
    /// manager to `RealtimeAudioEngine.confirmedPlayedMilliseconds`. Never wall-clock.
    var playedAudioMilliseconds: (() -> Int)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Configure session parameters before connecting.
    func configure(apiKey: String, model: String, systemInstruction: String) {
        self.apiKey = apiKey
        self.model = model
        self.systemInstruction = systemInstruction
    }

    // MARK: - Connect / Disconnect

    func connect() async -> Bool {
        guard !apiKey.isEmpty else {
            connectionState = .error("No OpenAI API key configured")
            return false
        }

        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"
        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid model name")
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
                    self.startReceiving(generation: gen)
                    // OpenAI sends session.created automatically, then we send session.update
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                Task { @MainActor in
                    guard self.generationGate.isCurrent(gen) else {
                        PrivacyLog.realtimeSession(.openai, .unhandledEvent,
                                                   detail: PrivacyToken("staleClose"))
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
                        PrivacyLog.realtimeSession(.openai, .unhandledEvent,
                                                   detail: PrivacyToken("staleError"))
                        return
                    }
                    self.resolveConnect(success: false)
                    self.connectionState = .error(msg)
                    self.isModelSpeaking = false
                    self.onDisconnected?(msg)
                    self.scheduleReconnect(reason: msg)
                }
            }

            // Create request with auth headers
            var request = URLRequest(url: url)
            request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

            self.webSocketTask = self.urlSession.webSocketTask(with: request)
            self.webSocketTask?.resume()

            // Timeout after 15 seconds. Stored + cancelled on resolve (Plan BD).
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
        onReconnected = nil
        connectionState = .disconnected
        isModelSpeaking = false
        // A `speech_started` with no matching `speech_stopped` would otherwise leave the next
        // session believing the wearer never stopped talking, and hold every injection to its
        // full bounded wait.
        isUserSpeaking = false
        currentResponseId = nil
        resolveConnect(success: false)
    }

    // MARK: - Send Audio

    func sendAudio(data: Data) {
        guard connectionState == .ready, let task = webSocketTask else { return }
        sendQueue.async {
            let base64 = data.base64EncodedString()
            let json: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": base64
            ]
            Self.sendJSONDirect(json, via: task)
        }
    }

    // MARK: - Send Image (Vision)

    func sendImage(image: UIImage, prompt: String? = nil) {
        guard connectionState == .ready, let task = webSocketTask else { return }
        sendQueue.async {
            guard let jpegData = image.jpegData(compressionQuality: 0.5) else { return }
            let base64 = jpegData.base64EncodedString()

            var content: [[String: Any]] = [
                [
                    "type": "input_image",
                    "image": base64
                ]
            ]
            if let prompt {
                content.insert(["type": "input_text", "text": prompt], at: 0)
            }

            let json: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": content
                ]
            ]
            Self.sendJSONDirect(json, via: task)
            PrivacyLog.realtimeMedia(.openai, kind: .streamedFrame, kilobytes: jpegData.count / 1024)
        }
    }

    // MARK: - Mid-session injection (Plan CB)

    /// Put text in front of the model as a user turn. `completeTurn: true` follows with
    /// `response.create` so the model actually answers — `conversation.item.create` alone only
    /// appends, the Realtime spelling of the Gemini `turnComplete` trap. The streamed-frame path
    /// above stays append-only deliberately: forcing a response per frame would be wrong.
    func sendText(_ text: String, completeTurn: Bool) {
        guard connectionState == .ready, let task = webSocketTask else {
            PrivacyLog.realtimeSendSkipped(.openai, kind: .text, reason: .notReady,
                                           state: connectionState.privacyToken)
            return
        }
        sendQueue.async {
            Self.sendJSONDirect(LiveInjectionEnvelope.realtimeText(text), via: task)
            if completeTurn {
                Self.sendJSONDirect(LiveInjectionEnvelope.realtimeResponseCreate(), via: task)
            }
        }
    }

    /// Push a pre-encoded full-quality still into the conversation, bypassing the streamed-frame
    /// path's quality-0.5 re-encode. No `response.create`: for `look_closely` the pending tool
    /// response drives generation, and elsewhere the caller pairs it with a completing text.
    func sendHighResImage(jpegData: Data, prompt: String? = nil) {
        guard connectionState == .ready, let task = webSocketTask else {
            PrivacyLog.realtimeSendSkipped(.openai, kind: .image, reason: .notReady,
                                           state: connectionState.privacyToken)
            return
        }
        sendQueue.async {
            let json = LiveInjectionEnvelope.realtimeImage(
                base64JPEG: jpegData.base64EncodedString(), prompt: prompt)
            PrivacyLog.realtimeMedia(.openai, kind: .sharpFrame, kilobytes: jpegData.count / 1024)
            Self.sendJSONDirect(json, via: task)
        }
    }

    // MARK: - Interruption

    /// Cancel the current model response (client-side interrupt).
    ///
    /// Sends `response.cancel`, then `conversation.item.truncate` with the confirmed-played
    /// `audio_end_ms` (CJ item 6): without the truncate, the server-side conversation item keeps
    /// the full unheard audio, so later turns reference speech the user never heard. The played
    /// count is read *before* `onInterrupted` stops playback (stopping discards the queue and
    /// resets the accounting).
    func cancelResponse() {
        guard let task = webSocketTask else { return }
        isModelSpeaking = false
        let playedMs = playedAudioMilliseconds?() ?? 0
        let itemId = currentAudioItemId
        let contentIndex = currentAudioContentIndex
        currentAudioItemId = nil
        onInterrupted?()
        sendQueue.async {
            Self.sendJSONDirect(["type": "response.cancel"], via: task)
            if let itemId, playedMs > 0 {
                Self.sendJSONDirect([
                    "type": "conversation.item.truncate",
                    "item_id": itemId,
                    "content_index": contentIndex,
                    "audio_end_ms": playedMs,
                ], via: task)
                PrivacyLog.realtimeTruncated(.openai, item: itemId, playedMs: playedMs)
            }
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect(reason: String?) {
        guard !intentionalDisconnect else { return }
        // Coalesce the duplicate triggers a single failure fires (Plan BD).
        guard !reconnectPending else { return }

        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempts + 1) else {
            connectionState = .error("Connection lost after \(maxReconnectAttempts) reconnect attempts")
            reconnecting = false
            onReconnectExhausted?()
            return
        }

        reconnecting = true
        reconnectPending = true
        reconnectAttempts += 1
        PrivacyLog.realtimeReconnectScheduled(.openai, attempt: reconnectAttempts,
                                              of: maxReconnectAttempts, delaySeconds: delay)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectPending = false

            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil

            let success = await self.connect()
            if success {
                self.reconnectAttempts = 0
                self.reconnecting = false
                self.onReconnected?()
            } else {
                // Drive the next attempt ourselves so a connect-timeout with no close/error event
                // can't stall the machine forever (Plan BD); coalesced if close/error already fired.
                self.scheduleReconnect(reason: "retry failed")
            }
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

    private func sendSessionUpdate() {
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": systemInstruction,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "gpt-4o-mini-transcribe"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                    // Both stated rather than left to the API's defaults. `create_response`
                    // is what makes end-of-speech produce an answer at all; `interrupt_response`
                    // keeps barge-in server-side, where it can cancel a response the client
                    // never learns about. Defaults for these have moved between API versions,
                    // and a session that silently stops answering is indistinguishable from a
                    // dead microphone.
                    "create_response": true,
                    "interrupt_response": true
                ]
            ]
        ]
        sendJSON(sessionConfig)
        PrivacyLog.realtimeSession(.openai, .sessionUpdateSent)
    }

    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask?.send(.string(string)) { _ in }
    }

    private static nonisolated func sendJSONDirect(_ json: [String: Any], via task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(string)) { error in
            if let error {
                PrivacyLog.realtimeError(.openai, phase: .send, SafeErrorSummary(error))
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
                    // Parse JSON + decode the audio delta OFF the main actor, then apply on main —
                    // response.audio.delta arrives many times/sec while the model speaks.
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

    /// A message parsed off the main actor: decoded JSON plus the pre-decoded audio delta.
    /// `@unchecked Sendable` is safe — single-owner handoff, built off-main and consumed once on main.
    private struct ParsedOpenAIMessage: @unchecked Sendable {
        let json: [String: Any]
        let type: String
        let audioDelta: Data?
    }

    private nonisolated static func parse(_ text: String) async -> ParsedOpenAIMessage? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        var audioDelta: Data?
        if type == "response.audio.delta", let delta = json["delta"] as? String {
            audioDelta = Data(base64Encoded: delta)
        }
        return ParsedOpenAIMessage(json: json, type: type, audioDelta: audioDelta)
    }

    private func handleMessage(_ parsed: ParsedOpenAIMessage) {
        let json = parsed.json
        let type = parsed.type

        switch type {
        case "session.created":
            PrivacyLog.realtimeSession(.openai, .sessionCreated)
            // Now send our session configuration
            sendSessionUpdate()

        case "session.updated":
            PrivacyLog.realtimeSession(.openai, .sessionConfigured)
            connectionState = .ready
            resolveConnect(success: true)

        case "response.audio.delta":
            // Model audio chunk — base64-decoded off the main actor in `parse`.
            if let audioData = parsed.audioDelta {
                if !isModelSpeaking {
                    isModelSpeaking = true
                    if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                        let latency = Date().timeIntervalSince(speechEnd)
                        PrivacyLog.realtimeLatency(.openai, milliseconds: Int(latency * 1000))
                        responseLatencyLogged = true
                    }
                }
                if let responseId = json["response_id"] as? String {
                    currentResponseId = responseId
                }
                if let itemId = json["item_id"] as? String {
                    currentAudioItemId = itemId
                    currentAudioContentIndex = json["content_index"] as? Int ?? 0
                }
                onAudioReceived?(audioData)
            }

        case "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                onOutputTranscription?(delta)
            }

        case "response.done":
            isModelSpeaking = false
            currentResponseId = nil
            currentAudioItemId = nil
            responseLatencyLogged = false
            // Record this response's token usage for the cost tracker (Plan AU).
            if let usage = RealtimeUsage.openAIResponseUsage(json) {
                let model = self.model
                Task { @MainActor in
                    UsageTracker.shared.record(provider: .openai, model: model,
                                               tokensIn: usage.tokensIn, tokensOut: usage.tokensOut)
                }
            }
            onTurnComplete?()

        case "input_audio_buffer.speech_started":
            // User started speaking — interrupt model if it's responding
            isUserSpeaking = true
            if isModelSpeaking {
                PrivacyLog.realtimeSession(.openai, .userInterrupted)
                cancelResponse()
            }
            lastUserSpeechEnd = nil

        case "input_audio_buffer.speech_stopped":
            isUserSpeaking = false
            lastUserSpeechEnd = Date()

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                // The transcript is the wearer's own speech: length only.
                PrivacyLog.realtimeUtterance(.openai, direction: .input, characters: transcript.count)
                onInputTranscription?(transcript)
            }

        case "error":
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String
                let code = error["code"] as? String
                // A recoverable error (most often a response.cancel that raced the end of a
                // response — "no active response") must NOT flip the session into a terminal
                // .error state, or the assistant goes silently deaf while the mic stays open
                // (Plan BD). Only tear down + reconnect on a genuinely fatal error.
                if RealtimeReconnect.isFatalOpenAIError(code: code, message: message) {
                    // The server's `message` is free-form prose about our request; only the
                    // machine-readable code is summarised.
                    PrivacyLog.realtimeError(.openai, phase: .fatal, .remote(code: code))
                    connectionState = .error(message ?? "Realtime error")
                    isModelSpeaking = false
                    onDisconnected?(message)
                    scheduleReconnect(reason: message)
                } else {
                    PrivacyLog.realtimeError(.openai, phase: .recoverable, .remote(code: code))
                }
            }

        case "rate_limits.updated":
            break // Ignore rate limit info

        case "response.created", "response.output_item.added",
             "response.content_part.added", "response.content_part.done",
             "response.output_item.done", "response.audio.done",
             "response.audio_transcript.done", "conversation.item.created",
             "input_audio_buffer.committed", "input_audio_buffer.cleared":
            break // Expected events, no action needed

        default:
            PrivacyLog.realtimeSession(.openai, .unhandledEvent, detail: PrivacyToken(type))
        }
    }
}

// MARK: - WebSocket Delegate

private class OpenAIWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
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
