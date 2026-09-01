import Foundation
import os.lock

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

/// How a server authenticates. `bearer` reuses the static-header path that ships today; `header`
/// is the same static-header path under a custom header name (e.g. `X-API-Key`) for servers that
/// don't speak `Authorization: Bearer` (BM P6 — the transport always applied arbitrary headers,
/// only the catalogue couldn't express it); `oauth` is reserved for the deferred device-code /
/// PKCE flow (Plan V) — a one-tap OAuth install currently prefills the editor so the user can
/// paste a token they obtained out-of-band. `none` is an unauthenticated server.
enum MCPAuthKind: String, Codable, CaseIterable, Identifiable {
    case none, bearer, oauth, header

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:   return "None"
        case .bearer: return "Bearer token"
        case .oauth:  return "OAuth"
        case .header: return "API-key header"
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

/// The shipped transport: Streamable HTTP (JSON-RPC over HTTP POST) with the MCP session
/// lifecycle. On first contact with a server it performs the MCP handshake (`initialize` →
/// `notifications/initialized`) and captures the `mcp-session-id` header; subsequent requests
/// carry that header. Responses may arrive as plain JSON (`application/json`) or SSE-framed
/// (`text/event-stream` — FastMCP and the official TS server always frame POST responses this
/// way), so the JSON-RPC payload is unwrapped via `SSEEventParser` before it's returned; callers
/// always receive raw JSON `Data`. Servers that implement neither (bare single-POST endpoints,
/// e.g. Home Assistant's) still work: a failed handshake marks the server "no session" and the
/// request proceeds exactly as before.
///
/// The `session` is injectable purely so tests can stub `URLProtocol`; production uses `.shared`.
struct HTTPTransport: MCPTransport {
    var session: URLSession = .shared

    /// Per-server MCP session IDs, `static` so they survive across the per-request instances that
    /// `MCPTransportFactory` creates. Empty string means "initialized, server doesn't use
    /// sessions"; absent key means "not yet initialized".
    ///
    /// Lock-guarded, **not** actor-isolated: `MCPTransport.request` is a `nonisolated async`
    /// requirement on a non-isolated struct, so it runs on the cooperative pool even though every
    /// caller goes through the `@MainActor` `MCPClient` — an `async` call does not inherit the
    /// caller's actor. Two turns with requests in flight (a voice tool call and a Settings-driven
    /// `discoverAllTools`), or `MCPClient.updateServer` calling `resetSessions()` from the main
    /// actor mid-request, would otherwise mutate the dictionary concurrently.
    private static let sessionStore = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Clear cached sessions (test support, and `MCPClient` calls it when a server's config
    /// changes so a rotated token re-handshakes).
    static func resetSessions() { sessionStore.withLock { $0.removeAll() } }

    /// The cached session ID for a server: `nil` = never initialized, `""` = initialized and the
    /// server doesn't use sessions.
    private static func session(for serverID: String) -> String? {
        sessionStore.withLock { $0[serverID] }
    }

    private static func setSession(_ sessionID: String, for serverID: String) {
        sessionStore.withLock { $0[serverID] = sessionID }
    }

    private static func clearSession(for serverID: String) {
        sessionStore.withLock { $0[serverID] = nil }
    }

    func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data {
        // First contact with this server: run the MCP initialize handshake.
        if Self.session(for: server.id) == nil {
            await initializeSession(server: server)
        }

        let sessionID = Self.session(for: server.id)
        let (data, response) = try await sendHTTP(payload, server: server, sessionID: sessionID)
        guard let httpResponse = response as? HTTPURLResponse else { return data }

        // 400/406 while we hold no real session → the server requires the MCP session
        // lifecycle (a previous handshake failed or expired). Re-initialize and retry once.
        if (httpResponse.statusCode == 400 || httpResponse.statusCode == 406), (sessionID ?? "").isEmpty {
            Self.clearSession(for: server.id)
            await initializeSession(server: server)
            let (retryData, retryResponse) = try await sendHTTP(payload, server: server,
                                                                sessionID: Self.session(for: server.id))
            if let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode >= 400 {
                let body = String(data: retryData, encoding: .utf8) ?? ""
                throw MCPTransportError.http(status: retryHTTP.statusCode, body: String(body.prefix(200)))
            }
            return extractJSON(from: retryData, response: retryResponse, payload: payload)
        }

        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPTransportError.http(status: httpResponse.statusCode, body: String(body.prefix(200)))
        }

        // Capture a session ID from any successful response (a server may mint one late).
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "mcp-session-id") {
            Self.setSession(newSessionID, for: server.id)
        }

        return extractJSON(from: data, response: response, payload: payload)
    }

    // MARK: - MCP session handshake

    /// `initialize` → `notifications/initialized`. On failure the server is marked "no session
    /// needed" so the real request still goes through — simple MCP servers skip the lifecycle.
    private func initializeSession(server: MCPServerConfig) async {
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "OpenGlasses", "version": "1.0"] as [String: Any],
            ] as [String: Any],
        ]
        do {
            let (_, response) = try await sendHTTP(initPayload, server: server, sessionID: nil)
            let sessionID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "mcp-session-id") ?? ""
            Self.setSession(sessionID, for: server.id)   // "" = server doesn't use sessions

            // Fire-and-forget; a server that returned a session expects this before real calls.
            let notifPayload: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
            _ = try? await sendHTTP(notifPayload, server: server,
                                    sessionID: sessionID.isEmpty ? nil : sessionID)
        } catch {
            Self.setSession("", for: server.id)
            PrivacyLog.mcpFailed(.sessionInit, server: PrivateIdentifier(server.id),
                                 SafeErrorSummary(error))
        }
    }

    // MARK: - HTTP

    private func sendHTTP(_ payload: [String: Any], server: MCPServerConfig,
                          sessionID: String?) async throws -> (Data, URLResponse) {
        guard !server.url.isEmpty, let url = URL(string: server.url) else {
            throw MCPTransportError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // MCP Streamable HTTP requires the client to accept both response framings.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "mcp-session-id")
        }

        // Auth headers (e.g. Authorization: Bearer …) are applied identically for every transport.
        for (key, value) in server.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 15
        return try await session.data(for: request)
    }

    // MARK: - SSE response unwrapping

    /// If the server answered in `text/event-stream` framing, pull the JSON-RPC response out of
    /// the SSE events — matched to the request's `id` where possible (a stream can interleave
    /// notifications before the response), else the first event. Plain JSON passes through.
    private func extractJSON(from data: Data, response: URLResponse, payload: [String: Any]) -> Data {
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("text/event-stream"),
              let body = String(data: data, encoding: .utf8) else { return data }
        let events = SSEEventParser.parse(body)
        if let rpcID = payload["id"] as? Int,
           let matched = SSEEventParser.jsonRPCResponse(in: events, id: rpcID) {
            return matched
        }
        if let first = events.first, let jsonData = first.data.data(using: .utf8) {
            return jsonData
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
