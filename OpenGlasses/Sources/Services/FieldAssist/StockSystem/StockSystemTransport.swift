import Foundation

// The common transport every stock system's requests ride (Plan MM P2, §7). One HTTPS client for
// every system: the adapter supplies its hosts, its endpoints and its response cap, and this file
// pins them. It names no vendor.

/// Where a connection's requests go: the adapter's pinned host for the chosen environment, the
/// route they are checked against, the endpoints they may call and the most bytes a reply may be.
struct StockSystemDestination: Equatable, Sendable {
    let connectorID: String
    let route: NetworkRoute
    /// The one host this connection talks to.
    let host: String
    /// Every host the adapter pins (its production and its sandbox host). `host` is one of them.
    let pinnedHosts: Set<String>
    let allowedEndpoints: [StockSystemEndpoint]
    let maximumResponseBytes: Int

    /// Nil when the adapter has no host for `environment` (no sandbox) or its host is not a plain
    /// host name.
    init?(adapter: any StockSystemAdapter, route: NetworkRoute, environment: StockSystemEnvironment) {
        let hosts = adapter.hosts
        guard let host = environment == .production ? hosts.production : hosts.sandbox,
              Self.isPlainHost(host), adapter.maximumResponseBytes > 0 else { return nil }
        self.connectorID = adapter.connectorID
        self.route = route
        self.host = host
        self.pinnedHosts = Set([hosts.production, hosts.sandbox].compactMap { $0 })
        self.allowedEndpoints = adapter.allowedEndpoints
        self.maximumResponseBytes = adapter.maximumResponseBytes
    }

    /// A destination stated outright. The transport checks it again before every request, so a
    /// host that is not pinned is refused there.
    init(connectorID: String, route: NetworkRoute, host: String, pinnedHosts: Set<String>,
         allowedEndpoints: [StockSystemEndpoint], maximumResponseBytes: Int) {
        self.connectorID = connectorID
        self.route = route
        self.host = host
        self.pinnedHosts = pinnedHosts
        self.allowedEndpoints = allowedEndpoints
        self.maximumResponseBytes = maximumResponseBytes
    }

    /// A lower-case host name of letters, digits, `-` and `.`, with at least one dot.
    static func isPlainHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" || $0 == "." }
    }
}

/// The key a connection pastes, as the transport sends it. Its descriptions never show it.
struct StockSystemCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// The longest key accepted.
    static let maximumBytes = 4096

    let key: String

    /// Nil unless `raw`, trimmed, is 1–4096 visible ASCII characters with no space: a key is
    /// opaque, and anything else is a paste that went wrong (or a header injection).
    init?(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= Self.maximumBytes,
              key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        self.key = key
    }

    /// The last four characters, for an administrator only ("ends in …a1b2"). Never the key.
    var ending: String { String(key.suffix(4)) }

    var description: String { "StockSystemCredential(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["key": "redacted"], displayStyle: .struct) }
}

/// Why the transport refused to send. Each is a programming or configuration error, never
/// something to retry.
enum StockSystemTransportRefusal: Error, Equatable, Sendable {
    /// The destination's host is not one the adapter pins.
    case foreignHost
    /// The request's endpoint is not on the adapter's list.
    case offList
    /// The URL could not be made over HTTPS on the pinned host.
    case notHTTPS
    /// The system answered with a redirect. Redirects are never followed.
    case redirected
}

/// Sends one adapter-built request to a connection's pinned host, adding the key on the way out.
/// Tests use a fixture transport.
protocol StockSystemTransport: Sendable {
    func send(_ request: StockSystemRequest, to destination: StockSystemDestination,
              credential: StockSystemCredential) async throws -> StockSystemResponse
}

/// The one transport for every stock system's route (`NetworkRoute.owningTypes`): a dedicated
/// ephemeral session with no cookies, no cache and no stored credentials; redirects refused; only
/// the adapter's pinned hosts, over HTTPS; only the adapter's endpoints; the key added here as a
/// bearer header and never kept on the request; the reply capped at the adapter's size. The
/// medical guard is asked before every request, so a retry is asked again.
final class URLSessionStockSystemTransport: NSObject, StockSystemTransport, URLSessionTaskDelegate, @unchecked Sendable {

    /// Seconds before an idle request gives up, and before a whole request does.
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120
    /// The most reply headers kept, and the longest value.
    static let headerCap = 64
    static let headerValueCap = 1024

    private var session: URLSession!

    /// `configuration` is for tests (a stub protocol); its caching, cookies and credentials are
    /// switched off whatever it says.
    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        let config = configuration
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Ends the session and every request on it.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func send(_ request: StockSystemRequest, to destination: StockSystemDestination,
              credential: StockSystemCredential) async throws -> StockSystemResponse {
        try MedicalEgressGuard.check(destination.route)
        let urlRequest = try Self.urlRequest(request, to: destination, credential: credential)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw StockSystemFailure.malformedResponse }
            if (300..<400).contains(http.statusCode) {
                bytes.task.cancel()
                throw StockSystemTransportRefusal.redirected
            }
            guard http.url?.host == destination.host else {
                bytes.task.cancel()
                throw StockSystemTransportRefusal.foreignHost
            }
            let cap = destination.maximumResponseBytes
            if http.expectedContentLength > Int64(cap) {
                bytes.task.cancel()
                throw StockSystemFailure.tooLarge
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < cap else {
                    bytes.task.cancel()
                    throw StockSystemFailure.tooLarge
                }
                data.append(byte)
            }
            return StockSystemResponse(status: http.statusCode, body: data, headers: Self.headers(http))
        } catch let failure as StockSystemFailure {
            throw failure
        } catch let refusal as StockSystemTransportRefusal {
            throw refusal
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Offline, timed out, the host not found, TLS refused: no connection reached the system.
            throw StockSystemFailure.unreachable
        }
    }

    /// The request as it goes on the wire: the pinned host over HTTPS, the endpoint checked against
    /// the adapter's list again, the adapter's non-secret headers, and the key as a bearer header.
    /// Pure, so the checks are tested without a network.
    static func urlRequest(_ request: StockSystemRequest, to destination: StockSystemDestination,
                           credential: StockSystemCredential) throws -> URLRequest {
        guard destination.pinnedHosts.contains(destination.host),
              StockSystemDestination.isPlainHost(destination.host) else { throw StockSystemTransportRefusal.foreignHost }
        guard destination.allowedEndpoints.contains(request.endpoint) else { throw StockSystemTransportRefusal.offList }
        guard let url = request.url(host: destination.host), url.scheme == "https", url.host == destination.host,
              url.user == nil, url.password == nil, url.port == nil else { throw StockSystemTransportRefusal.notHTTPS }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = request.body
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("Bearer " + credential.key, forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    /// The reply's headers, for `Retry-After` and the like: string values only, capped, and never a
    /// cookie.
    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var kept: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard kept.count < headerCap, let name = name as? String, let value = value as? String,
                  name.lowercased() != "set-cookie", value.count <= headerValueCap else { continue }
            kept[name] = value
        }
        return kept
    }

    // MARK: - URLSessionTaskDelegate

    /// Never follow a redirect: the 3xx itself comes back, and `send` refuses it.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
