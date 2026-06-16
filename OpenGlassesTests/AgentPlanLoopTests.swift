import XCTest
@testable import OpenGlasses

/// Tests for the plan-then-execute loop (Plan S Phase 1b): the multi-step `AgentComplexity`
/// gate, the pure `AgentPlanner` JSON decoding, and the `AgentRunner` orchestration. Headless —
/// the model call and tool execution are injected fakes.
@MainActor
final class AgentPlanLoopTests: XCTestCase {

    // MARK: - AgentComplexity gate

    func testComplexityDetectsChainedActions() {
        XCTAssertTrue(AgentComplexity.isMultiStep("find the work order, photo the gauge, then log it and message my lead"))
        XCTAssertTrue(AgentComplexity.isMultiStep("take a photo and send it to mom"))
        XCTAssertTrue(AgentComplexity.isMultiStep("search for the manual then summarize it"))
    }

    func testComplexityIgnoresSingleShotAndChat() {
        XCTAssertFalse(AgentComplexity.isMultiStep("what's the weather"))
        XCTAssertFalse(AgentComplexity.isMultiStep("take a photo"))                 // single action, no sequencer
        XCTAssertFalse(AgentComplexity.isMultiStep("tell me about cats and dogs"))  // conjunction but no actions
        XCTAssertFalse(AgentComplexity.isMultiStep("who won the game last night"))
    }

    // MARK: - AgentPlanner decoding (pure)

    func testDecodeValidPlan() throws {
        let json = """
        {"goal":"do x","steps":[
          {"tool":"web_search","args":{"q":"a"},"rationale":"look it up"},
          {"tool":"send_message","rationale":"tell mom"}
        ]}
        """
        let plan = try AgentPlanner.decode(json, goal: "fallback")
        XCTAssertEqual(plan.goal, "do x")
        XCTAssertEqual(plan.steps.map(\.tool), ["web_search", "send_message"])
        XCTAssertEqual(plan.steps[0].reversibility, .reversible)
        XCTAssertEqual(plan.steps[1].reversibility, .irreversible)   // from the static table
        XCTAssertEqual(plan.steps[0].rationale, "look it up")
    }

    func testDecodeStripsFencesAndProse() throws {
        let raw = """
        Sure — here is the plan:
        ```json
        {"steps":[{"tool":"web_search","rationale":"look"}]}
        ```
        Hope that helps!
        """
        let plan = try AgentPlanner.decode(raw, goal: "the goal")
        XCTAssertEqual(plan.goal, "the goal")                        // model omitted goal → fallback
        XCTAssertEqual(plan.steps.map(\.tool), ["web_search"])
    }

    func testDecodeHandlesBracesInsideStrings() throws {
        let json = #"{"goal":"use { braces } ok","steps":[{"tool":"web_search"}]}"#
        let plan = try AgentPlanner.decode(json, goal: "f")
        XCTAssertEqual(plan.goal, "use { braces } ok")
        XCTAssertEqual(plan.steps.count, 1)
    }

    func testDecodeRejectsGarbageAndEmpty() {
        XCTAssertThrowsError(try AgentPlanner.decode("no json here", goal: "g"))
        XCTAssertThrowsError(try AgentPlanner.decode(#"{"steps":[]}"#, goal: "g"))
    }

    // MARK: - AgentRunner orchestration

    private func plannerReturning(_ json: String) -> AgentPlanner {
        let planner = AgentPlanner()
        planner.complete = { _, _ in json }
        return planner
    }

    func testRunnerExecutesPlanAndSummarises() async {
        let router = FakePlanRouter()
        let json = """
        {"goal":"g","steps":[
          {"tool":"web_search","rationale":"find the manual"},
          {"tool":"summarize_conversation","rationale":"summarise it"}
        ]}
        """
        let runner = AgentRunner(router: router, planner: plannerReturning(json))
        var steps: [Int] = []
        runner.onStep = { i, _, _ in steps.append(i) }

        let result = await runner.run(request: "do the thing then summarise",
                                      availableTools: ["web_search", "summarize_conversation"])
        guard let result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.completedSteps, 2)
        XCTAssertFalse(result.aborted)
        XCTAssertEqual(router.calls, ["web_search", "summarize_conversation"])
        XCTAssertEqual(steps, [1, 2])
        XCTAssertTrue(result.summary.contains("find the manual"))
        XCTAssertTrue(result.summary.contains("summarise it"))
    }

    func testRunnerFallsBackOnUnparseablePlan() async {
        let runner = AgentRunner(router: FakePlanRouter(), planner: plannerReturning("not json"))
        let result = await runner.run(request: "x", availableTools: ["web_search"])
        XCTAssertNil(result)   // caller falls back to single-shot
    }

    func testRunnerFallsBackOnUnknownTool() async {
        let json = #"{"steps":[{"tool":"made_up_tool","rationale":"nope"}]}"#
        let runner = AgentRunner(router: FakePlanRouter(), planner: plannerReturning(json))
        let result = await runner.run(request: "x", availableTools: ["web_search"])
        XCTAssertNil(result)   // validator rejects unknown tool → fall back
    }

    func testRunnerAbortsAndReportsOnStepFailure() async {
        let router = FakePlanRouter()
        router.failTools = ["send_message"]
        let json = """
        {"steps":[
          {"tool":"web_search","rationale":"look it up"},
          {"tool":"send_message","rationale":"message lead"},
          {"tool":"web_search","rationale":"should not run"}
        ]}
        """
        let runner = AgentRunner(router: router, planner: plannerReturning(json))
        let result = await runner.run(request: "x", availableTools: ["web_search", "send_message"])
        guard let result else { return XCTFail("expected a result") }
        XCTAssertTrue(result.aborted)
        XCTAssertEqual(result.completedSteps, 1)
        XCTAssertEqual(router.calls, ["web_search", "send_message"])   // stopped at the failure
        XCTAssertTrue(result.summary.lowercased().contains("stopped"))
    }
}

/// In-memory `ToolExecuting` double for plan-loop tests.
@MainActor
private final class FakePlanRouter: ToolExecuting {
    var calls: [String] = []
    var failTools: Set<String> = []

    func handleToolCall(name: String, args: [String: Any]) async -> ToolResult {
        calls.append(name)
        return failTools.contains(name) ? .failure("blocked") : .success("ok")
    }
}
