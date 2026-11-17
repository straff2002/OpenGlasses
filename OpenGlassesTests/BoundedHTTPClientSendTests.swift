import XCTest
@testable import OpenGlasses

/// Plan GF P2 — the hardened client's one-hop `send`: POST with a body, the caller's headers made
/// safe, a redirect handed back rather than followed, the address check unchanged, and the add-on
/// profiles. No socket: the resolver and transport are injected.
final class BoundedHTTPClientSendTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var requests: [BoundedHTTPClient.PinnedRequest] = []
        var profiles: [BoundedHTTPClient.Profile] = []
    }

    private func client(addresses: [String] = ["93.184.216.34"], status: Int = 200,
                        headers: [String: String] = ["content-type": "application/json"],
                        body: Data = Data(#"{"ok":true}"#.utf8), box: Box = Box()) -> BoundedHTTPClient {
        BoundedHTTPClient(
            resolve: { _ in addresses },
            transport: { request, profile, sink in
                box.requests.append(request)
                box.profiles.append(profile)
                if ![301, 302, 303, 307, 308].contains(status) { try sink(body) }
                return .init(statusCode: status, headers: headers, finalURL: request.url, byteCount: body.count)
            })
    }

    private let profile = BoundedHTTPClient.Profile.recipeAddOnStep(timeout: 15, maximumBytes: 1_048_576)

    func testAPostCarriesItsMethodHeadersAndBody() async throws {
        let box = Box()
        let url = URL(string: "https://api.example.org/v1/convert")!
        var received = Data()
        let response = try await client(box: box).send(
            .init(method: "post", url: url, headers: ["X-Api-Version": "2", "Accept": "application/json"],
                  body: Data(#"{"amount":5}"#.utf8)),
            profile: profile) { received.append($0) }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(received, Data(#"{"ok":true}"#.utf8))
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.address, "93.184.216.34", "still pinned to one resolved public address")
        XCTAssertEqual(request.body, Data(#"{"amount":5}"#.utf8))
        XCTAssertEqual(request.headerFields["X-Api-Version"], "2")
    }

    func testTheWireCarriesTheBodyAfterItsLength() throws {
        let request = BoundedHTTPClient.PinnedRequest(
            url: URL(string: "https://api.example.org/v1/convert?x=1")!, address: "93.184.216.34",
            host: "api.example.org", port: 443, usesTLS: true, method: "POST",
            headerFields: ["Accept": "application/json", "X-Test": "yes"], body: Data("{}".utf8))
        let plan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: request))
        let wire = String(decoding: BoundedHTTPClient.requestBytes(plan: plan, request: request, profile: profile),
                          as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("POST /v1/convert?x=1 HTTP/1.1\r\nHost: api.example.org\r\nAccept: application/json\r\n"))
        XCTAssertTrue(wire.contains("\r\nX-Test: yes\r\n"))
        XCTAssertTrue(wire.hasSuffix("Content-Length: 2\r\n\r\n{}"))
        XCTAssertEqual(wire.components(separatedBy: "Accept:").count, 2, "one Accept, the caller's")
    }

    func testAGetIsWrittenExactlyAsBefore() throws {
        let request = BoundedHTTPClient.PinnedRequest(
            url: URL(string: "https://example.test/context")!, address: "93.184.216.34",
            host: "example.test", port: 443, usesTLS: true)
        let plan = try XCTUnwrap(BoundedHTTPClient.PinnedConnectionPlan(request: request))
        let wire = String(decoding: BoundedHTTPClient.requestBytes(plan: plan, request: request, profile: .qrContext),
                          as: UTF8.self)
        XCTAssertEqual(wire, "GET /context HTTP/1.1\r\nHost: example.test\r\nAccept: application/json, text/html, text/plain\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: OpenGlasses/BoundedFetch\r\n\r\n")
    }

    func testCallerHeadersCannotReframeTheRequest() {
        let cleaned = BoundedHTTPClient.sanitisedRequestHeaders([
            "Host": "evil.example", "Content-Length": "0", "Transfer-Encoding": "chunked",
            "Connection": "keep-alive", "User-Agent": "spoof", "Cookie": "a=b", "Proxy-Authorization": "x",
            "Accept-Encoding": "gzip", "Bad Name": "x", "X-Ok": "line\r\nInjected: yes",
        ])
        XCTAssertEqual(cleaned, ["X-Ok": "lineInjected: yes"], "only a well-formed, unreserved header stays, on one line")
    }

    func testARedirectIsReturnedNotFollowed() async throws {
        let box = Box()
        let response = try await client(status: 302, headers: ["location": "https://other.example.org/next"], box: box)
            .send(.init(url: URL(string: "https://api.example.org/a")!), profile: profile) { _ in }
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.headers["location"], "https://other.example.org/next")
        XCTAssertEqual(box.requests.count, 1, "the sandbox decides about the next hop, not the client")
    }

    func testPrivateAddressesAreStillRefused() async {
        do {
            _ = try await client(addresses: ["192.168.1.10"])
                .send(.init(url: URL(string: "https://api.example.org/a")!), profile: profile) { _ in }
            XCTFail("a public name resolving to a LAN address must be refused")
        } catch {
            XCTAssertEqual(error as? BoundedHTTPClient.ClientError, .disallowedAddress)
        }
    }

    func testOnlyGetAndPostAndOnlyAPostMayCarryABody() async {
        let url = URL(string: "https://api.example.org/a")!
        for outbound in [BoundedHTTPClient.OutboundRequest(method: "DELETE", url: url),
                         .init(method: "GET", url: url, body: Data("x".utf8)),
                         .init(method: "POST", url: url, body: Data(count: BoundedHTTPClient.maximumRequestBodyBytes + 1)),
                         .init(method: "GET", url: URL(string: "http://api.example.org/a")!)] {
            do {
                _ = try await client().send(outbound, profile: profile) { _ in }
                XCTFail("\(outbound.method) \(outbound.url) should be refused")
            } catch {}
        }
    }

    func testTheAddOnProfiles() {
        let file = BoundedHTTPClient.Profile.recipeAddOn
        XCTAssertEqual(file.maximumBytes, AddOnSignature.maxEnvelopeBytes)
        XCTAssertEqual(file.maximumRedirects, 3)
        XCTAssertFalse(file.allowsPrivateHTTP)
        XCTAssertTrue(file.accepts(mimeType: "application/json"))
        XCTAssertFalse(file.accepts(mimeType: "text/html"))

        XCTAssertEqual(profile.maximumRedirects, 0)
        XCTAssertTrue(profile.readsOnlyTheStatusOfAnError)
        XCTAssertTrue(profile.accepts(mimeType: "application/geo+json"))
        XCTAssertTrue(profile.accepts(mimeType: "text/csv"))
        XCTAssertFalse(profile.accepts(mimeType: "image/png"))
        XCTAssertFalse(profile.allowsPrivateHTTP)
    }
}
