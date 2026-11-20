import Combine
import XCTest
@testable import OpenGlasses

/// A `ProcedureHosting` over a real `ProcedureRunner`, for the lens and the no-model voice
/// (Plan MN P2). It answers the way `FieldSessionService.answerProcedure` does — a confirmed
/// read-back, a note alone, photos taken on the step — without standing up a vault and a session.
@MainActor
final class ProcedureRunnerHost: ObservableObject, ProcedureHosting {
    private(set) var runner: ProcedureRunner?
    /// Photo ids "taken" on the current step.
    var photoIds: [String] = []
    var finishedOutcome: String?

    init(_ procedure: Procedure, logger: SessionLogger) throws {
        runner = try ProcedureRunner(starting: procedure, logger: logger)
    }

    var activeProcedureStep: Procedure.Step? { runner?.currentStep }
    var activeProcedureTitle: String? { runner?.procedure.title }

    var activeProcedurePresentation: ProcedureStepPresentation? {
        guard let runner else { return nil }
        return ProcedureStepPresentation.make(procedure: runner.procedure, visited: runner.visited,
                                              answers: runner.answers, pendingReadBack: runner.pendingReadBack,
                                              ruleDecision: runner.ruleDecision, photosSinceStep: photoIds.count)
    }

    func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition {
        guard let runner else { throw ProcedureRunner.RunnerError.emptyProcedure }
        objectWillChange.send()
        let transition = try runner.advance(choice: choice, by: .person)
        if case .completed(let outcome) = transition {
            finishedOutcome = outcome
            self.runner = nil
        }
        return transition
    }

    func procedureBack() throws -> Procedure.Step {
        guard let runner else { throw ProcedureRunner.RunnerError.emptyProcedure }
        objectWillChange.send()
        return try runner.goBack()
    }

    func answerProcedure(value: String?, method: ProcedureAnswerMethod, note: String?,
                         confirmed: Bool, locale: Locale) throws -> ProcedureRunner.AnswerResult {
        guard let runner else { throw ProcedureRunner.RunnerError.emptyProcedure }
        objectWillChange.send()
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if confirmed, runner.pendingReadBack != nil, value.isEmpty { return runner.confirmReadBack(true) }
        if value.isEmpty, !note.isEmpty, runner.currentAnswer != nil { return runner.addCorrectiveNote(note) }
        if runner.currentStep?.answer?.kind == .photo, value.isEmpty {
            return runner.answer(photoIds.joined(separator: ","), method: .photo, locale: locale)
        }
        return runner.answer(value, method: method, note: note.isEmpty ? nil : note, locale: locale)
    }

    func confirmProcedureReadBack(_ correct: Bool) throws -> ProcedureRunner.AnswerResult {
        guard let runner else { throw ProcedureRunner.RunnerError.emptyProcedure }
        objectWillChange.send()
        return runner.confirmReadBack(correct)
    }
}
