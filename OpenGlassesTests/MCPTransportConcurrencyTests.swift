import XCTest
import os.lock
@testable import OpenGlasses

/// Concurrency guards for `HTTPTransport`'s process-wide MCP session cache.
///
/// `MCPTransport.request` is a `nonisolated async` requirement on a non-isolated struct, so it runs
/// on the cooperative pool even though every caller goes through the `@MainActor` `MCPClient` — an
/// `async` call does not inherit its caller's actor. Concurrent turns (a voice tool call alongside a
/// Settings-driven `discoverAllTools`), and `MCPClient.updateServer` calling `resetSessions()`
/// mid-flight, therefore reach the cache from several threads at once.
///
/// These tests exercise that access pattern for real. The correctness assertion is per-server
/// session attribution — a cache that tore under concurrent mutation would cross wires between
/// servers or lose entries. Run under the Thread Sanitizer to also catch the raw data race.
@MainActor
final class MCPTransportConcurrencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionEchoURLProtocol.reset()
        HTTPTransport.resetSessions()
    }

    override func tearDown() {
        HTTPTransport.resetSessions()
        super.tearDown()
    }

    private func server(_ index: Int) -> MCPServerConfig {
        MCPServerConfig(id: "server-\(index)", label: "S\(index)",
                        url: "http://s\(index).test/mcp", headers: [:], enabled: true)
    }

    // MARK: - Concurrent access

    /// Many servers handshaking at once — the shape a parallel discovery or two overlapping turns
    /// produce. Every server must end up with its *own* session ID.
    func testConcurrentRequestsKeepPerServerSessionsDistinct() async throws {
        let count = 16
        let transport = HTTPTransport(session: SessionEchoURLProtocol.session(), processingConsent: CloudConsentFixture.conversation(origins: (0..<16).map { "http://s\($0).test" }))
        let servers = (0..<count).map(server)

        await withTaskGroup(of: Void.self) { group in
            for config in servers {
                group.addTask { _ = try? await transport.request(["id": 1], server: config) }
            }
        }

        // Second round: sessions are cached now, so each request must carry the session its own
        // server minted. A torn cache shows up here as a missing or cross-wired ID.
        await withTaskGroup(of: Void.self) { group in
            for config in servers {
                group.addTask { _ = try? await transport.request(["id": 2], server: config) }
            }
        }

        for index in 0..<count {
            XCTAssertEqual(SessionEchoURLProtocol.lastSessionHeader(forHost: "s\(index).test"),
                           "sid-s\(index).test",
                           "server \(index) sent the wrong cached session ID")
        }
    }

    /// `MCPClient.updateServer` resets the cache from the main actor while requests are in flight
    /// off-actor. The interleaving is inherently racy in outcome — what must hold is that it stays
    /// memory-safe and every request still completes.
    func testResetSessionsDuringInFlightRequestsIsSafe() async {
        let transport = HTTPTransport(session: SessionEchoURLProtocol.session(), processingConsent: CloudConsentFixture.conversation(origins: (0..<16).map { "http://s\($0).test" }))
        let completed = OSAllocatedUnfairLock(initialState: 0)
        // Four servers, three requests each — so the same cache entries are contended, not just
        // disjoint keys.
        let servers = (0..<12).map { server($0 % 4) }

        await withTaskGroup(of: Void.self) { group in
            for config in servers {
                group.addTask {
                    _ = try? await transport.request(["id": 1], server: config)
                    completed.withLock { $0 += 1 }
                }
            }
            for _ in 0..<8 {
                group.addTask { HTTPTransport.resetSessions() }
            }
        }

        XCTAssertEqual(completed.withLock { $0 }, 12, "every in-flight request should complete")
    }

    // MARK: - Attribution under sequential access (regression guard for the accessor refactor)

    func testSessionIsScopedToItsOwnServer() async throws {
        let transport = HTTPTransport(session: SessionEchoURLProtocol.session(), processingConsent: CloudConsentFixture.conversation(origins: (0..<16).map { "http://s\($0).test" }))

        _ = try? await transport.request(["id": 1], server: server(1))
        _ = try? await transport.request(["id": 1], server: server(2))
        _ = try? await transport.request(["id": 2], server: server(1))

        XCTAssertEqual(SessionEchoURLProtocol.lastSessionHeader(forHost: "s1.test"), "sid-s1.test")
        XCTAssertEqual(SessionEchoURLProtocol.lastSessionHeader(forHost: "s2.test"), "sid-s2.test")
    }

    func testResetForcesAFreshHandshake() async throws {
        let transport = HTTPTransport(session: SessionEchoURLProtocol.session(), processingConsent: CloudConsentFixture.conversation(origins: (0..<16).map { "http://s\($0).test" }))

        _ = try? await transport.request(["id": 1], server: server(1))
        let afterFirst = SessionEchoURLProtocol.requestCount(forHost: "s1.test")
        XCTAssertGreaterThan(afterFirst, 1, "first contact should handshake before the real call")

        // Cached: no second handshake.
        _ = try? await transport.request(["id": 2], server: server(1))
        let cachedCost = SessionEchoURLProtocol.requestCount(forHost: "s1.test") - afterFirst
        XCTAssertEqual(cachedCost, 1, "a cached session should cost exactly one request")

        // Rotated config: handshake again.
        HTTPTransport.resetSessions()
        _ = try? await transport.request(["id": 3], server: server(1))
        let afterReset = SessionEchoURLProtocol.requestCount(forHost: "s1.test")
        XCTAssertGreaterThan(afterReset - afterFirst - cachedCost, 1,
                             "reset should force a fresh handshake")
    }
}

// MARK: - Thread-safe URLProtocol stub

/// Returns a per-host `mcp-session-id` and records what each host was sent, all behind a lock so
/// the harness itself contributes no races to a concurrency test.
final class SessionEchoURLProtocol: URLProtocol {

    private struct State {
        var lastSessionHeader: [String: String] = [:]
        var requestCounts: [String: Int] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() { state.withLock { $0 = State() } }

    static func lastSessionHeader(forHost host: String) -> String? {
        state.withLock { $0.lastSessionHeader[host] }
    }

    static func requestCount(forHost host: String) -> Int {
        state.withLock { $0.requestCounts[host] ?? 0 }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionEchoURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "?"
        let sent = request.value(forHTTPHeaderField: "mcp-session-id")
        Self.state.withLock { state in
            state.requestCounts[host, default: 0] += 1
            // Only the real call carries a session; don't let the handshake's absent header
            // overwrite what a previous round recorded.
            if let sent { state.lastSessionHeader[host] = sent }
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "mcp-session-id": "sid-\(host)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
