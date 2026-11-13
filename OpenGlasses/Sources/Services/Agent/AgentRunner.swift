import Foundation

/// Orchestrates the plan-then-execute loop (Plan S): plan → validate → execute → summarise.
///
/// Returns `nil` when the request couldn't be turned into a usable, valid plan, so the caller
/// (`LLMService`) cleanly falls back to the normal single-shot tool loop — which is still safe,
/// since the `SafetySupervisor` gates every individual call. When it does run, the validated plan
/// is the single source of truth and tool output never re-enters planning, so an injected
/// instruction in a result can't redirect the agent.
@MainActor
final class AgentRunner {
    private let router: ToolExecuting
    private let planner: AgentPlanner
    /// The router's approval half (Plan LP §1). Nil keeps every step asking at its own call, as
    /// before.
    private let approvals: PlanApprovalAuthority?

    /// Plan-header narration for the HUD plan-trace.
    var onNarrate: ((String) -> Void)?
    /// Per-step progress (1-based index, total, step) for a "step i of N" HUD trace.
    var onStep: ((Int, Int, AgentStep) -> Void)?
    /// The plan's spoken opener (Plan LP §2), said before the first step runs.
    var onSpeak: ((String) -> Void)?
    /// The plan step budget (defaults to the persisted safety setting).
    var stepBudget: () -> Int = { SafetySettings.stepBudget }
    /// Quiet after actions is on for this turn (Plan LA).
    var quietAfterActionsActive: () -> Bool = { Config.quietAfterActionsEnabled && !Config.simpleModeEnabled }
    /// Whether a step is an action Quiet after actions would end quietly, judged before it runs.
    /// Defaults to no, which keeps the opener.
    var stepEndsQuietly: (AgentStep) -> Bool = { _ in false }

    init(router: ToolExecuting, planner: AgentPlanner, approvals: PlanApprovalAuthority? = nil) {
        self.router = router
        self.planner = planner
        self.approvals = approvals
    }

    struct Result {
        let summary: String       // natural-language outcome, spoken back to the user
        let completedSteps: Int
        let totalSteps: Int
        let aborted: Bool
    }

    func run(request: String, availableTools: [String]) async -> Result? {
        guard let plan = try? await planner.plan(request: request, availableTools: availableTools) else {
            return nil   // couldn't parse a plan → fall back to single-shot
        }
        let validated: AgentPlan
        switch PlanValidator.validate(plan, knownTools: Set(availableTools), stepBudget: stepBudget()) {
        case .valid(let p): validated = p
        case .invalid:      return nil   // over budget / unknown tool → fall back to single-shot
        }

        onNarrate?(planHeader(validated))

        // Plan LP §1: ask once, before anything runs, for every step that would stop at its call.
        // The grants this issues are this run's alone and do not outlive it: whatever is unspent
        // when the run ends — finished, stopped at a step, declined, or cancelled — is revoked.
        let runID = UUID().uuidString
        defer {
            if let approvals {
                let revoked = approvals.revokePlanGrants(scope: runID)
                if revoked > 0 { PrivacyLog.model(.planGrantsRevoked, count: revoked) }
            }
        }
        var grants: [Int: PlanStepGrant] = [:]
        var asked = false
        if let approvals {
            let preflights = validated.steps.map { approvals.planPreflight(name: $0.tool, args: $0.args) }
            if case .asks(let parts) = PlanApproval.shape(for: preflights) {
                asked = true
                for part in parts {
                    PrivacyLog.model(.planApprovalAsked, count: part.items.count)
                    let outcome = await approvals.requestPlanApproval(
                        part, scope: runID, ttl: PlanApproval.grantLifetimeCeiling)
                    PrivacyLog.model(.planApprovalAnswered, count: part.items.count,
                                     reason: PrivacyToken(Self.token(outcome)))
                    switch outcome {
                    case .approved(let issued):
                        grants.merge(issued) { first, _ in first }
                    case .unavailable:
                        break   // each step fails closed at its own call
                    case .declined, .busy, .consentWithdrawn:
                        // A no to either half stops the plan before any step has run.
                        return Result(summary: Self.notStartedLine(outcome), completedSteps: 0,
                                      totalSteps: validated.steps.count, aborted: true)
                    }
                }
            }
        }

        // Plan LP §2: one sentence for a plan of two or more steps, unless the ask already said it.
        let opener = PlanOpener.sentence(
            for: validated, request: request, asking: asked,
            quietEndsEveryStep: quietAfterActionsActive() && validated.steps.allSatisfy(stepEndsQuietly))
        if let opener { onSpeak?(opener) }
        let narration: PlanTurnNarration? = (asked || opener != nil) ? PlanTurnNarration() : nil

        let executor = PlanExecutor(router: router)
        // Per-step trace flows through onStep (index + step); onNarrate carries the header only,
        // so the HUD/TTS aren't told the same thing twice.
        executor.onStep = { [weak self] index, total, step in self?.onStep?(index, total, step) }
        let run = await PlanNarrationScope.$current.withValue(narration) {
            await executor.execute(validated, grants: grants, runID: runID)
        }

        return Result(
            summary: Self.summary(plan: validated, run: run),
            completedSteps: run.completedSteps,
            totalSteps: validated.steps.count,
            aborted: run.aborted
        )
    }

    /// What the plan says when its ask did not come back a yes. Nothing ran.
    static func notStartedLine(_ outcome: PlanApprovalOutcome) -> String {
        switch outcome {
        case .busy: return PlanApprovalPhraser.busyLine
        case .consentWithdrawn: return PlanApprovalPhraser.consentWithdrawnLine
        case .declined, .approved, .unavailable: return PlanApprovalPhraser.declinedLine
        }
    }

    private static func token(_ outcome: PlanApprovalOutcome) -> String {
        switch outcome {
        case .approved: return "approved"
        case .declined: return "declined"
        case .busy: return "busy"
        case .consentWithdrawn: return "consentWithdrawn"
        case .unavailable: return "unavailable"
        }
    }

    private func planHeader(_ plan: AgentPlan) -> String {
        "Planning \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")"
    }

    /// Deterministic, natural-ish spoken summary built from the step rationales + outcome — no
    /// extra model round-trip.
    static func summary(plan: AgentPlan, run: PlanRunResult) -> String {
        let done = plan.steps.prefix(run.completedSteps)
            .map { $0.rationale.isEmpty ? $0.tool : $0.rationale }
        if run.aborted {
            let didPart = done.isEmpty ? "I couldn't get started" : "I \(joinClauses(done))"
            let reason = run.abortReason ?? "a step didn't complete"
            return "\(didPart), then stopped — \(reason)."
        }
        if done.isEmpty { return "There was nothing to do for that." }
        return "Done — I \(joinClauses(done))."
    }

    /// "a, b and c" from a list of short clauses.
    private static func joinClauses(_ items: some Collection<String>) -> String {
        let parts = Array(items)
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
