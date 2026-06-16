import Foundation

/// Outcome of validating a planner's proposed `AgentPlan` before any step runs.
enum PlanValidationResult: Equatable {
    case valid(AgentPlan)          // possibly with irreversible steps flagged for confirmation
    case invalid(reason: String)
}

/// Structural + scope checks on a plan before execution (Plan S). Pure and deterministic — no
/// LLM — so a malformed or over-reaching plan is rejected the same way every time. The validated
/// plan is the executor's single source of truth: tool output never re-enters planning, so an
/// injected instruction in a result can't grow or redirect it past these bounds.
enum PlanValidator {

    static func validate(_ plan: AgentPlan, knownTools: Set<String>, stepBudget: Int) -> PlanValidationResult {
        guard !plan.steps.isEmpty else {
            return .invalid(reason: "the plan has no steps")
        }
        guard plan.steps.count <= stepBudget else {
            return .invalid(reason: "the plan has \(plan.steps.count) steps, over the budget of \(stepBudget)")
        }
        if let unknown = plan.steps.first(where: { !knownTools.contains($0.tool) }) {
            return .invalid(reason: "the plan references an unknown tool '\(unknown.tool)'")
        }

        // Flag every irreversible step so it can't auto-run without an explicit confirmation
        // (the supervisor enforces this at execution; the flag also drives the HUD/spoken trace).
        var steps = plan.steps
        for index in steps.indices where steps[index].reversibility == .irreversible {
            steps[index].requiresConfirmation = true
        }
        return .valid(AgentPlan(goal: plan.goal, steps: steps))
    }
}
