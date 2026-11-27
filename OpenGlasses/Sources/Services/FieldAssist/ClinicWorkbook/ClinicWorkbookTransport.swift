import Foundation

// The transport the clinic's workbook rides (Plan NK §3), on MM's pattern: Microsoft's two hosts
// only, no redirect followed, the reply capped, the token in a header and never kept on the request
// or logged, and the medical guard asked before every request.

/// A reply, as the transport hands it back.
struct ClinicWorkbookResponse: Equatable, Sendable {
    let status: Int
    let body: Data
    /// Seconds from `Retry-After`, when the reply gave one.
    let retryAfter: TimeInterval?
}

/// Why the transport refused to send. Each is a programming error, never something to retry.
enum ClinicWorkbookTransportRefusal: Error, Equatable, Sendable {
    /// A host other than Microsoft's two.
    case foreignHost
    /// A request that is not one of the builder's shapes.
    case offList
    /// The URL could not be made over HTTPS.
    case notHTTPS
    /// The reply was a redirect. Redirects are never followed.
    case redirected
}

/// What went wrong reaching the workbook, as the screens and the queue read it.
enum ClinicWorkbookFailure: Error, Equatable, Sendable {
    /// The sign-in has expired or was withdrawn: sign in again.
    case unauthorized
    /// Signed in, and not allowed this file (or the administrator has not consented).
    case forbidden
    /// The workbook or a table is gone.
    case notFound
    case rateLimited(TimeInterval?)
    case server
    case malformedResponse
    case tooLarge
    /// No connection reached Microsoft.
    case unreachable

    static func from(status: Int, retryAfter: TimeInterval?) -> ClinicWorkbookFailure? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404, 410: return .notFound
        case 429: return .rateLimited(retryAfter)
        case 500..<600: return status == 503 || status == 504 ? .rateLimited(retryAfter) : .server
        default: return .malformedResponse
        }
    }

    var code: String {
        switch self {
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .rateLimited: return "rate_limited"
        case .server: return "server"
        case .malformedResponse: return "malformed_response"
        case .tooLarge: return "too_large"
        case .unreachable: return "unreachable"
        }
    }

    var sentence: String {
        switch self {
        case .unauthorized:
            return String(localized: "The sign-in to the clinic's Microsoft 365 has expired. Sign in again from the clinic's workbook settings.",
                          comment: "The clinic workbook sign-in needs renewing.")
        case .forbidden:
            return String(localized: "Microsoft 365 didn't allow this account to use the clinic's workbook. Ask the clinic's Microsoft 365 administrator to approve the app, and check the account can edit the workbook.",
                          comment: "The clinic workbook refused the signed-in account.")
        case .notFound:
            return String(localized: "The clinic's workbook, or one of its stock tables, can't be found. Choose the workbook again.",
                          comment: "The clinic workbook or a table is gone.")
        case .rateLimited, .server, .unreachable:
            return String(localized: "Microsoft 365 can't be reached just now. The rows wait on this phone and go when it can.",
                          comment: "The clinic workbook is out of reach for now.")
        case .malformedResponse:
            return String(localized: "Microsoft 365 sent a reply the app couldn't read. Nothing more was sent.",
                          comment: "The clinic workbook sent an unreadable reply.")
        case .tooLarge:
            return String(localized: "Microsoft 365 sent more than the app reads at once. Nothing more was sent.",
                          comment: "The clinic workbook sent too large a reply.")
        }
    }
}

/// Sends one builder-made request to Microsoft. Tests use a fixture transport.
protocol ClinicWorkbookTransport: Sendable {
    /// `bearer` goes in the `Authorization` header of a request to Graph, and never to the sign-in
    /// host. `workbook` is the one the connection is on: a request naming any other is refused.
    func send(_ request: GraphRequest, bearer: String?, workbook: GraphWorkbook?) async throws -> ClinicWorkbookResponse
}

/// The one transport for `NetworkRoute.clinicStockRecord`: a dedicated ephemeral session with no
/// cookies, no cache and no stored credentials; redirects refused; `graph.microsoft.com` and
/// `login.microsoftonline.com` only, over HTTPS; only the builder's shapes; the reply capped.
final class URLSessionClinicWorkbookTransport: NSObject, ClinicWorkbookTransport, URLSessionTaskDelegate, @unchecked Sendable {

    static let hosts: Set<String> = [GraphRequestBuilder.host, EntraOAuth.loginHost]
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120
    /// The most bytes one reply may be: a page of 500 rows is well under this.
    static let maximumResponseBytes = 2 * 1024 * 1024

    private var session: URLSession!

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

    func invalidate() {
        session.invalidateAndCancel()
    }

    func send(_ request: GraphRequest, bearer: String?, workbook: GraphWorkbook?) async throws -> ClinicWorkbookResponse {
        try MedicalEgressGuard.check(.clinicStockRecord)
        let urlRequest = try Self.urlRequest(request, bearer: bearer, workbook: workbook)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ClinicWorkbookFailure.malformedResponse }
            if (300..<400).contains(http.statusCode) {
                bytes.task.cancel()
                throw ClinicWorkbookTransportRefusal.redirected
            }
            guard http.url?.host == request.host else {
                bytes.task.cancel()
                throw ClinicWorkbookTransportRefusal.foreignHost
            }
            if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
                bytes.task.cancel()
                throw ClinicWorkbookFailure.tooLarge
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw ClinicWorkbookFailure.tooLarge
                }
                data.append(byte)
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            return ClinicWorkbookResponse(status: http.statusCode, body: data, retryAfter: retryAfter.map { min(max($0, 0), 3600) })
        } catch let failure as ClinicWorkbookFailure {
            throw failure
        } catch let refusal as ClinicWorkbookTransportRefusal {
            throw refusal
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ClinicWorkbookFailure.unreachable
        }
    }

    /// The request as it goes on the wire. Pure, so every check is tested without a network:
    /// Microsoft's two hosts over HTTPS; on Graph only the builder's shapes on the one workbook,
    /// with the token as a bearer header; on the sign-in host only the token request, with no
    /// bearer at all.
    static func urlRequest(_ request: GraphRequest, bearer: String?, workbook: GraphWorkbook?) throws -> URLRequest {
        guard hosts.contains(request.host) else { throw ClinicWorkbookTransportRefusal.foreignHost }
        if request.host == GraphRequestBuilder.host {
            guard GraphRequestBuilder.isAllowed(request, workbook: workbook) else { throw ClinicWorkbookTransportRefusal.offList }
        } else {
            guard EntraOAuth.isTokenRequest(request) else { throw ClinicWorkbookTransportRefusal.offList }
        }
        guard let url = request.url, url.scheme == "https", url.host == request.host, url.user == nil,
              url.password == nil, url.port == nil else { throw ClinicWorkbookTransportRefusal.notHTTPS }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: requestTimeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType = request.contentType { urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if request.host == GraphRequestBuilder.host, let bearer {
            guard ClinicWorkbookBearer.isSendable(bearer) else { throw ClinicWorkbookTransportRefusal.offList }
            urlRequest.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A token is sent only if it is plain visible ASCII with no space: anything else is a corrupted
/// store or a header injection.
enum ClinicWorkbookBearer {
    static func isSendable(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384 && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
