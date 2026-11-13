import XCTest
@testable import OpenGlasses

/// What a plan says when it stops at a step. The summary is said to the person as it stands, so
/// it is built from the plan's own rationales and the kind of stop — never the router's reason,
/// which is written for the model, and never a tool's internal name. Field report: a scheduled
/// task's held first step read back as "I couldn't get started, then stopped — step 1 of 2
/// (run_shortcut) did not complete: 'run_shortcut' wasn't run because … Do not retry
/// automatically."
@MainActor
final class PlanStopWordingTests: XCTestCase {

    private func plan(_ rationales: [(tool: String, rationale: String)]) -> AgentPlan {
        AgentPlan(goal: "g", steps: rationales.map { AgentStep(tool: $0.tool, rationale: $0.rationale) })
    }

    private let checkEmail = AgentPlan(goal: "check email", steps: [
        AgentStep(tool: "run_shortcut", rationale: "Run the Check Email shortcut."),
        AgentStep(tool: "speak", rationale: "tell you what's urgent"),
    ])

    // MARK: - Classifying a stop

    func testKindReadsThePolicysOwnCopy() {
        let tool = "run_shortcut"
        XCTAssertNil(PlanStop.kind(of: .completed("ok"), tool: tool))
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: ToolAuthorizationPolicy.holdMessage(tool)), tool: tool), .held)
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: ToolAuthorizationPolicy.declineMessage(tool)), tool: tool), .declined)
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: ToolAuthorizationPolicy.unavailableConfirmationMessage(tool)),
                                     tool: tool), .needsApproval)
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: ToolAuthorizationPolicy.blockMessage(tool, reason: "quiet hours")),
                                     tool: tool), .notAllowed)
        XCTAssertEqual(PlanStop.kind(of: .failedBeforeExecution(reason: "no such shortcut"), tool: tool), .failed)
        XCTAssertEqual(PlanStop.kind(of: .outcomeUnknown(operationID: "x", message: "timed out"), tool: tool), .unsure)
    }

    func testAnotherToolsHoldIsNotThisOnes() {
        // The copy is matched for this step's tool, so a hold worded for another is not a hold.
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: ToolAuthorizationPolicy.holdMessage("send_message")),
                                     tool: "run_shortcut"), .notAllowed)
    }

    func testExecutorRecordsWhereAndWhy() async {
        let router = ScriptedRouter(["run_shortcut": .rejected(reason: ToolAuthorizationPolicy.holdMessage("run_shortcut"))])
        let run = await PlanExecutor(router: router).execute(checkEmail)
        XCTAssertTrue(run.aborted)
        XCTAssertEqual(run.completedSteps, 0)
        XCTAssertEqual(run.stop, PlanStop(stepIndex: 0, kind: .held))
        XCTAssertEqual(router.calls, ["run_shortcut"])
    }

    // MARK: - The spoken summary

    func testHeldFirstStepSaysSoInPlainWords() {
        let run = PlanRunResult(completedSteps: 0, aborted: true,
                                stop: PlanStop(stepIndex: 0, kind: .held), transcript: [])
        let line = AgentRunner.summary(plan: checkEmail, run: run)
        XCTAssertEqual(line, "I didn't run the Check Email shortcut — you've been away, so I've held it for when you're back. I stopped there.")
    }

    func testNoStopEverLeaksModelCopyOrToolNames() {
        let kinds: [PlanStop.Kind] = [.held, .declined, .needsApproval, .notAllowed, .failed, .unsure]
        for kind in kinds {
            for index in 0..<2 {
                let run = PlanRunResult(completedSteps: index, aborted: true,
                                        stop: PlanStop(stepIndex: index, kind: kind), transcript: [])
                let line = AgentRunner.summary(plan: checkEmail, run: run)
                for leak in ["run_shortcut", "Do not retry", "step 1 of", "step 2 of", "then stopped", "couldn't get started"] {
                    XCTAssertFalse(line.contains(leak), "\(kind) at \(index): \(line)")
                }
            }
        }
    }

    func testDoneStepsComeFirst() {
        let p = plan([("web_search", "look it up"), ("send_message", "message the lead")])
        let run = PlanRunResult(completedSteps: 1, aborted: true,
                                stop: PlanStop(stepIndex: 1, kind: .declined), transcript: [])
        XCTAssertEqual(AgentRunner.summary(plan: p, run: run),
                       "I look it up, but I didn't message the lead, since you said no.")
    }

    func testUnsureStepSaysStoppedOnce() {
        let p = plan([("send_message", "message the lead"), ("web_search", "look it up")])
        let run = PlanRunResult(completedSteps: 0, aborted: true,
                                stop: PlanStop(stepIndex: 0, kind: .unsure), transcript: [])
        XCTAssertEqual(AgentRunner.summary(plan: p, run: run),
                       "I'm not sure I managed to message the lead, so I stopped there.")
    }

    func testAStepWithoutARationaleIsNumberedNotNamed() {
        let p = plan([("web_search", ""), ("run_shortcut", "")])
        let run = PlanRunResult(completedSteps: 1, aborted: true,
                                stop: PlanStop(stepIndex: 1, kind: .failed), transcript: [])
        XCTAssertEqual(AgentRunner.summary(plan: p, run: run),
                       "I did step 1, but I couldn't do step 2 — it didn't go through.")
    }

    func testFinishedPlanIsUnchanged() {
        let p = plan([("web_search", "find the manual"), ("summarize_conversation", "summarise it")])
        let run = PlanRunResult(completedSteps: 2, aborted: false, stop: nil, transcript: [])
        XCTAssertEqual(AgentRunner.summary(plan: p, run: run), "Done — I find the manual and summarise it.")
    }

    func testClauseTidiesARationale() {
        XCTAssertEqual(AgentRunner.clause("Run the Check Email shortcut."), "run the Check Email shortcut")
        XCTAssertEqual(AgentRunner.clause("  SMS Sam  "), "SMS Sam")
        XCTAssertNil(AgentRunner.clause(" . "))
    }

    // MARK: - Scheduled runs

    func testAScheduledRunNeverPlans() {
        // The plan speaks its opener and always has a summary to say; a scheduled task must be
        // able to stay quiet.
        XCTAssertTrue(LLMService.mayPlan(agentMode: true, hasNativeTools: true, hasImage: false,
                                         offlineHandoff: false, scheduledRun: false))
        XCTAssertFalse(LLMService.mayPlan(agentMode: true, hasNativeTools: true, hasImage: false,
                                          offlineHandoff: false, scheduledRun: true))
        XCTAssertFalse(LLMService.mayPlan(agentMode: false, hasNativeTools: true, hasImage: false,
                                          offlineHandoff: false, scheduledRun: false))
        XCTAssertFalse(LLMService.mayPlan(agentMode: true, hasNativeTools: true, hasImage: true,
                                          offlineHandoff: false, scheduledRun: false))
    }

    // MARK: - Shortcut templates

    func testTemplatesInstallSwitchedOff() {
        XCTAssertFalse(ShortcutTemplate.allTemplates.isEmpty)
        for template in ShortcutTemplate.allTemplates {
            let task = template.scheduledTask
            XCTAssertFalse(task.enabled, "\(template.id) must wait for its Shortcut to exist")
            XCTAssertEqual(task.id, template.taskId)
            XCTAssertEqual(task.prompt, template.taskPrompt)
            XCTAssertEqual(task.intervalMinutes, template.intervalMinutes)
        }
    }
}

/// A router that answers each tool from a script, and completes anything unscripted.
@MainActor
private final class ScriptedRouter: ToolExecuting {
    private let script: [String: ToolExecutionOutcome]
    private(set) var calls: [String] = []

    init(_ script: [String: ToolExecutionOutcome]) { self.script = script }

    func executeRoot(name: String, args: [String: Any], origin: ToolInvocationOrigin,
                     invocationID: String) async -> ToolExecutionOutcome {
        calls.append(name)
        return script[name] ?? .completed("ok")
    }
}
