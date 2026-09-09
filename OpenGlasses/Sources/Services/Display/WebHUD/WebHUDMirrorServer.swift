import CryptoKit
import Foundation
import Network

/// Plan BP — the flag-gated phone serving edge: `GET /` (the self-contained page, no data)
/// and `GET /hud.json?t=<token>` (the current mirror frame). Reuses the Plan E listener
/// pattern (`MCPGlassesServer`): NWListener, per-device Keychain bearer token, developer
/// gates. Gated `agentModeEnabled && hudMirrorEnabled` (default off) and the compile-time
/// ``LocalServiceExposurePolicy``. Release builds refuse this cleartext transport.
///
/// Privacy hard line: **HIPAA mode hard-disables the mirror** — at start, on mode change
/// (AppState wiring), and per request in the router, so vault/health content never crosses
/// this surface. The token is read-only scope by construction: the mirror has no mutation
/// endpoints at all.
@MainActor
final class WebHUDMirrorServer: ObservableObject {

    static let port: UInt16 = 8766

    @Published private(set) var isRunning = false

    /// Explicit availability, so a Release build reads as refusing rather than merely idle.
    @Published private(set) var availability: LocalServiceAvailability = .stopped

    /// Build marker of the transport actually opened, or nil when none ever was. Only a build that
    /// can open the legacy LAN transport can set this.
    private(set) var listenerBuildMarker: String?

    /// The current mirror frame, wired by AppState to `GlassesDisplayService.mirrorScreen`.
    var payloadProvider: () -> WebHUDPayload = { .empty }

    private let policy: LocalServiceExposurePolicy
    private let listenerFactory: LocalListenerFactory
    private let defaults: UserDefaults

    private var listener: NWListener?

    private static let tokenKey = "hudMirrorBearerToken"

    /// Defaults are the production wiring: the compile-time exposure policy and the real listener
    /// factory. The seams exist so a test can compose this server under a Release-flavoured policy
    /// and prove no listener is ever constructed.
    init(policy: LocalServiceExposurePolicy = .current,
         listenerFactory: @escaping LocalListenerFactory = LocalListenerProvider.production,
         defaults: UserDefaults = .standard) {
        self.policy = policy
        self.listenerFactory = listenerFactory
        self.defaults = defaults
    }

    /// The current access token, generating and persisting one on first read.
    var accessToken: String {
        if let existing = KeychainService.string(for: Self.tokenKey), !existing.isEmpty {
            return existing
        }
        let token = Self.generateToken()
        KeychainService.setString(token, for: Self.tokenKey)
        return token
    }

    /// Rotate the token (invalidates the registered URL's hash).
    @discardableResult
    func rotateToken() -> String {
        let token = Self.generateToken()
        KeychainService.setString(token, for: Self.tokenKey)
        return token
    }

    private static func generateToken() -> String {
        let raw = SymmetricKey(size: .bits256)
        return raw.withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL to register in Developer Mode (token rides the hash — never sent over HTTP).
    var registrationURL: String? {
        guard policy.permitsListener(for: .webHUDMirror) else {
            return nil
        }
        guard let ip = MCPGlassesServer.lanIPAddress() else { return nil }
        return "http://\(ip):\(Self.port)/#t=\(accessToken)"
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        guard Config.agentModeEnabled, Config.hudMirrorEnabled, !Config.hipaaMode else { return }
        start()
    }

    func start() {
        guard policy.permitsListener(for: .webHUDMirror) else {
            // Refuse before creating a token or a listener. Release preference state is not an
            // authorization mechanism and cannot override the build boundary, and refusing also
            // retires the stale opt-in behind this surface.
            availability = .unavailableInProduction
            isRunning = false
            policy.clearPersistedOptIns(defaults: defaults)
            return
        }
        guard listener == nil else { return }
        guard !Config.hipaaMode, MedicalEgressGuard.allows(.webHUDMirrorListener) else { return }
        _ = accessToken
        do {
            let handle = try listenerFactory(LocalListenerRequest(service: .webHUDMirror, port: Self.port))
            let listener = handle.listener
            listenerBuildMarker = handle.buildMarker
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.availability = .running
                        PrivacyLog.stream(.hudMirror, .listening, count: Int(Self.port))
                    case .failed(let error):
                        PrivacyLog.stream(.hudMirror, .startFailed, error: SafeErrorSummary(error))
                        self?.stop()
                    case .cancelled:
                        self?.isRunning = false
                        self?.availability = .stopped
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            PrivacyLog.stream(.hudMirror, .startFailed, error: SafeErrorSummary(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        availability = .stopped
    }

    // MARK: - Connection handling

    private nonisolated func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let firstLine = text.split(separator: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let method = parts.first.map(String.init) ?? ""
            let target = parts.count > 1 ? String(parts[1]) : "/"
            Task { @MainActor in
                let response = Self.routeResponse(method: method, target: target,
                                                 hipaa: Config.hipaaMode,
                                                 expectedToken: self.accessToken,
                                                 payload: self.payloadProvider())
                connection.send(content: Self.httpData(response), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: - Routing (pure, tested)

    struct Response: Equatable {
        let status: String
        let contentType: String
        let body: Data
    }

    /// Pure request → response. The page itself carries no data and needs no token; the
    /// data endpoint checks the hash-forwarded token. HIPAA refuses everything.
    static func routeResponse(method: String, target: String, hipaa: Bool,
                              expectedToken: String, payload: WebHUDPayload) -> Response {
        guard !hipaa else {
            return Response(status: "503 Service Unavailable", contentType: "text/plain",
                            body: Data("mirror disabled".utf8))
        }
        guard method == "GET" else {
            return Response(status: "405 Method Not Allowed", contentType: "text/plain",
                            body: Data("read-only mirror".utf8))
        }
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        switch path {
        case "/", "/index.html":
            let html = WebHUDRenderer.page(mode: .polling(intervalSeconds: 2))
            return Response(status: "200 OK", contentType: "text/html; charset=utf-8",
                            body: Data(html.utf8))
        case "/hud.json":
            guard constantTimeEquals(queryToken(in: target) ?? "", expectedToken) else {
                return Response(status: "401 Unauthorized", contentType: "text/plain",
                                body: Data("missing or invalid token".utf8))
            }
            return Response(status: "200 OK", contentType: "application/json",
                            body: payload.jsonData())
        default:
            return Response(status: "404 Not Found", contentType: "text/plain",
                            body: Data("not found".utf8))
        }
    }

    static func queryToken(in target: String) -> String? {
        guard let queryStart = target.firstIndex(of: "?") else { return nil }
        let query = target[target.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "t" {
                return String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        return nil
    }

    /// Length-safe comparison so token checks don't leak by timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    private static func httpData(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

extension Config {
    /// Web HUD mirror (Plan BP) — default off; developer surface gated with Agent Mode.
    static var hudMirrorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hudMirrorEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "hudMirrorEnabled") }
    }
}
