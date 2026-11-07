import Foundation

/// The limits every recipe add-on run is held to, and the per-run fetcher that enforces them.
///
/// - ≤ 3 requests per run; a 4th is refused **as data** (`error: request_limit`), not thrown.
/// - ≤ 1 MB per response, JSON or text MIME types only.
/// - 30 s per run and 15 s per request, measured on the injected clock.
/// - ≤ 3 redirects per request, each followed here (never by the transport) and each re-checked:
///   https, no userinfo or port, host on the allowlist. Redirect hops do not count toward the
///   request budget; they have their own cap.
/// - The URL is checked against the allowlist **after** substitution, whatever the validator saw.
/// - Forbidden headers (`Host`, `Content-Length`, `Connection`, `Transfer-Encoding`, `Proxy-*`,
///   `Cookie`, `User-Agent`) are dropped; header values lose every control character.
///
/// Not here: private, loopback and LAN addresses reached through an allowed name. Nothing in this
/// type resolves DNS; the real transport's connect-time address check (`BoundedHTTPClient`) is
/// what refuses those, DNS-rebinding included.
struct RecipeSandbox: Sendable {

    static let maxRequestsPerRun = 3
    static let maxResponseBytes = 1_048_576
    static let runTimeout: TimeInterval = 30
    static let requestTimeout: TimeInterval = 15
    static let maxRedirects = 3

    static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding", "cookie", "user-agent",
    ]

    static func isForbiddenHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return forbiddenHeaders.contains(lower) || lower.hasPrefix("proxy-")
    }

    /// Author headers made safe to send: forbidden and malformed names dropped, control
    /// characters removed from values.
    static func sanitisedHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers where RecipeAddOnValidator.isHeaderToken(name) && !isForbiddenHeader(name) {
            out[name] = RecipeTemplate.escape(value, for: .headerValue)
        }
        return out
    }

    /// JSON (`application/json`, `…+json`) or any `text/…` type.
    static func isAcceptableMIME(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
              !mime.isEmpty else { return false }
        return mime == "application/json" || mime.hasSuffix("+json") || mime.hasPrefix("text/")
    }

    enum URLRefusal: Equatable, Sendable {
        case malformed, notHTTPS, hasUserInfo, hasPort, hostNotAllowed(String)
    }

    /// Why `url` may not be fetched under `rules`, or `nil` when it may.
    static func refusal(for url: URL, rules: [AddOnDomainRule]) -> URLRefusal? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return .malformed }
        guard c.scheme?.lowercased() == "https" else { return .notHTTPS }
        guard c.user == nil, c.password == nil else { return .hasUserInfo }
        if let port = c.port, port != 443 { return .hasPort }
        guard let host = c.host, !host.isEmpty else { return .malformed }
        guard AddOnDomainRule.allows(host: host, rules: rules) else { return .hostNotAllowed(host) }
        return nil
    }

    // MARK: - Per-run state

    /// One `http` step's result, as the recipe sees it: `<as>`, `<as>.status`, `<as>.ok`,
    /// `<as>.error`.
    struct FetchResult: Equatable, Sendable {
        let body: String
        let status: Int
        let ok: Bool
        /// Empty on success. Otherwise one of: `request_limit`, `bad_url`, `host_not_allowed`,
        /// `run_timeout`, `timeout`, `network`, `too_many_redirects`, `redirect_refused`,
        /// `too_large`, `unsupported_type`, `not_text`, `status` (a non-2xx answer; the body
        /// is still set when it is text).
        let error: String

        static func failed(_ error: String) -> FetchResult {
            FetchResult(body: "", status: 0, ok: false, error: error)
        }
    }

    let rules: [AddOnDomainRule]
    let transport: any AddOnHTTPTransport
    let clock: any AddOnClock
    let startedAt: Date
    private(set) var requestsMade = 0

    init(rules: [AddOnDomainRule], transport: any AddOnHTTPTransport, clock: any AddOnClock) {
        self.rules = rules
        self.transport = transport
        self.clock = clock
        self.startedAt = clock.now()
    }

    var elapsed: TimeInterval { clock.now().timeIntervalSince(startedAt) }
    var isOutOfTime: Bool { elapsed >= Self.runTimeout }

    /// Make one request (following up to three redirects). Never throws.
    mutating func fetch(method: String, url urlString: String, headers: [String: String], body: Data?,
                        contentType: String?) async -> FetchResult {
        guard requestsMade < Self.maxRequestsPerRun else { return .failed("request_limit") }
        requestsMade += 1
        guard var url = URL(string: urlString) else { return .failed("bad_url") }
        if Self.refusal(for: url, rules: rules) != nil { return .failed("host_not_allowed") }

        var method = method.uppercased()
        var body = body
        var headers = Self.sanitisedHeaders(headers)
        if body != nil, let contentType {
            headers = headers.filter { $0.key.lowercased() != "content-type" }
            headers["Content-Type"] = contentType
        }
        if !headers.keys.contains(where: { $0.lowercased() == "accept" }) {
            headers["Accept"] = "application/json, text/*;q=0.9"
        }

        var hops = 0
        while true {
            let remaining = Self.runTimeout - elapsed
            guard remaining > 0 else { return .failed("run_timeout") }
            let timeout = min(Self.requestTimeout, remaining)
            let request = AddOnHTTPRequest(method: method, url: url, headers: headers, body: body,
                                           timeout: timeout, maxResponseBytes: Self.maxResponseBytes)
            let sentAt = clock.now()
            let response: AddOnHTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                return .failed("network")
            }
            if clock.now().timeIntervalSince(sentAt) > timeout {
                return .failed(elapsed >= Self.runTimeout ? "run_timeout" : "timeout")
            }

            if (300...399).contains(response.status), response.status != 304, let location = response.location {
                hops += 1
                guard hops <= Self.maxRedirects else { return .failed("too_many_redirects") }
                guard let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      Self.refusal(for: next, rules: rules) == nil else { return .failed("redirect_refused") }
                // 303 always, and 301/302 after a POST, continue as a GET without the body.
                if response.status == 303 || ((response.status == 301 || response.status == 302) && method == "POST") {
                    method = "GET"
                    body = nil
                    headers = headers.filter { $0.key.lowercased() != "content-type" }
                }
                // The author's headers were written for the host they named, not for another one.
                if next.host?.lowercased() != url.host?.lowercased() {
                    headers = headers.filter { $0.key.lowercased() == "accept" || $0.key.lowercased() == "content-type" }
                }
                url = next
                continue
            }

            guard response.body.count <= Self.maxResponseBytes else { return .failed("too_large") }
            let ok = (200...299).contains(response.status)
            if response.body.isEmpty {
                return FetchResult(body: "", status: response.status, ok: ok, error: ok ? "" : "status")
            }
            guard Self.isAcceptableMIME(response.mimeType) else {
                return FetchResult(body: "", status: response.status, ok: false, error: "unsupported_type")
            }
            guard let text = String(data: response.body, encoding: .utf8) else {
                return FetchResult(body: "", status: response.status, ok: false, error: "not_text")
            }
            return FetchResult(body: text, status: response.status, ok: ok, error: ok ? "" : "status")
        }
    }
}
