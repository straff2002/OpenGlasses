import XCTest
@testable import OpenGlasses

/// BM P9 — chat SSE hardening. Fixture streams for both providers through a `URLProtocol` stub
/// (no network, no keys): delta assembly, tool-call accumulation, mid-stream `error` events and
/// premature EOF throwing instead of returning partials as success, the transient-retry policy,
/// and the per-iteration stream reset that keeps intermediate tool-turn text out of the bubble.
@MainActor
final class LLMStreamingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SSEQueueProtocol.queue = []
    }

    private func service() -> LLMService {
        let s = LLMService()
        s.streamingSession = SSEQueueProtocol.session()
        return s
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://api.test/v1")!) }

    // MARK: - Anthropic fixtures

    /// A turn that streams text, then a tool_use block, then stops for tool use.
    private let anthropicToolTurn = """
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking"}}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"get_weather"}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"Auckland\\"}"}}

    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

    data: {"type":"message_stop"}

    """

    /// A final turn: plain text, end_turn, message_stop.
    private let anthropicFinalTurn = """
    data: {"type":"message_start","message":{}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It is "}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sunny."}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

    data: {"type":"message_stop"}

    """

    // MARK: - Anthropic stream parsing

    func testAnthropicStreamAssemblesBlocksToolInputAndStopReason() async throws {
        SSEQueueProtocol.queue = [(200, anthropicToolTurn)]
        var tokens = ""
        let (content, stopReason) = try await service().streamAnthropicContent(
            request: request, model: "m") { tokens += $0 }

        XCTAssertEqual(tokens, "Checking")
        XCTAssertEqual(stopReason, "tool_use")
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"] as? String, "Checking")
        XCTAssertEqual(content[1]["name"] as? String, "get_weather")
        XCTAssertEqual((content[1]["input"] as? [String: Any])?["city"] as? String, "Auckland")
    }

    func testAnthropicMidStreamErrorThrowsInsteadOfReturningPartial() async {
        let body = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}

        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """
        SSEQueueProtocol.queue = [(200, body)]
        var tokens = ""
        do {
            _ = try await service().streamAnthropicContent(request: request, model: "m") { tokens += $0 }
            XCTFail("mid-stream error must throw, not return the partial as success")
        } catch let LLMError.streamInterrupted(provider, reason) {
            XCTAssertEqual(provider, "Anthropic")
            XCTAssertTrue(reason.contains("overloaded_error"), "got: \(reason)")
            XCTAssertEqual(tokens, "partial", "tokens before the error still streamed to the UI")
        } catch {
            XCTFail("expected .streamInterrupted, got \(error)")
        }
    }

    func testAnthropicPrematureEOFThrows() async {
        // Connection dropped before message_stop — truncation, not success.
        let body = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half an ans"}}

        """
        SSEQueueProtocol.queue = [(200, body)]
        do {
            _ = try await service().streamAnthropicContent(request: request, model: "m") { _ in }
            XCTFail("premature EOF must throw")
        } catch let LLMError.streamInterrupted(_, reason) {
            XCTAssertTrue(reason.contains("truncated"), "got: \(reason)")
        } catch {
            XCTFail("expected .streamInterrupted, got \(error)")
        }
    }

    // MARK: - OpenAI stream parsing

    func testOpenAIStreamAssemblesContentAndToolCalls() async throws {
        let body = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_weather","arguments":"{\\"cit"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"y\\":\\"AKL\\"}"}}]}}]}

        data: [DONE]

        """
        SSEQueueProtocol.queue = [(200, body)]
        var tokens = ""
        let message = try await service().streamOpenAIMessage(
            request: request, provider: .openai, model: "m") { tokens += $0 }

        XCTAssertEqual(tokens, "Hello")
        XCTAssertEqual(message["content"] as? String, "Hello")
        let calls = message["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.count, 1)
        let fn = calls?.first?["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_weather")
        XCTAssertEqual(fn?["arguments"] as? String, #"{"city":"AKL"}"#)
    }

    func testOpenAIMidStreamErrorThrows() async {
        let body = """
        data: {"choices":[{"delta":{"content":"part"}}]}

        data: {"error":{"type":"server_error","message":"The server is overloaded"}}

        """
        SSEQueueProtocol.queue = [(200, body)]
        do {
            _ = try await service().streamOpenAIMessage(request: request, provider: .openai, model: "m") { _ in }
            XCTFail("mid-stream error must throw")
        } catch let LLMError.streamInterrupted(_, reason) {
            XCTAssertTrue(reason.contains("server_error"), "got: \(reason)")
        } catch {
            XCTFail("expected .streamInterrupted, got \(error)")
        }
    }

    func testOpenAIPrematureEOFBeforeDoneThrows() async {
        SSEQueueProtocol.queue = [(200, "data: {\"choices\":[{\"delta\":{\"content\":\"cut off\"}}]}\n\n")]
        do {
            _ = try await service().streamOpenAIMessage(request: request, provider: .openai, model: "m") { _ in }
            XCTFail("EOF before [DONE] must throw")
        } catch let LLMError.streamInterrupted(_, reason) {
            XCTAssertTrue(reason.contains("truncated"), "got: \(reason)")
        } catch {
            XCTFail("expected .streamInterrupted, got \(error)")
        }
    }

    // MARK: - Transient retry policy

    func testTransientClassification() {
        XCTAssertTrue(LLMService.isTransientSSEError(LLMError.apiError(provider: "p", statusCode: 429, message: nil)))
        XCTAssertTrue(LLMService.isTransientSSEError(LLMError.apiError(provider: "p", statusCode: 529, message: nil)))
        XCTAssertTrue(LLMService.isTransientSSEError(LLMError.apiError(provider: "p", statusCode: 503, message: nil)))
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.apiError(provider: "p", statusCode: 401, message: nil)))
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.apiError(provider: "p", statusCode: 400, message: nil)))
        XCTAssertTrue(LLMService.isTransientSSEError(LLMError.streamInterrupted(provider: "p", reason: "overloaded_error: Overloaded")))
        XCTAssertTrue(LLMService.isTransientSSEError(LLMError.streamInterrupted(provider: "p", reason: "stream ended before [DONE] — response truncated")))
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.streamInterrupted(provider: "p", reason: "invalid_request_error: bad tool schema")))
        XCTAssertTrue(LLMService.isTransientSSEError(URLError(.networkConnectionLost)))
        XCTAssertFalse(LLMService.isTransientSSEError(LLMError.invalidResponse("p")))
    }

    func testRetrySucceedsAfterTransient429() async throws {
        let svc = service()
        var attempts = 0
        let result: String = try await svc.withTransientSSERetries(
            policy: .init(maxAttempts: 2, maxBackoffSeconds: 0.05),
            tokenFlag: LLMService.TokenDeliveryFlag()) {
            attempts += 1
            if attempts == 1 { throw LLMError.apiError(provider: "p", statusCode: 429, message: "rate limited") }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func testNoRetryAfterTokensReachedTheUI() async {
        let svc = service()
        let flag = LLMService.TokenDeliveryFlag()
        flag.mark()
        var attempts = 0
        do {
            let _: String = try await svc.withTransientSSERetries(tokenFlag: flag) {
                attempts += 1
                throw LLMError.apiError(provider: "p", statusCode: 429, message: nil)
            }
            XCTFail("should rethrow")
        } catch {
            XCTAssertEqual(attempts, 1, "a failure after visible partial text must not silently retry")
        }
    }

    func testNoRetryOnNonTransientError() async {
        let svc = service()
        var attempts = 0
        do {
            let _: String = try await svc.withTransientSSERetries(tokenFlag: LLMService.TokenDeliveryFlag()) {
                attempts += 1
                throw LLMError.apiError(provider: "p", statusCode: 401, message: "bad key")
            }
            XCTFail("should rethrow")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    // MARK: - Tool loop: accumulator reset per iteration

    func testStreamedToolLoopResetsAccumulatorPerIteration() async throws {
        // Two streamed iterations: a tool_use turn ("Checking") then the final reply. The caller's
        // accumulator (mirroring AppState's streaming bubble) must be reset at each iteration so
        // the bubble ends with ONLY the final text — never "CheckingIt is sunny.".
        SSEQueueProtocol.queue = [(200, anthropicToolTurn), (200, anthropicFinalTurn)]
        let svc = service()   // no tool router: the tool call fails but the loop continues

        var bubble = ""
        var resets = 0
        let config = ModelConfig(id: "t", name: "t", provider: "anthropic",
                                 apiKey: "sk-test", model: "claude-test", baseURL: "")
        let response = try await svc.sendAnthropic(
            "what's the weather", systemPrompt: "sys", config: config,
            includeTools: true, imageData: nil,
            onToken: { bubble += $0 },
            onStreamReset: { resets += 1; bubble = "" })

        XCTAssertEqual(resets, 2, "each streamed iteration must reset the accumulator")
        XCTAssertEqual(bubble, "It is sunny.", "bubble must hold only the final iteration's text")
        XCTAssertEqual(response, "It is sunny.")
        XCTAssertTrue(SSEQueueProtocol.queue.isEmpty, "both canned turns consumed")
    }
}

// MARK: - ChatGPT Responses backend (always streamed)

/// The ChatGPT-subscription backend refuses non-streaming requests
/// (`400 {"detail":"Stream must be set to true"}`), so every Responses call — including the
/// stateless summariser/structured paths that have no token sink — reads SSE and takes the
/// `response.completed` payload.
@MainActor
final class ResponsesStreamingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SSEQueueProtocol.queue = []
    }

    private func service() -> LLMService {
        let s = LLMService()
        s.streamingSession = SSEQueueProtocol.session()
        return s
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://api.test/responses")!) }

    private let completedTurn = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_1"}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"It is "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"sunny."}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"It is sunny."}]}],"usage":{"input_tokens":3,"output_tokens":4}}}

    """

    func testNoTokenSinkStillReturnsCompletedPayload() async throws {
        SSEQueueProtocol.queue = [(200, completedTurn)]
        let json = try await service().streamResponsesTurn(request: request, onToken: nil)
        XCTAssertEqual(ResponsesTranslator.parseOutput(json).text, "It is sunny.")
        XCTAssertEqual((json["usage"] as? [String: Any])?["output_tokens"] as? Int, 4)
    }

    func testTokenSinkReceivesDeltasAndCompletedPayload() async throws {
        SSEQueueProtocol.queue = [(200, completedTurn)]
        var tokens = ""
        let json = try await service().streamResponsesTurn(request: request) { tokens += $0 }
        XCTAssertEqual(tokens, "It is sunny.")
        XCTAssertEqual(json["id"] as? String, "resp_1")
    }

    func testStreamRejectionSurfacesBackendDetail() async {
        SSEQueueProtocol.queue = [(400, #"{"detail":"Stream must be set to true"}"#)]
        do {
            _ = try await service().streamResponsesTurn(request: request, onToken: nil)
            XCTFail("expected a thrown API error")
        } catch let LLMError.apiError(provider, statusCode, message) {
            XCTAssertEqual(provider, "ChatGPT")
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(message?.contains("Stream must be set to true"), true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPrematureEOFWithoutCompletionThrows() async {
        SSEQueueProtocol.queue = [(200, """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"half"}

        """)]
        do {
            _ = try await service().streamResponsesTurn(request: request, onToken: nil)
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue("\(error)".contains("stream ended without completion"), "\(error)")
        }
    }
}

// MARK: - SSE stub (queue of canned responses, popped per request)

final class SSEQueueProtocol: URLProtocol {
    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSEQueueProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.queue.isEmpty ? (status: 200, body: "") : Self.queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
