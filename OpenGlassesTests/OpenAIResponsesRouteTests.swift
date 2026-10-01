import XCTest
@testable import OpenGlasses

/// Plan GC P2 — the OpenAI API route through the real `sendOpenAICompatible`, over a fake
/// transport (no network, no keys): an explicit reasoning level with tools goes to `/v1/responses`
/// and replays its encrypted reasoning across the tool round-trip; Automatic stays on Chat
/// Completions at `none`; a Responses 4xx retries once on Chat Completions and is remembered; a
/// 401 is not retried; the cloud agent's entry takes the same route; a reply the output cap cut
/// short is named in the log.
@MainActor
final class OpenAIResponsesRouteTests: XCTestCase {

    private var usagePath: URL!
    /// Every service a test made, and a weak hold on each tracker, so `tearDown` can see the
    /// usage database's connection closed before it unlinks the file.
    private var services: [LLMService] = []
    private var trackers: [WeakTracker] = []

    private struct WeakTracker { weak var tracker: UsageTracker? }

    override func setUp() {
        super.setUp()
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        usagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-usage-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        services.forEach { $0.usageTrackerOverride = nil }
        services = []
        // A recorded turn lands through a main-actor Task that holds its tracker, and it can
        // still be queued when the test returns. Let those run, so the last reference — and with
        // it the connection — is gone before the file is.
        var spins = 0
        while trackers.contains(where: { $0.tracker != nil }), spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        trackers = []
        try? FileManager.default.removeItem(at: usagePath)
        try await super.tearDown()
    }

    private func service() -> (LLMService, UsageTracker) {
        let s = LLMService()
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        let tracker = UsageTracker(store: UsageStore(path: usagePath))
        s.usageTrackerOverride = tracker
        services.append(s)
        trackers.append(WeakTracker(tracker: tracker))
        return (s, tracker)
    }

    private func config(_ model: String = "gpt-6-sol", effort: String? = "medium") -> ModelConfig {
        ModelConfig(id: "gc", name: "gc", provider: LLMProvider.openai.rawValue, apiKey: "test",
                    model: model, baseURL: "", reasoningEffort: effort)
    }

    // MARK: - Fixtures

    private let reasoningItem: [String: Any] = [
        "type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "enc",
    ]

    /// Request 1: the model reasons, then calls `get_time`. The completed envelope is slim (no
    /// `output`), as the live backend sends it; the items arrive on `output_item.done`.
    private var toolCallTurn: String {
        """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_time","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":0},"output_tokens":60,"output_tokens_details":{"reasoning_tokens":48}}}}


        """
    }

    private func answerTurn(_ text: String = "It is noon.") -> String {
        """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"\(text)"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"\(text)"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","usage":{"input_tokens":200,"input_tokens_details":{"cached_tokens":100},"output_tokens":10}}}


        """
    }

    private func chatAnswer(_ text: String = "Fine.") -> String {
        #"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
    }

    private func capturingLog(_ body: () async throws -> Void) async rethrows -> [String] {
        let sink = LineSink()
        let token = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(token) }
        try await body()
        return sink.lines
    }

    /// Usage lands through a main-actor `Task`; poll until it has, bounded.
    private func records(_ tracker: UsageTracker, atLeast count: Int) async -> [UsageRecord] {
        for _ in 0..<200 {
            let found = tracker.store.records(since: .distantPast)
            if found.count >= count { return found }
            await Task.yield()
        }
        return tracker.store.records(since: .distantPast)
    }

    // MARK: - 1. Explicit Medium with tools → Responses, reasoning replayed

    func testExplicitMediumWithToolsUsesResponsesAndReplaysReasoning() async throws {
        RecordingQueueProtocol.queue = [(200, toolCallTurn), (200, answerTurn())]
        let (svc, tracker) = service()

        let reply = try await svc.sendOpenAICompatibleForTesting(
            "what time is it", volatileTail: "Now: test", config: config())

        XCTAssertEqual(reply, "It is noon.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2)

        let first = requests[0]
        XCTAssertEqual(first.url, "https://api.openai.com/v1/responses")
        XCTAssertEqual(first.headers["Authorization"], "Bearer test")
        let body1 = try XCTUnwrap(first.json)
        XCTAssertEqual(body1["store"] as? Bool, false)
        XCTAssertEqual(body1["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual((body1["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertGreaterThanOrEqual(body1["max_output_tokens"] as? Int ?? 0, 4096)
        XCTAssertTrue((body1["prompt_cache_key"] as? String)?.hasPrefix("og-") == true)
        XCTAssertFalse((body1["instructions"] as? String ?? "").isEmpty)
        XCTAssertNil(body1["messages"], "a Responses body, not a Chat Completions one")
        let input1 = body1["input"] as? [[String: Any]] ?? []
        XCTAssertEqual(input1.last?["role"] as? String, "developer",
                       "the volatile tail rides last, after the history")

        let body2 = try XCTUnwrap(requests[1].json)
        let input2 = body2["input"] as? [[String: Any]] ?? []
        let reasoningIndex = try XCTUnwrap(input2.firstIndex { $0["type"] as? String == "reasoning" })
        XCTAssertTrue(NSDictionary(dictionary: input2[reasoningIndex]).isEqual(to: reasoningItem),
                      "the reasoning item is replayed verbatim")
        XCTAssertEqual(input2[reasoningIndex + 1]["type"] as? String, "function_call",
                       "the reasoning item immediately precedes its function_call")
        XCTAssertEqual(input2[reasoningIndex + 1]["call_id"] as? String, "call_1")
        let outputIndex = try XCTUnwrap(input2.firstIndex { $0["type"] as? String == "function_call_output" })
        XCTAssertGreaterThan(outputIndex, reasoningIndex + 1)
        XCTAssertEqual(input2[outputIndex]["call_id"] as? String, "call_1")

        for message in svc.rawConversationHistoryForTesting() {
            XCTAssertNil(message[ResponsesTranslator.rawOutputItemsKey],
                         "the reasoning ciphertext leaves the transcript when the turn ends")
        }

        let recorded = await records(tracker, atLeast: 2)
        XCTAssertEqual(recorded.count, 2, "usage recorded once per request")
        XCTAssertEqual(recorded.map(\.provider), ["openai", "openai"])
        XCTAssertEqual(Set(recorded.map(\.tokensIn)), [120, 100],
                       "Responses usage parsed, cached input counted once")
    }

    // MARK: - 2. Automatic with tools → Chat Completions at none

    func testAutomaticWithToolsStaysOnChatCompletionsAtNone() async throws {
        RecordingQueueProtocol.queue = [(200, chatAnswer())]
        let (svc, _) = service()

        let reply = try await svc.sendOpenAICompatibleForTesting("hello", config: config(effort: nil))

        XCTAssertEqual(reply, "Fine.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        let request = RecordingQueueProtocol.requests[0]
        XCTAssertEqual(request.url, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.json?["reasoning_effort"] as? String, "none")
        XCTAssertNotNil(request.json?["messages"])
    }

    // MARK: - 3. Responses 400 → one Chat Completions retry at none, remembered

    func testResponses400FallsBackOnceToChatAtNone() async throws {
        RecordingQueueProtocol.queue = [
            (400, #"{"error":{"message":"This model is not supported on this endpoint.","type":"invalid_request_error"}}"#),
            (200, chatAnswer()),
        ]
        let (svc, _) = service()
        var resets = 0

        let lines = try await capturingLog {
            let reply = try await svc.sendOpenAICompatibleForTesting(
                "what time is it", config: config(), onStreamReset: { resets += 1 })
            XCTAssertEqual(reply, "Fine.")
        }

        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2, "one Responses attempt, one Chat Completions retry")
        XCTAssertEqual(requests[0].url, "https://api.openai.com/v1/responses")
        XCTAssertEqual(requests[1].url, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(requests[1].json?["reasoning_effort"] as? String, "none")
        XCTAssertFalse(requests[1].bodyText.contains(ResponsesTranslator.rawOutputItemsKey))
        XCTAssertGreaterThanOrEqual(resets, 1, "the caller's bubble is cleared before the retry")

        let userTurns = svc.conversationHistorySnapshotForTesting()
            .filter { $0.role == "user" && $0.content == "what time is it" }
        XCTAssertEqual(userTurns.count, 1, "the rewound turn does not append the user message twice")
        XCTAssertTrue(lines.contains { $0.contains("routeFallback") && $0.contains("chatCompletions") },
                      "the fallback carries its own marker")

        // A later turn on the same model goes straight to Chat Completions.
        RecordingQueueProtocol.queue = [(200, chatAnswer("Again."))]
        let later = try await capturingLog {
            _ = try await svc.sendOpenAICompatibleForTesting("and now", config: config())
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 3)
        XCTAssertEqual(RecordingQueueProtocol.requests[2].url, "https://api.openai.com/v1/chat/completions")
        XCTAssertTrue(later.contains { $0.contains("routeSelected") && $0.contains("responsesRefusedEarlier") })
    }

    // MARK: - 4. Responses 401 → propagates, not retried

    func testResponses401IsNotRetriedOnChat() async {
        RecordingQueueProtocol.queue = [
            (401, #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}"#),
            (200, chatAnswer()),
        ]
        let (svc, _) = service()

        do {
            _ = try await svc.sendOpenAICompatibleForTesting("what time is it", config: config())
            XCTFail("expected the 401 to propagate")
        } catch LLMError.apiError(_, let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "authentication failures are not retried")
        XCTAssertEqual(RecordingQueueProtocol.requests[0].url, "https://api.openai.com/v1/responses")
    }

    // MARK: - 5. The cloud agent's entry takes the same route

    func testCloudAgentEntryUsesResponses() async throws {
        RecordingQueueProtocol.queue = [(200, answerTurn("Done."))]
        let (svc, _) = service()

        let reply = try await svc.sendCloudForTesting("run the check", config: config())

        XCTAssertEqual(reply, "Done.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertEqual(RecordingQueueProtocol.requests[0].url, "https://api.openai.com/v1/responses")
        XCTAssertEqual((RecordingQueueProtocol.requests[0].json?["reasoning"] as? [String: Any])?["effort"] as? String,
                       "medium")
    }

    // MARK: - 6. Output cap reached before any text → named, then the empty-completion path

    func testMaxOutputIncompleteIsLoggedNotSilent() async throws {
        RecordingQueueProtocol.queue = [(200, """
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_9","summary":[],"encrypted_content":"enc"}}

        event: response.incomplete
        data: {"type":"response.incomplete","response":{"id":"resp_9","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":50,"output_tokens":4096}}}


        """)]
        let (svc, _) = service()
        var reply: String?

        let lines = try await capturingLog {
            reply = try await svc.sendOpenAICompatibleForTesting("think hard", config: config())
        }

        XCTAssertEqual(reply, "", "the turn ends the way an empty completion does")
        XCTAssertTrue(lines.contains { $0.contains("emptyCompletion") && $0.contains("maxOutputTokens") },
                      "the cut-off reply is named in the privacy log")
    }

    // MARK: - Streamed (Chat tab) turn

    func testStreamedResponsesTurnDeliversDeltas() async throws {
        RecordingQueueProtocol.queue = [(200, answerTurn("Streamed."))]
        let (svc, _) = service()
        var bubble = ""

        let reply = try await svc.sendOpenAICompatibleForTesting(
            "hello", config: config(), onToken: { bubble += $0 }, onStreamReset: { bubble = "" })

        XCTAssertEqual(reply, "Streamed.")
        XCTAssertEqual(bubble, "Streamed.")
        XCTAssertEqual(RecordingQueueProtocol.requests.first?.url, "https://api.openai.com/v1/responses")
    }

    // MARK: - Chat Completions URL derivation is unchanged

    /// The string surgery `sendOpenAICompatible` did before Plan GC, kept here as the oracle.
    private func legacyChatURL(_ base: String) -> String {
        var url = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasSuffix("/chat/completions") {
            url += url.hasSuffix("/") ? "chat/completions" : "/chat/completions"
        }
        return url
    }

    func testChatCompletionsURLMatchesTheLegacyDerivation() {
        var bases = LLMProvider.allCases.map(\.defaultBaseURL).filter { $0.hasSuffix("/chat/completions") }
        bases += [
            "https://api.openai.com/v1", "https://api.openai.com/v1/",
            "https://r.openai.azure.com/openai/v1", " https://r.openai.azure.com/openai/v1 ",
            "http://192.168.1.20:11434/v1", "http://localhost:1234/v1/",
            "https://openrouter.ai/api/v1", "https://gateway.test/proxy/openai/v1/chat/completions",
        ]
        for provider in [LLMProvider.openai, .custom, .groq] {
            for base in bases {
                XCTAssertEqual(LLMService.chatCompletionsURLString(baseURL: base, provider: provider),
                               legacyChatURL(base), "\(provider.rawValue) \(base)")
            }
        }
        // An empty base: the API default for the OpenAI provider only; any other provider keeps
        // the old relative path instead of sending its key to api.openai.com.
        XCTAssertEqual(LLMService.chatCompletionsURLString(baseURL: "", provider: .openai),
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(LLMService.chatCompletionsURLString(baseURL: "", provider: .custom), legacyChatURL(""))
    }

    func testFallbackStatusPolicy() {
        for status in [400, 404, 409, 413, 422] {
            XCTAssertTrue(LLMService.responsesRouteShouldFallBack(status: status), "\(status)")
        }
        for status in [200, 401, 403, 429, 500, 502, 503] {
            XCTAssertFalse(LLMService.responsesRouteShouldFallBack(status: status), "\(status)")
        }
    }
}

// MARK: - Recording transport (queue of canned responses, every request kept)

final class RecordingQueueProtocol: URLProtocol {
    struct Recorded {
        let url: String
        let headers: [String: String]
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    }

    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    private static let lock = NSLock()

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        recorded = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingQueueProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        Self.lock.lock()
        Self.recorded.append(Recorded(url: request.url?.absoluteString ?? "",
                                      headers: request.allHTTPHeaderFields ?? [:], body: body))
        let next = Self.queue.isEmpty ? (status: 200, body: "") : Self.queue.removeFirst()
        Self.lock.unlock()
        let contentType = next.body.hasPrefix("{") ? "application/json" : "text/event-stream"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []
    func record(_ line: String) { lock.lock(); captured.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return captured }
}
