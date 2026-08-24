import XCTest
@testable import OpenGlasses

/// Coverage for the loopback OAuth callback listener (Plan DD P1): the pure accept/reject rules,
/// and the socket end to end on an ephemeral loopback port — capture, state-mismatch rejection,
/// single use, clean shutdown, cancellation, port conflict and timeout.
final class LoopbackCallbackServerTests: XCTestCase {

    private let path = LoopbackCallbackServer.defaultCallbackPath

    // MARK: - Pure routing

    func testValidCallbackRoutesToCapture() {
        let (route, response) = LoopbackCallbackServer.route(
            method: "GET", target: "\(path)?code=ac_123&state=st_456",
            callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(route, .capture(code: "ac_123", state: "st_456"))
        XCTAssertEqual(response.status, "200 OK")
    }

    func testStateMismatchIsRejected() {
        let (route, response) = LoopbackCallbackServer.route(
            method: "GET", target: "\(path)?code=ac_123&state=not_the_state",
            callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(route, .reject)
        XCTAssertEqual(response.status, "404 Not Found")
    }

    func testCallbackWithoutStateIsRejected() {
        let (route, _) = LoopbackCallbackServer.route(
            method: "GET", target: "\(path)?code=ac_123",
            callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(route, .reject)
    }

    /// Nothing to authenticate the callback against means nothing can be captured.
    func testNoExpectedStateNeverCaptures() {
        let (route, _) = LoopbackCallbackServer.route(
            method: "GET", target: "\(path)?code=ac_123&state=st_456",
            callbackPath: path, expectedState: nil)
        XCTAssertEqual(route, .reject)
    }

    func testMissingCodeIsRejected() {
        let (route, _) = LoopbackCallbackServer.route(
            method: "GET", target: "\(path)?state=st_456",
            callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(route, .reject)
    }

    func testOtherPathsAndMethodsAreRejected() {
        let query = "?code=ac_123&state=st_456"
        let (wrongPath, _) = LoopbackCallbackServer.route(
            method: "GET", target: "/anything\(query)", callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(wrongPath, .reject)

        let (wrongMethod, _) = LoopbackCallbackServer.route(
            method: "POST", target: "\(path)\(query)", callbackPath: path, expectedState: "st_456")
        XCTAssertEqual(wrongMethod, .reject)
    }

    func testSuccessPageIsSelfContainedAndCarriesNoCode() {
        let page = LoopbackCallbackServer.successPageHTML
        XCTAssertTrue(page.contains("You're connected"))
        XCTAssertFalse(page.contains("http://"))
        XCTAssertFalse(page.contains("https://"))
        XCTAssertFalse(page.contains("<script"))
    }

    func testConstantTimeCompareMatchesEquality() {
        XCTAssertTrue(LoopbackCallbackServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(LoopbackCallbackServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LoopbackCallbackServer.constantTimeEquals("abc", "abcd"))
    }

    // MARK: - End to end over loopback

    func testCapturesTheCallbackRejectsEverythingElseAndStops() async throws {
        let server = LoopbackCallbackServer()
        let port = try await start(server, expectedState: "st_456")
        let base = "http://127.0.0.1:\(port)"

        // A stray path gets nothing.
        let strayStatus = try await status(of: "\(base)/status?code=ac_1&state=st_456")
        XCTAssertEqual(strayStatus, 404)

        // A callback carrying the wrong state gets nothing, and does not consume the capture.
        let mismatchStatus = try await status(of: "\(base)\(path)?code=ac_1&state=wrong")
        XCTAssertEqual(mismatchStatus, 404)

        // The real callback: success page, and the code is nowhere in it.
        let (body, response) = try await URLSession.shared.data(
            for: noCacheRequest("\(base)\(path)?code=ac_secret&state=st_456"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let page = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(page.contains("You're connected"))
        XCTAssertFalse(page.contains("ac_secret"))

        let outcome = await capture!.value
        XCTAssertEqual(outcome, .captured(code: "ac_secret", state: "st_456"))

        // Single use: the listener is gone, so a second callback can't be served at all.
        await assertNothingListening(at: "\(base)\(path)?code=ac_second&state=st_456")
    }

    func testCancellingTheSheetStopsTheListener() async throws {
        let server = LoopbackCallbackServer()
        let port = try await start(server, expectedState: "st_456")
        let task = try XCTUnwrap(capture)

        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        await assertNothingListening(at: "http://127.0.0.1:\(port)\(path)?code=ac_1&state=st_456")
    }

    func testExplicitStopReportsCancelled() async throws {
        let server = LoopbackCallbackServer()
        _ = try await start(server, expectedState: "st_456")
        server.stop()
        let outcome = await capture!.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testPortAlreadyInUseIsReported() async throws {
        let holder = LoopbackCallbackServer()
        let port = try await start(holder, expectedState: "st_456")

        let contender = LoopbackCallbackServer()
        let outcome = await contender.capture(expectedState: "st_456", port: port, timeout: 3)
        XCTAssertEqual(outcome, .portUnavailable)

        holder.stop()
        _ = await capture!.value
    }

    func testTimeoutIsReported() async {
        let server = LoopbackCallbackServer()
        let outcome = await server.capture(expectedState: "st_456", port: 0, timeout: 0.4)
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - Harness

    /// The in-flight capture of the test currently running (each test starts at most one).
    private var capture: Task<LoopbackCallbackServer.Outcome, Never>?

    override func tearDown() {
        capture?.cancel()
        capture = nil
        super.tearDown()
    }

    /// Start a capture on an ephemeral loopback port, remember the task, and return the port it
    /// bound to.
    @discardableResult
    private func start(_ server: LoopbackCallbackServer, expectedState: String?) async throws -> UInt16 {
        let ready = expectation(description: "listener ready")
        let boundPort = PortBox()
        server.onReady = { port in
            boundPort.value = port
            ready.fulfill()
        }
        capture = Task { await server.capture(expectedState: expectedState, port: 0, timeout: 30) }
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(boundPort.value)
    }

    private func noCacheRequest(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        return request
    }

    private func status(of url: String) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: noCacheRequest(url))
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func assertNothingListening(at url: String,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await URLSession.shared.data(for: noCacheRequest(url))
            XCTFail("expected the listener to be gone", file: file, line: line)
        } catch {
            // Connection refused — exactly what a torn-down listener looks like.
        }
    }

    /// Carries the bound port back from the listener's queue.
    private final class PortBox {
        private let lock = NSLock()
        private var stored: UInt16?
        var value: UInt16? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
