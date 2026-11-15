import XCTest
@testable import OpenGlasses

/// Plan JP — the pure half of talking to Hermes Agent's API server: the address, the requests, the
/// replies, the errors and the one-sentence diagnosis. No network.
final class HermesAgentAPITests: XCTestCase {

    // MARK: - Base URL

    func testBaseURLTable() {
        let cases: [(host: String, port: Int, expected: String?, why: String)] = [
            ("192.168.1.20", 8642, "http://192.168.1.20:8642", "private IPv4 → http with the port field"),
            ("10.0.0.4:9000", 8642, "http://10.0.0.4:9000", "a typed port wins"),
            ("mac.local", 8642, "http://mac.local:8642", ".local → http"),
            ("hermes-box", 8642, "http://hermes-box:8642", "single label → http"),
            ("hermes.example.com", 8642, "https://hermes.example.com:8642", "public name → https"),
            ("https://192.168.1.20", 8642, "https://192.168.1.20:8642", "typed scheme honoured"),
            ("http://hermes.example.com", 8642, "http://hermes.example.com:8642", "typed http kept for the policy to judge"),
            ("ws://192.168.1.20:8765", 8642, "http://192.168.1.20:8765", "a pasted bridge address reads as http"),
            ("wss://box.tailnet.ts.net", 443, "https://box.tailnet.ts.net:443", "wss → https"),
            ("192.168.1.20/p/work", 8642, "http://192.168.1.20:8642/p/work", "profile prefix kept"),
            ("http://192.168.1.20:8642/p/work/v1/", 8642, "http://192.168.1.20:8642/p/work", "trailing /v1 dropped"),
            ("http://192.168.1.20:8642/v1", 8642, "http://192.168.1.20:8642", "bare /v1 dropped"),
            ("192.168.1.20/p/work?x=1#y", 8642, "http://192.168.1.20:8642/p/work", "query and fragment dropped"),
            ("[fd12::5]", 8642, "http://[fd12::5]:8642", "IPv6 unique-local"),
            ("user@192.168.1.20", 8642, nil, "user info refused"),
            ("http://user:pw@192.168.1.20", 8642, nil, "user info refused even with a scheme"),
            ("ftp://192.168.1.20", 8642, nil, "only http(s)/ws(s)"),
            ("   ", 8642, nil, "empty"),
            ("not a host", 8642, nil, "not an address"),
        ]
        for testCase in cases {
            XCTAssertEqual(HermesAgentAPI.baseURL(host: testCase.host, port: testCase.port)?.absoluteString,
                           testCase.expected, testCase.why)
        }
    }

    func testEndpointsHangOffTheBaseIncludingAProfilePrefix() throws {
        let base = try XCTUnwrap(HermesAgentAPI.baseURL(host: "192.168.1.20/p/work", port: 8642))
        XCTAssertEqual(HermesAgentAPI.responsesURL(base: base).absoluteString,
                       "http://192.168.1.20:8642/p/work/v1/responses")
        XCTAssertEqual(HermesAgentAPI.modelsURL(base: base).absoluteString,
                       "http://192.168.1.20:8642/p/work/v1/models")
        XCTAssertEqual(HermesAgentAPI.healthURLs(base: base).map(\.absoluteString),
                       ["http://192.168.1.20:8642/p/work/health", "http://192.168.1.20:8642/health"])

        let plain = try XCTUnwrap(HermesAgentAPI.baseURL(host: "192.168.1.20", port: 8642))
        XCTAssertEqual(HermesAgentAPI.healthURLs(base: plain).map(\.absoluteString),
                       ["http://192.168.1.20:8642/health"])
    }

    /// Choosing a scheme never widens the policy: a cleartext public host stays refused in Release,
    /// while the wearer's own network is fine.
    func testTheEndpointPolicyStillJudgesTheBuiltAddress() throws {
        let publicCleartext = try XCTUnwrap(HermesAgentAPI.baseURL(host: "http://hermes.example.com", port: 8642))
        guard case .cleartextHTTPNotPermitted? = EndpointPolicy.validate(
            url: HermesAgentAPI.responsesURL(base: publicCleartext), for: .hermesAgentAPI, build: .release).failure
        else { return XCTFail("cleartext to a public host was allowed") }

        let lan = try XCTUnwrap(HermesAgentAPI.baseURL(host: "192.168.1.20", port: 8642))
        XCTAssertNil(EndpointPolicy.validate(url: HermesAgentAPI.responsesURL(base: lan),
                                             for: .hermesAgentAPI, build: .release).failure)
        let publicTLS = try XCTUnwrap(HermesAgentAPI.baseURL(host: "hermes.example.com", port: 8642))
        XCTAssertNil(EndpointPolicy.validate(url: HermesAgentAPI.responsesURL(base: publicTLS),
                                             for: .hermesAgentAPI, build: .release).failure)
    }

    // MARK: - Requests

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var base: URL { HermesAgentAPI.baseURL(host: "192.168.1.20", port: 8642)! }

    func testTextTurnRequest() throws {
        let request = HermesAgentAPI.responsesRequest(base: base, apiKey: "test-key", input: "what's next on my list?")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:8642/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "hermes-agent")
        XCTAssertEqual(json["input"] as? String, "what's next on my list?", "text-only input is a plain string")
        XCTAssertEqual(json["store"] as? Bool, true)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertNil(json["previous_response_id"])
        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertTrue(instructions.contains("spoken aloud"))
        XCTAssertTrue(instructions.contains("No markdown"))
    }

    func testImageTurnUsesTheContentArrayWithADataURL() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let request = HermesAgentAPI.responsesRequest(base: base, apiKey: "k", input: "what is this?", imageJPEG: jpeg)
        let json = try body(request)
        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "what is this?")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
    }

    func testChainedTurnCarriesThePreviousResponseID() throws {
        let request = HermesAgentAPI.responsesRequest(base: base, apiKey: "k", input: "and tomorrow?",
                                                      previousResponseID: "resp_abc")
        XCTAssertEqual(try body(request)["previous_response_id"] as? String, "resp_abc")
        let empty = HermesAgentAPI.responsesRequest(base: base, apiKey: "k", input: "x", previousResponseID: "")
        XCTAssertNil(try body(empty)["previous_response_id"], "an empty id is no chain")
    }

    /// Plan LU §5: a private conversation's turn is not stored, and chains to nothing.
    func testAPrivateTurnIsNotStoredAndChainsToNothing() throws {
        let request = HermesAgentAPI.responsesRequest(base: base, apiKey: "k", input: "a private question",
                                                      previousResponseID: "resp_abc", store: false)
        let json = try body(request)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNil(json["previous_response_id"], "an unstored turn continues no chain")
    }

    func testHealthAndModelsRequests() throws {
        let health = HermesAgentAPI.healthRequest(url: HermesAgentAPI.healthURLs(base: base)[0])
        XCTAssertEqual(health.url?.absoluteString, "http://192.168.1.20:8642/health")
        XCTAssertEqual(health.httpMethod, "GET")
        XCTAssertNil(health.value(forHTTPHeaderField: "Authorization"), "health needs no key, so none is sent")

        let models = HermesAgentAPI.modelsRequest(base: base, apiKey: "test-key")
        XCTAssertEqual(models.url?.absoluteString, "http://192.168.1.20:8642/v1/models")
        XCTAssertEqual(models.httpMethod, "GET")
        XCTAssertEqual(models.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    // MARK: - Replies

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testReplyJoinsMessageTextAndSkipsToolItems() throws {
        let reply = try HermesAgentAPI.parseReply(data(#"""
        {"id":"resp_1","object":"response","status":"completed","model":"hermes-agent",
         "output":[
           {"type":"function_call","name":"web_search","arguments":"{}"},
           {"type":"function_call_output","output":"raw tool text"},
           {"type":"message","role":"assistant","content":[
              {"type":"output_text","text":"It's 18 degrees."},
              {"type":"output_text","text":"Light rain later."}]}
         ],"usage":{}}
        """#))
        XCTAssertEqual(reply, HermesAgentReply(id: "resp_1", text: "It's 18 degrees.\nLight rain later."))
    }

    func testReplyFallsBackToTopLevelOutputText() throws {
        let reply = try HermesAgentAPI.parseReply(data(#"{"id":"resp_2","status":"completed","output":[],"output_text":" Done. "}"#))
        XCTAssertEqual(reply, HermesAgentReply(id: "resp_2", text: "Done."))
    }

    func testReplyFailuresAreTyped() {
        XCTAssertThrowsError(try HermesAgentAPI.parseReply(data(
            #"{"id":"r","status":"failed","error":{"message":"tool crashed"}}"#))) { error in
            XCTAssertEqual(error as? HermesAgentAPIError, .runFailed("tool crashed"))
        }
        XCTAssertThrowsError(try HermesAgentAPI.parseReply(data(
            #"{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#))) { error in
            XCTAssertEqual(error as? HermesAgentAPIError, .runFailed("max_output_tokens"))
        }
        XCTAssertThrowsError(try HermesAgentAPI.parseReply(data(
            #"{"id":"r","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"  "}]}]}"#))) { error in
            XCTAssertEqual(error as? HermesAgentAPIError, .emptyReply)
        }
        XCTAssertThrowsError(try HermesAgentAPI.parseReply(data("<html>nope</html>"))) { error in
            XCTAssertEqual(error as? HermesAgentAPIError, .malformedReply)
        }
    }

    func testModelIDs() {
        XCTAssertEqual(HermesAgentAPI.modelIDs(in: data(#"{"object":"list","data":[{"id":"hermes-agent"},{"id":"other"}]}"#)),
                       ["hermes-agent", "other"])
        XCTAssertNil(HermesAgentAPI.modelIDs(in: data("[]")))
    }

    // MARK: - Errors

    func testHTTPErrorMapping() {
        let body = data(#"{"error":{"message":"Too many concurrent runs","type":"rate_limit"}}"#)
        XCTAssertNil(HermesAgentAPI.error(status: 200, body: body))
        XCTAssertEqual(HermesAgentAPI.error(status: 401, body: body), .unauthorized)
        XCTAssertEqual(HermesAgentAPI.error(status: 403, body: nil), .unauthorized)
        XCTAssertEqual(HermesAgentAPI.error(status: 404, body: data(#"{"error":{"message":"not_found"}}"#)),
                       .notFound("not_found"))
        XCTAssertEqual(HermesAgentAPI.error(status: 429, body: body), .busy("Too many concurrent runs"))
        XCTAssertEqual(HermesAgentAPI.error(status: 503, body: data(#"{"error":{"message":"runtime_draining"}}"#)),
                       .unavailable("runtime_draining"))
        XCTAssertEqual(HermesAgentAPI.error(status: 400, body: data(#"{"error":{"message":"unsupported_content_type"}}"#)),
                       .server(status: 400, message: "unsupported_content_type"))
        XCTAssertEqual(HermesAgentAPI.error(status: 409, body: data("not json")), .server(status: 409, message: nil))
    }

    func testServerTextNeverCarriesTheKey() {
        // Built at runtime so the secret scanner has no key-shaped literal to flag.
        let key = ["fixture", "key", "0123456789"].joined(separator: "-")
        let body = data(#"{"error":{"message":"bad key "# + key + #" for\n  this   server"}}"#)
        guard case .server(_, let message?)? = HermesAgentAPI.error(status: 400, body: body, redacting: key) else {
            return XCTFail("expected a server error with a message")
        }
        XCTAssertFalse(message.contains(key))
        XCTAssertEqual(message, "bad key [key] for this server")
        XCTAssertEqual(HermesAgentAPI.sanitised(String(repeating: "a", count: 400), redacting: nil)?.count, 161)
        XCTAssertNil(HermesAgentAPI.sanitised("   \n ", redacting: nil))
        for error: HermesAgentAPIError in [.unauthorized, .missingKey, .busy("x"), .server(status: 500, message: nil)] {
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
    }

    func testTransportErrorMapping() {
        XCTAssertEqual(HermesAgentAPI.error(forTransport: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(HermesAgentAPI.error(forTransport: URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(HermesAgentAPI.error(forTransport: URLError(.secureConnectionFailed)),
                       .transport(code: URLError.secureConnectionFailed.rawValue))
        XCTAssertEqual(HermesAgentAPI.urlErrorCode(of: NSError(domain: NSPOSIXErrorDomain, code: 61)),
                       URLError.cannotConnectToHost.rawValue, "ECONNREFUSED reads as cannot connect")
        XCTAssertNil(HermesAgentAPI.urlErrorCode(of: NSError(domain: "Other", code: 1)))
    }

    // MARK: - Connection kind

    func testDefaultKindKeepsExistingBridgeUsersOnTheBridge() {
        XCTAssertEqual(HermesConnectionKind.resolved(stored: nil, bridgeHost: "192.168.1.9"), .bridgeScript)
        XCTAssertEqual(HermesConnectionKind.resolved(stored: nil, bridgeHost: ""), .apiServer)
        XCTAssertEqual(HermesConnectionKind.resolved(stored: nil, bridgeHost: "   "), .apiServer)
        XCTAssertEqual(HermesConnectionKind.resolved(stored: "apiServer", bridgeHost: "192.168.1.9"), .apiServer,
                       "a stored choice always wins")
        XCTAssertEqual(HermesConnectionKind.resolved(stored: "bridgeScript", bridgeHost: ""), .bridgeScript)
        XCTAssertEqual(HermesConnectionKind.resolved(stored: "garbage", bridgeHost: ""), .apiServer)
    }

    /// The default is written down once, so a host typed after the first launch cannot flip a
    /// fresh install from the API server to the bridge.
    func testSettlingPinsTheDefaultOnce() {
        let defaults = UserDefaults.standard
        let key = Config.hermesConnectionKindKey
        let savedKind = defaults.object(forKey: key)
        let savedHost = Config.hermesBridgeHost
        defer {
            if let savedKind { defaults.set(savedKind, forKey: key) } else { defaults.removeObject(forKey: key) }
            Config.setHermesBridgeHost(savedHost)
        }

        defaults.removeObject(forKey: key)
        Config.setHermesBridgeHost("")
        Config.settleHermesConnectionKind()
        XCTAssertEqual(defaults.string(forKey: key), "apiServer")
        Config.setHermesBridgeHost("192.168.1.9")
        Config.settleHermesConnectionKind()
        XCTAssertEqual(Config.hermesConnectionKind, .apiServer)

        defaults.removeObject(forKey: key)
        Config.settleHermesConnectionKind()
        XCTAssertEqual(Config.hermesConnectionKind, .bridgeScript, "an upgrading bridge user keeps the bridge")
    }

    func testPortHint() {
        XCTAssertEqual(HermesConnectionKind.portHint(kind: .bridgeScript, host: "192.168.1.9", port: 8642), .apiServer)
        XCTAssertEqual(HermesConnectionKind.portHint(kind: .apiServer, host: "192.168.1.9", port: 8765), .bridgeScript)
        XCTAssertNil(HermesConnectionKind.portHint(kind: .apiServer, host: "192.168.1.9", port: 8642))
        XCTAssertNil(HermesConnectionKind.portHint(kind: .bridgeScript, host: "192.168.1.9", port: 8765))
        XCTAssertEqual(HermesConnectionKind.portHint(kind: .bridgeScript, host: "192.168.1.9:8642", port: 8765),
                       .apiServer, "a port typed in the host field is the one dialled")
        XCTAssertNil(HermesConnectionKind.portHint(kind: .apiServer, host: "", port: 9000))
    }

    // MARK: - Diagnosis

    func testAPIHealthDiagnosis() {
        XCTAssertNil(HermesConnectionDiagnosis.apiHealth(status: 200, body: data(#"{"status":"ok"}"#), urlErrorCode: nil))
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: nil, body: nil,
                                                           urlErrorCode: URLError.cannotConnectToHost.rawValue),
                       .unreachable(.apiServer))
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: nil, body: nil, urlErrorCode: URLError.timedOut.rawValue),
                       .unreachable(.apiServer))
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: 200, body: data("<html>router</html>"), urlErrorCode: nil),
                       .notHermesAPIServer)
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: 404, body: nil, urlErrorCode: nil), .notHermesAPIServer)
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: 426, body: nil, urlErrorCode: nil), .looksLikeBridgeScript)
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: 503, body: data(#"{"error":{"message":"storage_unavailable"}}"#),
                                                           urlErrorCode: nil),
                       .serverError(status: 503, message: "storage_unavailable"))
        XCTAssertEqual(HermesConnectionDiagnosis.apiHealth(status: nil, body: nil,
                                                           urlErrorCode: URLError.serverCertificateUntrusted.rawValue),
                       .secureConnectionFailed)
    }

    func testAPIModelsDiagnosis() {
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 200, body: data(#"{"data":[{"id":"hermes-agent"}]}"#),
                                                           urlErrorCode: nil, redacting: "k"),
                       .apiServerReady(model: "hermes-agent"))
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 200, body: data("{}"), urlErrorCode: nil, redacting: "k"),
                       .apiServerReady(model: nil))
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 401, body: nil, urlErrorCode: nil, redacting: "k"),
                       .keyRejected)
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 403, body: nil, urlErrorCode: nil, redacting: "k"),
                       .keyRejected)
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 404, body: nil, urlErrorCode: nil, redacting: "k"),
                       .notHermesAPIServer)
        XCTAssertEqual(HermesConnectionDiagnosis.apiModels(status: 500, body: data(#"{"error":{"message":"oops k"}}"#),
                                                           urlErrorCode: nil, redacting: "k"),
                       .serverError(status: 500, message: "oops [key]"))
    }

    func testBridgeFailureDiagnosis() {
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: 101, closeCode: 4401, urlErrorCode: nil),
                       .bridgeRefusedToken)
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: 404, closeCode: nil,
                                                               urlErrorCode: URLError.badServerResponse.rawValue),
                       .looksLikeAPIServer, "plain HTTP instead of an upgrade")
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: 200, closeCode: nil, urlErrorCode: nil),
                       .looksLikeAPIServer)
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: 401, closeCode: nil, urlErrorCode: nil),
                       .bridgeRefusedToken)
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: nil, closeCode: nil,
                                                               urlErrorCode: URLError.cannotConnectToHost.rawValue),
                       .unreachable(.bridgeScript))
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: nil, closeCode: nil,
                                                               urlErrorCode: URLError.timedOut.rawValue),
                       .unreachable(.bridgeScript))
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: 101, closeCode: nil, urlErrorCode: nil),
                       .noWelcome)
        XCTAssertEqual(HermesConnectionDiagnosis.bridgeFailure(httpStatus: nil, closeCode: nil, urlErrorCode: nil),
                       .unreachable(.bridgeScript))
    }

    func testPolicyDiagnosis() {
        XCTAssertEqual(HermesConnectionDiagnosis.policy(MedicalEgressRefusal(route: .hermesAgentAPI)), .medicalLocalOnly)
        XCTAssertEqual(HermesConnectionDiagnosis.policy(
            EndpointPolicy.Rejection.cleartextHTTPNotPermitted(host: "x.example.com", route: .hermesAgentAPI)),
                       .refusedByPolicy)
        XCTAssertEqual(HermesConnectionDiagnosis.policy(EndpointPolicy.Rejection.credentialInURL), .invalidAddress)
    }

    func testExplanationsSayWhatToDoAndSuggestTheOtherKind() {
        XCTAssertTrue(HermesConnectionDiagnosis.unreachable(.apiServer).explanation.contains("API_SERVER_HOST=0.0.0.0"))
        XCTAssertTrue(HermesConnectionDiagnosis.missingKey.explanation.contains("API_SERVER_KEY"))
        XCTAssertTrue(HermesConnectionDiagnosis.bridgeRefusedToken.explanation.contains("HERMES_BRIDGE_TOKEN"))
        XCTAssertTrue(HermesConnectionDiagnosis.apiServerReady(model: "hermes-agent").explanation.contains("hermes-agent"))
        XCTAssertEqual(HermesConnectionDiagnosis.looksLikeAPIServer.suggestedKind, .apiServer)
        XCTAssertEqual(HermesConnectionDiagnosis.looksLikeBridgeScript.suggestedKind, .bridgeScript)
        XCTAssertTrue(HermesConnectionDiagnosis.apiServerReady(model: nil).isSuccess)
        XCTAssertTrue(HermesConnectionDiagnosis.bridgeReady.isSuccess)
        XCTAssertFalse(HermesConnectionDiagnosis.noWelcome.isSuccess)
        let all: [HermesConnectionDiagnosis] = [
            .apiServerReady(model: nil), .bridgeReady, .noHost, .invalidAddress, .missingKey, .medicalLocalOnly,
            .refusedByPolicy, .unreachable(.apiServer), .unreachable(.bridgeScript), .secureConnectionFailed,
            .notHermesAPIServer, .looksLikeBridgeScript, .keyRejected, .serverError(status: 500, message: nil),
            .looksLikeAPIServer, .bridgeRefusedToken, .noWelcome, .bridgeSilent, .transportFailed(code: -1),
        ]
        for diagnosis in all {
            XCTAssertFalse(diagnosis.explanation.isEmpty, diagnosis.logToken)
            XCTAssertFalse(diagnosis.explanation.contains("Plan "), "no plan letters in user-facing text")
        }
    }
}

private extension Result where Failure == EndpointPolicy.Rejection {
    var failure: EndpointPolicy.Rejection? {
        if case .failure(let rejection) = self { return rejection }
        return nil
    }
}
