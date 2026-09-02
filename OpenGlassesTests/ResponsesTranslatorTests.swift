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
}
