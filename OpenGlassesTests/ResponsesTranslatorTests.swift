import XCTest
@testable import OpenGlasses

/// Fixture coverage for the Responses-API wire translation (Plan BW P2): chat-format history →
/// input items, chat tools → Responses tools, output parsing (with the tool-call leniency the
/// chat-completions path learned live), history round-trip, and SSE stream accumulation.
final class ResponsesTranslatorTests: XCTestCase {

    // MARK: - Input items

    func testUserTextAndImageBecomeInputBlocks() throws {
        let history: [[String: Any]] = [
            ["role": "user", "content": "plain question"],
            ["role": "user", "content": [
                ["type": "text", "text": "what's this?"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]],
            ]],
        ]
        let items = ResponsesTranslator.inputItems(history: history)
        XCTAssertEqual(items.count, 2)

        let first = items[0]
        XCTAssertEqual(first["type"] as? String, "message")
        XCTAssertEqual(first["role"] as? String, "user")
        let firstBlocks = try XCTUnwrap(first["content"] as? [[String: Any]])
        XCTAssertEqual(firstBlocks.first?["type"] as? String, "input_text")
        XCTAssertEqual(firstBlocks.first?["text"] as? String, "plain question")

        let secondBlocks = try XCTUnwrap(items[1]["content"] as? [[String: Any]])
        XCTAssertEqual(secondBlocks.count, 2)
        XCTAssertEqual(secondBlocks[1]["type"] as? String, "input_image")
        XCTAssertEqual(secondBlocks[1]["image_url"] as? String, "data:image/jpeg;base64,AAAA")
    }

    func testAssistantToolCallsAndToolResultsRoundTrip() throws {
        // A full tool turn in chat format: assistant calls → tool result → assistant answer.
        let history: [[String: Any]] = [
            ["role": "user", "content": "status?"],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "call_9", "type": "function",
                 "function": ["name": "home_status", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "call_9", "content": "all quiet"],
            ["role": "assistant", "content": "All quiet at home."],
        ]
        let items = ResponsesTranslator.inputItems(history: history)
        XCTAssertEqual(items.count, 4)

        XCTAssertEqual(items[1]["type"] as? String, "function_call")
        XCTAssertEqual(items[1]["call_id"] as? String, "call_9")
        XCTAssertEqual(items[1]["name"] as? String, "home_status")
        XCTAssertEqual(items[1]["arguments"] as? String, "{}")

        XCTAssertEqual(items[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(items[2]["call_id"] as? String, "call_9")
        XCTAssertEqual(items[2]["output"] as? String, "all quiet")

        XCTAssertEqual(items[3]["type"] as? String, "message")
        XCTAssertEqual(items[3]["role"] as? String, "assistant")
        let blocks = try XCTUnwrap(items[3]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "output_text")
    }

    // MARK: - Tools

    func testChatToolsAreHoistedToResponsesShape() throws {
        let chatTools: [[String: Any]] = [
            ["type": "function", "function": [
                "name": "get_weather",
                "description": "Current weather",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
            ] as [String: Any]],
        ]
        let tools = ResponsesTranslator.responseTools(fromChatTools: chatTools)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "get_weather")
        XCTAssertEqual(tools[0]["description"] as? String, "Current weather")
        XCTAssertNotNil(tools[0]["parameters"])
    }

    func testRequestBodyShape() throws {
        let body = ResponsesTranslator.requestBody(
            model: "test-model", instructions: "be brief",
            history: [["role": "user", "content": "hi"]],
            tools: [["type": "function", "function": ["name": "t", "description": "d"] as [String: Any]]])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["instructions"] as? String, "be brief")
        // The backend answers `400 Stream must be set to true` to anything else.
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["input"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["name"] as? String, "t")
    }

    // MARK: - Output parsing

    func testParseOutputTextAndToolCall() {
        let response: [String: Any] = ["output": [
            ["type": "reasoning", "summary": []],
            ["type": "message", "content": [["type": "output_text", "text": "Checking now."]]],
            ["type": "function_call", "call_id": "call_1", "name": "home_status",
             "arguments": #"{"room":"all"}"#],
        ]]
        let parsed = ResponsesTranslator.parseOutput(response)
        XCTAssertEqual(parsed.text, "Checking now.")
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.toolCalls.first?.name, "home_status")
        XCTAssertEqual(parsed.toolCalls.first?.id, "call_1")
        XCTAssertEqual(parsed.toolCalls.first?.arguments?["room"] as? String, "all")
    }

    /// The leniency contract: a no-argument tool call with no call id must not be dropped.
    func testParseOutputToleratesMissingIDAndArguments() {
        let response: [String: Any] = ["output": [
            ["type": "function_call", "name": "home_status"],
        ]]
        let parsed = ResponsesTranslator.parseOutput(response)
        XCTAssertEqual(parsed.toolCalls.count, 1, "missing id/arguments must not drop the call")
        XCTAssertEqual(parsed.toolCalls.first?.id, "call_0", "missing call id is synthesised")
        XCTAssertEqual(parsed.toolCalls.first?.arguments?.isEmpty, true, "missing arguments default to {}")
    }

    func testAssistantHistoryMessageRoundTripsThroughInputItems() {
        let message = ResponsesTranslator.assistantHistoryMessage(
            text: "on it",
            toolCalls: [ToolInvocation(id: "call_2", name: "get_weather",
                                       arguments: ["city": "Auckland"],
                                       rawArguments: #"{"city":"Auckland"}"#)])
        let items = ResponsesTranslator.inputItems(history: [message])
        XCTAssertEqual(items.count, 2)   // text message + function_call
        XCTAssertEqual(items[1]["type"] as? String, "function_call")
        XCTAssertEqual(items[1]["call_id"] as? String, "call_2")
        XCTAssertEqual(items[1]["arguments"] as? String, #"{"city":"Auckland"}"#)
    }

    // MARK: - Image pruning compatibility

    /// History for this provider is stored in the chat shape, so the existing multi-format
    /// image pruning applies without new cases — pin that assumption.
    func testChatFormatHistoryIsPrunableByHistoryHygiene() {
        func imageTurn(_ text: String) -> [String: Any] {
            ["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]],
                ["type": "text", "text": text],
            ]]
        }
        let pruned = HistoryHygiene.pruneImages([imageTurn("old"), imageTurn("new")], keepLast: 1)
        let oldBlocks = pruned[0]["content"] as? [[String: Any]]
        XCTAssertFalse(oldBlocks?.contains { $0["type"] as? String == "image_url" } ?? true)
    }

    // MARK: - Stream accumulation

    func testStreamAccumulatorDeltasAndCompletion() {
        var accumulator = ResponsesTranslator.StreamAccumulator()
        let events = SSEEventParser.parse("""
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hel"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"lo"}

        event: response.completed
        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}]}}

        """)
        var streamed = ""
        for event in events {
            if let delta = accumulator.consume(event) { streamed += delta }
        }
        XCTAssertEqual(streamed, "Hello")
        let final = ResponsesTranslator.parseOutput(accumulator.completedResponse ?? [:])
        XCTAssertEqual(final.text, "Hello", "the completed payload is the authoritative result")
        XCTAssertNil(accumulator.failureMessage)
    }

    /// The backend slimmed `response.completed` to metadata/usage — no `output` array — which
    /// made every reply parse to empty text and zero tool calls, silently (seen on device
    /// 2026-09-04, gpt-5.6-terra; the upstream client never reads output from the envelope,
    /// collecting `response.output_item.done` instead). The accumulator must do the same.
    func testSlimCompletedEnvelopeUsesStreamedOutputItems() {
        var accumulator = ResponsesTranslator.StreamAccumulator()
        for event in SSEEventParser.parse("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"reasoning","summary":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Hello from items"}]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"get_weather","call_id":"c1","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":10,"output_tokens":5}}}

        """) {
            _ = accumulator.consume(event)
        }
        let final = ResponsesTranslator.parseOutput(accumulator.effectiveResponse ?? [:])
        XCTAssertEqual(final.text, "Hello from items")
        XCTAssertEqual(final.toolCalls.count, 1)
        XCTAssertEqual(final.toolCalls.first?.name, "get_weather")
        // Usage from the slim envelope survives alongside the substituted items.
        XCTAssertNotNil(accumulator.effectiveResponse?["usage"])
    }

    /// A fat envelope that genuinely carries output still wins over streamed items — older
    /// backends and every existing fixture keep their meaning.
    func testFatCompletedEnvelopeStillAuthoritative() {
        var accumulator = ResponsesTranslator.StreamAccumulator()
        for event in SSEEventParser.parse("""
        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"from items"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"from envelope"}]}]}}

        """) {
            _ = accumulator.consume(event)
        }
        let final = ResponsesTranslator.parseOutput(accumulator.effectiveResponse ?? [:])
        XCTAssertEqual(final.text, "from envelope")
    }

    func testStreamAccumulatorCapturesFailure() {
        var accumulator = ResponsesTranslator.StreamAccumulator()
        for event in SSEEventParser.parse("""
        event: response.failed
        data: {"type":"response.failed","response":{"error":{"message":"quota exhausted"}}}

        """) {
            _ = accumulator.consume(event)
        }
        XCTAssertEqual(accumulator.failureMessage, "quota exhausted")
        XCTAssertNil(accumulator.completedResponse)
    }

    // MARK: - Plan GC: the API route's body and reasoning replay

    private let rawReasoning: [String: Any] = [
        "type": "reasoning", "id": "rs_1",
        "summary": [["type": "summary_text", "text": "thinking"]],
        "encrypted_content": "gAAAAB-ciphertext",
    ]
    private let rawCall: [String: Any] = [
        "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "manual_lookup",
        "arguments": #"{"query":"fault 42"}"#, "status": "completed",
    ]

    private func replayHistory() -> [[String: Any]] {
        [
            ["role": "user", "content": "why is the pump tripping?"],
            ResponsesTranslator.assistantHistoryMessage(
                text: "",
                toolCalls: [ToolInvocation(id: "call_1", name: "manual_lookup",
                                           arguments: ["query": "fault 42"],
                                           rawArguments: #"{"query":"fault 42"}"#)],
                rawOutputItems: [rawReasoning, rawCall]),
            ["role": "tool", "tool_call_id": "call_1", "content": "Fault 42: over-current."],
        ]
    }

    private func replayOptions() -> ResponsesTranslator.RequestOptions {
        ResponsesTranslator.RequestOptions(
            includeEncryptedReasoning: true, maxOutputTokens: 4096, promptCacheKey: "og-abc",
            reasoning: ReasoningPolicy.resolve(provider: .openai, model: "gpt-6-sol", route: .responses,
                                               toolsAttached: true, requested: "medium"),
            trailingDeveloperMessage: "Local time 09:14.")
    }

    private func replayBody() -> [String: Any] {
        ResponsesTranslator.requestBody(
            model: "gpt-6-sol", instructions: "stable head", history: replayHistory(),
            tools: [["type": "function", "function": ["name": "manual_lookup", "description": "d",
                                                      "parameters": ["type": "object"]] as [String: Any]]],
            options: replayOptions())
    }

    func testToolTurnGoldenBodyReplaysReasoningInOrder() throws {
        let body = replayBody()
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 5)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[1]["type"] as? String, "reasoning")
        XCTAssertEqual(input[1]["id"] as? String, "rs_1")
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "gAAAAB-ciphertext")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["id"] as? String, "fc_1", "replayed verbatim, not re-synthesised")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[4]["type"] as? String, "message")
        XCTAssertEqual(input[4]["role"] as? String, "developer")
        let tail = try XCTUnwrap(input[4]["content"] as? [[String: Any]])
        XCTAssertEqual(tail.first?["type"] as? String, "input_text")
        XCTAssertEqual(tail.first?["text"] as? String, "Local time 09:14.")

        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(body["prompt_cache_key"] as? String, "og-abc")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "medium")
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["instructions"] as? String, "stable head")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["name"] as? String, "manual_lookup")
    }

    func testSerialisedBodyIsStableAcrossBuilds() throws {
        let first = try JSONSerialization.data(withJSONObject: replayBody(), options: [.sortedKeys])
        let second = try JSONSerialization.data(withJSONObject: replayBody(), options: [.sortedKeys])
        XCTAssertEqual(first, second)
    }

    func testDefaultOptionsLeaveTheSubscriptionBodyUnchanged() {
        let history: [[String: Any]] = [["role": "user", "content": "hi"]]
        let plain = ResponsesTranslator.requestBody(model: "m", instructions: "i", history: history, tools: nil)
        XCTAssertEqual(Set(plain.keys), ["model", "instructions", "input", "store", "stream"])
        let empty = ResponsesTranslator.requestBody(model: "m", instructions: "i", history: history, tools: nil,
                                                    options: .init(trailingDeveloperMessage: ""))
        XCTAssertEqual((empty["input"] as? [[String: Any]])?.count, 1, "an empty tail adds no item")
    }

    func testMessageWithoutRawItemsStillSynthesises() {
        let message = ResponsesTranslator.assistantHistoryMessage(
            text: "checking",
            toolCalls: [ToolInvocation(id: "call_3", name: "t", arguments: [:], rawArguments: "{}")],
            rawOutputItems: [])
        XCTAssertNil(message[ResponsesTranslator.rawOutputItemsKey], "no empty key is stored")
        let items = ResponsesTranslator.inputItems(history: [message])
        XCTAssertEqual(items.map { $0["type"] as? String }, ["message", "function_call"])
        XCTAssertEqual(items[1]["call_id"] as? String, "call_3")
    }

    func testParseOutputKeepsRawItemsAsReceived() {
        let output: [[String: Any]] = [
            rawReasoning,
            ["type": "message", "phase": "commentary", "content": [["type": "output_text", "text": "Looking."]]],
            rawCall,
        ]
        let parsed = ResponsesTranslator.parseOutput(["output": output])
        XCTAssertEqual(parsed.text, "Looking.")
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.rawOutputItems.count, 3)
        XCTAssertEqual(parsed.rawOutputItems[0]["encrypted_content"] as? String, "gAAAAB-ciphertext")
        XCTAssertEqual(parsed.rawOutputItems[1]["phase"] as? String, "commentary")
        XCTAssertTrue(ResponsesTranslator.parseOutput([:]).rawOutputItems.isEmpty)
    }

    func testStripResponsesItemsRemovesOnlyTheKey() throws {
        let history = replayHistory()
        let stripped = HistoryHygiene.stripResponsesItems(history)
        XCTAssertEqual(stripped.count, history.count)
        for message in stripped {
            XCTAssertNil(message[ResponsesTranslator.rawOutputItemsKey])
        }
        let assistant = stripped[1]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["content"] as? String, "")
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")
        XCTAssertEqual(stripped[0]["content"] as? String, "why is the pump tripping?")
        XCTAssertEqual(stripped[2]["tool_call_id"] as? String, "call_1")
        // After stripping, the chat-shape fallback synthesises the call again.
        let items = ResponsesTranslator.inputItems(history: stripped)
        XCTAssertEqual(items.map { $0["type"] as? String }, ["message", "function_call", "function_call_output"])
    }

    func testHygieneIsUnaffectedByTheRawItemsKey() {
        let history = replayHistory()
        let stripped = HistoryHygiene.stripResponsesItems(history)
        XCTAssertEqual(HistoryHygiene.estimatedTokens(history), HistoryHygiene.estimatedTokens(stripped))
        let pruned = HistoryHygiene.pruneImages(history, keepLast: 0)
        XCTAssertNotNil(pruned[1][ResponsesTranslator.rawOutputItemsKey], "pruning leaves the replay items alone")
        XCTAssertEqual(pruned.count, history.count)
    }

    func testIncompleteReason() {
        XCTAssertEqual(ResponsesTranslator.incompleteReason(
            ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]]), "max_output_tokens")
        XCTAssertEqual(ResponsesTranslator.incompleteReason(["status": "incomplete"]), "unknown")
        XCTAssertNil(ResponsesTranslator.incompleteReason(["status": "completed"]))
        XCTAssertNil(ResponsesTranslator.incompleteReason([:]))
    }

    func testAccumulatorKeepsReasoningDoneItemsForReplay() throws {
        var accumulator = ResponsesTranslator.StreamAccumulator()
        for event in SSEEventParser.parse("""
        event: response.output_item.added
        data: {"type":"response.output_item.added","item":{"type":"reasoning","id":"rs_9","summary":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_9","summary":[],"encrypted_content":"enc-9"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_9","call_id":"call_9","name":"field_session","arguments":"{}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_9","usage":{"input_tokens":10,"output_tokens":5}}}

        """) {
            _ = accumulator.consume(event)
        }
        XCTAssertEqual(accumulator.doneItems.map { $0["type"] as? String }, ["reasoning", "function_call"])
        let response = try XCTUnwrap(accumulator.effectiveResponse)
        let parsed = ResponsesTranslator.parseOutput(response)
        XCTAssertEqual(parsed.toolCalls.first?.id, "call_9")
        XCTAssertEqual(parsed.rawOutputItems.first?["type"] as? String, "reasoning")
        XCTAssertEqual(parsed.rawOutputItems.first?["encrypted_content"] as? String, "enc-9",
                       "the done copy, not the partial added copy")
        // Round-trip: the next request replays reasoning before its call.
        let message = ResponsesTranslator.assistantHistoryMessage(text: parsed.text, toolCalls: parsed.toolCalls,
                                                                  rawOutputItems: parsed.rawOutputItems)
        let items = ResponsesTranslator.inputItems(history: [message])
        XCTAssertEqual(items.map { $0["type"] as? String }, ["reasoning", "function_call"])
    }
}
