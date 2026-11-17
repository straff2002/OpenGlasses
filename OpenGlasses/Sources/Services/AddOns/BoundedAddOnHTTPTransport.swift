import Foundation

/// A transport failure the add-on sandbox can name, rather than calling every failure `network`.
enum AddOnTransportError: Error, Equatable, Sendable {
    case tooLarge
    case unsupportedType
    case timeout
    /// The name resolved to a private, loopback or reserved address: refused at connect time.
    case addressRefused

    /// The `<as>.error` value a recipe sees.
    var recipeCode: String {
        switch self {
        case .tooLarge: return "too_large"
        case .unsupportedType: return "unsupported_type"
        case .timeout: return "timeout"
        case .addressRefused: return "host_not_allowed"
        }
    }
}

/// The production network edge of the add-on runner (Plan GF P2), over the hardened client.
///
/// What it adds to the sandbox's own rules is everything that needs a socket: one DNS resolution
/// per request with every address classified, so a name on the add-on's allowlist that resolves
/// to a private, loopback or LAN address is refused (DNS rebinding included); TLS verified against
/// the hostname; no cookies, no cache, no credentials, the app's own `User-Agent`; a byte cap and
/// deadlines per request. Redirects are **not** followed here — `send` makes exactly one hop and a
/// 3xx comes back with its `Location`, so the sandbox checks every hop against the allowlist.
///
/// Medical Compliance's Local Only mode refuses the route at the request edge, whatever the
/// registry did: `NetworkRoute.recipeAddOn` is blocked when local-only.
struct BoundedAddOnHTTPTransport: AddOnHTTPTransport {

    /// Built per request so no client state is shared between runs.
    var makeClient: @Sendable () -> BoundedHTTPClient = { BoundedHTTPClient() }

    func send(_ request: AddOnHTTPRequest) async throws -> AddOnHTTPResponse {
        try MedicalEgressGuard.check(.recipeAddOn)
        let profile = BoundedHTTPClient.Profile.recipeAddOnStep(timeout: request.timeout,
                                                                maximumBytes: request.maxResponseBytes)
        let collector = BodyCollector()
        let response: BoundedHTTPClient.Response
        do {
            response = try await makeClient().send(
                .init(method: request.method, url: request.url, headers: request.headers, body: request.body),
                profile: profile) { chunk in collector.append(chunk) }
        } catch let error as BoundedHTTPClient.ClientError {
            throw Self.mapped(error)
        }
        let mime = response.headers["content-type"]?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return AddOnHTTPResponse(status: response.statusCode, mimeType: mime, body: collector.data,
                                 location: response.headers["location"])
    }

    static func mapped(_ error: BoundedHTTPClient.ClientError) -> Error {
        switch error {
        case .responseTooLarge: return AddOnTransportError.tooLarge
        case .unacceptableMIMEType, .unsupportedContentEncoding: return AddOnTransportError.unsupportedType
        case .timeout, .firstByteTimeout, .idleTimeout: return AddOnTransportError.timeout
        case .disallowedAddress, .mixedAddressPolicy: return AddOnTransportError.addressRefused
        default: return error
        }
    }
}

/// Collects one response's body as the client streams it.
private final class BodyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
    var data: Data { lock.withLock { bytes } }
}
