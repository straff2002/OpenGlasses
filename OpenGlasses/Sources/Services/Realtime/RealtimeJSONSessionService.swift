import Foundation
import UIKit

enum RealtimeConnectionState: Equatable {
    case disconnected, connecting, settingUp, ready, error(String)
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

/// Provider-neutral JSON session engine. Readiness is an adapter event, never socket-open.
@MainActor
class RealtimeJSONSessionService: ObservableObject {
    @Published var connectionState: RealtimeConnectionState = .disconnected
    @Published var isModelSpeaking = false
    @Published var isUserSpeaking = false
    @Published var reconnecting = false
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    /// The server's voice activity detection heard the wearer start speaking (Plan HY P1).
    var onUserSpeechStarted: (() -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onReconnected: (() -> Void)?
    var onReconnectExhausted: (() -> Void)?
    var onToolCall: ((OpenAIRealtimeFunctionCall) -> Void)?
    var playedAudioMilliseconds: (() -> Int)?
    private(set) var modelConfiguration: RealtimeModelConfig?
    private var instructions = ""
    private var appContext = RealtimeAppContext()
    private var tools: [[String: Any]] = []
    private var transport: RealtimeConnectionTransport?
    private var authorizationTask: Task<Void, Error>?
    private var adapter: RealtimeProtocolAdapter?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var generation = ConnectionGenerationGate()
    private var intentionalDisconnect = false
    private var terminalFailure = false
    private var reconnectAttempts = 0
    private var currentAudioItemID: String?
    private var currentContentIndex = 0
    private var muted = false
    private var lastBackgroundImageAt: Date = .distantPast
    private(set) var hasSentAudio = false
    private var packetizer = RealtimeAudioPacketizer(packetBytes: 640)

    private let transportFactory: (NetworkRoute) -> RealtimeConnectionTransport
    private let sleep: (TimeInterval) async throws -> Void
    init(transportFactory: @escaping (NetworkRoute) -> RealtimeConnectionTransport = { RealtimeWebSocketTransport(route: $0) },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transportFactory = transportFactory
        self.sleep = sleep
    }

    func configure(model: RealtimeModelConfig, systemInstruction: String, toolDeclarations: [[String: Any]] = []) {
        if modelConfiguration?.id != model.id { appContext = RealtimeAppContext() }
        modelConfiguration = model
        instructions = systemInstruction
        tools = toolDeclarations
    }
    func connectionRequest() throws -> URLRequest {
        guard let modelConfiguration else { throw RealtimeModelConfig.ConfigurationError.unknownProtocol }
        return try modelConfiguration.request()
    }
    func connect() async -> Bool {
        let request: URLRequest
        do {
            guard let modelConfiguration else { throw RealtimeModelConfig.ConfigurationError.unknownProtocol }
            try MedicalEgressGuard.check(modelConfiguration.route)
            request = try connectionRequest()
            adapter = try RealtimeAdapterRegistry.make(for: modelConfiguration)
        } catch { connectionState = .error(error.localizedDescription); terminalFailure = true; return false }
        resolve(false)
        authorizationTask?.cancel()
        receiveTask?.cancel()
        transport?.cancel()
        intentionalDisconnect = false
        terminalFailure = false
        let media = modelConfiguration?.profile?.mediaPolicy ?? .init()
        packetizer = RealtimeAudioPacketizer(packetBytes: media.audioPacketBytes ?? 640)
        hasSentAudio = false
        lastBackgroundImageAt = .distantPast
        muted = false
        currentAudioItemID = nil
        isUserSpeaking = false
        isModelSpeaking = false
        let identity = generation.advance()
        let transport = transportFactory(modelConfiguration!.route)
        let approval = Task { try await transport.authorize(request) }
        authorizationTask = approval
        do { try await withTaskCancellationHandler { try await approval.value } onCancel: { approval.cancel() } }
        catch {
            transport.cancel()
            guard generation.isCurrent(identity) else { return false }
            authorizationTask = nil
            connectionState = .error(error.localizedDescription)
            terminalFailure = true
            return false
        }
        guard generation.isCurrent(identity), !Task.isCancelled else { transport.cancel(); return false }
        authorizationTask = nil
        transport.audioPacketInterval = media.audioPacketInterval
        self.transport = transport
        connectionState = .connecting
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            transport.onOpen = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation.isCurrent(identity) else { return }
                    self.connectionState = .settingUp
                    self.startReceiving(identity: identity)
                    if self.adapter?.createsSessionOnOpen == true { self.sendConfiguration() }
                }
            }
            transport.onClose = { [weak self] code, _ in
                Task { @MainActor in
                    guard let self, self.generation.isCurrent(identity) else { return }
                    self.failed(String(localized: "The realtime connection closed (\(code.rawValue))."), retryable: ![1008, 4001, 4003].contains(code.rawValue))
                }
            }
            transport.onError = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation.isCurrent(identity) else { return }
                    self.failed(String(localized: "Could not connect to the realtime service."), retryable: ![400, 401, 403, 404].contains(self.transport?.httpStatusCode ?? 0))
                }
            }
            do { try transport.start(request) }
            catch { self.failed(error.localizedDescription, retryable: false); return }
            self.timeoutTask = Task { [weak self] in
                try? await self?.sleep(15)
                guard let self, !Task.isCancelled, self.generation.isCurrent(identity) else { return }
                self.failed(String(localized: "Realtime session setup timed out."), retryable: true)
            }
        }
        return result
    }
    func disconnect() {
        authorizationTask?.cancel(); authorizationTask = nil
        intentionalDisconnect = true
        _ = generation.advance()
        reconnectTask?.cancel(); reconnectTask = nil
        receiveTask?.cancel(); receiveTask = nil
        resolve(false)
        let closingTransport = transport
        let closeGrace = modelConfiguration?.profile?.mediaPolicy.closeGracePeriod ?? 0
        if closeGrace > 0, let closingTransport {
            // Give the protocol close a bounded chance to reach the server. Old callbacks are
            // already invalidated; no teardown work can touch a subsequently started session.
            send(.close, requireReady: false)
            Task {
                try? await sleep(closeGrace)
                closingTransport.cancel()
            }
        } else { closingTransport?.cancel() }
        transport = nil; adapter = nil
        packetizer.reset()
        appContext = RealtimeAppContext()
        reconnecting = false; reconnectAttempts = 0
        connectionState = .disconnected; isModelSpeaking = false; isUserSpeaking = false
        currentAudioItemID = nil
    }
    private func resolve(_ success: Bool) {
        timeoutTask?.cancel(); timeoutTask = nil
        let waiting = continuation; continuation = nil
        waiting?.resume(returning: success)
    }
    private func failed(_ message: String, retryable: Bool) {
        guard !intentionalDisconnect, !terminalFailure else { return }
        terminalFailure = !retryable
        _ = generation.advance()
        receiveTask?.cancel(); receiveTask = nil
        transport?.cancel()
        connectionState = .error(message)
        isModelSpeaking = false; isUserSpeaking = false
        resolve(false)
        // Set recovery state before notifying the coordinator.
        if retryable { scheduleReconnect() }
        onDisconnected?(message)
    }
    private func scheduleReconnect() {
        guard !intentionalDisconnect, !terminalFailure, reconnectTask == nil else { return }
        guard let delay = RealtimeReconnect.Policy(maxAttempts: 10, maxBackoffSeconds: 30).delay(forAttempt: reconnectAttempts + 1) else {
            reconnecting = false; onReconnectExhausted?(); return
        }
        reconnecting = true; reconnectAttempts += 1
        reconnectTask = Task { [weak self] in
            try? await self?.sleep(delay)
            guard let self, !Task.isCancelled, !self.intentionalDisconnect else { return }
            let success = await self.connect()
            guard !Task.isCancelled, !self.intentionalDisconnect else { return }
            self.reconnectTask = nil
            if success { self.reconnecting = false; self.reconnectAttempts = 0; self.onReconnected?() }
            else if !self.terminalFailure { self.scheduleReconnect() }
        }
    }
    private func sendConfiguration() {
        PrivacyLog.realtimeSession(logProvider, .sessionUpdateSent)
        send(.configure(instructions: appContext.instructions(appendingTo: instructions), tools: tools), requireReady: false)
    }
    func updateConfiguration() { send(.configure(instructions: appContext.instructions(appendingTo: instructions), tools: tools)) }
    func updateContext(_ text: String, key: String) {
        guard connectionState == .ready, modelConfiguration?.capabilities?.contextUpdate == true else { return }
        appContext.update(text, key: key)
        send(.updateContext(instructions: appContext.instructions(appendingTo: instructions)))
    }
    func speakText(_ text: String) {
        guard connectionState == .ready, modelConfiguration?.capabilities?.suppliedSpeech == true else { return }
        // Retain exactly what the app asked to announce, so a follow-up has the same context.
        // Do not present it as a fabricated user question or model-generated answer.
        updateContext("The app supplied this announcement to the wearer: " + text, key: "announcement")
        isModelSpeaking = true
        send(.speakText(text))
    }
    private func send(_ command: RealtimeCommand, requireReady: Bool = true) {
        guard !requireReady || connectionState == .ready, let transport, let adapter else { return }
        let identity = generation.current
        transport.perform { [weak self] in
            do { for message in try adapter.encode(command) { transport.send(message) } }
            catch {
                Task { @MainActor in
                    guard let self, self.generation.isCurrent(identity) else { return }
                    // An unsupported media operation must remain visible without killing audio.
                    self.onOperationRejected?(error.localizedDescription)
                }
            }
        }
    }
    var onOperationRejected: ((String) -> Void)?
    func sendAudio(data: Data) {
        guard connectionState == .ready else { return }
        setMuted(false)
        hasSentAudio = true
        if modelConfiguration?.profile?.mediaPolicy.audioPacketBytes != nil {
            for packet in packetizer.append(data) { send(.audio(packet)) }
        } else { send(.audio(data)) }
    }
    func setMuted(_ value: Bool) {
        guard muted != value else { return }
        muted = value
        if value { packetizer.reset() }
        send(.mute(value))
    }
    func sendImage(image: UIImage, prompt: String? = nil) {
        guard connectionState == .ready, let transport else { return }
        let media = modelConfiguration?.profile?.mediaPolicy ?? .init()
        guard !media.imageRequiresAudio || hasSentAudio else { return }
        guard Date().timeIntervalSince(lastBackgroundImageAt) >= media.backgroundImageInterval else { return }
        lastBackgroundImageAt = Date()
        let identity = generation.current
        transport.perform { [weak self] in
            var size = image.size
            if let maximum = media.imageMaxDimension, max(size.width, size.height) > maximum {
                let scale = maximum / max(size.width, size.height); size = .init(width: size.width * scale, height: size.height * scale)
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            var quality: CGFloat = 0.5
            var jpeg = resized.jpegData(compressionQuality: quality)
            while let maximum = media.imageMaxJPEGBytes, (jpeg?.count ?? 0) > maximum, quality > 0.1 {
                quality -= 0.1; jpeg = resized.jpegData(compressionQuality: quality)
            }
            guard let jpeg else { return }
            Task { @MainActor in
                guard let self, self.generation.isCurrent(identity) else { return }
                self.send(.image(jpeg, prompt: prompt))
            }
        }
    }
    func sendHighResImage(jpegData: Data, prompt: String? = nil) { send(.image(jpegData, prompt: prompt)) }
    func sendText(_ text: String, completeTurn: Bool, toolsAllowed: Bool = true) {
        send(.text(text, completeTurn: completeTurn, toolsAllowed: toolsAllowed))
    }
    func sendToolResult(id: String, output: String) { send(.toolResult(id: id, output: output)) }
    func sendToolMessage(_ json: [String: Any]) {
        guard connectionState == .ready, let transport else { return }
        transport.send(json)
    }
    func cancelResponse() {
        let played = playedAudioMilliseconds?() ?? 0
        send(.interrupt(itemID: currentAudioItemID, contentIndex: currentContentIndex, playedMilliseconds: played))
        currentAudioItemID = nil; isModelSpeaking = false
        onInterrupted?()
    }
    private func startReceiving(identity: UInt64) {
        guard let transport, let adapter else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await transport.receive()
                    transport.perform {
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        let events = adapter.decode(json)
                        Task { @MainActor in
                            guard let self, self.generation.isCurrent(identity), !self.terminalFailure else { return }
                            for event in events {
                                guard self.generation.isCurrent(identity), !self.terminalFailure else { break }
                                self.apply(event)
                            }
                        }
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.generation.isCurrent(identity) else { return }
                    self.failed(String(localized: "The realtime connection was interrupted."), retryable: true)
                    return
                }
            }
        }
    }
    private var logProvider: PrivacyLog.RealtimeProvider {
        switch modelConfiguration?.profile {
        case .geminiLiveV1: return .gemini
        case .qwenOmniV1, .qwenAudioV1: return .qwen
        case .doubaoDuplexV3: return .doubao
        default: return modelConfiguration?.providerID == "openai" ? .openai : .compatible
        }
    }
    private func apply(_ event: RealtimeEvent) {
        switch event {
        case .configureRequested: PrivacyLog.realtimeSession(logProvider, .sessionCreated); sendConfiguration()
        case .ready: PrivacyLog.realtimeSession(logProvider, .sessionConfigured); connectionState = .ready; resolve(true)
        case .audio(let data, let id, let index):
            isModelSpeaking = true; currentAudioItemID = id; currentContentIndex = index; onAudioReceived?(data)
        case .inputTranscript(let text, _):
            if !text.isEmpty {
                PrivacyLog.realtimeUtterance(logProvider, direction: .input, characters: text.count)
                onInputTranscription?(text)
            }
        case .outputTranscript(let text): onOutputTranscription?(text)
        case .userSpeaking(let speaking):
            isUserSpeaking = speaking
            if speaking { onUserSpeechStarted?() }
            if speaking && isModelSpeaking { cancelResponse() }
        case .interrupted: isModelSpeaking = false; onInterrupted?()
        case .speechFinished: isModelSpeaking = false
        case .turnComplete: isModelSpeaking = false; currentAudioItemID = nil; onTurnComplete?()
        case .toolCalls(let calls): for call in calls { onToolCall?(call) }
        case .usage(let input, let output):
            if let modelConfiguration {
                UsageTracker.shared.record(provider: modelConfiguration.providerID == "openai" ? .openai : .custom,
                                           model: modelConfiguration.model, tokensIn: input, tokensOut: output)
            }
        case .failure(let message, let retryable): failed(message, retryable: retryable)
        case .closed: failed(String(localized: "The realtime session ended."), retryable: false)
        }
    }
}
