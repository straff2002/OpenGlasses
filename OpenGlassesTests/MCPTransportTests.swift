import XCTest
@testable import OpenGlasses

/// Tests for the Plan V transport layer: the `MCPTransportKind`/`MCPAuthKind` config fields with
/// backward-compatible decoding, `HTTPTransport` request building (via a stubbed `URLProtocol`), and
/// the transport factory's selection (including the deferred-SSE clean failure).
final class MCPTransportTests: XCTestCase {

    // MARK: - Config fields + backward compatibility

    func testServerConfigDefaultsTransportAndAuthKind() {
        let config = MCPServerConfig(id: "a", label: "L", url: "http://h/mcp", headers: [:], enabled: true)
        XCTAssertEqual(config.transport, .http)
        XCTAssertEqual(config.authKind, .bearer)
    }

    func testLegacyConfigDecodeDefaultsNewKeys() throws {
        // A server persisted before Plan R/V: no policy, transport, or authKind keys.
        let legacy = Data(#"{"id":"x","label":"Old","url":"http://h/mcp","headers":{},"enabled":true}"#.utf8)
        let config = try JSONDecoder().decode(MCPServerConfig.self, from: legacy)
        XCTAssertEqual(config.policy, .redact)      // Plan R default preserved
        XCTAssertEqual(config.transport, .http)     // Plan V default
        XCTAssertEqual(config.authKind, .bearer)
        XCTAssertEqual(config.label, "Old")
    }

    func testConfigRoundTripPreservesTransportAndAuth() throws {
        let original = MCPServerConfig(id: "s", label: "Linear", url: "https://mcp.linear.app/sse",
                                       headers: ["Authorization": "Bearer t"], enabled: true,
                                       policy: .block, transport: .sse, authKind: .oauth)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded.transport, .sse)
        XCTAssertEqual(decoded.authKind, .oauth)
        XCTAssertEqual(decoded.policy, .block)
    }

    func testTransportKindAndAuthKindLivenessFlags() {
        XCTAssertTrue(MCPTransportKind.http.isLive)
        XCTAssertFalse(MCPTransportKind.sse.isLive)
        XCTAssertTrue(MCPAuthKind.bearer.isAutomated)
        XCTAssertFalse(MCPAuthKind.oauth.isAutomated)
    }

    // MARK: - Transport factory selection

    func testFactorySelectsHTTPForHTTPKind() {
        XCTAssertTrue(MCPTransportFactory.transport(for: .http) is HTTPTransport)
    }

    func testFactorySSEIsDeferredAndFailsCleanly() async {
        let transport = MCPTransportFactory.transport(for: .sse)
        XCTAssertTrue(transport is SSEUnavailableTransport)
        let server = MCPServerConfig(id: "s", label: "Linear", url: "https://mcp.linear.app/sse",
                                     headers: [:], enabled: true, transport: .sse)
        do {
            _ = try await transport.request(["jsonrpc": "2.0"], server: server)
            XCTFail("expected SSE transport to throw notYetSupported")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .notYetSupported(.sse))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - HTTPTransport request building (URLProtocol stub)

    func testHTTPTransportBuildsExpectedRequest() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)

        let server = MCPServerConfig(id: "s", label: "Notion", url: "https://example.test/mcp",
                                     headers: ["Authorization": "Bearer secret-token"], enabled: true)
        let transport = HTTPTransport(session: MockURLProtocol.session())

        let data = try await transport.request(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], server: server)

        // Response is returned unchanged.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((json?["result"] as? [String: Any])?["ok"] as? Bool, true)

        // The outbound request matches the original inline behaviour: POST, JSON content type,
        // auth header applied, and the payload serialised into the body.
        let captured = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.absoluteString, "https://example.test/mcp")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let sentPayload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(sentPayload?["method"] as? String, "tools/list")
    }

    func testHTTPTransportThrowsOnBadURL() async {
        let server = MCPServerConfig(id: "s", label: "Bad", url: "", headers: [:], enabled: true)
        do {
            _ = try await HTTPTransport().request([:], server: server)
            XCTFail("expected badURL")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .badURL)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - MCP session handshake + SSE framing (Streamable HTTP)

    func testFirstRequestPerformsInitializeHandshake() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)

        let server = MCPServerConfig(id: "hs", label: "FastMCP", url: "https://example.test/mcp",
                                     headers: [:], enabled: true)
        let transport = HTTPTransport(session: MockURLProtocol.session())
        _ = try await transport.request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], server: server)

        // initialize + notifications/initialized + the real payload.
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
        // Streamable HTTP requires accepting both response framings on every request.
        let captured = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")

        // Second request on the same server reuses the session — no re-handshake.
        _ = try await transport.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], server: server)
        XCTAssertEqual(MockURLProtocol.requestCount, 4)
    }

    func testSessionIDFromInitializeIsSentOnSubsequentRequests() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.responseBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#.utf8)
        MockURLProtocol.responseHeaders = ["mcp-session-id": "sess-123"]

        let server = MCPServerConfig(id: "sid", label: "Sessioned", url: "https://example.test/mcp",
                                     headers: [:], enabled: true)
        let transport = HTTPTransport(session: MockURLProtocol.session())
        _ = try await transport.request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], server: server)

        let captured = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "mcp-session-id"), "sess-123",
                       "the session minted at initialize rides every later request")
    }

    func testSSEFramedResponseIsUnwrappedToJSON() async throws {
        MockURLProtocol.reset()
        // FastMCP frames POST responses as SSE even for a single JSON-RPC reply.
        MockURLProtocol.responseHeaders = ["Content-Type": "text/event-stream"]
        MockURLProtocol.responseBody = Data(
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"tools\":[]}}\n\n".utf8)

        let server = MCPServerConfig(id: "sse-framed", label: "FastMCP", url: "https://example.test/mcp",
                                     headers: [:], enabled: true)
        let transport = HTTPTransport(session: MockURLProtocol.session())
        let data = try await transport.request(["jsonrpc": "2.0", "id": 7, "method": "tools/list"], server: server)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 7, "caller receives the unwrapped JSON-RPC payload, not SSE framing")
        XCTAssertNotNil((json["result"] as? [String: Any])?["tools"])
    }

    func testHTTPTransportThrowsOnHTTPError() async {
        MockURLProtocol.reset()
        MockURLProtocol.statusCode = 503
        MockURLProtocol.responseBody = Data("upstream down".utf8)

        let server = MCPServerConfig(id: "s", label: "Down", url: "https://example.test/mcp",
                                     headers: [:], enabled: true)
        let transport = HTTPTransport(session: MockURLProtocol.session())
        do {
            _ = try await transport.request(["x": 1], server: server)
            XCTFail("expected http error to throw")
        } catch let error as MCPTransportError {
            guard case .http(let status, _) = error else { return XCTFail("expected .http, got \(error)") }
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

/// Records the outbound request and returns a canned response, so `HTTPTransport` can be exercised
/// headlessly with no network. Reads the body from the HTTP body stream (URLSession routes
/// `httpBody` through a stream by the time a `URLProtocol` sees it).
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    /// Every request in order, with its body — so a test can assert *which* endpoint a reply went
    /// to, not just that the last one looked right (Plan FE P1).
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data?)] = []
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]
    nonisolated(unsafe) static var requestCount = 0

    /// One scripted answer. `failure` makes the request fail at the transport layer, the way a
    /// dropped connection does — which no status code can express.
    struct Scripted {
        var statusCode = 200
        var body = Data("{}".utf8)
        var failure: Error?

        static func json(_ text: String) -> Scripted { Scripted(body: Data(text.utf8)) }
        static func http(_ code: Int, _ body: String = "") -> Scripted {
            Scripted(statusCode: code, body: Data(body.utf8))
        }
        static var networkFailure: Scripted {
            Scripted(failure: URLError(.notConnectedToInternet))
        }
        /// A request that left the device and never came back — the uncertain-delivery case, which
        /// no status code can express (Plan FE P1).
        static var timeout: Scripted {
            Scripted(failure: URLError(.timedOut))
        }
    }

    /// Answers consumed in request order; the last entry repeats for every further request. Empty
    /// falls back to the single `statusCode`/`responseBody` pair.
    nonisolated(unsafe) static var script: [Scripted] = []

    static func reset() {
        lastRequest = nil
        lastBody = nil
        responseBody = Data("{}".utf8)
        statusCode = 200
        responseHeaders = [:]
        requestCount = 0
        requests = []
        script = []
        HTTPTransport.resetSessions()   // the session cache is static — isolate tests
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lastRequest = request
        MockURLProtocol.lastBody = Self.readBody(from: request)
        MockURLProtocol.requests.append((request, MockURLProtocol.lastBody))
        MockURLProtocol.requestCount += 1

        let scripted = MockURLProtocol.script.isEmpty
            ? nil
            : MockURLProtocol.script[min(MockURLProtocol.requestCount - 1, MockURLProtocol.script.count - 1)]
        if let failure = scripted?.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        var headers = ["Content-Type": "application/json"]
        headers.merge(MockURLProtocol.responseHeaders) { _, new in new }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: scripted?.statusCode ?? MockURLProtocol.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: scripted?.body ?? MockURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Server config lifecycle (issue #246)

/// A config change must invalidate what was discovered under the OLD config — a rotated token
/// otherwise kept serving stale tool definitions until force-quit, and a disabled server's
/// tools stayed callable.
final class MCPServerLifecycleTests: XCTestCase {

    /// Hermetic transport: every request answers an empty tools/list, so updateServer's
    /// re-discovery Task never touches the network.
    private struct EmptyToolsTransport: MCPTransport {
        func request(_ payload: [String: Any], server: MCPServerConfig) async throws -> Data {
            Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8)
        }
    }

    @MainActor
    private func makeClient() -> (MCPClient, MCPServerConfig, MCPServerConfig) {
        let client = MCPClient()
        client.transportOverride = EmptyToolsTransport()
        let a = MCPServerConfig(id: "a", label: "Alpha", url: "http://a/mcp",
                                headers: ["Authorization": "Bearer old-token"], enabled: true)
        let b = MCPServerConfig(id: "b", label: "Beta", url: "http://b/mcp", headers: [:], enabled: true)
        client.servers = [a, b]
        client.discoveredTools = [
            MCPTool(name: "t1", description: "d", inputSchema: [:], serverId: "a", serverLabel: "Alpha"),
            MCPTool(name: "t2", description: "d", inputSchema: [:], serverId: "b", serverLabel: "Beta"),
        ]
        return (client, a, b)
    }

    @MainActor
    func testTokenRotationDropsThatServersToolsOnly() {
        let (client, a, _) = makeClient()
        var updated = a
        updated.headers = ["Authorization": "Bearer new-token"]
        client.updateServer(updated)
        XCTAssertFalse(client.discoveredTools.contains { $0.serverId == "a" },
                       "tools discovered under the old token must not survive a rotation")
        XCTAssertTrue(client.discoveredTools.contains { $0.serverId == "b" },
                      "other servers' tools are untouched")
        XCTAssertEqual(client.servers.first { $0.id == "a" }?.headers["Authorization"], "Bearer new-token")
    }

    @MainActor
    func testDisablingDropsToolsSoTheyAreNoLongerCallable() {
        let (client, a, _) = makeClient()
        var updated = a
        updated.enabled = false
        client.updateServer(updated)
        XCTAssertFalse(client.discoveredTools.contains { $0.serverId == "a" },
                       "a disabled server's tools must leave the offered set")
    }

    @MainActor
    func testLabelOnlyChangeKeepsDiscoveredTools() {
        let (client, a, _) = makeClient()
        var updated = a
        updated.label = "Alpha Renamed"
        client.updateServer(updated)
        XCTAssertTrue(client.discoveredTools.contains { $0.serverId == "a" },
                      "a cosmetic rename must not force re-discovery")
    }

    @MainActor
    func testRemoveServerDropsItsTools() {
        let (client, _, _) = makeClient()
        client.removeServer(id: "a")
        XCTAssertFalse(client.discoveredTools.contains { $0.serverId == "a" })
        XCTAssertNil(client.server(id: "a"))
    }
}
