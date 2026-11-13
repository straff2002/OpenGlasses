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
    /// Where and why the plan stopped; nil when it ran to the end.
    let stop: PlanStop?
    let transcript: [String]   // one outcome line per attempted step
}

/// Why a plan stopped at a step, in terms the person can be told. The router's own reason is
/// written for the model ("…Do not retry automatically.") and carries the tool's internal name,
/// so it never reaches the spoken summary; this is what does.
struct PlanStop: Equatable {
    enum Kind: Equatable {
        /// The presence ceiling held it for when the person is back.
        case held
        /// The person said no to it.
        case declined
        /// It needed a yes, and there was no way to ask just then.
        case needsApproval
        /// A rule or policy would not let it run.
        case notAllowed
        /// It was tried and failed before doing anything.
        case failed
        /// It started and may or may not have landed.
        case unsure
    }

    /// Zero-based index of the step the plan stopped at.
    let stepIndex: Int
    let kind: Kind

    /// Reads a step's outcome. The rejections are told apart by the policy's own copy for that
    /// tool, so a rejection the policy did not word is `.notAllowed`, never mistaken for a hold.
    static func kind(of outcome: ToolExecutionOutcome, tool: String) -> Kind? {
        switch outcome {
        case .completed: return nil
        case .outcomeUnknown: return .unsure
        case .failedBeforeExecution: return .failed
        case .rejected(let reason):
            if reason.hasPrefix(ToolAuthorizationPolicy.holdMessage(tool)) { return .held }
            if reason.hasPrefix(ToolAuthorizationPolicy.declineMessage(tool)) { return .declined }
            if reason.hasPrefix(ToolAuthorizationPolicy.unavailableConfirmationMessage(tool)) {
                return .needsApproval
            }
            return .notAllowed
        }
    }
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
            guard let kind = PlanStop.kind(of: outcome, tool: step.tool) else {
                completed += 1
                transcript.append("✓ \(step.tool): \(String(outcome.text.prefix(120)))")
                continue
            }
            // The plan stops here. An unsure step must not be told as one that didn't happen —
            // the rest of the plan may be building on an effect that did land.
            transcript.append("\(kind == .unsure ? "?" : "✗") \(step.tool): \(outcome.text)")
            return PlanRunResult(completedSteps: completed, aborted: true,
                                 stop: PlanStop(stepIndex: index, kind: kind), transcript: transcript)
        }

        return PlanRunResult(completedSteps: completed, aborted: false, stop: nil, transcript: transcript)
    }
}
