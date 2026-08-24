import Foundation
import Network

/// Answers an OAuth loopback redirect on the phone itself (Plan DD P1).
///
/// The ChatGPT public client's registered redirect is `http://localhost:1455/auth/callback`, and
/// on the phone `localhost` **is** the phone. While a sign-in sheet is on screen the app is
/// foreground-active, so it can bind that port, catch the browser's redirect, and capture the
/// authorization code without the user copying anything out of an address bar.
///
/// Deliberately narrow, because it is a socket opened during authentication:
/// - binds **loopback only** (`127.0.0.1`) — never a routable interface;
/// - serves exactly one path, `GET <callbackPath>`; everything else is a 404;
/// - validates `state` (constant-time) before treating a request as a callback;
/// - is strictly **single-use** — the first valid hit captures and the listener shuts down;
/// - never logs, echoes, or renders the code, and the success page carries no external resources.
///
/// One instance serves one capture attempt. Every exit path (capture, port conflict, listener
/// failure, timeout, cancellation) tears the listener down and resolves to a typed `Outcome`, so
/// the UI always has somewhere to land — the paste fallback — and never a dead end.
final class LoopbackCallbackServer {

    /// The port the provider registered for the loopback redirect.
    static let defaultPort: UInt16 = 1455
    /// The path the provider registered for the loopback redirect.
    static let defaultCallbackPath = "/auth/callback"

    /// How a capture attempt ended.
    enum Outcome: Equatable {
        /// A valid, state-matched callback arrived.
        case captured(code: String, state: String?)
        /// Something else already holds the port — fall back to pasting.
        case portUnavailable
        /// The listener could not run for another reason.
        case listenerFailed(String)
        /// Nobody came back within the (generous) window.
        case timedOut
        /// The sheet went away, or the caller stopped us.
        case cancelled
    }

    /// What a parsed request means to us. Anything that isn't a valid callback is `.reject`.
    enum Route: Equatable {
        case capture(code: String, state: String?)
        case reject
    }

    struct Response: Equatable {
        let status: String
        let contentType: String
        let body: Data
    }

    /// Called once the socket is bound, with the port actually in use — tests bind port 0 and
    /// read the assigned port back from here.
    var onReady: ((UInt16) -> Void)?

    private static let queue = DispatchQueue(label: "com.openglasses.loopback-callback")

    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var expectedState: String?
    private var isFinished = false
    private var hasCaptured = false
    private var timeoutItem: DispatchWorkItem?

    // MARK: - Capture

    /// Listen for the redirect and suspend until it arrives, the listener gives up, the window
    /// expires, or the surrounding task is cancelled. The listener is always torn down on exit.
    ///
    /// `timeout` is generous on purpose: signing in legitimately takes minutes, and the real
    /// lifetime bound is the sheet — dismissing it cancels the task, which stops the listener.
    func capture(expectedState: String?,
                 port: UInt16 = LoopbackCallbackServer.defaultPort,
                 callbackPath: String = LoopbackCallbackServer.defaultCallbackPath,
                 timeout: TimeInterval = 600) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                begin(expectedState: expectedState, port: port, callbackPath: callbackPath,
                      timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Stop listening now (the sheet was dismissed). Safe to call more than once.
    func stop() {
        finish(.cancelled)
    }

    // MARK: - Pure routing

    /// Request line → what it means and what to answer with. Pure, so the accept/reject rules
    /// are testable without a socket.
    ///
    /// A request only counts as a callback when it is a `GET` of the registered path carrying a
    /// `code`, **and** its `state` matches the in-flight PKCE state. A sign-in with no state to
    /// compare against can never be captured — there would be nothing to authenticate it with.
    static func route(method: String, target: String,
                      callbackPath: String, expectedState: String?) -> (route: Route, response: Response) {
        let requestPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        guard method == "GET", requestPath == callbackPath else { return (.reject, notFoundResponse) }
        // Reuse the shared parser by rebuilding the absolute URL the browser asked for.
        guard let parsed = ChatGPTOAuth.parseAuthorizationInput("http://127.0.0.1" + target) else {
            return (.reject, notFoundResponse)
        }
        guard let expectedState, let state = parsed.state,
              constantTimeEquals(state, expectedState) else {
            return (.reject, notFoundResponse)
        }
        return (.capture(code: parsed.code, state: parsed.state), successResponse)
    }

    /// The page the browser lands on after a successful capture. Self-contained — no external
    /// resources — and it never contains the code.
    static let successPageHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Connected</title>
    <style>
    :root { color-scheme: light dark; }
    body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
           font: 17px/1.4 -apple-system, system-ui, sans-serif; background: Canvas; color: CanvasText; }
    main { max-width: 22rem; padding: 2rem; text-align: center; }
    h1 { font-size: 1.35rem; margin: 0 0 .5rem; }
    p { margin: 0; opacity: .7; }
    </style></head>
    <body><main><h1>You're connected</h1><p>Return to the app — you can close this page.</p></main></body></html>
    """

    static var successResponse: Response {
        Response(status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(successPageHTML.utf8))
    }

    static var notFoundResponse: Response {
        Response(status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                 body: Data("not found".utf8))
    }

    /// Length-safe comparison so the state check doesn't leak by timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    static func httpData(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    // MARK: - Listener lifecycle

    private func begin(expectedState: String?, port: UInt16, callbackPath: String,
                       timeout: TimeInterval, continuation: CheckedContinuation<Outcome, Never>) {
        lock.lock()
        guard !isFinished, self.continuation == nil else {
            lock.unlock()
            continuation.resume(returning: .cancelled)   // one instance, one capture
            return
        }
        self.continuation = continuation
        self.expectedState = expectedState
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Binding the required local endpoint to 127.0.0.1 is what keeps this off every other
        // interface: nothing outside the device can reach the listener at all.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any))

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            finish(.portUnavailable)
            return
        }

        lock.lock()
        listener = newListener
        lock.unlock()

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, callbackPath: callbackPath)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?(newListener.port?.rawValue ?? port)
                self.armTimeout(timeout)
            case .failed(let error):
                self.finish(Self.outcome(for: error))
            case .waiting(let error):
                // A loopback bind that has to wait isn't going to succeed later — the port is
                // taken. Terminal here, so the UI reaches its fallback instead of hanging.
                self.finish(Self.outcome(for: error))
            case .cancelled:
                break   // torn down by `finish` — the outcome is already decided
            default:
                break
            }
        }
        newListener.start(queue: Self.queue)
    }

    private static func outcome(for error: NWError) -> Outcome {
        if case .posix(let code) = error, code == .EADDRINUSE || code == .EADDRNOTAVAIL {
            return .portUnavailable
        }
        return .listenerFailed(error.localizedDescription)
    }

    private func armTimeout(_ timeout: TimeInterval) {
        guard timeout > 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        lock.lock()
        timeoutItem?.cancel()
        timeoutItem = item
        lock.unlock()
        Self.queue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let pending = continuation
        let openListener = listener
        let pendingTimeout = timeoutItem
        continuation = nil
        listener = nil
        timeoutItem = nil
        expectedState = nil
        lock.unlock()

        pendingTimeout?.cancel()
        openListener?.cancel()
        pending?.resume(returning: outcome)
    }

    /// Claim the one capture this instance is allowed to make.
    private func claimCapture() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !hasCaptured, !isFinished else { return false }
        hasCaptured = true
        return true
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection, callbackPath: String) {
        connection.start(queue: Self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let target = parts.count > 1 ? String(parts[1]) : "/"

            self.lock.lock()
            let expected = self.expectedState
            self.lock.unlock()

            var (route, response) = Self.route(method: method, target: target,
                                               callbackPath: callbackPath, expectedState: expected)
            // Single-use: a second valid callback is answered like any other stray request.
            if case .capture = route, !self.claimCapture() {
                route = .reject
                response = Self.notFoundResponse
            }
            connection.send(content: Self.httpData(response), completion: .contentProcessed { _ in
                connection.cancel()
                if case .capture(let code, let state) = route {
                    self.finish(.captured(code: code, state: state))
                }
            })
        }
    }
}
