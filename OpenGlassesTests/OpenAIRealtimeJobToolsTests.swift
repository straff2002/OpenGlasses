import XCTest
@testable import OpenGlasses

/// A tool this backend can be given without a network. Records what it was called with.
private final class RealtimeFakeTool: NativeTool, @unchecked Sendable {
    let name: String
    let description = "A tool for the realtime router's tests."
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    private(set) var receivedArgs: [[String: Any]] = []
    private let answer: String

    init(name: String, answer: String = "done") {
        self.name = name
        self.answer = answer
    }

    func execute(args: [String: Any]) async throws -> String {
        receivedArgs.append(args)
        return answer
    }
}

/// OpenAI Realtime's Field Assist wiring (Plan FO P3a): the session payload, the function-call
/// round trip, and the promise that a wearer without Field Assist sees the session that shipped.
@MainActor
final class OpenAIRealtimeJobToolsTests: XCTestCase {

    // MARK: - session.update

    /// The golden fixture. With no tools the payload is exactly what it was before this plan —
    /// same keys, same values, no `tools` and no `tool_choice`.
    func testSessionUpdateWithoutToolsIsUnchanged() throws {
        let payload = OpenAIRealtimeService.sessionUpdate(instructions: "INSTRUCTIONS", tools: [])
        let expected: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": "INSTRUCTIONS",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "gpt-4o-mini-transcribe"],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                    "create_response": true,
                    "interrupt_response": true,
                ],
            ],
        ]
        XCTAssertEqual(LiveJobContract.canonicalJSON(payload),
                       LiveJobContract.canonicalJSON(expected))
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertNil(session["tools"], "an empty tools list must not appear as an empty key")
        XCTAssertNil(session["tool_choice"])
    }

    func testSessionUpdateCarriesTheJobToolsWhenThereAreSome() throws {
        let tools = ToolDeclarations.openAIRealtimeTools(
            declarations: [["name": "field_session", "description": "d",
                            "parameters": ["type": "object"]]],
            names: LiveJobContract.jobToolNames)
        let payload = OpenAIRealtimeService.sessionUpdate(instructions: "I", tools: tools)
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        let declared = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(declared.compactMap { $0["name"] as? String }, ["field_session"])
    }

    // MARK: - The round trip

    func testAToolCallReachesTheNativeRouterAndComesBackInTheProvidersFormat() async throws {
        let tool = RealtimeFakeTool(name: "field_session", answer: "Started job 1005.")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        var sent: [[String: Any]] = []
        let router = OpenAIRealtimeToolRouter { sent.append($0) }
        router.nativeToolRouter = NativeToolRouter(registry: registry)

        router.handle(OpenAIRealtimeFunctionCall(callId: "call_1", name: "field_session",
                                                 argumentsJSON: "{\"action\":\"start\"}"))
        try await waitUntil { sent.count == 2 }

        XCTAssertEqual(tool.receivedArgs.first?["action"] as? String, "start")
        // Two messages, in order: the output item, then the request to carry on.
        XCTAssertEqual(sent[0]["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(sent[0]["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_1")
        XCTAssertEqual(item["output"] as? String, "Started job 1005.")
        XCTAssertEqual(sent[1]["type"] as? String, "response.create")
    }

    func testAnUnknownToolFailsWithoutTakingTheSessionDown() async throws {
        var sent: [[String: Any]] = []
        let router = OpenAIRealtimeToolRouter { sent.append($0) }
        router.nativeToolRouter = nil

        router.handle(OpenAIRealtimeFunctionCall(callId: "call_2", name: "nope",
                                                 argumentsJSON: "{}"))
        try await waitUntil { sent.count == 2 }
        let item = try XCTUnwrap(sent[0]["item"] as? [String: Any])
        let output = try XCTUnwrap(item["output"] as? String)
        XCTAssertTrue(output.contains("Unknown tool"))
        // A failure is JSON, so the model reads it as a result rather than as a line to repeat.
        XCTAssertTrue(output.hasPrefix("{"))
    }

    /// Malformed arguments are not a reason to drop the call: the tool answers, and the model gets
    /// a sentence it can act on where silence would leave it waiting forever.
    func testMalformedArgumentsStillReachTheTool() async throws {
        let tool = RealtimeFakeTool(name: "equipment_lookup")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        var sent: [[String: Any]] = []
        let router = OpenAIRealtimeToolRouter { sent.append($0) }
        router.nativeToolRouter = NativeToolRouter(registry: registry)

        router.handle(OpenAIRealtimeFunctionCall(callId: "call_3", name: "equipment_lookup",
                                                 argumentsJSON: "not json"))
        try await waitUntil { sent.count == 2 }
        XCTAssertEqual(tool.receivedArgs.count, 1)
        XCTAssertTrue(tool.receivedArgs[0].isEmpty)
    }

    func testTheWireShapeIsStatedAsAValue() throws {
        let messages = OpenAIRealtimeToolRouter.outputMessages(callId: "c", output: "o")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(LiveJobContract.canonicalJSON(messages[0]),
                       LiveJobContract.canonicalJSON([
                        "type": "conversation.item.create",
                        "item": ["type": "function_call_output", "call_id": "c", "output": "o"],
                       ]))
        XCTAssertEqual(messages[1]["type"] as? String, "response.create")
    }

    func testFunctionCallArgumentsParse() {
        let call = OpenAIRealtimeFunctionCall(callId: "c", name: "n",
                                              argumentsJSON: "{\"job_reference\":\"1005\"}")
        XCTAssertEqual(call.args["job_reference"] as? String, "1005")
    }

    // MARK: - Helpers

    /// Poll for a condition with a deadline rather than sleeping a fixed time.
    private func waitUntil(_ condition: () -> Bool,
                           timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition never became true", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
