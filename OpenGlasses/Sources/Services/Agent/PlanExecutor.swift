import Foundation

/// The execution seam the `PlanExecutor` runs steps through — `NativeToolRouter` in production,
/// a fake in tests. Matches `NativeToolRouter.executeRoot` so the router conforms for free.
@MainActor
protocol ToolExecuting: AnyObject {
    func executeRoot(name: String, args: [String: Any], origin: ToolInvocationOrigin,
                     invocationID: String) async -> ToolExecutionOutcome
}

extension NativeToolRouter: ToolExecuting {}
extension NativeToolRouter: PlanApprovalAuthority {}

/// The outcome of running a plan.
struct PlanRunResult: Equatable {
    let completedSteps: Int
    let aborted: Bool
    let abortReason: String?
    let transcript: [String]   // one outcome line per attempted step
}

/// Runs a validated `AgentPlan` step-by-step through the `NativeToolRouter` (Plan S).
///
/// Two properties make this the agentic spine rather than just a loop:
///  1. **Tool output is consumed locally and never fed back into planning** — the plan is fixed,
///     so an injected instruction in step _i_'s result can't add or redirect later steps. This is
///     the structural prompt-injection defense that pairs with [[PromptInjectionPolicy]].
///  2. **Fail-safe** — a failed or vetoed step (the router returns `.failure`, e.g. a
///     supervisor block or a declined confirmation) aborts the rest of the plan instead of
///     barrelling on.
@MainActor
final class PlanExecutor {
    private let router: ToolExecuting

    /// Per-step progress hook with (1-based index, total, step), for a "step i of N" HUD trace.
    var onStep: ((Int, Int, AgentStep) -> Void)?

    init(router: ToolExecuting) {
        self.router = router
    }

    /// - Parameter grants: the plan's one approval (Plan LP §1) — a grant per approved step index,
    ///   handed to that step's dispatch only. `runID` names the run they were scoped to.
    func execute(_ plan: AgentPlan, grants: [Int: PlanStepGrant] = [:],
                 runID: String = UUID().uuidString) async -> PlanRunResult {
        var transcript: [String] = []
        var completed = 0

        for (index, step) in plan.steps.enumerated() {
            onStep?(index + 1, plan.steps.count, step)

            // One identity per step of this run, so a step is the same operation wherever it is
            // observed. A fresh run of the same plan gets a fresh run id and executes normally —
            // re-running a plan is a decision, not a redelivery.
            let stepInvocationID = "\(runID)#\(index)"
            // Plan IW P1: the router records the step on the activity trail as a planned step,
            // with the plan's goal beside it. Only the step's tool, action and reason ride along —
            // never its arguments.
            let context = PlannedStepContext(goal: plan.goal, step: step.record)
            // A step's grant rides with that step's own dispatch and no other: the next step
            // gets its own, or none, and asks at its call if it needs to.
            let outcome = await PlanApprovalScope.$stepGrant.withValue(grants[index]) {
                await ActivityScope.$plannedStep.withValue(context) {
                    await router.executeRoot(name: step.tool, args: step.args, origin: .model,
                                             invocationID: stepInvocationID)
                }
            }
            switch outcome {
            case .completed(let text):
                completed += 1
                transcript.append("✓ \(step.tool): \(String(text.prefix(120)))")
            case .outcomeUnknown(_, let message):
                // The plan still stops here, but it must not claim the step didn't happen — the
                // rest of the plan may be building on an effect that did land.
                transcript.append("? \(step.tool): \(message)")
                return PlanRunResult(
                    completedSteps: completed,
                    aborted: true,
                    abortReason: "step \(index + 1) of \(plan.steps.count) (\(step.tool)) may or may not have completed: \(message)",
                    transcript: transcript
                )
            case .rejected(let reason), .failedBeforeExecution(let reason):
                transcript.append("✗ \(step.tool): \(reason)")
                return PlanRunResult(
                    completedSteps: completed,
                    aborted: true,
                    abortReason: "step \(index + 1) of \(plan.steps.count) (\(step.tool)) did not complete: \(reason)",
                    transcript: transcript
                )
            }
        }

        return PlanRunResult(completedSteps: completed, aborted: false, abortReason: nil, transcript: transcript)
    }
}
