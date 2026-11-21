import XCTest
@testable import OpenGlasses

/// Plan MQ P1: the allowlist, the per-turn tool cut, the transcript renderings and the parsed-call
/// precedence. Pure.
final class LocalNativeToolPolicyTests: XCTestCase {

    // MARK: - Allowlist (decision 1)

    func testOnlyGemma4E2BOnMLXWithTheFlagOnRunsNativeToolCalls() {
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertTrue(LocalNativeToolPolicy.usesNativeToolCalls(modelID: gemma, runtime: .mlx, flagOn: true))
        XCTAssertTrue(LocalNativeToolPolicy.usesNativeToolCalls(modelID: "mlx-community/gemma-4-E2B-it-4bit",
                                                                runtime: .mlx, flagOn: true), "case does not matter")
        XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(modelID: gemma, runtime: .mlx, flagOn: false))
        XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(modelID: gemma, runtime: .llamaCpp, flagOn: true))
        for other in ["mlx-community/gemma-4-e4b-it-4bit", "mlx-community/Qwen2.5-3B-Instruct-4bit",
                      "LiquidAI/LFM2.5-2.6B-MLX-4bit"] {
            XCTAssertFalse(LocalNativeToolPolicy.usesNativeToolCalls(modelID: other, runtime: .mlx, flagOn: true), other)
        }
        XCTAssertEqual(LocalNativeToolPolicy.allowlist.count, 1)
    }

    func testFieldAssistToolsGoToAQualifiedModelOrOneUnderQualification() {
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertTrue(LocalNativeToolPolicy.offersFieldAssistTools(modelID: gemma, runtime: .mlx, flagOn: true, qualified: false))
        XCTAssertFalse(LocalNativeToolPolicy.offersFieldAssistTools(modelID: gemma, runtime: .mlx, flagOn: false, qualified: false))
        XCTAssertTrue(LocalNativeToolPolicy.offersFieldAssistTools(modelID: "x/y", runtime: .mlx, flagOn: false, qualified: true))
        // Under qualification shows nothing in the catalog: the badge rule is evidence only.
        XCTAssertFalse(LocalModelCatalog.qualifiesForFieldAssistTools(LocalModelID(gemma)))
    }

    // MARK: - The per-turn cut (decision 3)

    func testNativeToolNamesPutTheJobFirstThenTheNamedEverydayToolsAtMostFive() {
        let field = ["field_session", "reading", "table_lookup"]
        let everyday = ["get_weather", "get_datetime", "calculate", "set_timer", "flashlight", "calendar"]
        let names = LocalNativeToolPolicy.nativeToolNames(field: field, everyday: everyday,
                                                          utterance: "set a timer for the flame check",
                                                          estimatedTokens: { _ in 100 }, budgetTokens: 10_000)
        XCTAssertEqual(names, ["field_session", "reading", "table_lookup", "set_timer", "get_weather"])
    }

    func testADefinitionThatDoesNotFitIsSkippedNotTheRest() {
        let names = LocalNativeToolPolicy.nativeToolNames(field: [], everyday: ["calendar", "get_datetime", "calculate"],
                                                          utterance: "what's on my calendar",
                                                          estimatedTokens: { $0 == "calendar" ? 500 : 100 },
                                                          budgetTokens: 250)
        XCTAssertEqual(names, ["get_datetime", "calculate"])
    }

    // MARK: - Transcript renderings

    func testStructuredMessagesCarryTheCallAndTheResultUnderTheTemplateKeys() throws {
        let call = LocalToolLoop.Call(id: "call_1", name: "reading", arguments: ["value": 3.5, "quantity": "manifold"])
        let assistant = LocalToolTranscript.rawMessage(.assistant("", calling: call))
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [any Sendable])
        let entry = try XCTUnwrap(calls.first as? [String: any Sendable])
        XCTAssertEqual(entry["id"] as? String, "call_1")
        XCTAssertEqual(entry["type"] as? String, "function")
        let function = try XCTUnwrap(entry["function"] as? [String: any Sendable])
        XCTAssertEqual(function["name"] as? String, "reading")
        let arguments = try XCTUnwrap(function["arguments"] as? [String: any Sendable])
        XCTAssertEqual(arguments["value"] as? Double, 3.5)

        let result = LocalToolTranscript.rawMessage(.toolResult("Logged.", for: call))
        XCTAssertEqual(result["role"] as? String, "tool")
        XCTAssertEqual(result["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(result["name"] as? String, "reading")
    }

    func testFlattenedMessagesAreTheHermesFrameAndTheSingleShotsResultLine() {
        let call = LocalToolLoop.Call(id: "call_1", name: "get_datetime", arguments: [:])
        let flat = LocalToolTranscript.flattened([.user("time?"), .assistant("", calling: call),
                                                  .toolResult("9 am", for: call)])
        XCTAssertEqual(flat.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(flat[1].content, #"<tool_call>{"name": "get_datetime", "arguments": {}}</tool_call>"#)
        XCTAssertEqual(flat[2].content, "Tool 'get_datetime' returned: 9 am")
        XCTAssertEqual(LocalOutputPolicy.classify(flat[1].content).invocation?.name, "get_datetime",
                       "the fallback frame is what the shipped parser reads")
    }

    func testBooleansStayBooleansOnTheWayToTheTemplate() {
        let object = LocalToolTranscript.sendableObject(json: #"{"confirmed": true, "count": 1, "ratio": 0.5}"#)
        XCTAssertEqual(object["confirmed"] as? Bool, true)
        XCTAssertEqual(object["count"] as? Int, 1)
        XCTAssertEqual(object["ratio"] as? Double, 0.5)
        XCTAssertEqual(LocalToolTranscript.templateContext(thinkingOff: true)?["enable_thinking"] as? Bool, false)
        XCTAssertNil(LocalToolTranscript.templateContext(thinkingOff: false))
    }

    // MARK: - Parsed calls

    func testAParsedCallIsTheTurnsCallWhenTheTextHasNone() {
        let parsed = LocalToolCallEvent(name: "get_datetime", arguments: ["format": "long"])
        let classification = LocalOutputPolicy.classify("", parsedCalls: [parsed])
        XCTAssertEqual(classification.kind, .toolCall)
        XCTAssertEqual(classification.invocation?.name, "get_datetime")
        XCTAssertEqual(classification.invocation?.arguments["format"] as? String, "long")

        let loopParsed = LocalToolLoop.parse(LocalToolLoop.Generation(text: "One moment.", toolCalls: [parsed]))
        XCTAssertEqual(loopParsed.invocation?.name, "get_datetime")
        XCTAssertEqual(loopParsed.text, "One moment.")
    }

    func testACallInTheTextWinsAndProtocolIsStillRemoved() {
        let text = #"Sure. <tool_call>{"name": "calculate", "arguments": {"expression": "1+1"}}</tool_call>"#
        let classification = LocalOutputPolicy.classify(text, parsedCalls: [LocalToolCallEvent(name: "get_datetime", arguments: [:])])
        XCTAssertEqual(classification.invocation?.name, "calculate")
        XCTAssertEqual(classification.text, "Sure.")
        XCTAssertNil(LocalOutputPolicy.classify("Hello.", parsedCalls: []).invocation)
    }

    func testTheEventCarriesCanonicalArguments() {
        let a = LocalToolCallEvent(name: "x", arguments: ["b": 2, "a": 1])
        let b = LocalToolCallEvent(name: "x", arguments: ["a": 1, "b": 2])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.argumentsJSON, #"{"a":1,"b":2}"#)
        XCTAssertTrue(LocalToolCallEvent(name: "x", argumentsJSON: "not json").arguments.isEmpty)
    }
}
