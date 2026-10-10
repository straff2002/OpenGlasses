import XCTest
@testable import OpenGlasses

/// Plan IE P1 — what each of the five Anthropic call sites actually puts on the wire, per model
/// family, through the real functions over a recording transport (no network, no keys): the
/// summariser and the one-shot frame analysis (`anthropicOneShotText`), structured vision and its
/// text sibling (`anthropicStructured`), and the conversation turn (`sendAnthropic`).
@MainActor
final class AnthropicRequestContractTests: XCTestCase {

    /// One id per row of the contract table, and one the table does not know.
    private let families = [
        "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
        "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
        "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-5-5",
        "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5",
        "claude-haiku-4-5", "claude-sonnet-4-5", "claude-nova-9",
    ]

    /// The families that answer a forced tool choice with a 400, plus the unknown id.
    private let refuseForcedToolChoice: Set<String> = [
        "claude-fable-5-1", "claude-mythos-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-nova-9",
    ]

    override func setUp() {
        super.setUp()
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func service() -> LLMService {
        let s = LLMService()
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        return s
    }

    private func config(_ model: String, effort: String? = nil) -> ModelConfig {
        ModelConfig(id: "ie", name: "ie", provider: LLMProvider.anthropic.rawValue, apiKey: "test",
                    model: model, baseURL: "", reasoningEffort: effort)
    }

    private let textReply = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#

    private let closedSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["label"],
        "properties": ["label": ["type": "string"]],
    ]
    private let openSchema: [String: Any] = [
        "type": "object", "properties": ["label": ["type": "string"]],
    ]

    private func tool(_ schema: [String: Any]) -> AnthropicRequest.AnswerTool {
        .init(name: "assessment", description: "Return the structured assessment.", schema: schema)
    }

    private var lastBody: [String: Any] {
        get throws { try XCTUnwrap(RecordingQueueProtocol.requests.last?.json) }
    }

    /// The fields no current model takes from this app: nothing may put them in a body.
    private func assertNoRefusedFields(_ body: [String: Any], _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        for field in ["thinking", "temperature", "top_p", "top_k", "budget_tokens"] {
            XCTAssertNil(body[field], "\(context): \(field)", file: file, line: line)
        }
    }

    /// The effort `ReasoningPolicy` resolves for this model at Automatic, or nil for none. Which
    /// level each family gets is `ReasoningPolicyTests`' business; here the point is that the body
    /// carries exactly what was resolved, and nothing else about reasoning.
    private func expectedAutomaticEffort(_ model: String) -> String? {
        var probe: [String: Any] = [:]
        config(model).reasoningResolution(toolsAttached: true).apply(to: &probe)
        return (probe["output_config"] as? [String: Any])?["effort"] as? String
    }

    private func effort(in body: [String: Any]) -> String? {
        (body["output_config"] as? [String: Any])?["effort"] as? String
    }

    // MARK: - Sites 1 and 2: the summariser and the one-shot frame analysis

    func testOneShotTextBodyPerFamily() async throws {
        for model in families {
            RecordingQueueProtocol.reset()
            RecordingQueueProtocol.queue = [(200, textReply), (200, textReply)]
            let svc = service()
            let thinks = AnthropicModelContract.contract(for: model).thinksByDefault

            // The summariser: a string for the user's content, a 512-token ceiling.
            _ = try await svc.anthropicOneShotText(config: config(model), system: "Summarise.",
                                                   userContent: "the conversation", maxTokens: 512,
                                                   timeout: 15, detail: "summarise")
            var body = try lastBody
            var keys: Set<String> = ["model", "max_tokens", "system", "messages"]
            if expectedAutomaticEffort(model) != nil { keys.insert("output_config") }
            XCTAssertEqual(Set(body.keys), keys, model)
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertEqual(body["system"] as? String, "Summarise.", model)
            XCTAssertEqual(body["max_tokens"] as? Int, thinks ? 4_096 : 512, model)
            XCTAssertEqual(effort(in: body), expectedAutomaticEffort(model), model)
            assertNoRefusedFields(body, model)

            // The frame analysis: an image block and a text block, a 200-token ceiling.
            _ = try await svc.anthropicOneShotText(
                config: config(model), system: "Describe.",
                userContent: [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]],
                              ["type": "text", "text": "What is this?"]] as [[String: Any]],
                maxTokens: 200, timeout: 20, detail: "analyzeFrame")
            body = try lastBody
            XCTAssertEqual(body["max_tokens"] as? Int, thinks ? 4_096 : 200, model)
            XCTAssertNil(body["tools"], model)
            XCTAssertNil(body["tool_choice"], model)
            let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"], model)
            assertNoRefusedFields(body, model)
        }
    }

    // MARK: - Sites 3 and 4: structured vision and its text sibling

    func testStructuredBodyPerFamily() async throws {
        let toolReply = #"{"content":[{"type":"tool_use","id":"tu_1","name":"assessment","input":{"label":"ok"}}],"stop_reason":"tool_use"}"#
        for model in families {
            for (schema, qualifies) in [(closedSchema, true), (openSchema, false)] {
                RecordingQueueProtocol.reset()
                RecordingQueueProtocol.queue = [(200, toolReply)]
                let result = try await service().anthropicStructured(
                    config: config(model), system: "Assess the image.", userContent: "the text",
                    tool: tool(schema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
                XCTAssertEqual(result?["label"] as? String, "ok", model)
                XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "\(model): a reply with the call is not retried")

                let body = try lastBody
                let sentTool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
                let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
                XCTAssertEqual(sentTool["name"] as? String, "assessment", model)
                XCTAssertNotNil(sentTool["input_schema"], model)
                assertNoRefusedFields(body, model)

                if refuseForcedToolChoice.contains(model) {
                    XCTAssertEqual(choice["type"] as? String, "auto", model)
                    XCTAssertNil(choice["name"], model)
                    XCTAssertEqual(sentTool["strict"] as? Bool, qualifies ? true : nil,
                                   "\(model): strict only where the schema closes every object")
                    let system = try XCTUnwrap(body["system"] as? String)
                    XCTAssertTrue(system.hasPrefix("Assess the image."), model)
                    XCTAssertTrue(system.contains("`assessment`"), "\(model): the instruction names the tool")
                    XCTAssertTrue(system.contains("calling"), model)
                } else {
                    // Unchanged where a forced choice is allowed: the tool is named, nothing is
                    // marked strict, and the system text is exactly what the caller passed.
                    XCTAssertEqual(choice["type"] as? String, "tool", model)
                    XCTAssertEqual(choice["name"] as? String, "assessment", model)
                    XCTAssertNil(sentTool["strict"], model)
                    XCTAssertEqual(body["system"] as? String, "Assess the image.", model)
                }
            }
        }
    }

    func testStructuredVisionCarriesTheImage() async throws {
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"tool_use","id":"t","name":"assessment","input":{"label":"gauge"}}]}"#)]
        let result = try await service().anthropicStructured(
            config: config("claude-sonnet-5-5"), system: "Assess.",
            userContent: [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]],
                          ["type": "text", "text": "Read the gauge."]] as [[String: Any]],
            tool: tool(closedSchema), maxTokens: 1_024, timeout: 30, detail: "analyzeFrameStructured")
        XCTAssertEqual(result?["label"] as? String, "gauge")
        let content = try XCTUnwrap((try lastBody["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual(try lastBody["max_tokens"] as? Int, 4_096, "room for the thinking this family does")
    }

    /// Asked in words, a model can answer in prose. The parser's tolerant fallback reads it, and
    /// that is an answer — no second request.
    func testStructuredReplyAsProseJSONIsAcceptedWithoutARetry() async throws {
        let prose = #"{"content":[{"type":"thinking","thinking":"","signature":"signature-fixture"},{"type":"text","text":"Here it is: {\"label\": \"prose\"}"}],"stop_reason":"end_turn"}"#
        RecordingQueueProtocol.queue = [(200, prose)]
        let result = try await service().anthropicStructured(
            config: config("claude-opus-5-5"), system: "Assess.", userContent: "x",
            tool: tool(closedSchema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
        XCTAssertEqual(result?["label"] as? String, "prose")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
    }

    /// Neither a call nor readable JSON: asked once more, and only once. Two empty replies are nil.
    func testStructuredReplyWithNeitherIsRetriedOnceThenNil() async throws {
        let neither = #"{"content":[{"type":"text","text":"I can see a pressure gauge."}],"stop_reason":"end_turn"}"#
        RecordingQueueProtocol.queue = [(200, neither), (200, neither), (200, neither)]
        let result = try await service().anthropicStructured(
            config: config("claude-sonnet-5-5"), system: "Assess.", userContent: "x",
            tool: tool(closedSchema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
        XCTAssertNil(result)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2, "one retry, not a loop")
        XCTAssertEqual(RecordingQueueProtocol.requests[0].body, RecordingQueueProtocol.requests[1].body,
                       "the retry is the same request")
    }

    func testStructuredRetryCanSucceed() async throws {
        let neither = #"{"content":[{"type":"text","text":"A gauge."}],"stop_reason":"end_turn"}"#
        let call = #"{"content":[{"type":"tool_use","id":"t","name":"assessment","input":{"label":"second"}}],"stop_reason":"tool_use"}"#
        RecordingQueueProtocol.queue = [(200, neither), (200, call)]
        let result = try await service().anthropicStructured(
            config: config("claude-fable-5-1"), system: "Assess.", userContent: "x",
            tool: tool(openSchema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
        XCTAssertEqual(result?["label"] as? String, "second")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
    }

    /// Where the call is forced the behaviour is what it was: one request, whatever comes back.
    func testForcedFamiliesAreNotRetried() async throws {
        let neither = #"{"content":[{"type":"text","text":"A gauge."}],"stop_reason":"end_turn"}"#
        RecordingQueueProtocol.queue = [(200, neither), (200, neither)]
        let result = try await service().anthropicStructured(
            config: config("claude-opus-4-8"), system: "Assess.", userContent: "x",
            tool: tool(closedSchema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
        XCTAssertNil(result)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
    }

    /// A refused request is not a reply: the same body would be refused again.
    func testARejectedStructuredRequestIsNotRetried() async throws {
        RecordingQueueProtocol.queue = [(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"fixture"}}"#),
                                        (200, textReply)]
        let result = try await service().anthropicStructured(
            config: config("claude-sonnet-5-5"), system: "Assess.", userContent: "x",
            tool: tool(closedSchema), maxTokens: 1_024, timeout: 30, detail: "completeStructured")
        XCTAssertNil(result)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
    }

    // MARK: - Defect E: the reply is read by type, not by position

    func testOneShotTextSkipsALeadingThinkingBlock() async throws {
        let reply = #"{"content":[{"type":"thinking","thinking":"","signature":"signature-fixture"},{"type":"redacted_thinking","data":"opaque-fixture"},{"type":"text","text":"A red valve."}],"stop_reason":"end_turn"}"#
        RecordingQueueProtocol.queue = [(200, reply)]
        let text = try await service().anthropicOneShotText(
            config: config("claude-sonnet-5-5"), system: "Describe.", userContent: "x",
            maxTokens: 200, timeout: 20, detail: "analyzeFrame")
        XCTAssertEqual(text, "A red valve.")
    }

    func testOneShotTextJoinsTextBlocksTheWayTheToolLoopDoes() {
        let content: [[String: Any]] = [
            ["type": "thinking", "thinking": "not the reply", "signature": "signature-fixture"],
            ["type": "text", "text": "First."],
            ["type": "tool_use", "id": "t", "name": "n", "input": ["text": "not the reply either"]],
            ["type": "text", "text": "Second."],
        ]
        XCTAssertEqual(AnthropicReply.text(in: content), "First.\nSecond.")
        let data = try! JSONSerialization.data(withJSONObject: ["content": content, "stop_reason": "end_turn"])
        XCTAssertEqual(AnthropicReply.oneShotText(from: data), "First.\nSecond.")
    }

    func testOneShotTextIsNilForADeclinedAnEmptyOrAnUnreadableReply() async throws {
        XCTAssertNil(AnthropicReply.oneShotText(from: Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"refusal"}"#.utf8)))
        XCTAssertNil(AnthropicReply.oneShotText(from: Data(#"{"content":[{"type":"thinking","thinking":"","signature":"s"}],"stop_reason":"max_tokens"}"#.utf8)))
        XCTAssertNil(AnthropicReply.oneShotText(from: Data(#"{"content":[]}"#.utf8)))
        XCTAssertNil(AnthropicReply.oneShotText(from: Data("not json".utf8)))
        // A reply cut short that did say something is still what it said.
        XCTAssertEqual(AnthropicReply.oneShotText(from: Data(#"{"content":[{"type":"text","text":"Half an"}],"stop_reason":"max_tokens"}"#.utf8)), "Half an")

        RecordingQueueProtocol.queue = [(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"fixture"}}"#)]
        let refused = try await service().anthropicOneShotText(
            config: config("claude-sonnet-5-5"), system: "Describe.", userContent: "x",
            maxTokens: 200, timeout: 20, detail: "analyzeFrame")
        XCTAssertNil(refused)
    }

    // MARK: - Site 5: the conversation turn

    func testTurnBodyPerFamily() async throws {
        for model in families {
            for includeTools in [true, false] {
                RecordingQueueProtocol.reset()
                RecordingQueueProtocol.queue = [(200, textReply)]
                let reply = try await service().sendAnthropic(
                    "hello", systemPrompt: "stable head", volatileTail: "volatile tail",
                    config: config(model), includeTools: includeTools, imageData: nil)
                XCTAssertEqual(reply, "ok", model)

                let body = try lastBody
                let contract = AnthropicModelContract.contract(for: model)
                var keys: Set<String> = ["model", "max_tokens", "system", "messages"]
                if includeTools { keys.insert("tools") }
                if expectedAutomaticEffort(model) != nil { keys.insert("output_config") }
                XCTAssertEqual(Set(body.keys), keys, "\(model) tools=\(includeTools)")
                XCTAssertNil(body["tool_choice"], "\(model): a turn never forces a tool")
                XCTAssertNil(body["stream"], model)
                assertNoRefusedFields(body, model)
                XCTAssertEqual(effort(in: body), expectedAutomaticEffort(model), model)

                // The output ceiling: 1,024 on a tool turn where the model does not think by
                // default, never under 4,096 where it does.
                let base = includeTools ? 1_024 : Config.maxTokens
                XCTAssertEqual(body["max_tokens"] as? Int, contract.outputCap(base: base), "\(model) tools=\(includeTools)")
                if contract.thinksByDefault {
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(body["max_tokens"] as? Int), 4_096, model)
                } else if includeTools {
                    XCTAssertEqual(body["max_tokens"] as? Int, 1_024, model)
                }

                // The cache breakpoint stays on the stable head; the tail follows uncached.
                let system = try XCTUnwrap(body["system"] as? [[String: Any]])
                XCTAssertEqual(system.count, 2, model)
                XCTAssertEqual(system[0]["text"] as? String, "stable head", model)
                XCTAssertNotNil(system[0]["cache_control"], model)
                XCTAssertEqual(system[1]["text"] as? String, "volatile tail", model)
                XCTAssertNil(system[1]["cache_control"], model)
            }
        }
    }

    func testTurnBodyBytesAreStableForTheSameContent() async throws {
        // Sorted keys: two turns with the same content produce the same bytes (prompt caching).
        var bodies: [Data] = []
        for _ in 0..<2 {
            RecordingQueueProtocol.reset()
            RecordingQueueProtocol.queue = [(200, textReply)]
            _ = try await service().sendAnthropic("hello", systemPrompt: "stable head", volatileTail: "tail",
                                                  config: config("claude-sonnet-5-5", effort: "medium"),
                                                  includeTools: true, imageData: nil)
            bodies.append(try XCTUnwrap(RecordingQueueProtocol.requests.last?.body))
        }
        XCTAssertEqual(bodies[0], bodies[1])
        // Sorted all the way down: the top-level keys arrive in order.
        let text = String(decoding: bodies[0], as: UTF8.self)
        let positions = ["\"max_tokens\"", "\"messages\"", "\"model\"", "\"system\"", "\"tools\""]
            .compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, 5)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testStreamedTurnAsksForAStream() async throws {
        let stream = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        data: {"type":"message_stop"}

        """
        RecordingQueueProtocol.queue = [(200, stream)]
        _ = try await service().sendAnthropic("hello", systemPrompt: "sys", config: config("claude-opus-5-5"),
                                              includeTools: true, imageData: nil, onToken: { _ in })
        XCTAssertEqual(try lastBody["stream"] as? Bool, true)
    }
}
