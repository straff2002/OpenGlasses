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

    /// Plan MN §3: the answer recorded on each step, by step id. Only the steps on the path taken
    /// (`visited`) count for rules and the record; stepping back drops the step left.
    private(set) var answers: [String: RecordedProcedureAnswer]
    /// A spoken critical answer read back and waiting for the person to confirm it (decision 4).
    /// Nothing is recorded, and nothing decides, until they do.
    private(set) var pendingReadBack: PendingReadBack?
    /// When this run started, for the record (`CaptureRecord.startedAt`).
    let startedAt: Date
    /// When the current step was entered: a photo answer collects the job photos taken since.
    private(set) var stepEnteredAt: Date

    var currentStepId: String { visited.last ?? procedure.entry?.id ?? "" }
    var currentStep: Procedure.Step? { procedure.step(id: currentStepId) }

    enum RunnerError: LocalizedError {
        case emptyProcedure
        case unknownStep(String)
        case noNextStep
        case atStart
        /// The last step asks for a check the technician has not confirmed (Plan GB P3).
        case awaitingConfirmation(String)
        /// Plan MN §3: the step needs its answer before it can go on.
        case answerRequired(String)
        /// A spoken critical answer was read back and is waiting for the person's confirmation.
        case awaitingReadBack(String)
        /// An out-of-spec critical answer needs a corrective note before the run goes on.
        case correctiveNoteRequired(String)
        /// The rule decides this step's route, and the choice passed disagrees with it.
        case ruleDecides(String)
        /// No rule holds and there is no default: the person chooses, the assistant never does.
        case noRuleMatched(String)
        /// An override names no reason.
        case overrideNeedsReason
        /// An override on a step whose route no rule decides.
        case notRuleDecided
        /// An override names a branch the step doesn't have.
        case unknownBranch(String)

        var errorDescription: String? {
            switch self {
            case .emptyProcedure: return "Procedure has no steps."
            case .unknownStep(let id): return "Procedure step '\(id)' not found."
            case .noNextStep: return "This step has no next step. Resolve a branch or complete the procedure."
            case .atStart: return "Already at the first step."
            case .awaitingConfirmation(let instruction):
                return "This is the final step and it needs the technician's confirmation: \(instruction) "
                    + "\(VerificationRequirement.notYetVerified)"
            case .answerRequired(let line), .awaitingReadBack(let line), .correctiveNoteRequired(let line),
                 .ruleDecides(let line), .noRuleMatched(let line):
                return line
            case .overrideNeedsReason:
                return "An override needs the technician's reason, in their words."
            case .notRuleDecided:
                return "This step's route isn't decided by a rule; choose a branch with 'next' instead."
            case .unknownBranch(let id):
                return "This step has no branch '\(id)'."
            }
        }
    }

    /// The result of advancing or stepping back.
    enum Transition {
        case moved(Procedure.Step)
        /// The procedure has reached its last step. Nothing is complete yet: the step's instruction
        /// is what the technician does next, and the procedure completes on an explicit
        /// `complete` (Plan GB P3). It used to complete on *entering* the step, which is how job
        /// 1011 was resolved before its retest.
        case arrivedAtTerminal(Procedure.Step)
        case completed(outcome: String)
    }

    /// Start a fresh procedure: logs `procedureStarted`, enters the entry step.
    init(starting procedure: Procedure, logger: SessionLogger) throws {
        guard let entry = procedure.entry else { throw RunnerError.emptyProcedure }
        self.procedure = procedure
        self.logger = logger
        self.visited = [entry.id]
        self.answers = [:]
        let now = Date()
        self.startedAt = now
        self.stepEnteredAt = now
        logger.append(.init(timestamp: Date(), kind: .procedureStarted, text: procedure.title, payload: [
            "procedure_id": AnyCodable(procedure.id),
            "version": AnyCodable(procedure.version),
            "entry_step": AnyCodable(entry.id)
        ]))
        logStep(entry.id, branchTaken: nil, from: nil, decision: nil)
    }

    /// Rebuild a runner from a recovered position (no logging — the log already records it).
    /// `answers` are the ones the log carries for steps already left (Plan MN §5).
    init(restoring procedure: Procedure, visited: [String], logger: SessionLogger,
         answers: [String: RecordedProcedureAnswer] = [:], startedAt: Date = Date()) {
        self.procedure = procedure
        self.logger = logger
        self.visited = visited.isEmpty ? (procedure.entry.map { [$0.id] } ?? []) : visited
        self.answers = answers
        self.startedAt = startedAt
        self.stepEnteredAt = Date()
    }

    // MARK: - Navigation

    /// Advance from the current step. Pass a branch `choice` to take a specific branch; omit it to
    /// follow `default_next`. Reaching a terminal step completes the procedure.
    ///
    /// On a step the app decides (Plan MN §3) the rules choose: a `choice` is accepted only when it
    /// is the branch the rules give, and refused with the reason otherwise. `by` is who is asking —
    /// the assistant through the tool, or the person on the phone or the lens — and is what the
    /// record says decided a route chosen from words, or chosen when no rule held.
    @discardableResult
    func advance(choice: String?, by decider: ProcedureDecider = .assistant) throws -> Transition {
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        try requireAnswerReady(step)
        if step.terminal {
            // "Next" on the last step is finishing it — unless it asks for a confirmation, which
            // only an explicit `complete` carries.
            if step.needsConfirmation { throw RunnerError.awaitingConfirmation(step.instruction) }
            return complete(outcome: step.outcome ?? "resolved")
        }
        if step.isAppDecided { return try advanceByRule(step, choice: choice, by: decider) }

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
        let decision = branchTaken.map { _ in LoggedDecision(decidedBy: decider) }
        return try move(to: targetId, branchTaken: branchTaken, from: step, decision: decision)
    }

    /// A step whose every branch has a rule: the rules decide (Plan MN §2–§3).
    private func advanceByRule(_ step: Procedure.Step, choice: String?, by decider: ProcedureDecider) throws -> Transition {
        let chosen = choice.flatMap { id in step.branches.first { $0.id == id } }
        switch BranchRuleEvaluator.decide(step, answers: pathAnswers) {
        case .branch(let branch, let ruleText):
            if let chosen, chosen.id != branch.id {
                throw RunnerError.ruleDecides(Self.ruleDecidesLine(ruleText, next: title(of: branch.next)))
            }
            return try move(to: branch.next, branchTaken: branch.id, from: step,
                            decision: LoggedDecision(decidedBy: .rule, ruleText: ruleText))
        case .defaultNext(let next, let ruleText):
            if chosen != nil {
                throw RunnerError.ruleDecides(Self.ruleDecidesLine(ruleText, next: title(of: next)))
            }
            return try move(to: next, branchTaken: nil, from: step,
                            decision: LoggedDecision(decidedBy: .rule, ruleText: ruleText))
        case .noRuleMatched(let reason):
            // It never guesses: the person chooses, and the record says no rule matched. The
            // assistant may not choose for them.
            guard let chosen, decider != .assistant else {
                throw RunnerError.noRuleMatched(Self.noRuleLine(reason, step: step, assistant: decider == .assistant))
            }
            return try move(to: chosen.next, branchTaken: chosen.id, from: step,
                            decision: LoggedDecision(decidedBy: .person, ruleText: reason,
                                                     reason: Self.noRuleMatchedReason))
        }
    }

    /// "The reading decides: pH 4.60 is above 4.4, so the next step is Adjust acid."
    static func ruleDecidesLine(_ ruleText: String, next: String) -> String {
        "The reading decides: \(ruleText), so the next step is \(next). Only the technician can take "
            + "another route, with an override and their reason."
    }

    /// The reason recorded when the person chose because no rule held.
    static let noRuleMatchedReason = "no rule matched"

    private static func noRuleLine(_ reason: String, step: Procedure.Step, assistant: Bool) -> String {
        let routes = step.branches.map { "'\($0.id)' (\($0.condition))" }.joined(separator: ", ")
        let who = assistant
            ? "Ask the technician which route to take: \(routes). Their choice is taken with 'override', "
                + "their words as the reason; don't choose for them."
            : "Choose the route: \(routes)."
        return "\(reason). \(who)"
    }

    /// The person takes a different route from the rule's (Plan MN §3, decision 3), with a reason
    /// that is non-empty after trimming. Recorded as `decided_by: override` with the branch the
    /// rule gave and the reason. The assistant calls this only on the person's spoken instruction,
    /// and `ToolAuthorizationPolicy` asks the person to confirm it.
    @discardableResult
    func override(branch branchId: String, reason: String) throws -> Transition {
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        guard step.isAppDecided else { throw RunnerError.notRuleDecided }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw RunnerError.overrideNeedsReason }
        guard let branch = step.branches.first(where: { $0.id == branchId }) else {
            throw RunnerError.unknownBranch(branchId)
        }
        // A missing answer is what an override may be for (the meter is broken); an unconfirmed
        // read-back and an owed corrective note are not.
        if let pending = pendingReadBack, pending.stepId == step.id { throw RunnerError.awaitingReadBack(pending.prompt) }
        if let recorded = answers[step.id], recorded.needsCorrectiveNote {
            throw RunnerError.correctiveNoteRequired(Self.notePrompt(recorded))
        }
        let decision: LoggedDecision
        switch BranchRuleEvaluator.decide(step, answers: pathAnswers) {
        case .branch(let ruled, let ruleText) where ruled.id == branch.id:
            decision = LoggedDecision(decidedBy: .rule, ruleText: ruleText)
        case .branch(let ruled, let ruleText):
            decision = LoggedDecision(decidedBy: .override, ruleText: ruleText, ruleBranch: ruled.id, reason: reason)
        case .defaultNext(let next, let ruleText):
            decision = LoggedDecision(decidedBy: .override, ruleText: ruleText, ruleBranch: "default_next:\(next)", reason: reason)
        case .noRuleMatched(let ruleText):
            decision = LoggedDecision(decidedBy: .person, ruleText: ruleText, reason: reason)
        }
        return try move(to: branch.next, branchTaken: branch.id, from: step, decision: decision)
    }

    private func move(to targetId: String, branchTaken: String?, from step: Procedure.Step,
                      decision: LoggedDecision?) throws -> Transition {
        guard let target = procedure.step(id: targetId) else { throw RunnerError.unknownStep(targetId) }
        visited.append(target.id)
        stepEnteredAt = Date()
        if pendingReadBack?.stepId == step.id { pendingReadBack = nil }
        logStep(target.id, branchTaken: branchTaken, from: step, decision: decision)
        // Entering a step again (a retest loop) asks for a fresh answer; the earlier one is on the
        // record already, carried by the transition out of it.
        answers[target.id] = nil
        if target.terminal { return .arrivedAtTerminal(target) }
        return .moved(target)
    }

    private func title(of stepId: String) -> String { procedure.step(id: stepId)?.title ?? stepId }

    /// The step's answer is in: given when required, confirmed when read back, and noted when a
    /// critical one is out of spec.
    private func requireAnswerReady(_ step: Procedure.Step) throws {
        guard let answer = step.answer else { return }
        if let pending = pendingReadBack, pending.stepId == step.id { throw RunnerError.awaitingReadBack(pending.prompt) }
        guard let recorded = answers[step.id] else {
            if answer.isRequired && answer.kind != nil {
                throw RunnerError.answerRequired("This step needs the \(answer.displayLabel) before it can go on. "
                                                 + AnswerReader.prompt(for: answer))
            }
            return
        }
        if recorded.needsCorrectiveNote { throw RunnerError.correctiveNoteRequired(Self.notePrompt(recorded)) }
    }

    // MARK: - Answers (Plan MN §3)

    /// What answering produced.
    enum AnswerResult: Equatable {
        /// Recorded. The route follows on `next`.
        case recorded(RecordedProcedureAnswer)
        /// Not read, or not plausible: nothing is recorded; ask again with this line.
        case askAgain(String)
        /// A spoken critical answer, read back: nothing is recorded until `confirmReadBack(true)`.
        case readBack(String)
        /// Recorded, out of spec and critical: a corrective note is owed before the run goes on.
        case needsNote(String)
        /// The current step takes no answer, or nothing is waiting.
        case notAccepted(String)
    }

    /// The answer on the current step, when one is recorded.
    var currentAnswer: RecordedProcedureAnswer? { answers[currentStepId] }

    /// Whether the current step's critical answer is out of spec with no corrective note yet.
    var awaitingCorrectiveNote: Bool { currentAnswer?.needsCorrectiveNote == true }

    /// Give the current step's answer. `raw` is what was typed, said or scanned (photo ids joined
    /// by commas for a photo answer); `note` is a corrective note given with it. A spoken critical
    /// answer is read back first (decision 4); a typed one is already on the screen.
    func answer(_ raw: String, method: ProcedureAnswerMethod = .typed, note: String? = nil,
                locale: Locale = .current) -> AnswerResult {
        guard let step = currentStep, let definition = step.answer, definition.kind != nil else {
            return .notAccepted("This step doesn't take an answer.")
        }
        switch AnswerReader.read(raw, for: definition, locale: locale) {
        case .askAgain(let line):
            return .askAgain(line)
        case .accepted(let value):
            let note = Self.cleaned(note)
            if definition.isCritical && method == .spoken {
                let pending = PendingReadBack(stepId: step.id, value: value, method: method, note: note,
                                              prompt: Self.readBackPrompt(definition, value))
                pendingReadBack = pending
                return .readBack(pending.prompt)
            }
            return commit(step: step, definition: definition, value: value, method: method, note: note)
        }
    }

    /// The person answered the read-back: true records the value, false drops it and asks again.
    func confirmReadBack(_ correct: Bool) -> AnswerResult {
        guard let pending = pendingReadBack, pending.stepId == currentStepId,
              let step = currentStep, let definition = step.answer else {
            return .notAccepted("No answer is waiting to be confirmed.")
        }
        pendingReadBack = nil
        guard correct else { return .askAgain("Read the \(definition.displayLabel) again. \(AnswerReader.prompt(for: definition))") }
        return commit(step: step, definition: definition, value: pending.value, method: pending.method, note: pending.note)
    }

    /// Add the corrective note an out-of-spec critical answer needs (decision 7), or replace one.
    func addCorrectiveNote(_ note: String) -> AnswerResult {
        guard var recorded = currentAnswer else { return .notAccepted("This step has no answer to note yet.") }
        guard let note = Self.cleaned(note) else {
            return .askAgain("The note can't be empty: say what was done about it.")
        }
        recorded.note = note
        answers[recorded.stepId] = recorded
        return .recorded(recorded)
    }

    private func commit(step: Procedure.Step, definition: StepAnswer, value: ProcedureAnswerValue,
                        method: ProcedureAnswerMethod, note: String?) -> AnswerResult {
        let recorded = RecordedProcedureAnswer(stepId: step.id, answer: definition, value: value,
                                               method: method, at: Date(), note: note)
        answers[step.id] = recorded
        return recorded.needsCorrectiveNote ? .needsNote(Self.notePrompt(recorded)) : .recorded(recorded)
    }

    private static func cleaned(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "pH 4.60, out of spec, is that right?"
    nonisolated static func readBackPrompt(_ answer: StepAnswer, _ value: ProcedureAnswerValue) -> String {
        let spec: String
        switch value.specStatus {
        case .out?: spec = ", out of spec"
        case .in?: spec = ", in spec"
        case nil: spec = ""
        }
        return "\(answer.displayLabel) \(value.display(for: answer))\(spec), is that right?"
    }

    /// "CO2 2.90 is out of spec (2.4 to 2.8). Before going on, add a corrective note: what was done about it?"
    nonisolated static func notePrompt(_ recorded: RecordedProcedureAnswer) -> String {
        let spec = recorded.answer.specText.map { " (\($0))" } ?? ""
        return "\(recorded.answer.displayLabel) \(recorded.value.display(for: recorded.answer)) is out of spec\(spec). "
            + "Before going on, add a corrective note: what was done about it?"
    }

    /// The answers on the path taken, by `record_as`, for the rules (§2).
    var pathAnswers: [String: KnownAnswer] {
        var known: [String: KnownAnswer] = [:]
        for stepId in visited {
            guard let recorded = answers[stepId] else { continue }
            known[recorded.answer.recordAs] = KnownAnswer(answer: recorded.answer, value: recorded.value)
        }
        return known
    }

    /// The route the rules give right now, for a step the app decides; nil otherwise.
    var ruleDecision: BranchRuleEvaluator.Decision? {
        guard let step = currentStep, step.isAppDecided else { return nil }
        return BranchRuleEvaluator.decide(step, answers: pathAnswers)
    }

    /// The run's answers as one Plan U `CaptureRecord` (§5): flow id `procedure:<id>@<version>`,
    /// one field per answer on the path. Nil when nothing was answered.
    func captureRecord(sessionId: String, assetId: String? = nil, finishedAt: Date = Date()) -> CaptureRecord? {
        var record = CaptureRecord(flowId: Self.flowId(procedure), sessionId: sessionId, assetId: assetId,
                                   startedAt: startedAt)
        var seen = Set<String>()
        for stepId in visited where seen.insert(stepId).inserted {
            guard let recorded = answers[stepId] else { continue }
            record.fields.removeAll { $0.field == recorded.answer.recordAs }
            record.fields.append(recorded.capturedField)
        }
        guard !record.fields.isEmpty else { return nil }
        record.finishedAt = finishedAt
        return record
    }

    /// `procedure:<id>@<version>`.
    nonisolated static func flowId(_ procedure: Procedure) -> String { "procedure:\(procedure.id)@\(procedure.version)" }

    /// Step back to the previously visited step.
    @discardableResult
    func goBack() throws -> Procedure.Step {
        guard visited.count > 1 else { throw RunnerError.atStart }
        let left = visited.removeLast()
        // The step left is no longer on the path: its answer and any read-back go with it,
        // unless the path still passes through it (a retest loop).
        if !visited.contains(left) { answers[left] = nil }
        if pendingReadBack?.stepId == left { pendingReadBack = nil }
        stepEnteredAt = Date()
        guard let step = currentStep else { throw RunnerError.unknownStep(currentStepId) }
        logStep(step.id, branchTaken: "back", from: nil, decision: nil)
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
        var payload: [String: AnyCodable] = [
            "procedure_id": AnyCodable(procedure.id),
            "outcome": AnyCodable(outcome),
            "steps_completed": AnyCodable(visited.count)
        ]
        // The last step's own answer (a sign-off, say) has no transition out of it to ride.
        if let step = currentStep, let recorded = answers[step.id] {
            payload["step_id"] = AnyCodable(step.id)
            payload["step_title"] = AnyCodable(step.title)
            payload["answer"] = AnyCodable(recorded.logPayload)
        }
        logger.append(.init(timestamp: Date(), kind: .procedureCompleted, text: procedure.title, payload: payload))
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
        if let coaching = procedure.coaching {
            // An expert's coaching (Plan KM P3): the rule first, then the step exactly as written.
            lines.append(CoachingProcedure.readAsWrittenRule(credit: coaching.credit))
            lines.append(contentsOf: CoachingProcedure.stepLines(step))
        } else {
            if let note = step.safetyNote {
                lines.append("SAFETY: \(note)")
            }
            lines.append("Step: \(step.title)")
            lines.append("Instruction to give the technician: \(step.instruction)")
            if let expected = step.expectedInput {
                lines.append("Expected observation from technician: \(expected)")
            }
        }
        if let calc = step.calcRef {
            lines.append("Calculation aid: call the \(calc.tool) tool (op: \(calc.op)).\(calc.hint.map { " " + $0 } ?? "")")
        }
        if !step.citations.isEmpty {
            lines.append("Cite: \(step.citations.joined(separator: ", "))")
        }
        lines.append(contentsOf: answerGuidance())
        if step.needsConfirmation {
            lines.append("This is the final step. Give the technician the instruction above. It is not "
                         + "resolved until they confirm the check passed: then call procedure_runner "
                         + "'complete' with confirmed true. \(VerificationRequirement.notYetVerified)")
        } else if step.terminal {
            lines.append("This is a terminal step. Call procedure_runner with action 'complete' (outcome: \(step.outcome ?? "resolved")).")
        } else if step.branches.isEmpty {
            lines.append("To continue, call procedure_runner action 'next' (no choice needed).")
        } else if step.isAppDecided {
            lines.append(contentsOf: ruleRouteGuidance(step))
        } else {
            lines.append("Based on the technician's observation, advance by calling procedure_runner action 'next' with one of these choices:")
            for branch in step.branches {
                lines.append("- choice \"\(branch.id)\": \(branch.condition)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Plan MN §3: what the model is told about the current step's answer — its kind, label and
    /// unit, that it calls `answer` with the value it heard, and where a read-back or a corrective
    /// note is waiting. Empty for a step with no answer. The tool's step text uses the same lines.
    func answerGuidance() -> [String] {
        guard let step = currentStep, let answer = step.answer, let kind = answer.kind else { return [] }
        var lines: [String] = []
        let unit = answer.unit.map { ", in \($0)" } ?? ""
        let what: String
        switch kind {
        case .number: what = "a number, the \(answer.displayLabel)\(unit)"
        case .choice: what = "one of: \((answer.options ?? []).map(\.label).joined(separator: ", ")), the \(answer.displayLabel)"
        case .yesNo: what = "yes or no, \(answer.displayLabel)"
        case .text: what = "a short text, the \(answer.displayLabel)"
        case .code: what = "a code, the \(answer.displayLabel)"
        case .photo: what = "photos of \(answer.displayLabel)"
        }
        lines.append("This step takes an answer: \(what) (\(answer.isRequired ? "required" : "optional")).")
        if let pending = pendingReadBack, pending.stepId == step.id {
            lines.append("Read this back to the technician and wait: \"\(pending.prompt)\" If they confirm, call "
                         + "procedure_runner 'answer' with confirmed true; if not, call 'answer' with the value they say now.")
        } else if let recorded = answers[step.id] {
            lines.append("Recorded: \(answer.displayLabel) \(recorded.value.display(for: answer))"
                         + (recorded.value.specStatus == .out ? " (out of spec)" : "") + ".")
            if recorded.needsCorrectiveNote {
                lines.append("It is critical and out of spec: ask the technician what was done about it, and call "
                             + "procedure_runner 'answer' with note set to their words. The run can't go on without it.")
            }
        } else if kind == .photo {
            lines.append("Once the photos are taken, call procedure_runner action 'answer' (no value): the photos taken on this step are attached.")
        } else {
            lines.append("When the technician gives it, call procedure_runner action 'answer' with value set to exactly what they said. "
                         + "Don't round, convert or judge it; the app reads and checks it.")
        }
        return lines
    }

    /// The route lines for a step the app decides: the branches are listed for reference only.
    private func ruleRouteGuidance(_ step: Procedure.Step) -> [String] {
        var lines = ["The route follows from the answer: the app decides it, and you don't choose it. "
                     + "Once the answer is recorded, call procedure_runner action 'next' with no choice."]
        lines.append("Routes (for reference):")
        for branch in step.branches { lines.append("- \(branch.id): \(branch.condition)") }
        lines.append("Only if the technician explicitly tells you to take another route, call procedure_runner "
                     + "'override' with that branch and their own words as the reason; they confirm it.")
        return lines
    }

    // MARK: - Helpers

    /// The record of one transition: who decided it and, for a rule, the rule in words (§5).
    struct LoggedDecision {
        let decidedBy: ProcedureDecider
        var ruleText: String? = nil
        /// For an override: the branch the rule gave.
        var ruleBranch: String? = nil
        var reason: String? = nil
    }

    private func logStep(_ stepId: String, branchTaken: String?, from: Procedure.Step?, decision: LoggedDecision?) {
        var payload: [String: AnyCodable] = [
            "procedure_id": AnyCodable(procedure.id),
            "step_id": AnyCodable(stepId),
            "stack": AnyCodable(visited)
        ]
        if let branchTaken { payload["branch_taken"] = AnyCodable(branchTaken) }
        if let from {
            payload["from_step"] = AnyCodable(from.id)
            payload["from_title"] = AnyCodable(from.title)
            if let recorded = answers[from.id] { payload["answer"] = AnyCodable(recorded.logPayload) }
        }
        if let decision {
            payload["decided_by"] = AnyCodable(decision.decidedBy.rawValue)
            if let ruleText = decision.ruleText { payload["rule_text"] = AnyCodable(ruleText) }
            if let ruleBranch = decision.ruleBranch { payload["rule_branch"] = AnyCodable(ruleBranch) }
            if let reason = decision.reason { payload["reason"] = AnyCodable(reason) }
        }
        logger.append(.init(timestamp: Date(), kind: .procedureStep, text: procedure.step(id: stepId)?.title, payload: payload))
    }

    /// The answers a log carries for `procedure`, by step id, for a runner rebuilt after a
    /// relaunch (§5). A later answer on the same step replaces an earlier one.
    nonisolated static func restoredAnswers(from events: [SessionLogger.Event],
                                            procedure: Procedure) -> [String: RecordedProcedureAnswer] {
        var restored: [String: RecordedProcedureAnswer] = [:]
        for event in events where [.procedureStarted, .procedureStep, .procedureCompleted].contains(event.kind) {
            guard event.payload?["procedure_id"]?.value as? String == procedure.id else { continue }
            // A run that started again, or finished, carries nothing forward.
            if event.kind != .procedureStep { restored = [:]; continue }
            guard let payload = event.payload?["answer"]?.value as? [String: Any],
                  let stepId = payload["step_id"] as? String,
                  let definition = procedure.step(id: stepId)?.answer,
                  let recorded = RecordedProcedureAnswer(logPayload: payload, answer: definition, at: event.timestamp)
            else { continue }
            restored[stepId] = recorded
        }
        return restored
    }
}

/// Who decided a procedure route (Plan MN §5): the rule, the person, the assistant, or the person
/// overriding the rule with a reason.
enum ProcedureDecider: String, Codable {
    case rule, person, assistant, override
}

/// A spoken critical answer waiting for the person to confirm the read-back (decision 4).
struct PendingReadBack: Equatable {
    let stepId: String
    let value: ProcedureAnswerValue
    let method: ProcedureAnswerMethod
    let note: String?
    /// "pH 4.60, out of spec, is that right?"
    let prompt: String
}

/// One answer recorded on a procedure step (Plan MN §3, §5).
struct RecordedProcedureAnswer: Equatable {
    let stepId: String
    let answer: StepAnswer
    let value: ProcedureAnswerValue
    let method: ProcedureAnswerMethod
    let at: Date
    /// The corrective note (decision 7), trimmed and non-empty when present.
    var note: String?

    /// A critical answer out of spec with no corrective note yet: the run can't go on.
    var needsCorrectiveNote: Bool { answer.isCritical && value.specStatus == .out && note == nil }

    /// The answer as the `procedureStep` event carries it, so the export and a rebuilt runner can
    /// read it back without a second log.
    var logPayload: [String: Any] {
        var payload: [String: Any] = [
            "step_id": stepId,
            "record_as": answer.recordAs,
            "kind": answer.kindName,
            "label": answer.displayLabel,
            "value": value.valueText(for: answer),
            "display": value.display(for: answer),
            "entered": value.entered,
            "method": method.rawValue,
        ]
        if let unit = answer.unit { payload["unit"] = unit }
        if let status = value.specStatus { payload["spec_status"] = status.rawValue }
        if let spec = answer.specText { payload["spec"] = spec }
        if let note { payload["note"] = note }
        if !value.photoIds.isEmpty { payload["photo_ids"] = value.photoIds }
        if answer.isCritical { payload["critical"] = true }
        return payload
    }

    init(stepId: String, answer: StepAnswer, value: ProcedureAnswerValue,
         method: ProcedureAnswerMethod, at: Date, note: String? = nil) {
        self.stepId = stepId
        self.answer = answer
        self.value = value
        self.method = method
        self.at = at
        self.note = note
    }

    /// Read back from `logPayload`. Nil when the payload does not fit the step's answer.
    init?(logPayload payload: [String: Any], answer: StepAnswer, at: Date) {
        guard let stepId = payload["step_id"] as? String, let kind = answer.kind,
              let text = payload["value"] as? String,
              let method = (payload["method"] as? String).flatMap(ProcedureAnswerMethod.init(rawValue:)) else { return nil }
        let entered = payload["entered"] as? String ?? text
        let status = (payload["spec_status"] as? String).flatMap(SpecStatus.init(rawValue:))
        let value: ProcedureAnswerValue
        switch kind {
        case .number:
            guard let number = ExactDecimal.parse(text) else { return nil }
            value = ProcedureAnswerValue(kind: kind, entered: entered, number: number, specStatus: status)
        case .choice, .yesNo:
            value = ProcedureAnswerValue(kind: kind, entered: entered, option: text)
        case .text, .code:
            value = ProcedureAnswerValue(kind: kind, entered: entered, text: text, specStatus: status)
        case .photo:
            let ids = (payload["photo_ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            value = ProcedureAnswerValue(kind: kind, entered: entered, photoIds: ids)
        }
        self.init(stepId: stepId, answer: answer, value: value, method: method, at: at,
                  note: payload["note"] as? String)
    }

    /// The answer as one field of the run's `CaptureRecord` (§5).
    var capturedField: CapturedField {
        let captured: CaptureValue
        switch value.kind {
        case .number:
            captured = CaptureValue(kind: "number", string: value.valueText(for: answer),
                                    number: value.number.map { NSDecimalNumber(decimal: $0).doubleValue },
                                    unit: answer.unit)
        case .choice, .yesNo: captured = .option(value.option ?? value.entered)
        case .text: captured = .text(value.text ?? value.entered)
        case .code: captured = .code(value.text ?? value.entered)
        case .photo: captured = CaptureValue(kind: "photo", string: value.photoIds.joined(separator: ","), number: nil, unit: nil)
        }
        return CapturedField(field: answer.recordAs, value: captured,
                             provenance: Provenance(method: method.rawValue, at: at),
                             entered: value.entered, specStatus: value.specStatus?.rawValue,
                             note: note, stepId: stepId,
                             photoIds: value.photoIds.isEmpty ? nil : value.photoIds)
    }
}
