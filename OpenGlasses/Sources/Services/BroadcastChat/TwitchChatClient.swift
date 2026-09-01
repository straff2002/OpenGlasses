import Foundation

/// Minimal WebSocket seam so the chat client (and the readback service above it) can be driven
/// by a fake in tests — production wraps `URLSessionWebSocketTask`.
protocol ChatSocketConnecting: AnyObject {
    /// Open the socket. `onText` delivers each received text frame; `onClose` fires once when
    /// the connection dies (either direction).
    func connect(url: URL,
                 onText: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable () -> Void)
    func send(_ text: String)
    func close()
}

/// Read-only Twitch chat connection (Plan CI P2): anonymous IRC-over-WebSocket to the channel
/// being broadcast to. Read access needs no OAuth — the anonymous `justinfan` login is the
/// documented no-auth read path — so v1 ships with zero new auth surface.
///
/// Owns login/JOIN, PING→PONG keepalive, and capped-backoff reconnection. Parsed messages go to
/// `onMessage`; everything else about *what to do* with chat lives in `ChatReadbackPolicy`.
@MainActor
final class TwitchChatClient {

    static let endpoint = URL(string: "wss://irc-ws.chat.twitch.tv:443")!

    /// A parsed chat message arrived.
    var onMessage: ((ChatMessage) -> Void)?

    private let makeSocket: () -> ChatSocketConnecting
    private var socket: ChatSocketConnecting?
    private var channel = ""
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    init(makeSocket: @escaping () -> ChatSocketConnecting = { URLSessionChatSocket() }) {
        self.makeSocket = makeSocket
    }

    /// Connect (read-only, anonymous) and join `#channel`.
    func start(channel: String) {
        let clean = channel.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
        guard !clean.isEmpty else { return }
        stop()
        self.channel = clean
        wantsConnection = true
        open()
    }

    func stop() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        socket?.close()
        socket = nil
    }

    /// Handle one IRC line (also the test entry point — fakes feed lines here).
    func handleLine(_ line: String) {
        switch TwitchChatMessageParser.parse(line: line) {
        case .privateMessage(let message):
            onMessage?(message)
        case .ping(let token):
            socket?.send("PONG :\(token)")
        case .other:
            break
        }
    }

    // MARK: - Private

    private func open() {
        let sock = makeSocket()
        socket = sock
        sock.connect(
            url: Self.endpoint,
            onText: { [weak self] frame in
                Task { @MainActor in
                    guard let self else { return }
                    // Frames may batch several CRLF-separated IRC lines.
                    for line in frame.split(separator: "\n") {
                        self.handleLine(String(line.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            },
            onClose: { [weak self] in
                Task { @MainActor in self?.scheduleReconnect() }
            })
        // Anonymous read-only login: justinfan<digits> needs no PASS/OAuth. Tags give us
        // display names + badges + emote ranges.
        sock.send("CAP REQ :twitch.tv/tags twitch.tv/commands")
        sock.send("NICK justinfan\(Int.random(in: 10_000...99_999))")
        sock.send("JOIN #\(channel)")
        // The channel is the wearer's own broadcast identity — fingerprinted, never named.
        PrivacyLog.stream(.broadcastChat, .joined, session: PrivateIdentifier(channel))
    }

    private func scheduleReconnect() {
        guard wantsConnection else { return }
        socket?.close()
        socket = nil
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 60)   // 1, 2, 4, … capped 60 s
        PrivacyLog.stream(.broadcastChat, .reconnectScheduled, attempt: reconnectAttempt,
                          delaySeconds: delay)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.wantsConnection else { return }
            self.open()
        }
    }
}

/// Production `ChatSocketConnecting` over `URLSessionWebSocketTask`.
final class URLSessionChatSocket: ChatSocketConnecting, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var onClose: (@Sendable () -> Void)?

    func connect(url: URL,
                 onText: @escaping @Sendable (String) -> Void,
                 onClose: @escaping @Sendable () -> Void) {
        self.onClose = onClose
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task, onText: onText)
    }

    func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    func close() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, onText: @escaping @Sendable (String) -> Void) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { onText(text) }
                self.receiveLoop(task, onText: onText)
            case .failure:
                if !self.closed { self.onClose?() }
            }
        }
    }
}
