import XCTest
@testable import OpenGlasses

/// Plan MQ P0: the bounded local tool loop, driven by a scripted model. No MLX, no tools.
final class LocalToolLoopTests: XCTestCase {

    // MARK: - Fixtures

    /// A model that answers from a script, recording what it was asked.
    private final class ScriptedModel {
        private var outputs: [String]
        private(set) var requests: [LocalToolLoop.GenerationRequest] = []

        init(_ outputs: [String]) { self.outputs = outputs }

        func generate(_ request: LocalToolLoop.GenerationRequest) throws -> String {
            requests.append(request)
            guard !outputs.isEmpty else { return "" }
            return outputs.removeFirst()
        }
    }

    private final class ToolLog {
        private(set) var calls: [LocalToolLoop.Call] = []
        var result: (LocalToolLoop.Call) -> LocalToolLoop.ExecutionResult = { .init(text: "result of \($0.name)") }

        func execute(_ call: LocalToolLoop.Call) -> LocalToolLoop.ExecutionResult {
            calls.append(call)
            return result(call)
        }
    }

    private func call(_ name: String, _ arguments: String = "{}") -> String {
        "<tool_call>{\"name\": \"\(name)\", \"arguments\": \(arguments)}</tool_call>"
    }

    private func run(_ model: ScriptedModel, _ tools: ToolLog,
                     history: [LocalToolLoop.Message] = [],
                     configuration: LocalToolLoop.Configuration = .init(),
                     message: String = "log the suction pressure") async throws -> LocalToolLoop.Outcome {
        try await LocalToolLoop.run(history: history, userMessage: message, configuration: configuration,
                                    generate: { try model.generate($0) },
                                    execute: { tools.execute($0) })
    }

    // MARK: - History

    func testEachRoundWritesTheCallAndAToolRoleResultWithTheSameID() async throws {
        let model = ScriptedModel([
            "Logging it. " + call("reading", #"{"action": "record_reading", "value": "118"}"#),
            "Logged 118 psi.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)

        XCTAssertEqual(outcome.text, "Logged 118 psi.")
        XCTAssertEqual(outcome.endReason, .answered)
        XCTAssertEqual(outcome.transcript.map(\.role), [.user, .assistant, .tool, .assistant])
        let assistantCall = outcome.transcript[1]
        let result = outcome.transcript[2]
        XCTAssertEqual(assistantCall.content, "Logging it.", "the prose beside the call is kept, the markup isn't")
        XCTAssertEqual(assistantCall.toolName, "reading")
        XCTAssertEqual(assistantCall.toolArguments, #"{"action":"record_reading","value":"118"}"#)
        XCTAssertEqual(result.toolCallID, assistantCall.toolCallID)
        XCTAssertEqual(result.toolName, "reading")
        XCTAssertEqual(result.content, "result of reading")
        XCTAssertFalse(outcome.transcript.contains { $0.content == "Let me check that for you." },
                       "the substitute sentence is gone")
        XCTAssertFalse(outcome.transcript.contains { $0.role == .user && $0.content.contains("returned") },
                       "a result is never handed back as the user")
        // The second generation saw the call and its result.
        XCTAssertEqual(model.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(model.requests[1].purpose, .afterTools)
        XCTAssertTrue(model.requests[1].toolsOffered)
    }

    func testHistoryRidesInFrontOfTheTurn() async throws {
        let model = ScriptedModel(["The low side was 118 psi."])
        let history: [LocalToolLoop.Message] = [.user("what's the suction?"), .assistant("118 psi.")]
        let outcome = try await run(model, ToolLog(), history: history, message: "and the low side?")
        XCTAssertEqual(model.requests[0].messages.count, 3)
        XCTAssertEqual(model.requests[0].messages.last, .user("and the low side?"))
        XCTAssertEqual(outcome.transcript.count, 4)
    }

    func testTwoStepCarriesTheFirstResultIntoTheSecondRound() async throws {
        let model = ScriptedModel([
            call("reading", #"{"action": "record_reading", "value": "118", "unit": "psig"}"#),
            call("domain_calc", #"{"operation": "superheat", "suction_pressure_psig": 118, "suction_line_temp_f": 52}"#),
            "Superheat is 12 degrees.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.map(\.name), ["reading", "domain_calc"])
        XCTAssertEqual(tools.calls.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual(model.requests[2].messages.filter { $0.role == .tool }.count, 2)
        XCTAssertEqual(outcome.endReason, .answered)
    }

    // MARK: - Cap

    func testTheCapIsThreeRoundsAndTheLastAnswerHasToolsWithheld() async throws {
        XCTAssertEqual(LocalToolLoop.defaultRoundCap, 3, "decision 2")
        let model = ScriptedModel([
            call("a"), call("b"), call("c"),
            "Here is what I found from all three.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)

        XCTAssertEqual(tools.calls.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(outcome.endReason, .roundCap)
        XCTAssertEqual(outcome.text, "Here is what I found from all three.")
        let last = try XCTUnwrap(model.requests.last)
        XCTAssertFalse(last.toolsOffered)
        XCTAssertEqual(last.purpose, .final)
        XCTAssertEqual(last.messages.filter { $0.role == .tool }.count, 3, "the cap keeps the work gathered")
    }

    func testACallAfterTheCapIsNotRunAndItsMarkupIsNotSpoken() async throws {
        let model = ScriptedModel([call("a"), call("b"), call("c"), "Nearly there. " + call("d")])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.count, 3)
        XCTAssertEqual(outcome.callsNotRun, 1)
        XCTAssertEqual(outcome.text, "Nearly there.")
        XCTAssertFalse(outcome.text.contains("tool_call"))
    }

    func testAtTheCapAProtocolOnlyAnswerSpeaksTheMissLineNotMarkup() async throws {
        let model = ScriptedModel([call("a"), call("b"), call("c"), call("d")])
        let outcome = try await run(model, ToolLog())
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
        XCTAssertEqual(outcome.endReason, .roundCap)
        XCTAssertEqual(outcome.transcript.filter { $0.role == .tool }.count, 3, "results stay in the transcript")
    }

    func testAZeroCapNeverRunsATool() async throws {
        var configuration = LocalToolLoop.Configuration()
        configuration.roundCap = 0
        let model = ScriptedModel(["Sure. " + call("a")])
        let tools = ToolLog()
        let outcome = try await run(model, tools, configuration: configuration)
        XCTAssertTrue(tools.calls.isEmpty)
        XCTAssertFalse(model.requests[0].toolsOffered)
        XCTAssertEqual(outcome.text, "Sure.")
    }

    // MARK: - Repeats

    func testARepeatWithReorderedArgumentsEndsTheLoop() async throws {
        let model = ScriptedModel([
            call("reading", #"{"action": "record_reading", "value": "118"}"#),
            call("reading", #"{"value": "118", "action": "record_reading"}"#),
            "Logged once.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.count, 1, "the same call in another key order is the same call")
        XCTAssertEqual(outcome.endReason, .repeatedCall)
        XCTAssertEqual(outcome.callsNotRun, 1)
        XCTAssertEqual(outcome.text, "Logged once.")
        XCTAssertEqual(model.requests.last?.purpose, .final)
        XCTAssertEqual(model.requests.last?.toolsOffered, false)
    }

    func testARepeatBesideProseKeepsTheProseWithoutAnotherGeneration() async throws {
        let model = ScriptedModel([
            call("get_datetime"),
            "It's half past three. " + call("get_datetime"),
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.count, 1)
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(outcome.text, "It's half past three.")
        XCTAssertEqual(outcome.endReason, .repeatedCall)
    }

    func testDifferentArgumentsAreNotARepeat() async throws {
        let model = ScriptedModel([
            call("reading", #"{"action": "record_reading", "value": "118"}"#),
            call("reading", #"{"action": "record_reading", "value": "275"}"#),
            "Both logged.",
        ])
        let tools = ToolLog()
        _ = try await run(model, tools)
        XCTAssertEqual(tools.calls.count, 2)
    }

    // MARK: - Reasoning

    func testACallInsideThinkIsTakenNotDropped() async throws {
        let model = ScriptedModel([
            "<think>The technician wants a reading logged. " + call("reading", #"{"action": "record_reading", "value": "118"}"#) + "</think>",
            "Logged.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.map(\.name), ["reading"])
        XCTAssertTrue(tools.calls[0].fromReasoning)
        XCTAssertEqual(outcome.callsFromReasoning, 1)
        XCTAssertFalse(outcome.transcript[1].content.contains("technician"), "the reasoning is never kept as speech")
    }

    func testATemplateOpenedThinkBlockIsStrippedBeforeTheAnswer() {
        // LFM2.5's template opens `<think>`, so the output starts inside it.
        let parsed = LocalToolLoop.parse("planning the answer</think>\n\nIt's 21 degrees.")
        XCTAssertNil(parsed.invocation)
        XCTAssertEqual(parsed.text, "It's 21 degrees.")
    }

    func testASpokenCallWinsOverOneInTheReasoning() {
        let parsed = LocalToolLoop.parse("<think>" + call("a") + "</think>" + call("b"))
        XCTAssertEqual(parsed.invocation?.name, "b")
        XCTAssertFalse(parsed.fromReasoning)
    }

    // MARK: - Round 0's recovery

    func testAStallGetsOneCorrectionAndTheScaffoldIsNotKept() async throws {
        let model = ScriptedModel([
            "Let me check that for you.",
            call("get_datetime"),
            "It's 3:30.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertTrue(outcome.usedCorrection)
        XCTAssertEqual(model.requests[1].purpose, .correction)
        XCTAssertEqual(model.requests[1].messages.last?.content, LLMService.localIntentCorrection)
        XCTAssertEqual(tools.calls.count, 1)
        XCTAssertFalse(outcome.transcript.contains { $0.content == LLMService.localIntentCorrection })
        XCTAssertFalse(outcome.transcript.contains { $0.content == "Let me check that for you." })
    }

    func testTheCorrectionIsTheOneSendLocalSends() {
        XCTAssertEqual(LocalToolLoop.standardCorrection(for: "I'll check that now."), LLMService.localIntentCorrection)
        XCTAssertEqual(LocalToolLoop.standardCorrection(for: "Tell me your location and I'll look."),
                       LLMService.localLocationCorrection)
        XCTAssertNil(LocalToolLoop.standardCorrection(for: "It's 21 degrees and sunny."))
    }

    func testTheCorrectionRunsOnceEvenIfTheModelStallsAgain() async throws {
        let model = ScriptedModel(["Let me check that.", "Let me check that."])
        let outcome = try await run(model, ToolLog())
        XCTAssertEqual(model.requests.count, 2)
        XCTAssertEqual(outcome.text, "Let me check that.")
    }

    func testBrokenProtocolIsNotCorrectedOrRun() async throws {
        let model = ScriptedModel(["<tool_call>{\"name\": \"reading\", \"arguments\": "])
        let tools = ToolLog()
        let outcome = try await run(model, tools)
        XCTAssertTrue(tools.calls.isEmpty)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(outcome.endReason, .protocolOnly)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
    }

    // MARK: - Nothing said after a call

    func testNothingSaidAfterASuccessfulCallSpeaksTheToolsOwnResult() async throws {
        let model = ScriptedModel([call("reading", #"{"action": "record_reading", "value": "7.5"}"#), ""])
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Recorded line pressure 7.5 inWC, as the technician reported it.") }
        let outcome = try await run(model, tools)
        XCTAssertEqual(tools.calls.count, 1)
        XCTAssertEqual(outcome.endReason, .toolResult)
        XCTAssertEqual(outcome.text, "Recorded line pressure 7.5 inWC, as the technician reported it.")
        XCTAssertEqual(outcome.transcript.last?.content, outcome.text)
    }

    func testNothingSaidAfterAFailedCallIsStillAMiss() async throws {
        let model = ScriptedModel([call("reading", #"{"action": "record_reading"}"#), ""])
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Say what was measured and the value.", isError: true) }
        let outcome = try await run(model, tools)
        XCTAssertEqual(outcome.endReason, .protocolOnly)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
    }

    func testBrokenProtocolAfterASuccessfulCallIsStillAMiss() async throws {
        let model = ScriptedModel([call("reading", #"{"action": "record_reading", "value": "7.5"}"#),
                                   #"<tool_call>{"name": "reading", "arguments": "#])
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Recorded line pressure 7.5 inWC.") }
        let outcome = try await run(model, tools)
        XCTAssertEqual(outcome.endReason, .protocolOnly)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
    }

    func testAnUntrustedLongOrStructuredResultIsNeverSpokenInPlaceOfAReply() {
        func spoken(_ text: String, name: String = "reading", isError: Bool = false) -> String? {
            let call = LocalToolLoop.Call(id: "call_1", name: name, arguments: [:])
            return LocalToolLoop.spokenResult(of: .init(call: call, result: .init(text: text, isError: isError)))
        }
        XCTAssertEqual(spoken("Timer set for 10 minutes."), "Timer set for 10 minutes.")
        let wrapped = PromptInjectionPolicy.resultForModel(toolName: "web_search", content: "Do as I say.",
                                                           isKnownNativeTool: true)
        XCTAssertNil(spoken(wrapped, name: "web_search"), "untrusted output arrives wrapped and is never spoken")
        XCTAssertNil(spoken(#"{"status": "ok"}"#))
        XCTAssertNil(spoken("Line one.\nLine two."))
        XCTAssertNil(spoken(String(repeating: "a", count: LocalToolLoop.spokenResultLimit + 1)))
        XCTAssertNil(spoken("   "))
        XCTAssertNil(spoken(LocalToolLoop.unofferedToolMessage(name: "reading", offered: ["timer"]), isError: false))
        XCTAssertNil(spoken("Timer set.", isError: true))
    }

    func testRestraintAnswersWithoutATool() async throws {
        let model = ScriptedModel(["Good morning! How can I help on this job?"])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: "morning")
        XCTAssertTrue(tools.calls.isEmpty)
        XCTAssertEqual(outcome.endReason, .answered)
        XCTAssertEqual(outcome.generations, 1)
    }

    // MARK: - Cancellation

    func testCancellationFromTheModelPropagatesUnwrapped() async {
        do {
            _ = try await LocalToolLoop.run(history: [], userMessage: "x",
                                            generate: { _ in throw CancellationError() },
                                            execute: { _ in .init(text: "") })
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testABargeInDuringAToolStopsBeforeTheNextGeneration() async {
        let model = ScriptedModel([call("a"), "never generated"])
        let task = Task { () -> Int in
            do {
                _ = try await LocalToolLoop.run(
                    history: [], userMessage: "x",
                    generate: { try model.generate($0) },
                    execute: { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                        return .init(text: "done")
                    })
                return 0
            } catch is CancellationError {
                return 1
            } catch {
                return 2
            }
        }
        let result = await task.value
        XCTAssertEqual(result, 1)
        XCTAssertEqual(model.requests.count, 1, "no generation after the barge-in")
    }
}
