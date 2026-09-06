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
