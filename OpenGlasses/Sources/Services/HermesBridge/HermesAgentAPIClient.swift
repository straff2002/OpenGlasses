import Foundation

/// The one seam between the Hermes API client and the network: send a request, get the body and
/// the HTTP answer. Production is an ephemeral `URLSession`; a test scripts the answers.
protocol HermesHTTPTransport: AnyObject, Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport for Hermes's API server (`NetworkRoute.hermesAgentAPI`).
///
/// Ephemeral — no cookies, no cache, nothing of a conversation left on disk — and redirects are
/// refused: the request carries the API key in a header, and a redirect is how a header ends up
/// somewhere the wearer never typed.
final class URLSessionHermesHTTPTransport: HermesHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = HermesAgentAPI.requestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 30
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.consentedData(for: request, scope: .conversation,
                                                              allowSameOriginRedirects: false)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }


}

/// Client for Hermes Agent's own API server (Plan JP) — the second way to reach Hermes, beside the
/// bridge script (`HermesBridgeService`).
///
/// A turn is one `POST /v1/responses`. Turns are chained: the id of the last reply goes out as
/// `previous_response_id`, so Hermes replays the conversation itself and the phone sends only the
/// new question. The id is held in memory only — a relaunch starts a new conversation, and
/// nothing about it is written to disk. A chained request the server no longer recognises (404)
/// drops the id and is retried once without it.
///
/// Every request first passes `EndpointPolicy.requireOpenable(url:for:)` — the endpoint rule and the
/// medical Local Only rule in one call — and Local Only turning on mid-request cancels it
/// (`MedicalEgressTeardown`, in `MedicalEgressCoordinator.swift`). The API key is read from the
/// Keychain per request and never appears in a debug line.
@MainActor
final class HermesAgentAPIClient {
    /// What a request is built from. Read fresh per request so a settings change applies at once.
    struct Settings: Equatable, Sendable {
        var host: String
        var port: Int
        var apiKey: String

        static func current() -> Settings {
            Settings(host: Config.hermesBridgeHost, port: Config.hermesAPIPort, apiKey: Config.hermesAgentAPIKey)
        }
    }

    var onDebugEvent: ((String) -> Void)?

    /// The id of the last reply, which the next turn chains to. Memory only.
    private(set) var conversationID: String?

    private let transport: HermesHTTPTransport
    private let settings: () -> Settings
    private let build: EndpointPolicy.BuildFlavor
    private var inFlight: [UUID: Task<(Data, HTTPURLResponse), Error>] = [:]

    init(transport: HermesHTTPTransport = URLSessionHermesHTTPTransport(),
         settings: @escaping () -> Settings = Settings.current,
         build: EndpointPolicy.BuildFlavor = .current) {
        self.transport = transport
        self.settings = settings
        self.build = build
    }

    /// Hermes is on, Agent Mode is on, and the connection kind is the API server.
    var isEnabled: Bool {
        Config.hermesBridgeEnabled && Config.agentModeEnabled && Config.hermesConnectionKind == .apiServer
    }

    var hasConversation: Bool { conversationID != nil }

    var hasRequestInFlight: Bool { !inFlight.isEmpty }

    // MARK: - Ask

    /// Ask Hermes and return the reply to speak. `imageJPEG` must already have passed the privacy
    /// chokepoint; this client never touches the camera.
    func ask(_ text: String, imageJPEG: Data? = nil) async throws -> String {
        let current = settings()
        let base = try resolveBase(current)
        let key = current.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw HermesAgentAPIError.missingKey }

        let chained = conversationID
        do {
            return try await send(text, imageJPEG: imageJPEG, base: base, key: key, previous: chained)
        } catch HermesAgentAPIError.notFound(_) where chained != nil {
            // The server forgot the stored response (restart, storage reset). Start a new chain
            // rather than failing the turn over bookkeeping the wearer never sees.
            onDebugEvent?("Hermes API: the stored conversation wasn't found — starting a new one")
            conversationID = nil
            return try await send(text, imageJPEG: imageJPEG, base: base, key: key, previous: nil)
        }
    }

    /// Forget the chain: the next turn starts a new conversation on the server.
    func resetConversation() {
        conversationID = nil
    }

    /// Cancel whatever is in flight. The caller's turn sees a medical refusal rather than a
    /// cancellation, so it falls through to the normal path instead of being dropped.
    func cancelInFlight() {
        inFlight.values.forEach { $0.cancel() }
    }

    private func resolveBase(_ current: Settings) throws -> URL {
        guard !current.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HermesAgentAPIError.noHost
        }
        guard let base = HermesAgentAPI.baseURL(host: current.host, port: current.port) else {
            throw HermesAgentAPIError.invalidAddress
        }
        return base
    }

    private func send(_ text: String, imageJPEG: Data?, base: URL, key: String,
                      previous: String?) async throws -> String {
        let request = HermesAgentAPI.responsesRequest(base: base, apiKey: key, input: text,
                                                      imageJPEG: imageJPEG, previousResponseID: previous)
        guard let url = request.url else { throw HermesAgentAPIError.invalidAddress }
        _ = try EndpointPolicy.requireOpenable(url: url, for: .hermesAgentAPI, build: build)

        let (data, response) = try await perform(request)
        if let error = HermesAgentAPI.error(status: response.statusCode, body: data, redacting: key) {
            throw error
        }
        let reply = try HermesAgentAPI.parseReply(data, redacting: key)
        conversationID = reply.id
        onDebugEvent?("Hermes API: answered\(previous == nil ? "" : " (chained)")\(imageJPEG == nil ? "" : " with a picture")")
        return reply.text
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let id = UUID()
        let transport = self.transport
        let task = Task { try await transport.send(request) }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // The caller's own task cancelled (barge-in): a cancellation, so the turn stops.
            if Task.isCancelled { throw CancellationError() }
            // Cancelled from here, which only the medical teardown does.
            if task.isCancelled { throw MedicalEgressRefusal(route: .hermesAgentAPI) }
            throw HermesAgentAPI.error(forTransport: error)
        }
    }

    // MARK: - Test Connection

    /// Health, then the key: each step's answer is read by the pure mappings on
    /// `HermesConnectionDiagnosis`. The key is checked for presence before anything is sent.
    func checkConnection() async -> HermesConnectionDiagnosis {
        let diagnosis = await diagnose()
        onDebugEvent?("Hermes API: test connection — \(diagnosis.logToken)")
        return diagnosis
    }

    private func diagnose() async -> HermesConnectionDiagnosis {
        let current = settings()
        guard !current.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noHost }
        guard let base = HermesAgentAPI.baseURL(host: current.host, port: current.port) else { return .invalidAddress }
        let key = current.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }

        let healthURLs = HermesAgentAPI.healthURLs(base: base)
        for (index, url) in healthURLs.enumerated() {
            do {
                _ = try EndpointPolicy.requireOpenable(url: url, for: .hermesAgentAPI, build: build)
            } catch {
                return .policy(error)
            }
            let outcome = await fetch(HermesAgentAPI.healthRequest(url: url))
            guard let problem = HermesConnectionDiagnosis.apiHealth(
                status: outcome.status, body: outcome.body, urlErrorCode: outcome.urlErrorCode) else { break }
            // A profile prefix may not serve health; the server root gets the next try.
            if outcome.status == 404, index < healthURLs.count - 1 { continue }
            return problem
        }

        let models = HermesAgentAPI.modelsRequest(base: base, apiKey: key)
        guard let modelsURL = models.url else { return .invalidAddress }
        do {
            _ = try EndpointPolicy.requireOpenable(url: modelsURL, for: .hermesAgentAPI, build: build)
        } catch {
            return .policy(error)
        }
        let outcome = await fetch(models)
        return HermesConnectionDiagnosis.apiModels(status: outcome.status, body: outcome.body,
                                                   urlErrorCode: outcome.urlErrorCode, redacting: key)
    }

    private struct FetchOutcome {
        var status: Int?
        var body: Data?
        var urlErrorCode: Int?
    }

    private func fetch(_ request: URLRequest) async -> FetchOutcome {
        do {
            let (data, response) = try await transport.send(request)
            return FetchOutcome(status: response.statusCode, body: data)
        } catch {
            return FetchOutcome(urlErrorCode: HermesAgentAPI.urlErrorCode(of: error)
                                ?? URLError.cannotConnectToHost.rawValue)
        }
    }
}

// MARK: - Conversation reset

/// The API kind's conversation lives in a chain of stored responses that the phone addresses by
/// id; dropping the id is the reset (`ResponseChainResetAdapter`).
extension HermesAgentAPIClient: ResponseChainResetting {}
