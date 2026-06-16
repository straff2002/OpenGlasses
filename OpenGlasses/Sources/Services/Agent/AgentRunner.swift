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

    /// One-line narration (plan header + each step's rationale) for TTS + the HUD plan-trace.
    var onNarrate: ((String) -> Void)?
    /// Per-step progress (1-based index, total, step) for a "step i of N" HUD trace.
    var onStep: ((Int, Int, AgentStep) -> Void)?
    /// The plan step budget (defaults to the persisted safety setting).
    var stepBudget: () -> Int = { SafetySettings.stepBudget }

    init(router: ToolExecuting, planner: AgentPlanner) {
        self.router = router
        self.planner = planner
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
        let executor = PlanExecutor(router: router)
        // Per-step trace flows through onStep (index + step); onNarrate carries the header only,
        // so the HUD/TTS aren't told the same thing twice.
        executor.onStep = { [weak self] index, total, step in self?.onStep?(index, total, step) }
        let run = await executor.execute(validated)

        return Result(
            summary: Self.summary(plan: validated, run: run),
            completedSteps: run.completedSteps,
            totalSteps: validated.steps.count,
            aborted: run.aborted
        )
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
