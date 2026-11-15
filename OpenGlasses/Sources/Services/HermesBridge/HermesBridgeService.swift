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
            case .notConfigured: return String(localized: "Hermes bridge host isn't configured")
            case .notConnected: return String(localized: "Hermes bridge isn't connected")
            case .timedOut: return String(localized: "Hermes bridge didn't answer in time")
            case .closed: return String(localized: "Hermes bridge connection closed")
            }
        }
    }

    @Published private(set) var status: Status = .disconnected

    /// Supplies a JPEG when the bridge asks for a photo. Injected so the
    /// service stays constructible without the camera stack.
    var photoProvider: (() async throws -> Data)?
    var onDebugEvent: ((String) -> Void)?

    private var socket: HermesSocket?
    /// The address the current socket dialled, so Test Connection can tell a socket opened for
    /// settings that have since changed from one for the settings on screen.
    private var socketURL: URL?
    /// Why the last socket failed, read from the transport before it was torn down (Plan JP).
    private(set) var lastFailure: HermesConnectionDiagnosis?
    /// Counts `pong` frames, so a probe on an open socket can tell its ping was answered.
    private var pongCount = 0
    private let socketFactory: HermesSocketFactory
    private var receiveLoop: Task<Void, Never>?
    private var pendingResponse: CheckedContinuation<String, Error>?
    /// Seconds a query may wait for `response` — agentic turns can be slow
    /// (tools, vision), so this is generous.
    private let queryTimeout: TimeInterval = 120

    /// Hermes is on, Agent Mode is on, and the connection kind is the bridge script — the only
    /// kind that holds a socket. Every launch-time and settings `connect()` is gated on this.
    var isEnabled: Bool {
        Config.hermesBridgeEnabled && Config.agentModeEnabled && Config.hermesConnectionKind == .bridgeScript
    }

    /// The socket factory is the only seam: production dials a `URLSessionWebSocketTask`, a test
    /// scripts frames.
    init(socketFactory: @escaping HermesSocketFactory = URLSessionHermesSocket.make) {
        self.socketFactory = socketFactory
    }

    // MARK: - Connection

    func connect() {
        guard status == .disconnected else { return }
        guard let candidate = HermesBridgeProtocol.endpointURL(
            host: Config.hermesBridgeHost,
            port: Config.hermesBridgePort,
            token: Config.hermesBridgeToken
        ) else {
            onDebugEvent?("Hermes bridge: no host configured")
            return
        }
        // The bridge is a documented local-network route, so a private address and cleartext ws
        // are allowed here — and only here.
        guard let url = try? EndpointPolicy.requireOpenable(url: candidate, for: .hermesBridgeSession) else {
            onDebugEvent?("Hermes bridge: endpoint refused by policy")
            return
        }
        status = .connecting
        lastFailure = nil
        self.socket = socketFactory(url)
        socketURL = url
        // The token rides in the query string; the debug line must not carry it.
        onDebugEvent?("Hermes bridge: connecting to \(HermesBridgeProtocol.redactedForLog(url))")
        startReceiveLoop()
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel()
        socket = nil
        socketURL = nil
        status = .disconnected
        failPending(with: BridgeError.closed)
    }

    /// Test Connection for the settings screen (Plan JP).
    ///
    /// It used to report success as soon as a ping was *sent* — and URLSession queues a send before
    /// the socket is open, so an address with nothing listening still showed a tick. Now an open
    /// socket must answer a ping with `pong`, and a new one must be greeted with `welcome` (the
    /// bridge sends it on connect), each within `timeout`. A failure is read from what the transport
    /// exposes (`HermesConnectionDiagnosis.bridgeFailure`).
    func checkConnection(timeout: TimeInterval = 5) async -> HermesConnectionDiagnosis {
        let diagnosis = await probe(timeout: timeout)
        onDebugEvent?("Hermes bridge: test connection — \(diagnosis.logToken)")
        return diagnosis
    }

    private func probe(timeout: TimeInterval) async -> HermesConnectionDiagnosis {
        guard !Config.hermesBridgeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noHost
        }
        guard let candidate = HermesBridgeProtocol.endpointURL(
            host: Config.hermesBridgeHost,
            port: Config.hermesBridgePort,
            token: Config.hermesBridgeToken
        ) else { return .invalidAddress }
        do {
            _ = try EndpointPolicy.requireOpenable(url: candidate, for: .hermesBridgeSession)
        } catch {
            return .policy(error)
        }

        if status == .connected, let socket, socketURL == candidate {
            let before = pongCount
            do {
                try await socket.send(HermesBridgeProtocol.encodePing())
            } catch {
                let failure = Self.failure(of: error, on: socket)
                disconnect()
                return failure
            }
            await waitUntil(timeout) { self.pongCount > before || self.status == .disconnected }
            if pongCount > before { return .bridgeReady }
            if status == .disconnected { return lastFailure ?? .unreachable(.bridgeScript) }
            return .bridgeSilent
        }

        // A socket still connecting, or one opened for settings since changed, is not evidence
        // about the address on screen: start over.
        if status != .disconnected { disconnect() }
        connect()
        guard socket != nil else { return lastFailure ?? .invalidAddress }
        await waitUntil(timeout) { self.status != .connecting }
        switch status {
        case .connected:
            return .bridgeReady
        case .disconnected:
            return lastFailure ?? .unreachable(.bridgeScript)
        case .connecting:
            let evidence = socket?.diagnostics() ?? HermesSocketDiagnostics()
            disconnect()
            return HermesConnectionDiagnosis.bridgeFailure(httpStatus: evidence.httpStatus,
                                                           closeCode: evidence.closeCode,
                                                           urlErrorCode: nil)
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func failure(of error: Error, on socket: HermesSocket) -> HermesConnectionDiagnosis {
        let evidence = socket.diagnostics()
        return HermesConnectionDiagnosis.bridgeFailure(httpStatus: evidence.httpStatus,
                                                       closeCode: evidence.closeCode,
                                                       urlErrorCode: HermesAgentAPI.urlErrorCode(of: error))
    }

    // MARK: - Query

    /// Ask the bridge and await its reply. Photo requests arriving mid-query
    /// are served inline by the receive loop.
    func ask(_ text: String) async throws -> String {
        if status == .disconnected { connect() }
        guard let socket else { throw BridgeError.notConfigured }
        guard pendingResponse == nil else { throw BridgeError.notConnected }

        try await socket.send(HermesBridgeProtocol.encodeQuery(text))

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
        Task { _ = await sendSessionReset() }
    }

    /// Send the reset frame and report whether it went out. The bridge protocol has no reply that
    /// correlates to it, so this is the whole of what can be established: the frame was written to
    /// the socket. The conversation-reset adapter reports that as issued-but-unverified rather
    /// than as a confirmed reset.
    @discardableResult
    func sendSessionReset() async -> Bool {
        guard let socket else { return false }
        do {
            try await socket.send(HermesBridgeProtocol.encodeNewSession())
            return true
        } catch {
            onDebugEvent?("Hermes bridge: session reset failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while let self, let socket = self.socket, !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    await self.handle(message)
                } catch {
                    if !Task.isCancelled {
                        await MainActor.run {
                            self.lastFailure = Self.failure(of: error, on: socket)
                            self.onDebugEvent?("Hermes bridge: receive failed — \(error.localizedDescription)")
                            self.disconnect()
                        }
                    }
                    return
                }
            }
        }
    }

    private func handle(_ frame: HermesFrame) async {
        switch frame {
        case .nonText:
            // Bridge TTS audio — always declined, so any stray frame is dropped.
            return
        case .text(let text):
            guard let decoded = HermesBridgeProtocol.decode(text) else {
                onDebugEvent?("Hermes bridge: undecodable frame ignored")
                return
            }
            await handle(decoded)
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
        case .pong:
            pongCount += 1
        case .sessionReset, .audioStart, .audioEnd:
            break
        case .unknown(let type):
            onDebugEvent?("Hermes bridge: unknown message type '\(type)'")
        }
    }

    private func serveCapturePhoto() async {
        guard let socket else { return }
        do {
            guard let photoProvider else {
                throw NSError(domain: "HermesBridge", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No camera available"])
            }
            let jpeg = try await photoProvider()
            try await socket.send(HermesBridgeProtocol.encodePhoto(jpegBase64: jpeg.base64EncodedString()))
            onDebugEvent?("Hermes bridge: served photo (\(jpeg.count / 1024) KB)")
        } catch {
            try? await socket.send(HermesBridgeProtocol.encodePhotoError(error.localizedDescription))
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


// MARK: - Conversation reset

/// The bridge owns its own conversation memory on the far side of the socket, so a "new topic"
/// that only cleared the phone would leave the agent remembering everything. `new_session` is the
/// protocol's reset; nothing in the protocol acknowledges it, which the adapter reports honestly.
extension HermesBridgeService: BridgeSessionResetting {
    var isBridgeConnected: Bool { status != .disconnected }
}
