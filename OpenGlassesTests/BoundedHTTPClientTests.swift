import XCTest
@testable import OpenGlasses

final class BoundedHTTPClientTests: XCTestCase {
    private actor Recorder {
        var requests: [BoundedHTTPClient.PinnedRequest] = []
        var scripts: [String: Script]

        init(_ scripts: [String: Script]) { self.scripts = scripts }

        func execute(
            _ request: BoundedHTTPClient.PinnedRequest,
            _ profile: BoundedHTTPClient.Profile,
            _ sink: BoundedHTTPClient.BodySink
        ) throws -> BoundedHTTPClient.Response {
            requests.append(request)
            guard let script = scripts[request.url.absoluteString] else {
                throw BoundedHTTPClient.ClientError.transport
            }
            if ![301, 302, 303, 307, 308].contains(script.status) {
                guard script.body.count <= profile.maximumBytes else {
                    throw BoundedHTTPClient.ClientError.responseTooLarge
                }
                try sink(script.body)
            }
            return .init(statusCode: script.status, headers: script.headers,
                         finalURL: request.url, byteCount: script.body.count)
        }
    }

    private struct Script {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func ok(_ text: String = "ok") -> Script {
            Script(status: 200, headers: ["content-type": "text/plain"], body: Data(text.utf8))
        }

        static func redirect(_ location: String) -> Script {
            Script(status: 302, headers: ["location": location], body: Data())
        }
    }

    private func client(
        addresses: [String: [String]],
        scripts: [String: Script]
    ) -> (BoundedHTTPClient, Recorder) {
        let recorder = Recorder(scripts)
        let client = BoundedHTTPClient(
            resolve: { host in addresses[host] ?? [] },
            transport: { request, profile, sink in
                try await recorder.execute(request, profile, sink)
            }
        )
        return (client, recorder)
    }

    func testPublicHostIsResolvedOnceAndTransportReceivesPinnedAddress() async throws {
        let url = URL(string: "https://example.test/context")!
        let (client, recorder) = client(
            addresses: ["example.test": ["93.184.216.34"]],
            scripts: [url.absoluteString: .ok("context")]
        )

        let (data, response) = try await client.fetchData(url, profile: .qrContext)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "context")
        XCTAssertEqual(response.finalURL, url)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].address, "93.184.216.34")
        XCTAssertEqual(requests[0].host, "example.test")
        XCTAssertTrue(requests[0].usesTLS)
    }

    func testAnyPrivateDNSAnswerRejectsWholeHostBeforeTransport() async {
        let url = URL(string: "https://mixed.test/context")!
        let (client, recorder) = client(
            addresses: ["mixed.test": ["93.184.216.34", "127.0.0.1"]],
            scripts: [:]
        )

        await assertError(.mixedAddressPolicy) {
            _ = try await client.fetchData(url, profile: .qrContext)
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRedirectIsResolvedAndPinnedAgain() async throws {
        let first = URL(string: "https://one.test/context")!
        let second = URL(string: "https://two.test/final")!
        let (client, recorder) = client(
            addresses: ["one.test": ["93.184.216.34"], "two.test": ["1.1.1.1"]],
            scripts: [first.absoluteString: .redirect(second.absoluteString), second.absoluteString: .ok("final")]
        )

        let (data, response) = try await client.fetchData(first, profile: .qrContext)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "final")
        XCTAssertEqual(response.finalURL, second)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.address), ["93.184.216.34", "1.1.1.1"])
    }

    func testPublicToPrivateRedirectFailsBeforeSecondConnection() async {
        let first = URL(string: "https://one.test/context")!
        let second = URL(string: "https://private.test/secret")!
        let (client, recorder) = client(
            addresses: ["one.test": ["93.184.216.34"], "private.test": ["169.254.169.254"]],
            scripts: [first.absoluteString: .redirect(second.absoluteString)]
        )

        await assertError(.disallowedAddress) {
            _ = try await client.fetchData(first, profile: .qrContext)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHTTPSRedirectCannotDowngrade() async {
        let first = URL(string: "https://one.test/context")!
        let (client, recorder) = client(
            addresses: ["one.test": ["93.184.216.34"]],
            scripts: [first.absoluteString: .redirect("http://two.test/final")]
        )

        await assertError(.insecureRedirect) {
            _ = try await client.fetchData(first, profile: .qrContext)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRedirectLoopAndLimitAreRejected() async {
        let one = URL(string: "https://one.test/a")!
        let two = URL(string: "https://two.test/b")!
        let (loopClient, _) = client(
            addresses: ["one.test": ["93.184.216.34"], "two.test": ["1.1.1.1"]],
            scripts: [one.absoluteString: .redirect(two.absoluteString), two.absoluteString: .redirect(one.absoluteString)]
        )
        await assertError(.redirectLoop) {
            _ = try await loopClient.fetchData(one, profile: .qrContext)
        }

        let zeroRedirects = BoundedHTTPClient.Profile(
            name: "zero", maximumBytes: 10, acceptedMIMETypes: ["text/plain"],
            maximumRedirects: 0, allowsPrivateHTTP: false, totalTimeout: 2)
        let (limitedClient, _) = client(
            addresses: ["one.test": ["93.184.216.34"]],
            scripts: [one.absoluteString: .redirect(two.absoluteString)]
        )
        await assertError(.tooManyRedirects) {
            _ = try await limitedClient.fetchData(one, profile: zeroRedirects)
        }
    }

    func testCredentialsFragmentsAndNonDefaultPublicPortsAreRejected() async {
        let (client, recorder) = client(addresses: [:], scripts: [:])
        for raw in ["https://user:pass@example.test/a", "https://example.test/a#secret"] {
            await assertError(.credentialsOrFragment) {
                _ = try await client.fetchData(URL(string: raw)!, profile: .qrContext)
            }
        }
        await assertError(.disallowedPort) {
            _ = try await client.fetchData(URL(string: "https://example.test:8443/a")!, profile: .qrContext)
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPResponseParserEnforcesMIMEEncodingAndLengthBeforeBody() throws {
        let url = URL(string: "https://example.test/context")!
        for (head, expected) in [
            ("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 1\r\n\r\n", .unacceptableMIMEType),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\n\r\n", .unsupportedContentEncoding),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 999999\r\n\r\n", .responseTooLarge),
        ] as [(String, BoundedHTTPClient.ClientError)] {
            let parser = HTTPResponseParser(url: url, profile: .qrContext, sink: { _ in XCTFail() })
            XCTAssertThrowsError(try parser.feed(Data(head.utf8))) { error in
                XCTAssertEqual(error as? BoundedHTTPClient.ClientError, expected)
            }
        }
    }

    func testHTTPResponseParserStreamsChunkedBodyAndRejectsOverflow() throws {
        let url = URL(string: "https://example.test/context")!
        let tiny = BoundedHTTPClient.Profile(
            name: "tiny", maximumBytes: 5, acceptedMIMETypes: ["text/plain"],
            maximumRedirects: 0, allowsPrivateHTTP: false, totalTimeout: 2)
        var received = Data()
        let parser = HTTPResponseParser(url: url, profile: tiny, sink: { received.append($0) })
        XCTAssertFalse(try parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n".utf8)))
        XCTAssertTrue(try parser.feed(Data("2\r\nlo\r\n0\r\n\r\n".utf8)))
        XCTAssertEqual(String(decoding: received, as: UTF8.self), "hello")

        let overflow = HTTPResponseParser(url: url, profile: tiny, sink: { _ in })
        XCTAssertThrowsError(try overflow.feed(Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n6\r\n".utf8)
        )) { error in
            XCTAssertEqual(error as? BoundedHTTPClient.ClientError, .responseTooLarge)
        }

        let stackedEncoding = HTTPResponseParser(url: url, profile: tiny, sink: { _ in })
        XCTAssertThrowsError(try stackedEncoding.feed(Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8)
        )) { error in
            XCTAssertEqual(error as? BoundedHTTPClient.ClientError, .unsupportedTransferEncoding)
        }
    }

    // MARK: - First-byte and idle deadlines

    /// A scripted peer for `readResponse`: each step says how much virtual time passes and what
    /// the socket then produced. No sockets and no real waiting, so both deadlines are exact.
    private final class ScriptedPeer {
        enum Step {
            /// After `delay` seconds the peer delivered these bytes.
            case after(TimeInterval, String, complete: Bool)
            /// The peer says nothing for as long as it is given.
            case silent
        }

        private(set) var clock: TimeInterval = 0
        private(set) var budgets: [TimeInterval] = []
        private var steps: [Step]

        init(_ steps: [Step]) { self.steps = steps }

        func now() -> TimeInterval { clock }

        func receive(budget: TimeInterval) -> BoundedHTTPClient.ReceivedChunk {
            budgets.append(budget)
            guard !steps.isEmpty else { clock += budget; return .lapsed }
            switch steps.removeFirst() {
            case .silent:
                clock += budget
                return .lapsed
            case .after(let delay, let bytes, let complete):
                clock += delay
                return .bytes(Data(bytes.utf8), complete: complete)
            }
        }
    }

    private static let okHead = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n"

    private func readResponse(
        _ peer: ScriptedPeer,
        profile: BoundedHTTPClient.Profile = .qrContext,
        sink: @escaping BoundedHTTPClient.BodySink = { _ in }
    ) async throws -> BoundedHTTPClient.Response {
        let parser = HTTPResponseParser(url: URL(string: "https://example.test/x")!,
                                        profile: profile, sink: sink)
        return try await BoundedHTTPClient.readResponse(
            into: parser,
            profile: profile,
            now: peer.now,
            receive: { peer.receive(budget: $0) })
    }

    func testFirstByteDeadlineFailsWhenTheServerAcceptsAndSaysNothing() async {
        let peer = ScriptedPeer([.silent])
        await assertError(.firstByteTimeout) { _ = try await self.readResponse(peer) }
        XCTAssertEqual(peer.budgets, [BoundedHTTPClient.Profile.qrContext.firstByteTimeout],
                       "the first read is budgeted by the first-byte deadline, not the total one")
    }

    func testFirstByteDeadlineBoundary() async throws {
        let deadline = BoundedHTTPClient.Profile.qrContext.firstByteTimeout

        let inTime = ScriptedPeer([.after(deadline - 0.1, Self.okHead + "hello", complete: true)])
        var body = Data()
        let response = try await readResponse(inTime, sink: { body.append($0) })
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")

        let tooLate = ScriptedPeer([.after(deadline + 0.1, Self.okHead + "hello", complete: true)])
        await assertError(.firstByteTimeout) { _ = try await self.readResponse(tooLate) }
    }

    func testIdleDeadlineFailsWhenTheBodyStallsMidStream() async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\n"
        let peer = ScriptedPeer([.after(1, head + "hel", complete: false), .silent])
        await assertError(.idleTimeout) { _ = try await self.readResponse(peer) }
        XCTAssertEqual(peer.budgets.last, BoundedHTTPClient.Profile.qrContext.idleTimeout,
                       "once bytes have flowed the gap is bounded by the idle deadline")
    }

    func testIdleDeadlineBoundary() async throws {
        let idle = BoundedHTTPClient.Profile.qrContext.idleTimeout

        let inTime = ScriptedPeer([
            .after(1, Self.okHead + "hel", complete: false),
            .after(idle - 0.1, "lo", complete: false),
        ])
        var body = Data()
        let response = try await readResponse(inTime, sink: { body.append($0) })
        XCTAssertEqual(response.byteCount, 5)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")

        let tooLate = ScriptedPeer([
            .after(1, Self.okHead + "hel", complete: false),
            .after(idle + 0.1, "lo", complete: false),
        ])
        await assertError(.idleTimeout) { _ = try await self.readResponse(tooLate) }
    }

    func testResponseCannotExtendItsOwnDeadlines() async {
        // A long-lived Keep-Alive, a large declared length and two empty reads: none of them is
        // progress, so the idle window keeps running from the last byte the peer actually sent.
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nKeep-Alive: timeout=600\r\n"
            + "Content-Length: 4096\r\n\r\n"
        let peer = ScriptedPeer([
            .after(1, head + "hel", complete: false),
            .after(0.5, "", complete: false),
            .after(0.5, "", complete: false),
            .silent,
        ])
        await assertError(.idleTimeout) { _ = try await self.readResponse(peer) }
        let idle = BoundedHTTPClient.Profile.qrContext.idleTimeout
        XCTAssertEqual(peer.budgets.last ?? 0, idle - 1, accuracy: 0.0001,
                       "empty reads must not restart the idle window")
    }

    func testProfileDeadlinesAreOrderedAndPublicProfilesAreTighter() {
        for profile in [BoundedHTTPClient.Profile.qrContext, .signedCatalog, .skillPack] {
            XCTAssertLessThan(profile.idleTimeout, profile.firstByteTimeout, profile.name)
            XCTAssertLessThan(profile.firstByteTimeout, profile.totalTimeout, profile.name)
        }
        #if DEBUG
        XCTAssertGreaterThan(BoundedHTTPClient.Profile.internalSkillPack.firstByteTimeout,
                             BoundedHTTPClient.Profile.skillPack.firstByteTimeout,
                             "the LAN dev profile is the loose one, and it is Debug-only")
        XCTAssertGreaterThan(BoundedHTTPClient.Profile.internalSkillPack.idleTimeout,
                             BoundedHTTPClient.Profile.skillPack.idleTimeout)
        #endif
    }

    // MARK: - Pinned endpoint versus verified hostname

    func testConnectionPlanPinsTheAddressAndKeepsTheRequestHostname() throws {
        let request = BoundedHTTPClient.PinnedRequest(
            url: URL(string: "https://example.test/context?q=1")!,
            address: "93.184.216.34", host: "example.test", port: 443, usesTLS: true)
        let plan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: request))

        XCTAssertEqual(plan.endpointHost, "93.184.216.34", "the socket goes to the approved peer")
        XCTAssertEqual(plan.tlsServerName, "example.test")
        XCTAssertEqual(plan.certificateHostname, "example.test")
        XCTAssertNotEqual(plan.tlsServerName, plan.endpointHost,
                          "pinning the address must never become trusting a cert for the address")
        XCTAssertEqual(plan.hostHeader, "example.test")
        XCTAssertEqual(plan.requestTarget, "/context?q=1")
        XCTAssertEqual(plan.port, 443)
    }

    func testConnectionPlanForANumericHostIsConsistentWithThePolicy() throws {
        // A URL whose host is already numeric resolves to itself, so endpoint and verified name
        // are the same literal — the policy is unchanged, not specially relaxed.
        let request = BoundedHTTPClient.PinnedRequest(
            url: URL(string: "https://93.184.216.34/context")!,
            address: "93.184.216.34", host: "93.184.216.34", port: 443, usesTLS: true)
        let plan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: request))
        XCTAssertEqual(plan.endpointHost, "93.184.216.34")
        XCTAssertEqual(plan.tlsServerName, "93.184.216.34")
        XCTAssertEqual(plan.certificateHostname, plan.tlsServerName)

        // IPv6 literals are bracketed in the Host header; the cleartext Debug profile has no name
        // to verify at all.
        let cleartext = BoundedHTTPClient.PinnedRequest(
            url: URL(string: "http://[fd00::1]:8080/pack.zip")!,
            address: "fd00::1", host: "fd00::1", port: 8080, usesTLS: false)
        let cleartextPlan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: cleartext))
        XCTAssertNil(cleartextPlan.tlsServerName)
        XCTAssertNil(cleartextPlan.certificateHostname)
        XCTAssertEqual(cleartextPlan.hostHeader, "[fd00::1]:8080")
    }

    func testConnectionPlanAfterARedirectCarriesTheRedirectTargetHost() async throws {
        let first = URL(string: "https://one.test/context")!
        let second = URL(string: "https://two.test/final")!
        let (client, recorder) = client(
            addresses: ["one.test": ["93.184.216.34"], "two.test": ["1.1.1.1"]],
            scripts: [first.absoluteString: .redirect(second.absoluteString),
                      second.absoluteString: .ok("final")]
        )

        _ = try await client.fetchData(first, profile: .qrContext)

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        let plan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: requests[1]))
        XCTAssertEqual(plan.tlsServerName, "two.test", "the second hop verifies its own hostname")
        XCTAssertEqual(plan.certificateHostname, "two.test")
        XCTAssertEqual(plan.hostHeader, "two.test")
        XCTAssertEqual(plan.endpointHost, "1.1.1.1", "pinned to the redirect target's approved peer")
        XCTAssertEqual(plan.requestTarget, "/final")
    }

    private func assertError(
        _ expected: BoundedHTTPClient.ClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? BoundedHTTPClient.ClientError, expected)
        }
    }
}
