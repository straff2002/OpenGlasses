import Foundation

/// WebSocket client for a Hermes agent bridge (Plan CL P5): an agentic
/// "brain" running on a Mac. When enabled (Agent Mode required, like every
/// gateway) the conversation turn asks the bridge instead of a cloud model;
/// any failure falls through to the normal local/cloud path — the bridge
/// can never strand a turn.
///
/// Mid-query the bridge may ask for eyes: `capture_photo` is answered with
/// a JPEG from the injected photo provider (the glasses camera), or a
/// `photo_error` so the bridge answers text-only. Bridge TTS is always
/// declined — replies are spoken by the app's own TTS stack.
@MainActor
final class HermesBridgeService: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
    }

    enum BridgeError: LocalizedError {
        case notConfigured
        case notConnected
        case timedOut
        case closed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Hermes bridge host isn't configured"
            case .notConnected: return "Hermes bridge isn't connected"
            case .timedOut: return "Hermes bridge didn't answer in time"
            case .closed: return "Hermes bridge connection closed"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected

    /// Supplies a JPEG when the bridge asks for a photo. Injected so the
    /// service stays constructible without the camera stack.
    var photoProvider: (() async throws -> Data)?
    var onDebugEvent: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pendingResponse: CheckedContinuation<String, Error>?
    /// Seconds a query may wait for `response` — agentic turns can be slow
    /// (tools, vision), so this is generous.
    private let queryTimeout: TimeInterval = 120

    var isEnabled: Bool {
        Config.hermesBridgeEnabled && Config.agentModeEnabled
    }

    // MARK: - Connection

    func connect() {
        guard status == .disconnected else { return }
        guard let url = HermesBridgeProtocol.endpointURL(
            host: Config.hermesBridgeHost,
            port: Config.hermesBridgePort,
            token: Config.hermesBridgeToken
        ) else {
            onDebugEvent?("Hermes bridge: no host configured")
            return
        }
        status = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        onDebugEvent?("Hermes bridge: connecting to \(url.absoluteString)")
        startReceiveLoop()
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        status = .disconnected
        failPending(with: BridgeError.closed)
    }

    /// One-shot reachability probe for the settings screen: connects if
    /// needed and pings.
    func checkConnection() async -> Bool {
        if status == .disconnected { connect() }
        guard let task else { return false }
        do {
            try await task.send(.string(HermesBridgeProtocol.encodePing()))
            return true
        } catch {
            onDebugEvent?("Hermes bridge: ping failed — \(error.localizedDescription)")
            disconnect()
            return false
        }
    }

    // MARK: - Query

    /// Ask the bridge and await its reply. Photo requests arriving mid-query
    /// are served inline by the receive loop.
    func ask(_ text: String) async throws -> String {
        if status == .disconnected { connect() }
        guard let task else { throw BridgeError.notConfigured }
        guard pendingResponse == nil else { throw BridgeError.notConnected }

        try await task.send(.string(HermesBridgeProtocol.encodeQuery(text)))

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingResponse = continuation
                }
            }
            group.addTask { [queryTimeout] in
                try await Task.sleep(nanoseconds: UInt64(queryTimeout * 1_000_000_000))
                throw BridgeError.timedOut
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw BridgeError.closed }
            return reply
        }
    }

    /// Tell the bridge to forget the conversation (mirrors "new conversation").
    func resetSession() {
        guard let task else { return }
        Task { try? await task.send(.string(HermesBridgeProtocol.encodeNewSession())) }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while let self, let task = self.task, !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.onDebugEvent?("Hermes bridge: receive failed — \(error.localizedDescription)")
                            self.disconnect()
                        }
                    }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .data:
            // Bridge TTS audio — always declined, so any stray frame is dropped.
            return
        case .string(let text):
            guard let decoded = HermesBridgeProtocol.decode(text) else {
                onDebugEvent?("Hermes bridge: undecodable frame ignored")
                return
            }
            await handle(decoded)
        @unknown default:
            return
        }
    }

    private func handle(_ message: HermesBridgeMessage) async {
        switch message {
        case .welcome:
            status = .connected
            onDebugEvent?("Hermes bridge: connected")
        case .capturePhoto:
            await serveCapturePhoto()
        case .response(let text, _):
            if let continuation = pendingResponse {
                pendingResponse = nil
                continuation.resume(returning: text)
            }
        case .error(let message):
            failPending(with: NSError(
                domain: "HermesBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        case .sessionReset, .audioStart, .audioEnd, .pong:
            break
        case .unknown(let type):
            onDebugEvent?("Hermes bridge: unknown message type '\(type)'")
        }
    }

    private func serveCapturePhoto() async {
        guard let task else { return }
        do {
            guard let photoProvider else {
                throw NSError(domain: "HermesBridge", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No camera available"])
            }
            let jpeg = try await photoProvider()
            try await task.send(.string(HermesBridgeProtocol.encodePhoto(jpegBase64: jpeg.base64EncodedString())))
            onDebugEvent?("Hermes bridge: served photo (\(jpeg.count / 1024) KB)")
        } catch {
            try? await task.send(.string(HermesBridgeProtocol.encodePhotoError(error.localizedDescription)))
            onDebugEvent?("Hermes bridge: photo request failed — \(error.localizedDescription)")
        }
    }

    private func failPending(with error: Error) {
        if let continuation = pendingResponse {
            pendingResponse = nil
            continuation.resume(throwing: error)
        }
    }
}
