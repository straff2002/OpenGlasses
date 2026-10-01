import Foundation

/// The one check that decides the connection is really back (Plan GE P1).
///
/// A `HEAD` to the origin of the cloud model's own host — a host the app already talks to on every
/// turn, so no new third party learns anything. The request carries no user content, no path, no
/// credentials and no cookies; any HTTP response at all (a 404 or 405 included) proves the host is
/// reachable, and only a transport failure counts as "still offline". Route:
/// `NetworkRoute.connectivityProbe` (telemetry-free), refused under medical local-only like every
/// other route — the handoff is inert there anyway.
struct ConnectivityProbe {

    /// The probe target for a cloud model: the origin of its endpoint. Nil for an on-device model
    /// or an endpoint that cannot be parsed — the caller then trusts the stable path alone.
    static func probeURL(for config: ModelConfig?) -> URL? {
        guard let config else { return nil }
        let provider = config.llmProvider
        guard provider != .local, provider != .appleOnDevice else { return nil }
        let raw: String
        if provider == .geminiVertex {
            raw = "https://aiplatform.googleapis.com"
        } else {
            let configured = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            raw = configured.isEmpty ? provider.defaultBaseURL : configured
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = url.port
        origin.path = "/"
        return origin.url
    }

    /// The request the probe sends: origin only, `HEAD`, nothing stored, nothing cached.
    static func request(for url: URL, timeout: TimeInterval = 8) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        return request
    }

    enum Outcome: Equatable {
        case reachable
        case unreachable
        /// There is nothing safe to probe (no cloud host, a private or rejected endpoint, or the
        /// route refused). The caller trusts the stable path window alone rather than staying on
        /// the phone forever.
        case notProbeable
    }

    /// Whether `url` answered at all. Any HTTP status is reachable; a transport error is not.
    static func probe(_ url: URL?, timeout: TimeInterval = 8) async -> Outcome {
        guard let url, MedicalEgressGuard.allows(.connectivityProbe),
              case .success = EndpointPolicy.validate(url: url, for: .connectivityProbe)
        else { return .notProbeable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request(for: url, timeout: timeout))
            return response is HTTPURLResponse ? .reachable : .unreachable
        } catch {
            return .unreachable
        }
    }
}
