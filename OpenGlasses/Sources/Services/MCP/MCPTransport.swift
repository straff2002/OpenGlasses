import Foundation

/// The wire transport a server speaks. The catalogue and editor pick one; `MCPClient` selects the
/// matching `MCPTransport` conformer at request time (`MCPTransportFactory`). Today only `.http`
/// has a live network path — `.sse` framing is shipped and unit-tested (`SSEEventParser`) but its
/// streaming initialize-handshake is deferred (Plan V). Keeping the kind on the config now means a
/// catalogue entry's transport is captured at install time and ready when the SSE path lands.
enum MCPTransportKind: String, Codable, CaseIterable, Identifiable {
    case http   // JSON-RPC over a single HTTP POST (Streamable HTTP) — the shipped path
    case sse    // Server-Sent Events stream with a session handshake — framing shipped, streaming deferred

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http: return "HTTP (Streamable)"
        case .sse:  return "SSE (Server-Sent Events)"
        }
    }

    /// Whether a live network round-trip is wired today. `.sse` is `false` until the streaming
    /// handshake lands; the UI uses this to warn before installing an SSE-only server.
    var isLive: Bool { self == .http }
}

/// How a server authenticates. `bearer` reuses the static-header path that ships today; `oauth` is
/// reserved for the deferred device-code / PKCE flow (Plan V) — a one-tap OAuth install currently
/// prefills the editor so the user can paste a token they obtained out-of-band. `none` is an
/// unauthenticated server.
enum MCPAuthKind: String, Codable, CaseIterable, Identifiable {
    case none, bearer, oauth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:   return "None"
        case .bearer: return "Bearer token"
        case .oauth:  return "OAuth"
        }
    }

    /// Whether sign-in is fully automated today. OAuth automation is deferred, so `oauth` is `false`.
    var isAutomated: Bool { self != .oauth }
}

/// Abstracts the network shape of a single MCP JSON-RPC round-trip, so `MCPClient.discoverTools` /
/// `performCall` — and the Plan R egress screen / inbound framing wrapped around them — stay
/// transport-agnostic. One indirection point means the safety screen lives in exactly one place
/// regardless of how the bytes reach the server. See [[EgressScreen]] / [[ToolDefinitionScanner]].
protocol MCPTransport {
    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data
}

/// Errors surfaced by a transport. Callers in `MCPClient` use `try?` and treat any throw as a
/// failed round-trip (the existing behaviour), so the specific case only matters for logging/UI.
enum MCPTransportError: LocalizedError, Equatable {
    case badURL
    case notYetSupported(MCPTransportKind)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The server URL is not valid."
        case .notYetSupported(let kind):
            return "\(kind.label) transport is not wired for live calls yet."
        case .http(let status, let body):
            return "Server returned HTTP \(status): \(body)"
        }
    }
}

/// The shipped transport: one JSON-RPC request over an HTTP POST (Streamable HTTP). This is a
/// byte-for-byte lift of the original inline `MCPClient.mcpRequest` — same method, headers, 15s
/// timeout, and ≥400 → throw — so extracting it is a pure refactor with no behaviour change. The
/// `session` is injectable purely so tests can stub `URLProtocol`; production uses `.shared`.
struct HTTPTransport: MCPTransport {
    var session: URLSession = .shared

    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data {
        guard let url = URL(string: server.url) else {
            throw MCPTransportError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth headers (e.g. Authorization: Bearer …) are applied identically for every transport.
        for (key, value) in server.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPTransportError.http(status: httpResponse.statusCode, body: String(body.prefix(200)))
        }
        return data
    }
}

/// Placeholder for the SSE transport while its live streaming handshake is deferred (Plan V). It
/// throws `notYetSupported`, so selecting an SSE server fails cleanly (the model is told the call
/// didn't go through) rather than silently doing nothing. The deterministic `SSEEventParser` that
/// the real transport will build on ships and is unit-tested in this PR.
struct SSEUnavailableTransport: MCPTransport {
    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data {
        throw MCPTransportError.notYetSupported(.sse)
    }
}

/// Maps a `MCPTransportKind` to its conformer. The single place that knows which transports are
/// live; `MCPClient.mcpRequest` calls through here so HTTP stays unchanged and SSE slots in later
/// by replacing `SSEUnavailableTransport` with the real streaming conformer.
enum MCPTransportFactory {
    static func transport(for kind: MCPTransportKind) -> MCPTransport {
        switch kind {
        case .http: return HTTPTransport()
        case .sse:  return SSEUnavailableTransport()
        }
    }
}
