import XCTest
@testable import OpenGlasses

/// The sandbox: request budget, response cap and MIME, run and request deadlines on the injected
/// clock, redirects re-checked hop by hop, the allowlist re-checked after substitution, and
/// forbidden headers stripped.
final class RecipeSandboxTests: XCTestCase {

    private typealias F = RecipeAddOnFixtures

    private func run(_ steps: [[String: Any]], params: [String: Any] = [:], args: [String: Any] = [:],
                     network: [String] = ["api.example.org"], transport: FakeAddOnHTTPTransport,
                     clock: FakeAddOnClock = FakeAddOnClock()) async throws -> RecipeRunResult {
        let m = try F.manifest(skills: [F.skill(parameters: params, steps: steps)], permissions: ["network": network])
        return await RecipeRunner(transport: transport, clock: clock).run(m, skill: "look_up", arguments: args, context: F.context)
    }

    private func get(_ name: String, _ url: String = "https://api.example.org/x") -> [String: Any] {
        ["http": ["url": url, "as": name]]
    }

    // MARK: - Budget

    func testFourthRequestIsRefusedAsData() async throws {
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let result = try await run([get("a"), get("b"), get("c"), get("d"),
                                    ["say": "{{c.ok}} {{d.ok}} {{d.error}} {{d.status}}"]], transport: transport)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(result.requestsMade, 3)
        XCTAssertEqual(result.spokenText, "true false request_limit 0")
    }

    // MARK: - Responses

    func testResponseOverOneMegabyteIsRefused() async throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: RecipeSandbox.maxResponseBytes + 1)
        let transport = FakeAddOnHTTPTransport { _ in AddOnHTTPResponse(status: 200, mimeType: "text/plain", body: big) }
        let result = try await run([get("r"), ["say": "{{r.error}} [{{r}}]"]], transport: transport)
        XCTAssertEqual(result.spokenText, "too_large []")
        XCTAssertEqual(transport.requests.first?.maxResponseBytes, 1_048_576)

        let exact = Data(repeating: UInt8(ascii: "a"), count: RecipeSandbox.maxResponseBytes)
        let fits = FakeAddOnHTTPTransport { _ in AddOnHTTPResponse(status: 200, mimeType: "text/plain", body: exact) }
        let ok = try await run([get("r"), ["say": "{{r.ok}}"]], transport: fits)
        XCTAssertEqual(ok.spokenText, "true")
    }

    func testOnlyJSONAndTextAreAccepted() async throws {
        for (mime, accepted) in [("application/json", true), ("application/json; charset=utf-8", true),
                                 ("application/geo+json", true), ("text/html", true), ("text/plain", true),
                                 ("image/png", false), ("application/octet-stream", false), (nil, false)] as [(String?, Bool)] {
            let transport = FakeAddOnHTTPTransport { _ in AddOnHTTPResponse(status: 200, mimeType: mime, body: Data("x".utf8)) }
            let result = try await run([get("r"), ["say": "{{r.ok}}|{{r.error}}"]], transport: transport)
            XCTAssertEqual(result.spokenText, accepted ? "true|" : "false|unsupported_type", mime ?? "nil")
        }
    }

    // MARK: - Time

    func testThirtySecondRunBudget() async throws {
        let clock = FakeAddOnClock()
        let transport = FakeAddOnHTTPTransport(clock: clock, json: "{}")
        transport.latency = 12        // each request inside its own 15 s, but three of them pass 30 s
        let result = try await run([get("a"), get("b"), get("c"), ["say": "never said"]],
                                   transport: transport, clock: clock)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[2].timeout, 6, "the last request only gets what is left of the run")
        XCTAssertEqual(result.spokenText, "")
    }

    func testRunStopsBeforeTheNextStepOnceOutOfTime() async throws {
        let clock = FakeAddOnClock()
        let transport = FakeAddOnHTTPTransport(clock: clock, json: "{}")
        transport.latency = 14
        let result = try await run([["say": "first"], get("a"), get("b"), get("c"), ["say": "late"]],
                                   transport: transport, clock: clock)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.spokenText, "first", "what was said before the deadline is kept")
    }

    func testFifteenSecondRequestTimeout() async throws {
        let clock = FakeAddOnClock()
        let transport = FakeAddOnHTTPTransport(clock: clock, json: #"{"a":1}"#)
        transport.latency = 16
        let result = try await run([get("r"), ["say": "{{r.ok}} {{r.error}} [{{r}}]"]], transport: transport, clock: clock)
        XCTAssertEqual(transport.requests.first?.timeout, RecipeSandbox.requestTimeout)
        XCTAssertEqual(result.spokenText, "false timeout []", "a late answer is discarded")
        XCTAssertEqual(result.outcome, .completed)
    }

    // MARK: - Redirects

    func testRedirectWithinTheAllowlistIsFollowed() async throws {
        let transport = FakeAddOnHTTPTransport { request in
            request.url.path == "/old" ? .redirect(to: "/new") : .json(#"{"v":"moved"}"#)
        }
        let result = try await run([get("r", "https://api.example.org/old"), ["say": "{{r}}"]], transport: transport)
        XCTAssertEqual(result.spokenText, #"{"v":"moved"}"#)
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), ["https://api.example.org/old", "https://api.example.org/new"])
        XCTAssertEqual(result.requestsMade, 1, "a redirect hop is not another request")
    }

    func testRedirectOffTheAllowlistIsRefused() async throws {
        for location in ["https://evil.example.com/steal", "http://api.example.org/plain", "https://127.0.0.1/",
                         "https://user@api.example.org/", "https://api.example.org:8443/"] {
            let transport = FakeAddOnHTTPTransport { request in
                request.url.host == "api.example.org" && request.url.path == "/x" ? .redirect(to: location) : .json("{}")
            }
            let result = try await run([get("r"), ["say": "{{r.error}}"]], transport: transport)
            XCTAssertEqual(result.spokenText, "redirect_refused", location)
            XCTAssertEqual(transport.requests.count, 1, location)
        }
    }

    func testAtMostThreeRedirects() async throws {
        let transport = FakeAddOnHTTPTransport { request in
            let n = Int(request.url.lastPathComponent) ?? 0
            return .redirect(to: "/\(n + 1)", status: 301)
        }
        let result = try await run([get("r", "https://api.example.org/0"), ["say": "{{r.error}}"]], transport: transport)
        XCTAssertEqual(result.spokenText, "too_many_redirects")
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testSeeOtherTurnsAPostIntoAGet() async throws {
        let transport = FakeAddOnHTTPTransport { request in
            request.url.path == "/submit" ? .redirect(to: "/result", status: 303) : .json("{}")
        }
        _ = try await run([["http": ["method": "POST", "url": "https://api.example.org/submit", "as": "r", "json": ["a": 1]]],
                           ["say": "ok"]], transport: transport)
        XCTAssertEqual(transport.requests.map(\.method), ["POST", "GET"])
        XCTAssertNil(transport.requests[1].body)
    }

    // MARK: - Substitution can't move the host

    func testSubstitutedURLIsCheckedAgainstTheAllowlist() async throws {
        // An unvalidated file whose host is templated: the run-time check still refuses.
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let result = try await run([["http": ["url": "https://{{h}}/x", "as": "r"]], ["say": "{{r.error}}"]],
                                   params: ["h": ["type": "string"]], args: ["h": "evil.example.com"], transport: transport)
        XCTAssertEqual(result.spokenText, "host_not_allowed")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAValueCannotSmuggleAHostThroughThePath() async throws {
        let transport = FakeAddOnHTTPTransport(json: "{}")
        _ = try await run([["http": ["url": "https://api.example.org/{{p}}?q={{p}}", "as": "r"]], ["say": "ok"]],
                          params: ["p": ["type": "string"]], args: ["p": "@evil.example.com/../x#"], transport: transport)
        XCTAssertEqual(transport.requests.first?.url.host, "api.example.org")
    }

    func testURLRefusals() throws {
        let rules = [try AddOnDomainRule.parse("api.example.org").get()]
        func refusal(_ s: String) -> RecipeSandbox.URLRefusal? { RecipeSandbox.refusal(for: URL(string: s)!, rules: rules) }
        XCTAssertNil(refusal("https://api.example.org/x"))
        XCTAssertNil(refusal("https://api.example.org:443/x"))
        XCTAssertEqual(refusal("http://api.example.org/x"), .notHTTPS)
        XCTAssertEqual(refusal("https://a:b@api.example.org/x"), .hasUserInfo)
        XCTAssertEqual(refusal("https://api.example.org:8080/x"), .hasPort)
        XCTAssertEqual(refusal("https://other.example.org/x"), .hostNotAllowed("other.example.org"))
    }

    // MARK: - Headers

    func testForbiddenHeadersAreStripped() async throws {
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let headers: [String: String] = [
            "Host": "evil.example.com", "Content-Length": "0", "Connection": "close", "Transfer-Encoding": "chunked",
            "Proxy-Authorization": "x", "cookie": "s=1", "User-Agent": "spoof", "Bad Name": "x",
            "Accept-Language": "en-GB", "X-Trace": "a\r\nInjected: yes",
        ]
        _ = try await run([["http": ["url": "https://api.example.org/x", "as": "r", "headers": headers]], ["say": "ok"]],
                          transport: transport)
        let sent = try XCTUnwrap(transport.requests.first?.headers)
        XCTAssertEqual(Set(sent.keys), ["Accept-Language", "X-Trace", "Accept"])
        XCTAssertEqual(sent["X-Trace"], "aInjected: yes")
        for name in ["Host", "content-length", "CONNECTION", "Transfer-Encoding", "Proxy-Anything", "Cookie", "user-agent"] {
            XCTAssertTrue(RecipeSandbox.isForbiddenHeader(name), name)
        }
        XCTAssertFalse(RecipeSandbox.isForbiddenHeader("Accept"))
    }

    func testAuthorHeadersDoNotFollowARedirectToAnotherHost() async throws {
        let transport = FakeAddOnHTTPTransport { request in
            request.url.host == "api.example.org" ? .redirect(to: "https://cdn.example.org/x") : .json("{}")
        }
        _ = try await run([["http": ["url": "https://api.example.org/x", "as": "r", "headers": ["X-Key": "v"]]], ["say": "ok"]],
                          network: ["api.example.org", "cdn.example.org"], transport: transport)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].headers["X-Key"], "v")
        XCTAssertNil(transport.requests[1].headers["X-Key"])
    }
}
