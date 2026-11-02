import Foundation

// Plan JP: Hermes Agent can be reached through two doors, and the app speaks both.
//
// - The **API server** built into Hermes Agent: OpenAI-compatible HTTP on port 8642 by default,
//   `Authorization: Bearer <API_SERVER_KEY>`, `POST /v1/responses`.
// - The **bridge script** (`hermes_bridge.py`), a separate process run beside Hermes: JSON over a
//   WebSocket on port 8765 by default, `?token=` auth (`HermesBridgeProtocol`).
//
// Everything in this file is pure — request building, reply parsing, error mapping and the
// one-sentence connection diagnosis — so it is tested without a server. `HermesAgentAPIClient` is
// the live edge.

// MARK: - Connection kind

/// Which of Hermes's two doors the app talks to. The host is shared; each kind has its own port and
/// its own credential.
enum HermesConnectionKind: String, CaseIterable, Equatable, Sendable {
    /// Hermes Agent's own OpenAI-compatible API server.
    case apiServer
    /// The glasses bridge script run beside Hermes.
    case bridgeScript

    var defaultPort: Int {
        switch self {
        case .apiServer: return HermesAgentAPI.defaultPort
        case .bridgeScript: return HermesBridgeProtocol.defaultPort
        }
    }

    /// The picker label.
    var title: String {
        switch self {
        case .apiServer: return String(localized: "API server")
        case .bridgeScript: return String(localized: "Bridge script")
        }
    }

    /// The kind to use when the wearer never chose one. An install that already has a bridge host
    /// was set up for the bridge script before the API server was an option, so it keeps the bridge;
    /// a fresh setup starts on the API server, which needs nothing installed beside Hermes.
    nonisolated static func resolved(stored: String?, bridgeHost: String) -> HermesConnectionKind {
        if let stored, let kind = HermesConnectionKind(rawValue: stored) { return kind }
        let hasBridgeHost = !bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasBridgeHost ? .bridgeScript : .apiServer
    }

    /// The other kind, when the port in use is that kind's well-known default — 8642 on the bridge
    /// kind, 8765 on the API kind. A port typed into the host field counts; it wins over the port
    /// field when the address is dialled, so it is the one that matters here too.
    nonisolated static func portHint(kind: HermesConnectionKind, host: String, port: Int) -> HermesConnectionKind? {
        let effective = GatewayAddress.components(host, defaultPort: port)?.port ?? port
        switch kind {
        case .bridgeScript where effective == HermesAgentAPI.defaultPort: return .apiServer
        case .apiServer where effective == HermesBridgeProtocol.defaultPort: return .bridgeScript
        default: return nil
        }
    }
}

// MARK: - Reply and errors

/// One answer from `POST /v1/responses`: the spoken text and the id that chains the next turn.
struct HermesAgentReply: Equatable, Sendable {
    let id: String?
    let text: String
}

/// Why a request to Hermes's API server did not produce a reply. The descriptions are what the
/// debug log and, through the turn's fall-through, the wearer's field log can show — plain, and
/// never carrying the key (server text is passed through `HermesAgentAPI.sanitised`).
enum HermesAgentAPIError: Error, Equatable, LocalizedError {
    case noHost
    case invalidAddress
    case missingKey
    case unauthorized
    case notFound(String?)
    case busy(String?)
    case unavailable(String?)
    case server(status: Int, message: String?)
    case runFailed(String?)
    case emptyReply
    case malformedReply
    case unreachable
    case timedOut
    case transport(code: Int)

    var errorDescription: String? {
        switch self {
        case .noHost:
            return String(localized: "No Hermes address is set.")
        case .invalidAddress:
            return String(localized: "The Hermes address can't be used.")
        case .missingKey:
            return String(localized: "No Hermes API key is set.")
        case .unauthorized:
            return String(localized: "Hermes's API server refused the API key.")
        case .notFound(let message):
            return Self.withDetail(String(localized: "Hermes's API server didn't find that."), message)
        case .busy(let message):
            return Self.withDetail(String(localized: "Hermes is busy with other requests."), message)
        case .unavailable(let message):
            return Self.withDetail(String(localized: "Hermes's API server is unavailable right now."), message)
        case .server(let status, let message):
            return Self.withDetail(String(localized: "Hermes's API server answered with error \(status)."), message)
        case .runFailed(let message):
            return Self.withDetail(String(localized: "Hermes couldn't finish the answer."), message)
        case .emptyReply:
            return String(localized: "Hermes answered with nothing to say.")
        case .malformedReply:
            return String(localized: "Hermes's answer couldn't be read.")
        case .unreachable:
            return String(localized: "Hermes's API server couldn't be reached.")
        case .timedOut:
            return String(localized: "Hermes didn't answer in time.")
        case .transport(let code):
            return String(localized: "Hermes couldn't be reached (network error \(code)).")
        }
    }

    private static func withDetail(_ sentence: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return sentence }
        return "\(sentence) \(detail)"
    }
}

// MARK: - The API

enum HermesAgentAPI {
    static let defaultPort = 8642
    /// The model name Hermes's own examples use; the server ignores it unless configured otherwise.
    static let model = "hermes-agent"
    /// The same generous budget as the bridge's query timeout: an agentic turn runs tools.
    static let requestTimeout: TimeInterval = 120
    /// Health and model-list checks answer at once or not at all.
    static let probeTimeout: TimeInterval = 10
    /// Keychain item holding `API_SERVER_KEY`.
    static let keychainKey = "hermesAgentAPIKey"

    /// Layered on Hermes's own system prompt. The reply is read out by the app's TTS, so anything
    /// that only works on a screen comes out as noise.
    #if AVENKIN_PHONE_ONLY
    private static let spokenTo = "Your reply will be spoken aloud to the user."
    #else
    private static let spokenTo = "Your reply will be spoken aloud to the wearer through smart glasses."
    #endif
    static let spokenReplyInstructions =
        spokenTo + " Keep it brief: a few "
        + "plain sentences. No markdown, headings, bullet or numbered lists, tables, code blocks or URLs."

    // MARK: Base URL

    /// `scheme://host:port[/prefix]`, no trailing slash, or nil when the address is empty, not an
    /// address, carries a user name, or names a scheme other than http(s)/ws(s).
    ///
    /// The host field takes what the bridge's and the gateway's take (`GatewayAddress`): a bare
    /// host, `host:port`, or a pasted URL. The scheme follows the same rule — `http` on the wearer's
    /// own network, `https` for a public name, a typed one kept (`ws`/`wss` read as `http`/`https`,
    /// for an address pasted from the bridge). A typed path is kept as a prefix so a profile served
    /// under `/p/<profile>/` works; a trailing `/v1` is dropped because the endpoints append it.
    nonisolated static func baseURL(host: String, port: Int) -> URL? {
        guard let address = GatewayAddress.components(host, defaultPort: port),
              address.userInfo == nil,
              let resolvedPort = address.port else { return nil }
        let scheme: String
        switch address.scheme {
        case "http", "ws": scheme = "http"
        case "https", "wss": scheme = "https"
        default: return nil
        }
        return URL(string: "\(scheme)://\(address.urlHost):\(resolvedPort)\(pathPrefix(address.tail))")
    }

    /// The path part of a typed tail, without query, fragment, trailing slashes or a final `/v1`.
    nonisolated static func pathPrefix(_ tail: String) -> String {
        let end = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? tail.endIndex
        var path = String(tail[..<end])
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    nonisolated static func responsesURL(base: URL) -> URL { base.appendingPathComponent("v1/responses") }
    nonisolated static func modelsURL(base: URL) -> URL { base.appendingPathComponent("v1/models") }

    /// Where to ask "are you Hermes?". Under a profile prefix the prefixed path is asked first and
    /// the server root second, since a server may answer health only at its root.
    nonisolated static func healthURLs(base: URL) -> [URL] {
        let prefixed = base.appendingPathComponent("health")
        guard var root = URLComponents(url: base, resolvingAgainstBaseURL: false),
              !root.path.isEmpty, root.path != "/" else { return [prefixed] }
        root.path = "/health"
        guard let rootURL = root.url, rootURL != prefixed else { return [prefixed] }
        return [prefixed, rootURL]
    }

    // MARK: Requests

    /// `POST /v1/responses`. Text-only turns send `input` as a plain string; a turn with a picture
    /// sends the content-array form with the JPEG as a data URL. `store: true` keeps the response
    /// on the server so the next turn can chain to it with `previous_response_id`.
    nonisolated static func responsesRequest(base: URL, apiKey: String, input: String,
                                             imageJPEG: Data? = nil,
                                             previousResponseID: String? = nil) -> URLRequest {
        var request = URLRequest(url: responsesURL(base: base), timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = responsesBody(input: input, imageJPEG: imageJPEG,
                                         previousResponseID: previousResponseID)
        return request
    }

    nonisolated static func responsesBody(input: String, imageJPEG: Data?, previousResponseID: String?) -> Data {
        var body: [String: Any] = [
            "model": model,
            "instructions": spokenReplyInstructions,
            "store": true,
            "stream": false,
        ]
        if let imageJPEG {
            body["input"] = [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": input],
                    ["type": "input_image",
                     "image_url": "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"],
                ],
            ]]
        } else {
            body["input"] = input
        }
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// `GET /health` — unauthenticated on Hermes's server.
    nonisolated static func healthRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: probeTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `GET /v1/models` with the key — the cheapest authenticated call, so it verifies the key.
    nonisolated static func modelsRequest(base: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: modelsURL(base: base), timeoutInterval: probeTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Replies

    /// The spoken text of a Responses reply: the `output_text` parts of every `message` item,
    /// joined. Tool-call items are Hermes's own working and are skipped. A top-level `output_text`
    /// (an OpenAI SDK convenience Hermes does not document) is accepted when there are no message
    /// parts.
    nonisolated static func parseReply(_ data: Data, redacting key: String? = nil) throws -> HermesAgentReply {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HermesAgentAPIError.malformedReply
        }
        let id = json["id"] as? String
        switch json["status"] as? String {
        case "failed":
            let error = json["error"] as? [String: Any]
            throw HermesAgentAPIError.runFailed(sanitised(error?["message"] as? String, redacting: key))
        case "incomplete":
            let details = json["incomplete_details"] as? [String: Any]
            throw HermesAgentAPIError.runFailed(sanitised(details?["reason"] as? String, redacting: key))
        default:
            break
        }

        var pieces: [String] = []
        for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                guard part["type"] as? String == "output_text", let text = part["text"] as? String else { continue }
                pieces.append(text)
            }
        }
        var text = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let fallback = json["output_text"] as? String {
            text = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw HermesAgentAPIError.emptyReply }
        return HermesAgentReply(id: id, text: text)
    }

    /// The model ids in an OpenAI list (`{"data":[{"id":…}]}`), or nil when the body is not one.
    nonisolated static func modelIDs(in data: Data) -> [String]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }

    /// True when a health body is a JSON object — Hermes answers `{"status":"ok"}`.
    nonisolated static func isHealthBody(_ data: Data?) -> Bool {
        guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return json["status"] != nil
    }

    // MARK: Errors

    /// The typed error for a non-2xx answer, or nil for a success.
    nonisolated static func error(status: Int, body: Data?, redacting key: String? = nil) -> HermesAgentAPIError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = sanitised(serverMessage(in: body), redacting: key)
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound(message)
        case 429: return .busy(message)
        case 503: return .unavailable(message)
        default: return .server(status: status, message: message)
        }
    }

    /// `error.message` (Hermes's shape), else a bare `error` string, `message` or `detail`.
    nonisolated static func serverMessage(in body: Data?) -> String? {
        guard let body, let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        return json["message"] as? String ?? json["detail"] as? String
    }

    /// Server text made safe to show: whitespace collapsed, capped, and the key replaced wherever
    /// it appears. Nil when nothing is left.
    nonisolated static func sanitised(_ message: String?, redacting key: String?) -> String? {
        guard var text = message else { return nil }
        if let key, !key.isEmpty {
            text = text.replacingOccurrences(of: key, with: "[key]")
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let limit = 160
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text
    }

    /// The typed error for a transport failure.
    nonisolated static func error(forTransport error: Error) -> HermesAgentAPIError {
        if let apiError = error as? HermesAgentAPIError { return apiError }
        guard let code = urlErrorCode(of: error) else { return .unreachable }
        if code == URLError.timedOut.rawValue { return .timedOut }
        if unreachableCodes.contains(code) { return .unreachable }
        return .transport(code: code)
    }

    /// A `URLError` code for `error`, with the POSIX socket errors a WebSocket can surface mapped
    /// onto their `URLError` equivalents. Nil for an error that is neither.
    nonisolated static func urlErrorCode(of error: Error) -> Int? {
        if let urlError = error as? URLError { return urlError.code.rawValue }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return ns.code }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case 60: return URLError.timedOut.rawValue                       // ETIMEDOUT
            case 61, 64, 65, 51, 50: return URLError.cannotConnectToHost.rawValue // ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ENETDOWN
            case 54, 57: return URLError.networkConnectionLost.rawValue      // ECONNRESET, ENOTCONN
            default: return nil
            }
        }
        return nil
    }

    /// Codes that mean "nothing answered at that address" rather than "something answered badly".
    static let unreachableCodes: Set<Int> = [
        URLError.cannotFindHost.rawValue, URLError.cannotConnectToHost.rawValue,
        URLError.networkConnectionLost.rawValue, URLError.dnsLookupFailed.rawValue,
        URLError.notConnectedToInternet.rawValue, URLError.timedOut.rawValue,
        URLError.dataNotAllowed.rawValue, URLError.internationalRoamingOff.rawValue,
        URLError.cannotLoadFromNetwork.rawValue,
    ]
}

// MARK: - Connection diagnosis

/// What Test Connection found, for either kind, as a sentence the wearer can act on. The mapping
/// from each probe step to a case is pure and lives here; the clients only gather the evidence.
enum HermesConnectionDiagnosis: Equatable, Sendable {
    /// The API server answered health and accepted the key; the model it advertises, if any.
    case apiServerReady(model: String?)
    /// The bridge script greeted the connection (or answered a ping).
    case bridgeReady
    case noHost
    case invalidAddress
    case missingKey
    case medicalLocalOnly
    /// `EndpointPolicy` refused the address — in a release build, cleartext to a public host.
    case refusedByPolicy
    case unreachable(HermesConnectionKind)
    case secureConnectionFailed
    /// Something answered over HTTP, but not like Hermes's API server.
    case notHermesAPIServer
    /// The API kind reached a WebSocket server that wanted an upgrade — the bridge script's port.
    case looksLikeBridgeScript
    case keyRejected
    case serverError(status: Int, message: String?)
    /// The bridge kind got a plain HTTP answer instead of a WebSocket — the API server's port.
    case looksLikeAPIServer
    case bridgeRefusedToken
    /// A WebSocket opened but nothing said `welcome`.
    case noWelcome
    /// Connected, but a ping went unanswered.
    case bridgeSilent
    case transportFailed(code: Int)

    var isSuccess: Bool {
        switch self {
        case .apiServerReady, .bridgeReady: return true
        default: return false
        }
    }

    /// The kind to switch to, when the failure says the wearer picked the wrong one.
    var suggestedKind: HermesConnectionKind? {
        switch self {
        case .looksLikeAPIServer: return .apiServer
        case .looksLikeBridgeScript: return .bridgeScript
        default: return nil
        }
    }

    /// A fixed token for the debug log — never server text.
    var logToken: String {
        switch self {
        case .apiServerReady: return "apiServerReady"
        case .bridgeReady: return "bridgeReady"
        case .noHost: return "noHost"
        case .invalidAddress: return "invalidAddress"
        case .missingKey: return "missingKey"
        case .medicalLocalOnly: return "medicalLocalOnly"
        case .refusedByPolicy: return "refusedByPolicy"
        case .unreachable: return "unreachable"
        case .secureConnectionFailed: return "secureConnectionFailed"
        case .notHermesAPIServer: return "notHermesAPIServer"
        case .looksLikeBridgeScript: return "looksLikeBridgeScript"
        case .keyRejected: return "keyRejected"
        case .serverError(let status, _): return "serverError(\(status))"
        case .looksLikeAPIServer: return "looksLikeAPIServer"
        case .bridgeRefusedToken: return "bridgeRefusedToken"
        case .noWelcome: return "noWelcome"
        case .bridgeSilent: return "bridgeSilent"
        case .transportFailed(let code): return "transportFailed(\(code))"
        }
    }

    /// The sentence shown (and read by VoiceOver) under Test Connection.
    var explanation: String {
        switch self {
        case .apiServerReady(let model?):
            return String(localized: "Connected to Hermes's API server (it offers “\(model)”), and the API key works.")
        case .apiServerReady(nil):
            return String(localized: "Connected to Hermes's API server, and the API key works.")
        case .bridgeReady:
            #if AVENKIN_PHONE_ONLY
            return String(localized: "Connected to the bridge script.")
            #else
            return String(localized: "Connected to the glasses bridge script.")
            #endif
        case .noHost:
            return String(localized: "Enter the address of the machine running Hermes.")
        case .invalidAddress:
            return String(localized: "That address can't be used. Enter an IP address or a host name, like 192.168.1.20, without a user name.")
        case .missingKey:
            return String(localized: "Enter the API key — the API_SERVER_KEY set on the Hermes machine.")
        case .medicalLocalOnly:
            return MedicalEgressRefusal.userMessage
        case .refusedByPolicy:
            return String(localized: "This build only makes an unencrypted connection to an address on your own network. Use the machine's local IP address, or an https:// address.")
        case .unreachable(.apiServer):
            return String(localized: "Couldn't reach Hermes's API server. By default it only listens on the Hermes machine itself: set API_SERVER_HOST=0.0.0.0 there and restart Hermes. Also check the IP address, the port (8642 by default) and the machine's firewall.")
        case .unreachable(.bridgeScript):
            return String(localized: "Couldn't reach the bridge script. Check that it's running, the IP address, the port (8765 by default) and the machine's firewall.")
        case .secureConnectionFailed:
            return String(localized: "Couldn't make a secure connection. If Hermes is on your own network, enter the address without https:// so the app uses plain http there.")
        case .notHermesAPIServer:
            return String(localized: "Something answered at that address, but it isn't Hermes's API server. Check the port (8642 by default) and that API_SERVER_ENABLED=true is set on the Hermes machine.")
        case .looksLikeBridgeScript:
            #if AVENKIN_PHONE_ONLY
            return String(localized: "That port answered like the bridge script, not the API server. Switch Connection to Bridge script, or use the API server's port (8642 by default).")
            #else
            return String(localized: "That port answered like the glasses bridge script, not the API server. Switch Connection to Bridge script, or use the API server's port (8642 by default).")
            #endif
        case .keyRejected:
            return String(localized: "Hermes's API server is reachable, but it refused the API key. Enter the API_SERVER_KEY set on the Hermes machine.")
        case .serverError(let status, let message?):
            return String(localized: "Hermes's API server answered with an error (\(status)): \(message)")
        case .serverError(let status, nil):
            return String(localized: "Hermes's API server answered with an error (\(status)).")
        case .looksLikeAPIServer:
            return String(localized: "Something answered over plain HTTP instead of opening a WebSocket — this looks like Hermes's API server. Switch Connection to API server.")
        case .bridgeRefusedToken:
            return String(localized: "The bridge script refused the token. Enter the HERMES_BRIDGE_TOKEN the script was started with, or leave it empty if it has none.")
        case .noWelcome:
            #if AVENKIN_PHONE_ONLY
            return String(localized: "Something accepted the connection but didn't greet like the bridge script. Check the port (8765 by default).")
            #else
            return String(localized: "Something accepted the connection but didn't greet like the glasses bridge script. Check the port (8765 by default).")
            #endif
        case .bridgeSilent:
            return String(localized: "The bridge is connected but didn't answer a ping within 5 seconds. It may be busy with a question; try again.")
        case .transportFailed(let code):
            return String(localized: "Couldn't connect (network error \(code)).")
        }
    }

    // MARK: Pure mappings

    /// An address the endpoint or medical rule refused.
    nonisolated static func policy(_ error: Error) -> HermesConnectionDiagnosis {
        if error is MedicalEgressRefusal { return .medicalLocalOnly }
        if let rejection = error as? EndpointPolicy.Rejection {
            switch rejection {
            case .cleartextHTTPNotPermitted, .privateHostNotPermitted: return .refusedByPolicy
            case .invalidURL, .missingHost, .disallowedScheme, .credentialInURL: return .invalidAddress
            }
        }
        return .invalidAddress
    }

    /// A transport error, read for the given kind.
    nonisolated static func transport(code: Int, kind: HermesConnectionKind) -> HermesConnectionDiagnosis {
        if HermesAgentAPI.unreachableCodes.contains(code) { return .unreachable(kind) }
        if (-1206 ... -1200).contains(code) { return .secureConnectionFailed }
        if code == URLError.appTransportSecurityRequiresSecureConnection.rawValue { return .refusedByPolicy }
        return .transportFailed(code: code)
    }

    /// Step one of the API probe, `GET /health`. Nil means healthy: go on to the key.
    nonisolated static func apiHealth(status: Int?, body: Data?, urlErrorCode: Int?) -> HermesConnectionDiagnosis? {
        if let urlErrorCode { return transport(code: urlErrorCode, kind: .apiServer) }
        guard let status else { return .unreachable(.apiServer) }
        switch status {
        case 200..<300:
            return HermesAgentAPI.isHealthBody(body) ? nil : .notHermesAPIServer
        case 426:
            // A WebSocket server asked for an upgrade: the bridge script is listening here.
            return .looksLikeBridgeScript
        case 500...:
            return .serverError(status: status,
                                message: HermesAgentAPI.sanitised(HermesAgentAPI.serverMessage(in: body), redacting: nil))
        default:
            return .notHermesAPIServer
        }
    }

    /// Step two of the API probe, `GET /v1/models` with the key.
    nonisolated static func apiModels(status: Int?, body: Data?, urlErrorCode: Int?,
                                      redacting key: String?) -> HermesConnectionDiagnosis {
        if let urlErrorCode { return transport(code: urlErrorCode, kind: .apiServer) }
        guard let status else { return .unreachable(.apiServer) }
        switch status {
        case 200..<300:
            return .apiServerReady(model: body.flatMap(HermesAgentAPI.modelIDs(in:))?.first)
        case 401, 403:
            return .keyRejected
        case 404:
            return .notHermesAPIServer
        case 426:
            return .looksLikeBridgeScript
        default:
            return .serverError(status: status,
                                message: HermesAgentAPI.sanitised(HermesAgentAPI.serverMessage(in: body), redacting: key))
        }
    }

    /// Why the bridge's WebSocket did not reach `welcome`, from what URLSession exposes: the HTTP
    /// status of a refused upgrade, the close code, and the transport error.
    nonisolated static func bridgeFailure(httpStatus: Int?, closeCode: Int?, urlErrorCode: Int?) -> HermesConnectionDiagnosis {
        if closeCode == 4401 { return .bridgeRefusedToken }
        if let httpStatus, httpStatus != 101 {
            // The bridge can refuse a token at the handshake; anything else that answers plain
            // HTTP on this port is not the bridge, and the likeliest thing is the API server.
            if httpStatus == 401 || httpStatus == 403 { return .bridgeRefusedToken }
            return .looksLikeAPIServer
        }
        if let urlErrorCode {
            if urlErrorCode == URLError.badServerResponse.rawValue { return .looksLikeAPIServer }
            return transport(code: urlErrorCode, kind: .bridgeScript)
        }
        if httpStatus == 101 { return .noWelcome }
        return .unreachable(.bridgeScript)
    }
}
