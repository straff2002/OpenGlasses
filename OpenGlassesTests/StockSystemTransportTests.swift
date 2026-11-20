import XCTest
@testable import OpenGlasses

/// Answers the stock transport's session from a test's handler, and keeps every request it saw.
/// Installed only on the session under test (`protocolClasses`), never globally.
final class StockTransportStubProtocol: URLProtocol {

    enum Reply {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (URLRequest) -> Reply = { _ in .failure(URLError(.notConnectedToInternet)) }
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func answer(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); self.handler = handler; requests = []; lock.unlock()
    }

    static var seen: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.handler(request)
        Self.lock.unlock()
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Plan MM P2 — the common stock transport: pinned hosts over HTTPS, the adapter's endpoints only,
/// the key on the wire and nowhere else, redirects refused, replies capped, the medical guard asked
/// first, and every failure to connect said as "unreachable".
final class StockSystemTransportTests: XCTestCase {

    private let adapter = SquareStockAdapter()
    private var key = ""
    private var credential: StockSystemCredential!

    override func setUp() {
        super.setUp()
        key = StockSystemConnectionSamples.key("t")
        credential = StockSystemCredential(key)
        MedicalEgressGuard.currentMode = { .off }
    }

    override func tearDown() {
        MedicalEgressGuard.currentMode = { MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) }
        StockTransportStubProtocol.answer { _ in .failure(URLError(.notConnectedToInternet)) }
        super.tearDown()
    }

    private var destination: StockSystemDestination {
        StockSystemDestination(adapter: adapter, route: .squareStockAPI, environment: .production)!
    }

    private func transport() -> URLSessionStockSystemTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StockTransportStubProtocol.self]
        return URLSessionStockSystemTransport(configuration: configuration)
    }

    private func locationsRequest() throws -> StockSystemRequest {
        try adapter.request(SquareStockAdapter.Endpoint.locations)
    }

    // MARK: - The request on the wire

    func testTheKeyIsABearerHeaderOnTheWireAndNowhereElse() throws {
        let request = try locationsRequest()
        let wire = try URLSessionStockSystemTransport.urlRequest(request, to: destination, credential: credential)
        XCTAssertEqual(wire.url?.absoluteString, "https://connect.squareup.com/v2/locations")
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        XCTAssertEqual(wire.value(forHTTPHeaderField: "Square-Version"), SquareStockAdapter.squareVersion)
        XCTAssertFalse(wire.httpShouldHandleCookies)
        var dumped = ""
        dump(credential, to: &dumped)
        dump(request, to: &dumped)
        for text in [String(describing: credential!), String(reflecting: credential!), String(describing: request),
                     String(describing: destination), dumped] {
            XCTAssertFalse(text.contains(key), "the key shows in \(text)")
        }
        XCTAssertNil(request.headers["Authorization"], "the request value never carries the key")
    }

    func testTheSandboxIsItsOwnPinnedHost() throws {
        let sandbox = try XCTUnwrap(StockSystemDestination(adapter: adapter, route: .squareStockAPI, environment: .sandbox))
        let wire = try URLSessionStockSystemTransport.urlRequest(try locationsRequest(), to: sandbox, credential: credential)
        XCTAssertEqual(wire.url?.host, "connect.squareupsandbox.com")
        XCTAssertEqual(destination.pinnedHosts, ["connect.squareup.com", "connect.squareupsandbox.com"])
    }

    func testAForeignHostIsRefused() throws {
        for host in ["evil.example.invalid", "connect.squareup.com.evil.invalid", "connect.squareup.com:8443", "CONNECT.SQUAREUP.COM"] {
            let foreign = StockSystemDestination(connectorID: "square", route: .squareStockAPI, host: host,
                                                 pinnedHosts: destination.pinnedHosts, allowedEndpoints: adapter.allowedEndpoints,
                                                 maximumResponseBytes: 1000)
            XCTAssertThrowsError(try URLSessionStockSystemTransport.urlRequest(try locationsRequest(), to: foreign, credential: credential), host) {
                XCTAssertEqual($0 as? StockSystemTransportRefusal, .foreignHost)
            }
        }
    }

    func testAnEndpointOffTheAdaptersListIsRefused() throws {
        let other = StockSystemEndpoint(.post, "/v2/inventory/physical-counts", purpose: .write, scope: nil)
        let request = try StockSystemRequest(other, allowed: adapter.allowedEndpoints + [other])
        XCTAssertThrowsError(try URLSessionStockSystemTransport.urlRequest(request, to: destination, credential: credential)) {
            XCTAssertEqual($0 as? StockSystemTransportRefusal, .offList)
        }
    }

    func testAKeyThatIsNotOneIsRefusedBeforeAnything() {
        for bad in ["", "   ", "two words", "line\nbreak", "tab\tkey", "é-accented", String(repeating: "k", count: 4097)] {
            XCTAssertNil(StockSystemCredential(bad), bad)
        }
        XCTAssertEqual(StockSystemCredential("  \(key)\n")?.key, key, "a pasted key is trimmed")
    }

    // MARK: - Over the session

    func testAReplyComesBackWithItsHeadersButNeverACookie() async throws {
        StockTransportStubProtocol.answer { _ in
            .response(status: 429, headers: ["Retry-After": "7", "Set-Cookie": "a=b", "Content-Type": "application/json"],
                      body: Data("{}".utf8))
        }
        let response = try await transport().send(try locationsRequest(), to: destination, credential: credential)
        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.header("Retry-After"), "7")
        XCTAssertNil(response.header("Set-Cookie"))
        XCTAssertEqual(StockSystemFailure.retryAfter(response), 7)
        let seen = try XCTUnwrap(StockTransportStubProtocol.seen.first)
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        XCTAssertNil(seen.value(forHTTPHeaderField: "Cookie"))
    }

    func testARedirectIsRefused() async throws {
        StockTransportStubProtocol.answer { _ in
            .response(status: 302, headers: ["Location": "https://evil.example.invalid/v2/locations"], body: Data())
        }
        do {
            _ = try await transport().send(try locationsRequest(), to: destination, credential: credential)
            XCTFail("a redirect was followed")
        } catch {
            XCTAssertEqual(error as? StockSystemTransportRefusal, .redirected)
        }
        XCTAssertEqual(StockTransportStubProtocol.seen.map { $0.url?.host }, ["connect.squareup.com"])

        // And the session's delegate never follows one.
        let session = URLSession(configuration: .ephemeral)
        let redirect = HTTPURLResponse(url: URL(string: "https://connect.squareup.com/v2/locations")!, statusCode: 301,
                                       httpVersion: nil, headerFields: nil)!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://example.invalid")!)
        transport().urlSession(session, task: session.dataTask(with: URLRequest(url: redirect.url!)),
                               willPerformHTTPRedirection: redirect,
                               newRequest: URLRequest(url: URL(string: "https://evil.example.invalid")!)) { followed = $0 }
        XCTAssertNil(followed)
        session.invalidateAndCancel()
    }

    func testTheReplyIsCappedAtTheAdaptersSize() async throws {
        let small = StockSystemDestination(connectorID: "square", route: .squareStockAPI, host: destination.host,
                                           pinnedHosts: destination.pinnedHosts, allowedEndpoints: adapter.allowedEndpoints,
                                           maximumResponseBytes: 1000)
        for headers in [["Content-Length": "5000"], [:]] {
            StockTransportStubProtocol.answer { _ in .response(status: 200, headers: headers, body: Data(count: 5000)) }
            do {
                _ = try await transport().send(try locationsRequest(), to: small, credential: credential)
                XCTFail("a reply over the cap was read")
            } catch {
                XCTAssertEqual(error as? StockSystemFailure, .tooLarge)
            }
        }
        StockTransportStubProtocol.answer { _ in .response(status: 200, headers: [:], body: Data(count: 1000)) }
        let fits = try await transport().send(try locationsRequest(), to: small, credential: credential)
        XCTAssertEqual(fits.body.count, 1000)
        XCTAssertEqual(adapter.maximumResponseBytes, SquareStockAdapter.maximumResponseBytes)
        XCTAssertEqual(destination.maximumResponseBytes, SquareStockAdapter.maximumResponseBytes)
    }

    func testNoConnectionIsUnreachable() async throws {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
                     .secureConnectionFailed] {
            StockTransportStubProtocol.answer { _ in .failure(URLError(code)) }
            do {
                _ = try await transport().send(try locationsRequest(), to: destination, credential: credential)
                XCTFail("\(code) was not reported")
            } catch {
                XCTAssertEqual(error as? StockSystemFailure, .unreachable, "\(code)")
            }
        }
        XCTAssertTrue(StockSystemFailure.unreachable.sentence(system: "Square").contains("No connection to Square"))
    }

    /// The canary: with Medical Local Only on, nothing reaches the session; with it off, the same
    /// call does, so the guard and not a broken transport is what stopped it.
    func testMedicalLocalOnlyStopsEveryRequestBeforeTheWire() async throws {
        StockTransportStubProtocol.answer { _ in .response(status: 200, headers: [:], body: Data("{}".utf8)) }
        XCTAssertEqual(NetworkRoute.squareStockAPI.medicalPolicy, .blockedWhenLocalOnly)
        MedicalEgressGuard.currentMode = { .localOnly }
        do {
            _ = try await transport().send(try locationsRequest(), to: destination, credential: credential)
            XCTFail("a request left under local-only")
        } catch {
            XCTAssertEqual(error as? MedicalEgressRefusal, MedicalEgressRefusal(route: .squareStockAPI))
        }
        XCTAssertTrue(StockTransportStubProtocol.seen.isEmpty)
        MedicalEgressGuard.currentMode = { .off }
        _ = try await transport().send(try locationsRequest(), to: destination, credential: credential)
        XCTAssertEqual(StockTransportStubProtocol.seen.count, 1)
    }

    // MARK: - The route

    func testTheRouteIsRegisteredForTheCommonTransport() {
        let route = NetworkRoute.squareStockAPI
        XCTAssertEqual(route.owningTypes, ["URLSessionStockSystemTransport"])
        XCTAssertEqual(route.dataClasses, [.promptText, .credential])
        XCTAssertFalse(route.dataClasses.contains(.contactData))
        XCTAssertEqual(route.endpointClass, .userConfiguredCloud)
        XCTAssertEqual(StockSystemAdapterRegistry.route(for: "square"), .squareStockAPI)
        for registration in StockSystemAdapterRegistry.all {
            XCTAssertEqual(registration.route.owningTypes, ["URLSessionStockSystemTransport"],
                           "\(registration.connectorID) rides the one stock transport")
            XCTAssertTrue(registration.route.medicalPolicy.blocksLocalOnly)
        }
    }
}
