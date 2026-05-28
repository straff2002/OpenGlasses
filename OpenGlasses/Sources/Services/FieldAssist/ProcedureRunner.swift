import Foundation

/// Drives a single active `Procedure` through its branching step graph.
///
/// The runner enforces the graph; the AI decides *which* branch to take by passing a branch
/// `choice` to `advance`. All transitions are written to the session's append-only JSONL log via
/// `SessionLogger`, so the procedure's position survives pause/resume and app relaunch.
///
/// Crash recovery: each `procedureStep` event carries the full visited-stack snapshot, so the
/// runner can be rebuilt from the last step event without replaying every transition.
///
/// Owned by `FieldSessionService` (`@MainActor`).
@MainActor
final class ProcedureRunner {
    let procedure: Procedure
    private let logger: SessionLogger

    /// Step ids in the order they were entered, current step last. Acts as the back-stack.
    private(set) var visited: [String]

    var currentStepId: String { visited.last ?? procedure.entry?.id ?? "" }
    var currentStep: Procedure.Step? { procedure.step(id: currentStepId) }

    enum RunnerError: LocalizedError {
        case emptyProcedure
        case unknownStep(String)
        case noNextStep
        case atStart

        var errorDescription: String? {
            switch self {
            case .emptyProcedure: return "Procedure has no steps."
            case .unknownStep(let id): return "Procedure step '\(id)' not found."
            case .noNextStep: return "This step has no next step. Resolve a branch or complete the procedure."
            case .atStart: return "Already at the first step."
            }
        }
    }

    /// The result of advancing or stepping back.
    enum Transition {
        case moved(Procedure.Step)
        case completed(outcome: String)
    }

    /// Start a fresh procedure: logs `procedureStarted`, enters the entry step.
    init(starting procedure: Procedure, logger: SessionLogger) throws {
        guard let entry = procedure.entry else { throw RunnerError.emptyProcedure }
        self.procedure = procedure
        self.logger = logger
        self.visited = [entry.id]
        logger.append(.init(timestamp: Date(), kind: .procedureStarted, text: procedure.title, payload: [
            "procedure_id": AnyCodable(procedure.id),
            "version": AnyCodable(procedure.version),
            "entry_step": AnyCodable(entry.id)
        ]))
        logStep(entry.id, branchTaken: nil)
    }

    /// Rebuild a runner from a recovered position (no logging — the log already records it).
    init(restoring procedure: Procedure, visited: [String], logger: SessionLogger) {
        self.procedure = procedure
        self.logger = logger
        self.visited = visited.isEmpty ? (procedure.entry.map { [$0.id] } ?? []) : visited
    }

    // MARK: - Navigation

    /// Advance from the current step. Pass a branch `choice` to take a specific branch; omit it to
    /// follow `default_next`. Reaching a terminal step completes the procedure.
    @discardableResult
    func advance(choice: String?) throws -> Transition {
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        if step.terminal { return complete(outcome: step.outcome ?? "resolved") }

        let targetId: String?
        var branchTaken: String?
        if let choice, let branch = step.branches.first(where: { $0.id == choice }) {
            targetId = branch.next
            branchTaken = branch.id
        } else if choice != nil, let only = step.branches.first, step.branches.count == 1 {
            // Tolerate a stray choice when the step is effectively linear.
            targetId = only.next
            branchTaken = only.id
        } else {
            targetId = step.defaultNext
        }

        guard let targetId else { throw RunnerError.noNextStep }
        guard let target = procedure.step(id: targetId) else { throw RunnerError.unknownStep(targetId) }

        visited.append(target.id)
        logStep(target.id, branchTaken: branchTaken)

        if target.terminal { return complete(outcome: target.outcome ?? "resolved") }
        return .moved(target)
    }

    /// Step back to the previously visited step.
    @discardableResult
    func goBack() throws -> Procedure.Step {
        guard visited.count > 1 else { throw RunnerError.atStart }
        visited.removeLast()
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        logStep(step.id, branchTaken: "back")
        return step
    }

    /// Re-present the current step without changing position.
    func repeatStep() throws -> Procedure.Step {
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        return step
    }

    /// Explicitly complete the procedure with an outcome.
    @discardableResult
    func complete(outcome: String) -> Transition {
        logger.append(.init(timestamp: Date(), kind: .procedureCompleted, text: procedure.title, payload: [
            "procedure_id": AnyCodable(procedure.id),
            "outcome": AnyCodable(outcome),
            "steps_completed": AnyCodable(visited.count)
        ]))
        return .completed(outcome: outcome)
    }

    // MARK: - Prompt context

    /// System-prompt addendum describing the active step and the branches the AI can take.
    /// Appended to `FieldSessionService.promptContext()` so both LLMService and GeminiLive see it.
    func promptContext() -> String {
        guard let step = currentStep else { return "" }
        var lines: [String] = []
        let position = "step \(visited.count)"
        lines.append("ACTIVE PROCEDURE — \(procedure.title) (\(position), step id: \(step.id)):")
        if let note = step.safetyNote {
            lines.append("SAFETY: \(note)")
        }
        lines.append("Step: \(step.title)")
        lines.append("Instruction to give the technician: \(step.instruction)")
        if let expected = step.expectedInput {
            lines.append("Expected observation from technician: \(expected)")
        }
        if let calc = step.calcRef {
            lines.append("Calculation aid: call the \(calc.tool) tool (op: \(calc.op)).\(calc.hint.map { " " + $0 } ?? "")")
        }
        if !step.citations.isEmpty {
            lines.append("Cite: \(step.citations.joined(separator: ", "))")
        }
        if step.terminal {
            lines.append("This is a terminal step. Call procedure_runner with action 'complete' (outcome: \(step.outcome ?? "resolved")).")
        } else if step.branches.isEmpty {
            lines.append("To continue, call procedure_runner action 'next' (no choice needed).")
        } else {
            lines.append("Based on the technician's observation, advance by calling procedure_runner action 'next' with one of these choices:")
            for branch in step.branches {
                lines.append("- choice \"\(branch.id)\": \(branch.condition)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func logStep(_ stepId: String, branchTaken: String?) {
        var payload: [String: AnyCodable] = [
            "procedure_id": AnyCodable(procedure.id),
            "step_id": AnyCodable(stepId),
            "stack": AnyCodable(visited)
        ]
        if let branchTaken { payload["branch_taken"] = AnyCodable(branchTaken) }
        logger.append(.init(timestamp: Date(), kind: .procedureStep, text: procedure.step(id: stepId)?.title, payload: payload))
    }
}
