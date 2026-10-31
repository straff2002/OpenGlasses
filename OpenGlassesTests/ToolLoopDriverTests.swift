import XCTest
@testable import OpenGlasses

/// Plan BG P3 — the shared tool-loop driver + dispatcher that replaced the four duplicated provider
/// loops. Exercised here with a synthetic adapter + in-memory history, no network.
@MainActor
final class ToolLoopDriverTests: XCTestCase {

    // MARK: - ToolDispatcher

    func testDispatcherExecutesWellFormedCallAndTracksStatus() async {
        var statuses: [ToolCallStatus] = []
        let dispatcher = ToolDispatcher(
            execute: { name, args, _, _ in .completed("ran \(name) with \(args["x"] ?? "?")") },
            onStatus: { statuses.append($0) }
        )
        let outcome = await dispatcher.dispatch(
            ToolInvocation(id: "1", name: "calc", arguments: ["x": 5])
        )
        XCTAssertTrue(outcome.result.isSuccess)
        XCTAssertNil(outcome.yieldReason)
        XCTAssertEqual(statuses, [.executing("calc"), .completed("calc")])
    }

    func testDispatcherReturnsParseErrorForNilArgumentsWithoutExecuting() async {
        var executed = false
        let dispatcher = ToolDispatcher(
            execute: { _, _, _, _ in executed = true; return .completed("should not run") },
            onStatus: { _ in }
        )
        let outcome = await dispatcher.dispatch(
            ToolInvocation(id: "1", name: "weather", arguments: nil)
        )
        XCTAssertFalse(executed, "Malformed args must not reach the executor")
        guard case .failure(let msg) = outcome.result else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("Could not parse the arguments for 'weather'"))
    }

    func testDispatcherReportsFailureStatus() async {
        var statuses: [ToolCallStatus] = []
        let dispatcher = ToolDispatcher(
            execute: { _, _, _, _ in .failedBeforeExecution(reason: "boom") },
            onStatus: { statuses.append($0) }
        )
        _ = await dispatcher.dispatch(ToolInvocation(id: "1", name: "t", arguments: [:]))
        XCTAssertEqual(statuses, [.executing("t"), .failed("t", "Failed")])
    }

    func testYieldReasonParsedFromSuccessfulYieldCall() {
        let reason = ToolDispatcher.yieldReason(
            name: "yield_to_human",
            result: .success("YIELD_TO_HUMAN: check the stove\nWaiting for you to say \"done\" or \"continue\" when ready.")
        )
        XCTAssertEqual(reason, "check the stove")
    }

    func testYieldReasonNilForOtherTools() {
        XCTAssertNil(ToolDispatcher.yieldReason(name: "calc", result: .success("YIELD_TO_HUMAN: x")))
        XCTAssertNil(ToolDispatcher.yieldReason(name: "yield_to_human", result: .failure("nope")))
        XCTAssertNil(ToolDispatcher.yieldReason(name: "yield_to_human", result: .success("plain text")))
    }

    // MARK: - runToolLoop

    /// Builds an adapter whose `performTurn` replays a scripted list of turns and records history +
    /// dispatched calls into shared arrays for assertions.
    private func makeScriptedAdapter(
        label: String = "Test",
        turns: [AssistantTurn],
        execute: @escaping (String, [String: Any], String?, String?) async -> ToolExecutionOutcome
            = { name, _, _, _ in .completed("ok:\(name)") },
        history: Box<[String]>,
        statuses: Box<[ToolCallStatus]>
    ) -> ProviderLoopAdapter {
        var index = 0
        return ProviderLoopAdapter(
            label: label,
            dispatcher: ToolDispatcher(execute: execute, onStatus: { statuses.value.append($0) }),
            performTurn: {
                defer { index += 1 }
                guard index < turns.count else {
                    // Keep returning tool calls to force the loop to exhaust iterations.
                    return turns.last ?? AssistantTurn(text: "")
                }
                return turns[index]
            },
            appendAssistantToolCall: { _ in history.value.append("assistant:toolcall") },
            appendToolResults: { outcomes in
                history.value.append("results:" + outcomes.map { $0.invocation.name }.joined(separator: ",")) },
            finalize: { turn in history.value.append("final:\(turn.text)"); return turn.text }
        )
    }

    func testLoopReturnsFinalAnswerWithNoTools() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "hello")],
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "hello")
        XCTAssertEqual(history.value, ["final:hello"])
        XCTAssertEqual(statuses.value.last, .idle)
    }

    func testLoopDispatchesToolsThenReturnsFinalAnswer() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let adapter = makeScriptedAdapter(
            turns: [
                AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "calc", arguments: [:])]),
                AssistantTurn(text: "done")
            ],
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "done")
        XCTAssertEqual(history.value, ["assistant:toolcall", "results:calc", "final:done"])
    }

    // MARK: - A stall after a tool has answered

    /// A search returned and the model's next reply promised to search ("Vou pesquisar… um
    /// momento"); the loop spoke it and the wearer waited ten minutes. Now it asks once more,
    /// with the results still in history and the stall itself kept out of it.
    func testAStallAfterAToolResultIsReaskedOnceAndNotSpoken() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var adapter = makeScriptedAdapter(
            turns: [
                AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "web_search", arguments: [:])]),
                AssistantTurn(text: "Vou pesquisar a programação. Um momento, por favor."),
                AssistantTurn(text: "Às quinze e trinta dá Eliminators.")
            ],
            history: history, statuses: statuses
        )
        adapter.appendUserNote = { _ in history.value.append("note") }
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "Às quinze e trinta dá Eliminators.")
        XCTAssertEqual(history.value, ["assistant:toolcall", "results:web_search", "note",
                                       "final:Às quinze e trinta dá Eliminators."],
                       "the stalled reply is never finalised; the note goes in; the answer follows")
    }

    /// Twice is the answer: one re-ask, then whatever comes back is spoken, as before.
    func testASecondStallIsSpokenAsTheAnswer() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var adapter = makeScriptedAdapter(
            turns: [
                AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "web_search", arguments: [:])]),
                AssistantTurn(text: "One moment, let me check."),
                AssistantTurn(text: "Hold on, I'll look that up.")
            ],
            history: history, statuses: statuses
        )
        adapter.appendUserNote = { _ in history.value.append("note") }
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "Hold on, I'll look that up.")
        XCTAssertEqual(history.value.filter { $0 == "note" }.count, 1)
    }

    /// Before any tool has run, "one moment" is an honest opener and is not re-asked.
    func testAStallWithNoToolResultIsNotReasked() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var adapter = makeScriptedAdapter(turns: [AssistantTurn(text: "One moment, let me check.")],
                                          history: history, statuses: statuses)
        adapter.appendUserNote = { _ in history.value.append("note") }
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "One moment, let me check.")
        XCTAssertEqual(history.value, ["final:One moment, let me check."])
    }

    /// A provider with no way to append a note speaks the stall, as before.
    func testAProviderWithoutANoteHookSpeaksTheStall() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let adapter = makeScriptedAdapter(
            turns: [
                AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "web_search", arguments: [:])]),
                AssistantTurn(text: "One moment, let me check.")
            ],
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "One moment, let me check.")
    }

    func testLoopShortCircuitsOnYield() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [
                ToolInvocation(id: "1", name: "yield_to_human", arguments: [:]),
                ToolInvocation(id: "2", name: "never", arguments: [:])
            ])],
            execute: { name, _, _, _ in
                name == "yield_to_human" ? .completed("YIELD_TO_HUMAN: your turn") : .completed("ran")
            },
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "your turn")
        // Only the yielding call was dispatched — the second tool never ran. It is still answered:
        // the assistant message names both calls, and a call with no result breaks the next request.
        XCTAssertEqual(history.value, ["assistant:toolcall", "results:yield_to_human,never"])
        XCTAssertEqual(statuses.value.last, .yielded("yield_to_human"))
    }

    /// A yield in the middle of a turn: what ran keeps its result, the yield keeps its own, and
    /// everything after it is answered as not run without being executed.
    func testYieldAnswersEveryCallOfTheTurnAndRunsNothingAfterIt() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let executed = Box<[String]>([])
        let appended = Box<[ToolDispatchOutcome]>([])
        var served = false
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(
                execute: { name, _, _, _ in
                    executed.value.append(name)
                    return name == "yield_to_human" ? .completed("YIELD_TO_HUMAN: your turn") : .completed("ran")
                },
                onStatus: { statuses.value.append($0) }),
            performTurn: {
                XCTAssertFalse(served, "a yield ends the loop; no second request is made")
                served = true
                return AssistantTurn(text: "", toolCalls: [
                    ToolInvocation(id: "1", name: "first", arguments: [:]),
                    ToolInvocation(id: "2", name: "yield_to_human", arguments: [:]),
                    ToolInvocation(id: "3", name: "send_message", arguments: [:]),
                    ToolInvocation(id: "4", name: "last", arguments: [:])
                ])
            },
            appendAssistantToolCall: { _ in history.value.append("assistant:toolcall") },
            appendToolResults: { appended.value.append(contentsOf: $0) },
            finalize: { $0.text })

        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })

        XCTAssertEqual(result, "your turn")
        XCTAssertEqual(executed.value, ["first", "yield_to_human"], "nothing after the yield runs")
        XCTAssertEqual(appended.value.map { $0.invocation.id }, ["1", "2", "3", "4"],
                       "every call the assistant message names has a result")
        XCTAssertEqual(appended.value[0].outcome, .completed("ran"))
        for unrun in appended.value.suffix(2) {
            XCTAssertEqual(unrun.outcome,
                           .failedBeforeExecution(reason: ToolDispatcher.notRunAfterYield(unrun.invocation.name)))
            XCTAssertEqual(unrun.retryDisposition, .safeToRetry, "nothing happened, so it may be asked for again")
            XCTAssertNil(unrun.yieldReason)
        }
    }

    /// The budget is spent but the tools already ran, so the turn is put into words rather than
    /// thrown away as a server failure — and a call the wrap-up asks for is answered, not run.
    func testExhaustedLoopWrapsUpWithoutRunningMoreTools() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var executed = 0
        // Every turn calls a tool → the loop never reaches a final answer by itself. Each answer
        // differs, so this is a budget running out, not a model repeating itself.
        let adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "loop", arguments: [:])])],
            execute: { _, _, _, _ in executed += 1; return .completed("Step \(executed) done.") },
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 3, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(executed, 3, "dispatched exactly maxIterations times, never in the wrap-up")
        XCTAssertEqual(result, "Done so far: Step 1 done. Step 2 done. Step 3 done.")
        XCTAssertEqual(history.value.filter { $0.hasPrefix("results:") }.count, 4,
                       "the wrap-up's calls get answers so the history stays well-formed")
        XCTAssertEqual(history.value.last, "final:\(result)", "the summary goes through finalize")
        XCTAssertEqual(statuses.value.last, .idle)
    }

    /// Nothing succeeded, so there is nothing to summarise: the old sentence, as before.
    func testTheCannedSentenceIsKeptWhenNothingSucceeded() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var attempt = 0
        let adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "loop", arguments: [:])])],
            execute: { _, _, _, _ in attempt += 1; return .failedBeforeExecution(reason: "No session \(attempt).") },
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 2, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, ToolLoopBudget.spokenFallback)
        XCTAssertEqual(history.value.last, "final:\(ToolLoopBudget.spokenFallback)")
    }

    // MARK: - The wrap-up offers no tools

    func testTheWrapUpUsesPerformWrapUpWhenTheProviderHasOne() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "task", arguments: [:])])],
            execute: { _, args, _, _ in .completed("ran \(args.count)") },
            history: history, statuses: statuses
        )
        var wrapUps = 0
        adapter.performWrapUp = {
            wrapUps += 1
            return AssistantTurn(text: "Closed the Verify task.")
        }
        let result = try await runToolLoop(maxIterations: 1, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(wrapUps, 1)
        XCTAssertEqual(result, "Closed the Verify task.")
        XCTAssertEqual(history.value, ["assistant:toolcall", "results:task", "final:Closed the Verify task."])
    }

    /// The flag a provider reads while it builds the request is raised for the wrap-up only.
    func testWithholdingRaisesTheFlagForTheWrapUpOnly() async throws {
        let withholding = ToolWithholding()
        var seen: [Bool] = []
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(execute: { _, _, _, _ in .completed("ok") }, onStatus: { _ in }),
            performTurn: {
                seen.append(withholding.active)
                return withholding.active
                    ? AssistantTurn(text: "All done.")
                    : AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "\(seen.count)", name: "t",
                                                                          arguments: ["n": seen.count])])
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { _ in },
            finalize: { $0.text }
        ).withholdingTools(withholding)
        let result = try await runToolLoop(maxIterations: 2, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(result, "All done.")
        XCTAssertEqual(seen, [false, false, true])
        XCTAssertFalse(withholding.active, "lowered again once the wrap-up is in")
    }

    /// A server that refuses a closed tool choice still gets asked the ordinary way.
    func testAWrapUpTheServerRefusesFallsBackToAnOrdinaryTurn() async throws {
        struct Refused: Error {}
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "task", arguments: [:])]),
                    AssistantTurn(text: "Recorded the reading.")],
            history: history, statuses: statuses
        )
        adapter.performWrapUp = { throw Refused() }
        let result = try await runToolLoop(maxIterations: 1, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "Recorded the reading.")
    }

    // MARK: - The same call, the same answer

    /// `field_session` five times in one turn, the same reply each time, and the technician heard
    /// only that it had stopped. The first repeat runs (a read can change); the second is not run.
    func testTwoIdenticalAnswersEndTheLoopAndTheThirdCallIsNeverDispatched() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let appended = Box<[ToolDispatchOutcome]>([])
        var executed = 0
        var requests = 0
        let call = AssistantTurn(text: "", toolCalls: [
            // Not `status`, which `ToolRepeatGuard` stops sooner (Plan KE P1).
            ToolInvocation(id: "x", name: "field_session", arguments: ["action": "list"])])
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(
                execute: { _, _, _, _ in executed += 1; return .completed("Job 1029 is open. Verify task done.") },
                onStatus: { statuses.value.append($0) }),
            performTurn: {
                requests += 1
                // Rounds 1–3 call it again; anything after is the wrap-up, which has no words.
                return requests <= 3 ? call : AssistantTurn(text: "")
            },
            appendAssistantToolCall: { _ in history.value.append("assistant:toolcall") },
            appendToolResults: { appended.value.append(contentsOf: $0) },
            finalize: { turn in history.value.append("final:\(turn.text)"); return turn.text }
        )
        let result = try await runToolLoop(maxIterations: 8, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })

        XCTAssertEqual(executed, 2, "the first call and its first repeat ran; the third was answered from them")
        XCTAssertEqual(requests, 4, "three rounds and the wrap-up — not the eight the budget allowed")
        XCTAssertEqual(appended.value.count, 3, "every call the model made has an answer")
        XCTAssertEqual(appended.value[2].outcome,
                       .rejected(reason: ToolLoopBudget.alreadyAnswered(
                           "field_session", previous: "Job 1029 is open. Verify task done.")))
        XCTAssertTrue(ToolLoopBudget.alreadyAnswered("field_session", previous: "Job 1029 is open.")
            .hasPrefix("'field_session' already ran this turn with the same input and gave the same answer: Job 1029 is open."))
        XCTAssertEqual(result, "Done so far: Job 1029 is open.", "the turn ends in what was done")
        XCTAssertEqual(history.value.last, "final:Done so far: Job 1029 is open.")
    }

    /// A repeat that comes back different is a read that changed, not a loop: it keeps running.
    func testARepeatWithADifferentAnswerIsNotStopped() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        var executed = 0
        let adapter = makeScriptedAdapter(
            turns: [AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "reading", arguments: [:])]),
                    AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "2", name: "reading", arguments: [:])]),
                    AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "3", name: "reading", arguments: [:])]),
                    AssistantTurn(text: "Pressure is settling.")],
            execute: { _, _, _, _ in executed += 1; return .completed("Pressure \(executed) bar.") },
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 5, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(executed, 3)
        XCTAssertEqual(result, "Pressure is settling.")
    }

    // MARK: - The words a turn ends in

    func testTheSummaryIsTheFirstSentenceOfEachDistinctSuccess() {
        func done(_ text: String) -> ToolDispatchOutcome {
            ToolDispatchOutcome(invocation: ToolInvocation(id: "1", name: "t", arguments: [:]),
                                outcome: .completed(text), yieldReason: nil)
        }
        let failed = ToolDispatchOutcome(invocation: ToolInvocation(id: "2", name: "t", arguments: [:]),
                                         outcome: .failedBeforeExecution(reason: "Nothing ran."), yieldReason: nil)
        XCTAssertEqual(ToolLoopBudget.spoken(from: [
            done("Reading recorded: 3.5 in. w.c. Saved to the job."),
            failed,
            done("Reading recorded: 3.5 in. w.c. Saved again."),
            done("{\"json\": true}"),
            done("Verify task closed\nwith a note"),
        ]), "Done so far: Reading recorded: 3.5 in. Verify task closed.")
        XCTAssertEqual(ToolLoopBudget.spoken(from: [failed]), ToolLoopBudget.spokenFallback)
        XCTAssertEqual(ToolLoopBudget.spoken(from: []), ToolLoopBudget.spokenFallback)

        let long = ToolLoopBudget.spoken(from: (1...20).map { done("Task \($0) of the job was closed and filed.") })
        XCTAssertLessThanOrEqual(long.count, ToolLoopBudget.summaryCharacterLimit)
        XCTAssertTrue(long.hasPrefix("Done so far: Task 1 of the job was closed and filed. Task 2"), long)
        XCTAssertTrue(long.hasSuffix("filed."), "whole sentences only: \(long)")
    }

    func testExhaustedLoopUsesTheWrapUpAnswerWhenItHasOne() async throws {
        let history = Box<[String]>([]), statuses = Box<[ToolCallStatus]>([])
        let call = AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "task", arguments: [:])])
        let adapter = makeScriptedAdapter(
            turns: [call, call, AssistantTurn(text: "Closed the ignitor task.")],
            history: history, statuses: statuses
        )
        let result = try await runToolLoop(maxIterations: 2, adapter: adapter,
                                           setStatus: { statuses.value.append($0) })
        XCTAssertEqual(result, "Closed the ignitor task.")
        XCTAssertEqual(history.value.filter { $0.hasPrefix("results:") }.count, 2)
    }

    func testWrapUpCallsAreAnsweredAsNotRun() async throws {
        var appended: [ToolDispatchOutcome] = []
        let call = AssistantTurn(text: "Done so far.", toolCalls: [ToolInvocation(id: "1", name: "task", arguments: [:])])
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(execute: { _, _, _, _ in .completed("ok") }, onStatus: { _ in }),
            performTurn: { call },
            appendAssistantToolCall: { _ in },
            appendToolResults: { appended = $0 },
            finalize: { $0.text }
        )
        let result = try await runToolLoop(maxIterations: 1, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(result, "Done so far.", "the wrap-up's own words are kept")
        XCTAssertEqual(appended.map(\.outcome), [.failedBeforeExecution(reason: ToolLoopBudget.notRun("task"))])
    }
}

/// Reference wrapper so escaping closures can mutate captured test state.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
