import XCTest
@testable import OpenGlasses

@MainActor
final class ToolCallModelsTests: XCTestCase {

    // MARK: - GeminiToolCall Parsing

    func testGeminiToolCallParseValid() {
        let json: [String: Any] = [
            "toolCall": [
                "functionCalls": [
                    [
                        "id": "call-123",
                        "name": "execute",
                        "args": ["task": "send a message to mom"]
                    ]
                ]
            ]
        ]

        let toolCall = GeminiToolCall(json: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.functionCalls.count, 1)
        XCTAssertEqual(toolCall?.functionCalls.first?.id, "call-123")
        XCTAssertEqual(toolCall?.functionCalls.first?.name, "execute")
        XCTAssertEqual(toolCall?.functionCalls.first?.args["task"] as? String, "send a message to mom")
    }

    func testGeminiToolCallParseMultipleCalls() {
        let json: [String: Any] = [
            "toolCall": [
                "functionCalls": [
                    ["id": "call-1", "name": "execute", "args": ["task": "first task"]],
                    ["id": "call-2", "name": "execute", "args": ["task": "second task"]]
                ]
            ]
        ]

        let toolCall = GeminiToolCall(json: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.functionCalls.count, 2)
        XCTAssertEqual(toolCall?.functionCalls[0].id, "call-1")
        XCTAssertEqual(toolCall?.functionCalls[1].id, "call-2")
    }

    func testGeminiToolCallParseWithEmptyArgs() {
        let json: [String: Any] = [
            "toolCall": [
                "functionCalls": [
                    ["id": "call-1", "name": "execute"]
                    // no "args" key
                ]
            ]
        ]

        let toolCall = GeminiToolCall(json: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.functionCalls.first?.args.count, 0)
    }

    func testGeminiToolCallParseInvalidJSON() {
        // Missing "toolCall" key
        let json: [String: Any] = ["serverContent": ["audio": []]]
        let toolCall = GeminiToolCall(json: json)
        XCTAssertNil(toolCall)
    }

    func testGeminiToolCallParseMissingFunctionCalls() {
        let json: [String: Any] = ["toolCall": [:] as [String: Any]]
        let toolCall = GeminiToolCall(json: json)
        XCTAssertNil(toolCall)
    }

    func testGeminiToolCallParseCallMissingRequiredFields() {
        let json: [String: Any] = [
            "toolCall": [
                "functionCalls": [
                    ["id": "call-1"]  // missing "name"
                ]
            ]
        ]

        let toolCall = GeminiToolCall(json: json)
        XCTAssertNotNil(toolCall)
        XCTAssertEqual(toolCall?.functionCalls.count, 0, "Call missing required 'name' should be filtered out")
    }

    // MARK: - GeminiToolCallCancellation

    func testCancellationParseValid() {
        let json: [String: Any] = [
            "toolCallCancellation": [
                "ids": ["call-1", "call-2", "call-3"]
            ]
        ]

        let cancellation = GeminiToolCallCancellation(json: json)
        XCTAssertNotNil(cancellation)
        XCTAssertEqual(cancellation?.ids, ["call-1", "call-2", "call-3"])
    }

    func testCancellationParseInvalid() {
        let json: [String: Any] = ["serverContent": [:] as [String: Any]]
        let cancellation = GeminiToolCallCancellation(json: json)
        XCTAssertNil(cancellation)
    }

    func testCancellationParseMissingIds() {
        let json: [String: Any] = ["toolCallCancellation": [:] as [String: Any]]
        let cancellation = GeminiToolCallCancellation(json: json)
        XCTAssertNil(cancellation)
    }

    // MARK: - ToolResult

    func testToolResultSuccessResponseValue() {
        let result = ToolResult.success("Task completed successfully")
        let response = result.responseValue
        XCTAssertEqual(response["result"] as? String, "Task completed successfully")
        XCTAssertNil(response["error"])
    }

    func testToolResultFailureResponseValue() {
        let result = ToolResult.failure("Connection timeout")
        let response = result.responseValue
        XCTAssertEqual(response["error"] as? String, "Connection timeout")
        XCTAssertNil(response["result"])
    }

    // MARK: - ToolCallStatus

    func testToolCallStatusDisplayText() {
        XCTAssertEqual(ToolCallStatus.idle.displayText, "")
        XCTAssertEqual(ToolCallStatus.executing("search").displayText, "Running: search...")
        XCTAssertEqual(ToolCallStatus.completed("search").displayText, "Done: search")
        XCTAssertEqual(ToolCallStatus.failed("search", "timeout").displayText, "Failed: search — timeout")
        XCTAssertEqual(ToolCallStatus.cancelled("search").displayText, "Cancelled: search")
    }

    func testToolCallStatusIsActive() {
        XCTAssertFalse(ToolCallStatus.idle.isActive)
        XCTAssertTrue(ToolCallStatus.executing("search").isActive)
        XCTAssertFalse(ToolCallStatus.completed("search").isActive)
        XCTAssertFalse(ToolCallStatus.failed("search", "err").isActive)
        XCTAssertFalse(ToolCallStatus.cancelled("search").isActive)
    }

    func testToolCallStatusEquatable() {
        XCTAssertEqual(ToolCallStatus.idle, ToolCallStatus.idle)
        XCTAssertEqual(ToolCallStatus.executing("x"), ToolCallStatus.executing("x"))
        XCTAssertNotEqual(ToolCallStatus.executing("x"), ToolCallStatus.executing("y"))
        XCTAssertNotEqual(ToolCallStatus.idle, ToolCallStatus.executing("x"))
    }

    // MARK: - ToolDeclarations

    func testAllDeclarationsContainsExecute() {
        let declarations = ToolDeclarations.allDeclarations()
        XCTAssertEqual(declarations.count, 1)

        let execute = declarations[0]
        XCTAssertEqual(execute["name"] as? String, "execute")
        XCTAssertNotNil(execute["description"])
        XCTAssertNotNil(execute["parameters"])
        XCTAssertEqual(execute["behavior"] as? String, "BLOCKING")
    }

    func testAnthropicToolsFormat() {
        let tools = ToolDeclarations.anthropicTools(registry: nil, includeOpenClaw: true)
        XCTAssertGreaterThanOrEqual(tools.count, 1)

        let tool = tools[0]
        XCTAssertEqual(tool["name"] as? String, "execute")
        XCTAssertNotNil(tool["input_schema"])

        let schema = tool["input_schema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertNotNil(schema?["properties"])
        XCTAssertNotNil(schema?["required"])
    }

    func testOpenAIToolsFormat() {
        let tools = ToolDeclarations.openAITools(registry: nil, includeOpenClaw: true)
        XCTAssertGreaterThanOrEqual(tools.count, 1)

        let tool = tools[0]
        XCTAssertEqual(tool["type"] as? String, "function")

        let function = tool["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "execute")
        XCTAssertNotNil(function?["description"])
        XCTAssertNotNil(function?["parameters"])
    }

    func testGeminiRESTToolsFormat() {
        let tools = ToolDeclarations.geminiRESTTools(registry: nil, includeOpenClaw: true)
        XCTAssertGreaterThanOrEqual(tools.count, 1)

        let tool = tools[0]
        let declarations = tool["functionDeclarations"] as? [[String: Any]]
        XCTAssertNotNil(declarations)
        XCTAssertGreaterThanOrEqual(declarations?.count ?? 0, 1)
        XCTAssertEqual(declarations?.first?["name"] as? String, "execute")
    }

    func testExecuteToolHasTaskParameter() {
        let params = ToolDeclarations.execute["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        let task = properties?["task"] as? [String: Any]

        XCTAssertEqual(task?["type"] as? String, "string")
        XCTAssertNotNil(task?["description"])

        let required = params?["required"] as? [String]
        XCTAssertEqual(required, ["task"])
    }
}
