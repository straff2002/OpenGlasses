import Foundation

/// The one spoken sentence a plan opens with (Plan LP §2). Pure.
///
/// Before this the wearer heard nothing until "Still working on that." ten seconds in; the plan
/// header and "Step i of N" only ever reached the lens, and still do.
enum PlanOpener {

    /// The opener for `plan`, or nil when none is said:
    /// - a plan of one step (its own reply is the whole story),
    /// - a plan that is asking first (the ask is the opener — never both),
    /// - Quiet after actions is on and every step is an action that setting would end quietly.
    static func sentence(for plan: AgentPlan, request: String, asking: Bool,
                         quietEndsEveryStep: Bool) -> String? {
        guard plan.steps.count >= 2, !asking, !quietEndsEveryStep else { return nil }
        let rationales = plan.steps.map { PlanApprovalPhraser.clause($0.rationale) }
        if plan.steps.count <= 3, rationales.allSatisfy({ !$0.isEmpty }) {
            return "I'll \(PlanApprovalPhraser.joinClauses(rationales))."
        }
        if let goal = speakableGoal(plan.goal, request: request) {
            return "I'll \(goal)."
        }
        return "I'll work through this in \(plan.steps.count) steps."
    }

    /// The planner's short restatement, when it gave one. The planner falls back to the request
    /// itself, which is the wearer's words back at them, so that is not used; nor is a long one.
    static func speakableGoal(_ goal: String, request: String) -> String? {
        let trimmed = PlanApprovalPhraser.clause(goal)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != PlanApprovalPhraser.clause(request).lowercased(),
              trimmed.split(separator: " ").count <= 15 else { return nil }
        return trimmed
    }
}

/// What has been said for the plan running in this task (Plan LP §2): once the opener or the ask
/// is spoken, it stands in for the router's first "Still working on that." for the turn.
@MainActor
final class PlanTurnNarration {
    private(set) var absorbedStillWorking = false

    /// True the first time it is asked: that "still working" line is not said.
    func absorbsStillWorking() -> Bool {
        guard !absorbedStillWorking else { return false }
        absorbedStillWorking = true
        return true
    }
}

enum PlanNarrationScope {
    /// Set by `AgentRunner` around a plan's execution when it has spoken first. The router's
    /// still-working timer runs in a task created inside the step's dispatch, so it inherits this.
    @TaskLocal static var current: PlanTurnNarration?
}
