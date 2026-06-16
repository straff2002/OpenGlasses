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
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var statusCode = 200

    static func reset() {
        lastRequest = nil
        lastBody = nil
        responseBody = Data("{}".utf8)
        statusCode = 200
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

        let response = HTTPURLResponse(
            url: request.url!, statusCode: MockURLProtocol.statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockURLProtocol.responseBody)
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
