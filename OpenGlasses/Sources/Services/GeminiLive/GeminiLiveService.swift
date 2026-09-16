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

extension GeminiConnectionState {
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

    /// Latest resumable session handle from `sessionResumptionUpdate` (Plan CJ item 7); goes
    /// into the next setup message so a reconnect resumes rather than cold-starts. Cleared on
    /// intentional disconnect — a deliberately fresh session must not inherit stale context.
    private var resumptionHandle: String?

    /// Whether a reconnect would resume the current context rather than cold-start.
    /// Read by the conversation-reset adapter: a "new topic" that left a handle behind would
    /// silently restore the conversation the wearer just asked to leave.
    var hasResumptionHandle: Bool { resumptionHandle != nil }

    /// Test-only: stand in for a handle the server would have sent, so a teardown's promise to
    /// drop it can be asserted without a socket. No production caller.
    func setResumptionHandleForTesting(_ handle: String?) { resumptionHandle = handle }

    /// Test-only: the handle currently held, so "the server refused it and we dropped it" is
    /// asserted rather than inferred from a later attempt's behaviour.
    var resumptionHandleForTesting: String? { resumptionHandle }

    // MARK: - Recovery facts (Plan FF P1/PR5)

    /// Whether the setup that most recently went out carried a resumption handle.
    ///
    /// Set when setup is actually sent, which is what makes the distinction below possible: an
    /// attempt that never opened a socket never sent setup, so a network failure on the way up
    /// leaves the handle alone.
    private(set) var setupCarriedResumptionHandle = false

    /// Whether the connection that is currently up resumed the previous conversation.
    ///
    /// This is the transport's half of `LiveRecoveryAssessment.ContextContinuity`: true means the
    /// server took the handle and handed the conversation back, so nothing has to be rebuilt.
    private(set) var lastConnectResumedContext = false

    /// Whether the last attempt went out with a handle and did not come up — the server refusing or
    /// having expired it.
    ///
    /// The wire does not distinguish "your handle is stale" from "the socket died after setup", so
    /// this does not claim to either. What it does is act on the only safe reading of both: the
    /// handle is dropped rather than retried. A handle the server will not take, retried, walks the
    /// entire ten-attempt ladder to exhaustion and ends a session that a cold start would have
    /// recovered in one attempt.
    private(set) var lastResumptionHandleRejected = false

    /// The system instruction the most recent setup carried.
    ///
    /// Recorded rather than reconstructed, so a rebuilt-context handover can be asserted to have
    /// actually reached the wire. Instruction text only — never audio, never a frame.
    private(set) var lastSetupInstruction: String?

    // Reconnection
    private var intentionalDisconnect = false
    private(set) var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    /// Whether a reconnect is scheduled or running. Distinct from `reconnectTask != nil`, which
    /// stays non-nil after an attempt has finished — "armed" is the question a teardown assertion
    /// actually wants answered (Plan EW's `scheduledWorkCount` shape, Plan FF P1/PR5).
    private var reconnectWorkArmed = false
    /// Test-only: multiplier on every backoff delay, so a ten-attempt ladder can be driven to
    /// exhaustion headlessly instead of over two minutes of real sleeping. 1 in production, and no
    /// production caller sets it.
    var reconnectDelayScaleForTesting: Double = 1
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

    /// How much work this service still has armed: a reconnect scheduled or running, a connect
    /// timeout ticking, and a receive loop attached.
    ///
    /// Exposed so "the wearer stopped it and nothing is left scheduled" is an assertion rather than
    /// a reading of the teardown code — the same reason `GlassesCameraBackend` exposes one.
    var scheduledWorkCount: Int {
        (reconnectWorkArmed ? 1 : 0)
            + (connectTimeoutTask == nil ? 0 : 1)
            + (receiveTask == nil ? 0 : 1)
    }

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

    /// The most recent close message, retained so a refusal can be explained rather than reported
    /// as a generic failure. Cleared at the start of each connect so a stale reason cannot describe
    /// a later attempt.
    private(set) var lastCloseReason: String?

    /// Model this session will use, decided before the socket opens. Defaults to the offline
    /// fallback so a session that somehow skips `prepareLiveModel` still names something real.
    private(set) var resolvedLiveModel = GeminiLiveModelPolicy.Resolution(
        model: GeminiLiveModelPolicy.offlineFallbackModel,
        substitutedFor: nil,
        usedOfflineFallback: true)

    /// Ask the account which models can open a Live session, and pick one.
    ///
    /// Runs before connecting rather than at setup time because it may make a network call, and a
    /// setup message must go out promptly once the socket is open. Failure is not fatal: an empty
    /// list resolves to the offline fallback and the attempt proceeds.
    private func prepareLiveModel() async {
        let key = Config.geminiLiveAPIKey
        let available = await GeminiLiveModelCatalog.shared.liveModels(apiKey: key)
        resolvedLiveModel = GeminiLiveModelPolicy.resolve(
            configured: Config.geminiLiveConfiguredModel, available: available)
    }

    func connect() async -> Bool {
        guard MedicalEgressGuard.allows(.geminiLiveSession) else {
            connectionState = .error(MedicalEgressRefusal.userMessage)
            return false
        }
        // Plan FF P1/PR5: a scripted attempt stands in for the socket only; everything the outcome
        // then drives — the ladder, the handle bookkeeping, the callbacks — is the production path.
        if scriptedTransportEnabled { return await runScriptedConnect() }
        await prepareLiveModel()
        lastCloseReason = nil
        guard let url = Config.geminiLiveWebSocketURL else {
            connectionState = .error("No Gemini API key configured")
            return false
        }

        intentionalDisconnect = false
        setupCarriedResumptionHandle = false
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
                        PrivacyLog.realtimeSession(.gemini, .unhandledEvent,
                                                   detail: PrivacyToken("staleClose"))
                        return
                    }
                    // Keep the message: a *refused* session closes rather than errors, so this is
                    // the only signal that carries the server's reason, and the state the handler
                    // sets is deliberately not `.error` (a normal end-of-session close lands here).
                    self.handleSocketClosed(message: "Connection closed (code \(code.rawValue): \(reasonStr))")
                }
            }

            self.delegate.onError = { [weak self] error in
                guard let self else { return }
                let msg = error?.localizedDescription ?? "Unknown error"
                Task { @MainActor in
                    guard self.generationGate.isCurrent(gen) else {
                        PrivacyLog.realtimeSession(.gemini, .unhandledEvent,
                                                   detail: PrivacyToken("staleError"))
                        return
                    }
                    self.handleSocketErrored(message: msg)
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
                    self.handleConnectTimedOut()
                }
            }
        }

        return finishConnect(success: result)
    }

    // MARK: - Socket events, as named paths (Plan FF P1/PR5)
    //
    // Extracted from the delegate closures so a fault injection drives the same bodies the socket
    // drives. A test-only copy of this ladder would prove only that the copy works.

    /// The socket closed. A normal end-of-session close lands here too, which is why the state is
    /// `.disconnected` rather than `.error`.
    private func handleSocketClosed(message: String) {
        resolveConnect(success: false)
        connectionState = .disconnected
        isModelSpeaking = false
        lastCloseReason = message
        onDisconnected?(message)
        scheduleReconnect(reason: message)
    }

    /// The transport reported an error rather than a clean close.
    private func handleSocketErrored(message: String) {
        resolveConnect(success: false)
        connectionState = .error(message)
        isModelSpeaking = false
        onDisconnected?(message)
        scheduleReconnect(reason: message)
    }

    /// Setup never completed inside the connect timeout. No close and no error arrives in this
    /// shape — the reschedule is driven by `connect()` returning false, not by an event.
    private func handleConnectTimedOut() {
        if connectionState == .connecting || connectionState == .settingUp {
            connectionState = .error("Connection timed out")
        }
        resolveConnect(success: false)
    }

    /// The server is rotating the connection. Sent before its session time limit, so every long
    /// conversation meets it.
    private func handleGoAway(secondsRemaining seconds: Int) {
        isModelSpeaking = false
        PrivacyLog.realtimeGoAway(.gemini, secondsRemaining: seconds)
        scheduleReconnect(reason: "server rotating connection")   // sets reconnecting = true first
        onDisconnected?("Server rotating connection (time left: \(seconds)s)")
    }

    /// Settle what an attempt means for the resumption handle, and report whether it came up.
    ///
    /// The rule is in one place because it is easy to get subtly wrong in two: a *successful*
    /// attempt that carried a handle resumed the conversation; a *failed* attempt that carried one
    /// drops it, so the next attempt cold-starts instead of re-offering a handle the server may
    /// already have refused; and a failure that never got as far as sending setup keeps it, because
    /// nothing was offered and nothing was refused.
    @discardableResult
    private func finishConnect(success: Bool) -> Bool {
        let carried = setupCarriedResumptionHandle
        if success {
            lastConnectResumedContext = carried
            lastResumptionHandleRejected = false
        } else {
            lastConnectResumedContext = false
            if carried {
                resumptionHandle = nil
                lastResumptionHandleRejected = true
                PrivacyLog.realtimeSession(.gemini, .unhandledEvent,
                                           detail: PrivacyToken("resumptionHandleDropped"))
            }
        }
        return success
    }

    // MARK: - Fault injection (test-only, Plan FF P1/PR5)

    /// What a scripted connect attempt does instead of opening a socket.
    ///
    /// Only the outcomes that are *about an attempt failing to come up* live here; a connection
    /// that dies once it is up is injected as a ``GeminiLiveFault`` through the same handlers the
    /// socket uses.
    enum ScriptedConnectOutcome: Equatable {
        /// Setup completed. The session is ready.
        case ready
        /// The socket opened, setup went out, and nothing came back inside the timeout.
        case setupTimedOut
        /// The socket opened, setup went out carrying a resumption handle, and the server refused
        /// it. The expired-handle fault.
        case setupRejected(reason: String)
        /// The socket never opened. Setup was never sent — so a held handle survives this.
        case failedBeforeSetup(reason: String)
    }

    /// Test-only: parked at the moment setup has gone out and the answer has not come back — the
    /// window a stop has to be able to land in, held open so the landing is deterministic rather
    /// than a race against a scheduler. No production caller.
    var holdAtSetupForTesting: (@MainActor () async -> Void)?

    private var scriptedTransportEnabled = false
    private var scriptedConnectOutcomes: [ScriptedConnectOutcome] = []
    /// How many scripted attempts have run. The ladder's shape, asserted directly.
    private(set) var scriptedConnectCount = 0

    /// Test-only: stand a script of connect outcomes in for the socket. No production caller.
    func setScriptedConnectOutcomesForTesting(_ outcomes: [ScriptedConnectOutcome]) {
        scriptedTransportEnabled = true
        scriptedConnectOutcomes = outcomes
    }

    /// Test-only: drive a socket event through the production handler it would have driven.
    func injectFaultForTesting(_ fault: GeminiLiveFault) {
        switch fault {
        case .socketClosed(let reason):
            handleSocketClosed(message: reason)
        case .socketError(let reason):
            handleSocketErrored(message: reason)
        case .setupTimedOut:
            handleConnectTimedOut()
        case .serverRotation(let seconds):
            // The real sequence: the announcement schedules the reconnect, then the close arrives
            // and coalesces into the attempt already pending.
            handleGoAway(secondsRemaining: seconds)
            handleSocketClosed(message: "Connection closed (code 1000: server rotating connection)")
        }
    }

    private func runScriptedConnect() async -> Bool {
        lastCloseReason = nil
        intentionalDisconnect = false
        setupCarriedResumptionHandle = false
        let gen = generationGate.advance()
        connectionState = .connecting
        scriptedConnectCount += 1

        let outcome = scriptedConnectOutcomes.isEmpty
            ? ScriptedConnectOutcome.failedBeforeSetup(reason: "no scripted outcome remaining")
            : scriptedConnectOutcomes.removeFirst()

        // A real connect suspends here; so does this, which is what gives a stop somewhere to land.
        await Task.yield()
        guard generationGate.isCurrent(gen) else { return false }

        if case .failedBeforeSetup(let reason) = outcome {
            connectionState = .disconnected
            lastCloseReason = reason
            onDisconnected?(reason)
            return finishConnect(success: false)
        }

        connectionState = .settingUp
        noteSetupGoingOut()
        await holdAtSetupForTesting?()
        await Task.yield()
        guard generationGate.isCurrent(gen) else { return false }

        switch outcome {
        case .ready:
            connectionState = .ready
            return finishConnect(success: true)
        case .setupTimedOut:
            connectionState = .error("Connection timed out")
            return finishConnect(success: false)
        case .setupRejected(let reason):
            connectionState = .error(reason)
            lastCloseReason = reason
            onDisconnected?(reason)
            return finishConnect(success: false)
        case .failedBeforeSetup:
            return finishConnect(success: false)   // handled above
        }
    }

    func disconnect() {
        intentionalDisconnect = true
        resumptionHandle = nil   // CJ item 7: a deliberate teardown must not resume later
        _ = generationGate.advance()   // BR P3: outstanding callbacks are stale from here
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        reconnectPending = false
        reconnectWorkArmed = false   // FF P1/PR5: nothing is scheduled after a stop, and says so
        reconnectAttempts = 0   // a fresh session must not inherit an exhausted counter (Plan BD)
        setupCarriedResumptionHandle = false
        lastConnectResumedContext = false
        lastResumptionHandleRejected = false
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
            PrivacyLog.realtimeSession(.gemini, .intentionalDisconnect)
            return
        }
        // Coalesce the duplicate triggers a single failure fires (close + error + receive-loop):
        // only the first schedules; the rest are no-ops until the pending attempt runs (Plan BD).
        guard !reconnectPending else { return }

        guard let delay = reconnectPolicy.delay(forAttempt: reconnectAttempts + 1) else {
            PrivacyLog.realtimeReconnectExhausted(.gemini, attempts: maxReconnectAttempts)
            connectionState = .error("Connection lost after \(maxReconnectAttempts) reconnect attempts")
            reconnecting = false
            // Disarmed *before* the terminal cue: the wearer is about to be told nothing further is
            // coming, and that has to be true at the moment it is said (Plan FF P1/PR5).
            reconnectWorkArmed = false
            onReconnectExhausted?()
            return
        }

        reconnecting = true
        reconnectPending = true
        reconnectWorkArmed = true
        reconnectAttempts += 1
        // The reason is derived from an error's description at every call site — dropped.
        PrivacyLog.realtimeReconnectScheduled(.gemini, attempt: reconnectAttempts,
                                              of: maxReconnectAttempts, delaySeconds: delay)

        reconnectTask?.cancel()
        let scaledDelay = delay * max(0, reconnectDelayScaleForTesting)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(scaledDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectPending = false

            // Clean up old socket
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil

            let success = await self.connect()
            // A stop that landed during the backoff or during setup: the generation has moved, the
            // old callbacks are stale, and nothing further is scheduled from here.
            guard !Task.isCancelled, !self.intentionalDisconnect else {
                self.reconnectWorkArmed = false
                return
            }
            if success {
                self.reconnectAttempts = 0
                self.reconnecting = false
                self.reconnectWorkArmed = false
                PrivacyLog.realtimeSession(.gemini, .reconnected)
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
            PrivacyLog.realtimeSendSkipped(.gemini, kind: .frame, reason: .notReady,
                                           state: connectionState.privacyToken)
            return
        }
        videoFramesSent += 1
        let count = videoFramesSent
        // Dispatch JPEG compression, base64 encoding, and send to background queue
        sendQueue.async {
            guard let jpegData = image.jpegData(compressionQuality: Config.geminiLiveVideoJPEGQuality) else {
                PrivacyLog.realtimeSendSkipped(.gemini, kind: .frame, reason: .encodingFailed)
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
            PrivacyLog.realtimeMedia(.gemini, kind: .streamedFrame,
                                     kilobytes: jpegData.count / 1024, sequence: count)
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
            PrivacyLog.realtimeSendSkipped(.gemini, kind: .text, reason: .notReady,
                                           state: connectionState.privacyToken)
            return
        }
        let json = LiveInjectionEnvelope.geminiText(text, completeTurn: completeTurn)
        sendQueue.async { Self.sendJSONDirect(json, via: task) }
    }

    /// Push a full-quality still into the model's view, bypassing the throttled stream path and its
    /// resize/quality-0.5 encode. Pre-encoded JPEG so the sharp bytes go out exactly as captured.
    func sendHighResImage(jpegData: Data) {
        guard connectionState == .ready, let task = webSocketTask else {
            PrivacyLog.realtimeSendSkipped(.gemini, kind: .image, reason: .notReady,
                                           state: connectionState.privacyToken)
            return
        }
        sendQueue.async {
            let json = LiveInjectionEnvelope.geminiImage(base64JPEG: jpegData.base64EncodedString())
            PrivacyLog.realtimeMedia(.gemini, kind: .sharpFrame, kilobytes: jpegData.count / 1024)
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

    /// Record what this setup carries, before it goes out. The handle fact is what
    /// `finishConnect(success:)` later reads to decide whether a failure means the server refused
    /// to resume (Plan FF P1/PR5).
    private func noteSetupGoingOut() {
        setupCarriedResumptionHandle = resumptionHandle != nil
        lastSetupInstruction = systemInstruction
    }

    private func sendSetupMessage() {
        noteSetupGoingOut()
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

        // Decided against the account's own model list before connecting (`prepareLiveModel`).
        // Report a swap: a silent substitution files the session's usage and latency cohorts under
        // a model that never served it.
        let resolution = resolvedLiveModel
        if resolution.substitutedFor != nil {
            PrivacyLog.realtimeSession(.gemini, .modelSubstituted,
                                       detail: PrivacyToken(resolution.model))
        }

        var setupBody = GeminiLiveSetup.body(
            model: "models/\(resolution.model)",
            responseModalities: responseModalities,
            systemInstruction: systemInstruction,
            tools: toolsArray,
            sessionResumption: GeminiSessionResumption.setupValue(handle: resumptionHandle))
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
                PrivacyLog.realtimeError(.gemini, phase: .send, SafeErrorSummary(error))
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
            UsageTracker.shared.record(provider: .gemini, model: resolvedLiveModel.model,
                                       tokensIn: d.tokensIn, tokensOut: d.tokensOut)
        }

        // Setup complete
        if json["setupComplete"] != nil {
            connectionState = .ready
            resolveConnect(success: true)
            return
        }

        // Session-resumption handle update (Plan CJ item 7) — store the latest resumable handle
        // so the next reconnect resumes instead of cold-starting.
        if let update = GeminiSessionResumption.update(from: json) {
            resumptionHandle = GeminiSessionResumption.apply(update, to: resumptionHandle)
            return
        }

        // GoAway — the server sends this before its session time limit, i.e. on EVERY long session.
        // The old code fired the fatal onDisconnected path (reconnecting == false), so the session
        // manager tore the session down right before the close it should have ridden through. Now we
        // proactively schedule a reconnect so a long conversation survives the server's rotation.
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            handleGoAway(secondsRemaining: timeLeft?["seconds"] as? Int ?? 0)
            return
        }

        // Tool call from model
        if let toolCall = GeminiToolCall(json: json) {
            PrivacyLog.realtimeToolCall(.gemini, functions: toolCall.functionCalls.count)
            onToolCall?(toolCall)
            return
        }

        // Tool call cancellation
        if let cancellation = GeminiToolCallCancellation(json: json) {
            PrivacyLog.realtimeToolCancellation(.gemini, calls: cancellation.ids.count)
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
                        PrivacyLog.realtimeLatency(.gemini, milliseconds: Int(latency * 1000))
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
                        PrivacyLog.realtimeUtterance(.gemini, direction: .output,
                                                     characters: text.count)
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
                // The wearer's own speech: length only.
                PrivacyLog.realtimeUtterance(.gemini, direction: .input, characters: text.count)
                lastUserSpeechEnd = Date()
                responseLatencyLogged = false
                onInputTranscription?(text)
            }

            // Output transcription (what the AI said)
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTranscription["text"] as? String, !text.isEmpty {
                PrivacyLog.realtimeUtterance(.gemini, direction: .output, characters: text.count)
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
