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

    // MARK: - A reply that opens by naming the assistant

    func testAReplyThatOpensWithTheAssistantsNameLosesIt() {
        func strip(_ text: String) -> String { LocalToolLoop.withoutLeadingName(text, name: "Avenkin") }
        XCTAssertEqual(strip("Avenkin, I can look that up."), "I can look that up.")
        XCTAssertEqual(strip("Avenkin. I see the nameplate."), "I see the nameplate.")
        XCTAssertEqual(strip("avenkin I can start the procedure."), "I can start the procedure.")
        XCTAssertEqual(strip("Avenkin here. I need the code."), "I need the code.")
        XCTAssertEqual(strip("Avenkin understood. Logging it."), "Understood. Logging it.")
        XCTAssertEqual(strip("avenkin yes, logged."), "Yes, logged.")
        XCTAssertEqual(strip("avenkin"), "")
        XCTAssertEqual(strip("Avenkin will log the line voltage."), "Avenkin will log the line voltage.",
                       "the name used in a sentence stays")
        XCTAssertEqual(strip("Avenkins are rare."), "Avenkins are rare.")
        XCTAssertEqual(strip("Logged 7.5, Avenkin."), "Logged 7.5, Avenkin.")
        XCTAssertEqual(LocalToolLoop.withoutLeadingName("Avenkin, hi.", name: ""), "Avenkin, hi.")
    }

    func testTheLoopTakesTheNameOffItsAnswer() async throws {
        var configuration = LocalToolLoop.Configuration()
        configuration.assistantName = "Avenkin"
        let outcome = try await run(ScriptedModel(["Avenkin, good morning!"]), ToolLog(), configuration: configuration,
                                    message: "morning")
        XCTAssertEqual(outcome.text, "Good morning!")
        XCTAssertEqual(outcome.transcript.last?.content, "Good morning!")
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

    // MARK: - Every call a generation asks for (Plan MQ P3)

    private let twoStepTurn = "Line voltage at the 090XV36C control is 120. Log it, then work out the voltage drop "
        + "at 15 amps over 50 feet of 14 gauge copper."

    /// A model whose runtime parses calls out of the stream, as mlx-swift-lm does for Gemma 4.
    private final class NativeModel {
        private var outputs: [LocalToolLoop.Generation]
        private(set) var requests: [LocalToolLoop.GenerationRequest] = []
        init(_ outputs: [LocalToolLoop.Generation]) { self.outputs = outputs }
        func generate(_ request: LocalToolLoop.GenerationRequest) -> LocalToolLoop.Generation {
            requests.append(request)
            return outputs.isEmpty ? .init(text: "") : outputs.removeFirst()
        }
    }

    private func runNative(_ model: NativeModel, _ tools: ToolLog,
                           configuration: LocalToolLoop.Configuration = .init(),
                           message: String) async throws -> LocalToolLoop.Outcome {
        try await LocalToolLoop.run(history: [], userMessage: message, configuration: configuration,
                                    generateTurn: { model.generate($0) }, execute: { tools.execute($0) })
    }

    func testTwoNativeCallsInOneGenerationBothRunInOrderAndTheCarryReachesTheSecond() async throws {
        let model = NativeModel([
            .init(text: "", toolCalls: [
                .init(name: "reading", arguments: ["action": "record_reading", "value": 120, "unit": "VAC"]),
                .init(name: "domain_calc", arguments: ["operation": "voltage_drop", "supply_v": 120,
                                                       "current_a": 15, "length_ft": 50]),
            ]),
            .init(text: "Logged 120 volts; the drop is about 3 volts."),
        ])
        let tools = ToolLog()
        let outcome = try await runNative(model, tools, message: twoStepTurn)

        XCTAssertEqual(tools.calls.map(\.name), ["reading", "domain_calc"])
        XCTAssertEqual(tools.calls.map(\.id), ["call_1", "call_2"])
        XCTAssertEqual((tools.calls[1].arguments["supply_v"] as? NSNumber)?.intValue, 120, "the carry the model gave")
        XCTAssertEqual(outcome.multiCallGenerations, 1)
        XCTAssertEqual(outcome.callsNotRun, 0)
        XCTAssertEqual(model.requests.count, 2, "one generation after both results")
        XCTAssertEqual(model.requests[1].purpose, .afterTools)
        XCTAssertEqual(model.requests[1].round, 2)
        XCTAssertEqual(model.requests[1].messages.map(\.role), [.user, .assistant, .tool, .assistant, .tool])
        XCTAssertEqual(model.requests[1].messages.filter { $0.role == .tool }.map(\.toolName), ["reading", "domain_calc"])
        XCTAssertEqual(outcome.text, "Logged 120 volts; the drop is about 3 volts.", "a claim both calls back passes")
        XCTAssertEqual(outcome.endReason, .answered)
    }

    func testTwoTaggedCallsInOneReplyBothRunAndTheProseRidesOnTheFirst() async throws {
        let model = ScriptedModel([
            "On it. " + call("reading", #"{"action": "record_reading", "value": "120"}"#)
                + call("domain_calc", #"{"operation": "voltage_drop", "current_a": 15, "length_ft": 50}"#),
            "Done.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: twoStepTurn)
        XCTAssertEqual(tools.calls.map(\.name), ["reading", "domain_calc"])
        let calls = outcome.transcript.filter { $0.toolName != nil && $0.role == .assistant }
        XCTAssertEqual(calls.map(\.content), ["On it.", ""])
    }

    func testAnErrorOnTheSecondCallReachesTheModelWhichMayRetry() async throws {
        // Gemma's own two-call reply on the phone: `application` for `operation`, refused.
        let model = NativeModel([
            .init(text: "", toolCalls: [
                .init(name: "reading", arguments: ["action": "record_reading", "value": 120]),
                .init(name: "domain_calc", arguments: ["application": "voltage_drop", "current_a": 15, "length_ft": 50]),
            ]),
            .init(text: "", toolCalls: [
                .init(name: "domain_calc", arguments: ["operation": "voltage_drop", "supply_v": 120,
                                                       "current_a": 15, "length_ft": 50]),
            ]),
            .init(text: "Logged; the drop is about 3 volts."),
        ])
        let tools = ToolLog()
        tools.result = { call in
            call.arguments["operation"] == nil && call.name == "domain_calc"
                ? .init(text: "Argument 'operation' is required.", isError: true) : .init(text: "result of \(call.name)")
        }
        let outcome = try await runNative(model, tools, message: twoStepTurn)

        let afterBoth = try XCTUnwrap(model.requests.dropFirst().first)
        XCTAssertEqual(afterBoth.messages.last?.content, "Argument 'operation' is required.")
        XCTAssertTrue(afterBoth.toolsOffered, "two of three rounds used: it may call again")
        XCTAssertEqual(tools.calls.map(\.name), ["reading", "domain_calc", "domain_calc"])
        XCTAssertEqual(outcome.executed.map(\.result.isError), [false, true, false])
        XCTAssertEqual(outcome.endReason, .roundCap)
        XCTAssertEqual(outcome.text, "Logged; the drop is about 3 volts.")
    }

    func testACallPastTheCapInOneGenerationIsCountedNotRun() async throws {
        var configuration = LocalToolLoop.Configuration()
        configuration.roundCap = 1
        let model = NativeModel([
            .init(text: "", toolCalls: [
                .init(name: "reading", arguments: ["action": "record_reading", "value": 120]),
                .init(name: "domain_calc", arguments: ["operation": "voltage_drop"]),
            ]),
            .init(text: "I logged 120 volts. I couldn't work out the drop."),
        ])
        let tools = ToolLog()
        let outcome = try await runNative(model, tools, configuration: configuration, message: twoStepTurn)
        XCTAssertEqual(tools.calls.map(\.name), ["reading"])
        XCTAssertEqual(outcome.callsNotRun, 1)
        XCTAssertEqual(model.requests.last?.purpose, .final)
        XCTAssertEqual(model.requests.last?.toolsOffered, false)
        XCTAssertEqual(outcome.endReason, .roundCap)
    }

    func testARepeatInsideAGenerationIsSkippedWhileTheNewCallRuns() async throws {
        let model = ScriptedModel([
            call("reading", #"{"action": "record_reading", "value": "120"}"#),
            call("reading", #"{"value": "120", "action": "record_reading"}"#)
                + call("domain_calc", #"{"operation": "voltage_drop", "supply_v": 120}"#),
            "Logged, and the drop is about 3 volts.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: twoStepTurn)
        XCTAssertEqual(tools.calls.map(\.name), ["reading", "domain_calc"])
        XCTAssertEqual(outcome.callsNotRun, 1)
        XCTAssertEqual(outcome.endReason, .answered)
    }

    // MARK: - Claims of work not done (Plan MQ P3)

    func testAFalseLoggedClaimIsCorrectedOnceThenReplacedByTheMissLine() async throws {
        let model = ScriptedModel([
            "I have logged the line voltage as 120 volts. I can calculate the voltage drop for you.",
            "Logged 120 volts.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: twoStepTurn)

        XCTAssertTrue(tools.calls.isEmpty)
        XCTAssertEqual(model.requests.map(\.purpose), [.initial, .correction])
        XCTAssertEqual(model.requests[1].messages.last?.content, LLMService.localClaimCorrection)
        XCTAssertTrue(outcome.usedCorrection)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage, "never speak a false claim")
        XCTAssertEqual(outcome.endReason, .unbackedClaim)
        XCTAssertEqual(outcome.transcript.last?.content, LLMService.localMissMessage)
        XCTAssertFalse(outcome.transcript.contains { $0.content.contains("logged") })
    }

    func testACorrectedClaimThatCallsRunsTheCall() async throws {
        let model = ScriptedModel([
            "Avenkin is logging the line voltage reading.",
            call("reading", #"{"action": "record_reading", "value": "120"}"#),
            "Logged 120 volts.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: "Line voltage is 120, log it")
        XCTAssertEqual(tools.calls.map(\.name), ["reading"])
        XCTAssertEqual(outcome.text, "Logged 120 volts.")
        XCTAssertEqual(outcome.endReason, .answered)
    }

    func testAClaimOfACalculationAfterOnlyTheLogIsCorrectedThenReplaced() async throws {
        let model = ScriptedModel([
            call("reading", #"{"action": "record_reading", "value": "120"}"#),
            "Logged 120 volts, and the drop is about 3 volts.",
            "The drop is 3 volts.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: twoStepTurn)
        XCTAssertEqual(tools.calls.map(\.name), ["reading"])
        XCTAssertEqual(model.requests.map(\.purpose), [.initial, .afterTools, .correction])
        XCTAssertEqual(outcome.endReason, .unbackedClaim)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
    }

    func testAClaimAFailedCallMadeIsNotBacked() {
        let failed = LocalToolLoop.Executed(call: .init(id: "call_1", name: "reading", arguments: [:]),
                                            result: .init(text: "Say the value.", isError: true))
        let ran = LocalToolLoop.Executed(call: .init(id: "call_1", name: "reading", arguments: [:]),
                                         result: .init(text: "Recorded line voltage 120 VAC."))
        XCTAssertNotNil(LocalToolLoop.unbackedClaim(in: "I've logged 120 volts.", executed: [failed]))
        XCTAssertNil(LocalToolLoop.unbackedClaim(in: "I've logged 120 volts.", executed: [ran]))
    }

    func testClaimsAndWhatIsNotAClaim() {
        for claim in ["I have logged the line voltage as 120 volts.", "I've recorded it.", "Logged 120 volts.",
                      "Okay, logged.", "Avenkin is logging the line voltage reading.", "That's been recorded.",
                      "I logged it and calculated the drop.", "The voltage drop is about 3 volts.",
                      "I\u{2019}ve worked out the drop: 3 volts."] {
            XCTAssertNotNil(LocalToolLoop.unbackedClaim(in: claim, executed: []), claim)
        }
        for plain in ["Okay, nothing logged.", "I can calculate the voltage drop for you.",
                      "What value should I log?", "The manual says a drop under 3 percent is fine.",
                      "Normal is 2.6 µA or greater.", "Good morning! How can I help on this job?"] {
            XCTAssertNil(LocalToolLoop.unbackedClaim(in: plain, executed: []), plain)
        }
    }

    func testAPromiseOfTheActionIsAStall() {
        for promise in ["I will log the line voltage first, and then calculate the drop.",
                        "Avenkin is logging the line voltage reading. I will calculate the voltage drop for you.",
                        "Let me work out the voltage drop."] {
            XCTAssertTrue(LLMService.announcesToolIntent(promise), promise)
        }
        for waiting in ["What's the voltage? I'll log it.", "I'll log it once you tell me the value.",
                        "I can calculate the voltage drop for you."] {
            XCTAssertFalse(LLMService.announcesToolIntent(waiting), waiting)
        }
    }

    func testAnOfferInsteadOfTheActionAskedForIsCorrectedOnce() async throws {
        let model = ScriptedModel([
            "I can calculate the voltage drop for you.",
            call("domain_calc", #"{"operation": "voltage_drop", "current_a": 15, "length_ft": 50}"#),
            "About 3 volts.",
        ])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: "Work out the voltage drop at 15 amps over 50 feet")
        XCTAssertEqual(model.requests[1].purpose, .correction)
        XCTAssertEqual(model.requests[1].messages.last?.content, LLMService.localIntentCorrection)
        XCTAssertEqual(tools.calls.map(\.name), ["domain_calc"])
        XCTAssertEqual(outcome.text, "About 3 volts.")
    }

    func testAnOfferOnATurnThatAskedForNothingIsLeftAlone() async throws {
        let model = ScriptedModel(["Okay, I can log them when you're ready."])
        let outcome = try await run(model, ToolLog(), message: "I'll give you the readings in a bit")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertFalse(outcome.usedCorrection)
        XCTAssertEqual(outcome.text, "Okay, I can log them when you're ready.")
        XCTAssertFalse(LocalToolLoop.offersInsteadOfDoing("Sure, I can log it.", turn: "Don't log it yet"))
    }

    func testWithCorrectionsOffAFalseClaimIsStillNeverSpoken() async throws {
        var configuration = LocalToolLoop.Configuration()
        configuration.correction = nil
        let model = ScriptedModel(["I have logged it."])
        let outcome = try await run(model, ToolLog(), configuration: configuration, message: "Log 120 volts")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(outcome.endReason, .unbackedClaim)
        XCTAssertEqual(outcome.text, LLMService.localMissMessage)
    }

    // MARK: - Routed calls (Plan MQ P3)

    private func routing(_ offered: [String], procedureActive: Bool = false) -> LocalToolLoop.Configuration {
        var configuration = LocalToolLoop.Configuration()
        configuration.routing = LocalTurnRouter.Context(offered: Set(offered), procedureActive: procedureActive)
        return configuration
    }

    private let stepHistory: [LocalToolLoop.Message] = [
        .user("Start the no ignition procedure"), .assistant("Check the ignitor. What did you measure?"),
    ]

    func testARoutedLookupRunsBeforeAnyGenerationAndTheModelAnswersFromIt() async throws {
        let model = ScriptedModel(["E110 is a low line voltage; check the supply."])
        let tools = ToolLog()
        let outcome = try await run(model, tools, configuration: routing(["equipment_lookup", "table_lookup"]),
                                    message: "The control's showing E110. What do I check?")

        XCTAssertEqual(tools.calls.map(\.name), ["equipment_lookup"])
        XCTAssertEqual(tools.calls.first?.arguments["query"] as? String, "E110")
        XCTAssertEqual(outcome.routedCalls, 1)
        XCTAssertEqual(outcome.executed.map(\.routed), [true])
        XCTAssertEqual(model.requests.count, 1)
        let first = try XCTUnwrap(model.requests.first)
        XCTAssertEqual(first.purpose, .afterTools, "the model's first pass already has the result")
        XCTAssertEqual(first.round, 1)
        XCTAssertEqual(first.routedCalls, 1)
        XCTAssertTrue(first.toolsOffered, "it may still make a further call")
        XCTAssertEqual(first.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(first.messages[1].toolName, "equipment_lookup")
        XCTAssertEqual(first.messages[2].content, "result of equipment_lookup")
        XCTAssertEqual(outcome.text, "E110 is a low line voltage; check the supply.")
        XCTAssertEqual(outcome.endReason, .answered)
        XCTAssertFalse(outcome.usedCorrection)
    }

    func testTheModelDoesNotRepeatARoutedCall() async throws {
        let model = ScriptedModel([call("equipment_lookup", #"{"query": "E110"}"#), "Low line voltage."])
        let tools = ToolLog()
        let outcome = try await run(model, tools, configuration: routing(["equipment_lookup"]),
                                    message: "and if it's E110 instead?")
        XCTAssertEqual(tools.calls.count, 1, "the routed call counts as made")
        XCTAssertEqual(outcome.endReason, .repeatedCall)
    }

    func testARoutedStepIsSaidAsTheRunnerWroteItWithNoGeneration() async throws {
        let model = ScriptedModel(["never generated"])
        let tools = ToolLog()
        tools.result = { _ in
            .init(text: "⚠️ SAFETY: Power off at the disconnect.\nStep — Check the ignitor\n"
                  + "Measure the ignitor resistance. What did you measure?\n(Call 'next' to continue.)\nSource: p. 12")
        }
        let outcome = try await run(model, tools, history: stepHistory,
                                    configuration: routing(["procedure_runner", "reading"], procedureActive: true),
                                    message: "Done. Next step")

        XCTAssertEqual(tools.calls.map(\.name), ["procedure_runner"])
        XCTAssertEqual(tools.calls.first?.arguments["action"] as? String, "next")
        XCTAssertTrue(model.requests.isEmpty, "no generation")
        XCTAssertEqual(outcome.generations, 0)
        XCTAssertEqual(outcome.endReason, .routedResult)
        XCTAssertEqual(outcome.text, "⚠️ SAFETY: Power off at the disconnect. Check the ignitor. "
                       + "Measure the ignitor resistance. What did you measure?")
        XCTAssertEqual(outcome.transcript.last, .assistant(outcome.text))
    }

    func testAnAnswerToTheStepIsRoutedWithTheWordsAsSaid() async throws {
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Recorded ignitor: open (out of spec). Call 'next' to continue.") }
        let outcome = try await run(ScriptedModel([]), tools, history: stepHistory,
                                    configuration: routing(["procedure_runner"], procedureActive: true),
                                    message: "Open or out of specification")
        XCTAssertEqual(tools.calls.first?.arguments["action"] as? String, "answer")
        XCTAssertEqual(tools.calls.first?.arguments["value"] as? String, "Open or out of specification")
        XCTAssertEqual(outcome.text, "Recorded ignitor: open (out of spec).")
    }

    func testARoutedStepTheRunnerRefusesFallsBackToTheModel() async throws {
        let model = ScriptedModel(["Which way did it go: open, or within specification?"])
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Could not advance: choose a route.") }
        let outcome = try await run(model, tools, history: stepHistory,
                                    configuration: routing(["procedure_runner"], procedureActive: true),
                                    message: "next step")
        XCTAssertEqual(model.requests.map(\.purpose), [.afterTools])
        XCTAssertEqual(model.requests.first?.messages.last?.content, "Could not advance: choose a route.")
        XCTAssertEqual(outcome.text, "Which way did it go: open, or within specification?")
        XCTAssertEqual(outcome.routedCalls, 1)
    }

    func testARoutedStepWhoseResultIsAnErrorFallsBackToTheModel() async throws {
        let model = ScriptedModel(["Let's try that again."])
        let tools = ToolLog()
        tools.result = { _ in .init(text: "Error: the tool 'procedure_runner' is not available on this turn.", isError: true) }
        let outcome = try await run(model, tools, history: stepHistory,
                                    configuration: routing(["procedure_runner"], procedureActive: true),
                                    message: "say that again")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(outcome.text, "Let's try that again.")
        XCTAssertNotEqual(outcome.endReason, .routedResult)
    }

    func testWithoutRoutingTheSameTurnGoesToTheModelFirst() async throws {
        let model = ScriptedModel(["E110 is in the table."])
        let tools = ToolLog()
        let outcome = try await run(model, tools, message: "The control's showing E110. What do I check?")
        XCTAssertTrue(tools.calls.isEmpty)
        XCTAssertEqual(model.requests.map(\.purpose), [.initial])
        XCTAssertEqual(model.requests.first?.routedCalls, 0)
        XCTAssertEqual(outcome.routedCalls, 0)
    }

    func testARoutedCallFillingTheCapAnswersWithToolsWithheld() async throws {
        let model = ScriptedModel(["Low line voltage."])
        var configuration = routing(["equipment_lookup"])
        configuration.roundCap = 1
        let outcome = try await run(model, ToolLog(), configuration: configuration, message: "What does E110 mean?")
        XCTAssertEqual(model.requests.map(\.purpose), [.final])
        XCTAssertEqual(model.requests.first?.toolsOffered, false)
        XCTAssertEqual(outcome.endReason, .roundCap)
    }

    func testARoutedStartIsSaidAsTheRunnerWroteItWithNoGeneration() async throws {
        var configuration = routing(["procedure_runner", "field_session"])
        configuration.routing?.procedures = [.init(id: "slp99_no_ignition", title: "SLP99 No Ignition, Soft Lockout E270")]
        let tools = ToolLog()
        tools.result = { _ in
            .init(text: "Started procedure 'SLP99 No Ignition, Soft Lockout E270'.\n\n⚠️ SAFETY: Power off.\n"
                  + "Step — Confirm the lockout\nRead the code on the control. What does it show?\n(Call 'next' to continue.)")
        }
        let model = ScriptedModel(["never generated"])
        let outcome = try await run(model, tools, configuration: configuration,
                                    message: "Start the sLP99 No Ignition, Soft Lockout E270 procedure")
        XCTAssertEqual(tools.calls.first?.arguments["action"] as? String, "start")
        XCTAssertEqual(tools.calls.first?.arguments["procedure_id"] as? String, "slp99_no_ignition")
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(outcome.endReason, .routedResult)
        XCTAssertEqual(outcome.text, "Started procedure 'SLP99 No Ignition, Soft Lockout E270'. ⚠️ SAFETY: Power off. "
                       + "Confirm the lockout. Read the code on the control. What does it show?")
    }

    func testABargeInDuringARoutedCallStopsBeforeAnyGeneration() async {
        let model = ScriptedModel(["never generated"])
        let configuration = routing(["equipment_lookup"])
        let task = Task { () -> Int in
            do {
                _ = try await LocalToolLoop.run(
                    history: [], userMessage: "What does E110 mean?",
                    configuration: configuration,
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
        XCTAssertTrue(model.requests.isEmpty)
    }
}
