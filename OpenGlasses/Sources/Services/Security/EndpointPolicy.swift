import Foundation

/// One endpoint rule for every network client (roadmap W02.3).
///
/// `URLFetchGuard` already answers the server-side-request-forgery question for URLs that came from
/// untrusted input: it refuses private and reserved hosts outright. That is the right answer for a
/// scanned QR code and the wrong one for Home Assistant, an MCP server, or a Hermes bridge, which
/// live on the wearer's own LAN by design. So the rules are keyed on the route: private space is
/// reachable only by routes whose registry entry says `localNetwork` or `loopback`, and a route
/// cannot borrow another route's exception.
enum EndpointPolicy {

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case invalidURL(String)
        case missingHost
        case disallowedScheme(String)
        case credentialInURL
        case privateHostNotPermitted(host: String, route: NetworkRoute)
        case cleartextHTTPNotPermitted(host: String, route: NetworkRoute)

        var description: String {
            switch self {
            case .invalidURL(let raw):
                return "'\(raw)' is not a usable URL"
            case .missingHost:
                return "the URL has no host"
            case .disallowedScheme(let scheme):
                return "scheme '\(scheme.isEmpty ? "(none)" : scheme)' is not allowed (only http/https/ws/wss)"
            case .credentialInURL:
                return "the URL carries a username or password; put the credential in a header instead"
            case .privateHostNotPermitted(let host, let route):
                return "'\(host)' is on a private or reserved network and \(route.rawValue) is not a local-network route"
            case .cleartextHTTPNotPermitted(let host, let route):
                return "cleartext http to '\(host)' is not allowed for \(route.rawValue) in a release build"
            }
        }
    }

    enum BuildFlavor: Equatable {
        case debug
        case release

        static var current: Self {
            #if DEBUG
            .debug
            #else
            .release
            #endif
        }
    }

    // MARK: - Validation

    static func validate(_ urlString: String,
                         for route: NetworkRoute,
                         build: BuildFlavor = .current) -> Result<URL, Rejection> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            return .failure(.invalidURL(trimmed))
        }
        return validate(url: url, for: route, build: build)
    }

    static func validate(url: URL,
                         for route: NetworkRoute,
                         build: BuildFlavor = .current) -> Result<URL, Rejection> {
        // Websocket routes carry the same rules under a different scheme, so both spellings are
        // handled here rather than each socket client inventing its own check.
        let scheme = (url.scheme ?? "").lowercased()
        guard ["http", "https", "ws", "wss"].contains(scheme) else {
            return .failure(.disallowedScheme(scheme))
        }
        let isCleartext = scheme == "http" || scheme == "ws"
        // A credential in the URL is copied into logs, crash reports and Referer headers by
        // everything that touches it, so it is refused before anything else looks at the host.
        guard url.user == nil, url.password == nil else {
            return .failure(.credentialInURL)
        }
        guard let host = url.host, !host.isEmpty else {
            return .failure(.missingHost)
        }

        let isPrivate = URLFetchGuard.isBlockedHost(host)
        if isPrivate, !route.endpointClass.permitsPrivateNetwork {
            return .failure(.privateHostNotPermitted(host: host, route: route))
        }
        if isCleartext, build == .release {
            // Cleartext is tolerated only where the destination is provably the wearer's own
            // network. A `localNetwork` route pointed at a public host gets no exception.
            guard route.endpointClass.permitsCleartextHTTP, isPrivate else {
                return .failure(.cleartextHTTPNotPermitted(host: host, route: route))
            }
        }
        return .success(url)
    }

    /// Throwing form for call sites that already propagate errors.
    static func require(_ urlString: String,
                        for route: NetworkRoute,
                        build: BuildFlavor = .current) throws -> URL {
        switch validate(urlString, for: route, build: build) {
        case .success(let url): return url
        case .failure(let rejection): throw rejection
        }
    }

    static func require(url: URL,
                        for route: NetworkRoute,
                        build: BuildFlavor = .current) throws -> URL {
        switch validate(url: url, for: route, build: build) {
        case .success(let value): return value
        case .failure(let rejection): throw rejection
        }
    }

    /// Endpoint rule *and* medical local-only rule in one call, for the many clients that need
    /// both immediately before building their request.
    static func requireOpenable(url: URL,
                                for route: NetworkRoute,
                                build: BuildFlavor = .current) throws -> URL {
        try MedicalEgressGuard.check(route)
        return try require(url: url, for: route, build: build)
    }

    static func requireOpenable(_ urlString: String,
                                for route: NetworkRoute,
                                build: BuildFlavor = .current) throws -> URL {
        try MedicalEgressGuard.check(route)
        return try require(urlString, for: route, build: build)
    }
}
