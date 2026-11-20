import Foundation

/// What the phone step screen, the lens and the no-model voice show and say about the running
/// procedure's current step (Plan MN §4). Built from the runner's state; pure, so all three read
/// the same facts and a test can build one without a session.
struct ProcedureStepPresentation: Equatable {

    /// "Step 3 of 12" on a procedure that runs straight through, "Step 3" on one that branches.
    struct Position: Equatable {
        let number: Int
        let total: Int?

        var text: String {
            if let total { return String(localized: "Step \(number) of \(total)") }
            return String(localized: "Step \(number)")
        }
    }

    /// One step already done on this run, with what was recorded on it.
    struct TrailEntry: Equatable, Identifiable {
        /// Position in the run, 1-based. Unique within a trail, since a step can be visited twice.
        let id: Int
        let stepId: String
        let title: String
        /// "CO2 2.60 — in spec", "Line clear yes", nil when the step took no answer.
        let answerLine: String?
        let outOfSpec: Bool
        let note: String?
    }

    let procedureId: String
    let procedureTitle: String
    let safetyNotes: [String]
    let step: Procedure.Step
    let position: Position
    /// The answer recorded on this step, when there is one.
    let recorded: RecordedProcedureAnswer?
    /// A spoken critical answer waiting for the person to confirm it.
    let pendingReadBack: PendingReadBack?
    /// The route the rules give now, on a step the app decides.
    let ruleDecision: BranchRuleEvaluator.Decision?
    let trail: [TrailEntry]
    let canGoBack: Bool
    /// Job photos taken since the step was entered — what a photo answer would attach.
    let photosSinceStep: Int

    static func make(procedure: Procedure, visited: [String],
                     answers: [String: RecordedProcedureAnswer],
                     pendingReadBack: PendingReadBack?,
                     ruleDecision: BranchRuleEvaluator.Decision?,
                     photosSinceStep: Int = 0) -> ProcedureStepPresentation? {
        let currentId = visited.last ?? procedure.entry?.id ?? ""
        guard let step = procedure.step(id: currentId) else { return nil }
        let earlier = Array(visited.dropLast())
        var trail: [TrailEntry] = []
        for (index, stepId) in earlier.enumerated() {
            guard let done = procedure.step(id: stepId) else { continue }
            // A step visited twice (a retest loop) carries its answer at its last visit only: the
            // runner keeps one answer per step, the latest.
            let isLastVisit = !earlier[(index + 1)...].contains(stepId)
            let recorded = isLastVisit ? answers[stepId] : nil
            trail.append(TrailEntry(id: index + 1, stepId: stepId, title: done.title,
                                    answerLine: recorded.map(answerLine),
                                    outOfSpec: recorded?.value.specStatus == .out,
                                    note: recorded?.note))
        }
        return ProcedureStepPresentation(
            procedureId: procedure.id, procedureTitle: procedure.title,
            safetyNotes: procedure.safetyNotes, step: step,
            position: position(procedure, visited: visited),
            recorded: answers[step.id], pendingReadBack: pendingReadBack?.stepId == step.id ? pendingReadBack : nil,
            ruleDecision: step.isAppDecided ? ruleDecision : nil,
            trail: trail, canGoBack: visited.count > 1, photosSinceStep: photosSinceStep)
    }

    /// "Step 3 of 12" when the procedure runs straight through from its entry to an end, with no
    /// step offering more than one way on; "Step 3" (the steps taken so far) otherwise.
    static func position(_ procedure: Procedure, visited: [String]) -> Position {
        let number = max(1, visited.count)
        guard let chain = linearChain(procedure),
              let current = visited.last, let index = chain.firstIndex(of: current) else {
            return Position(number: number, total: nil)
        }
        return Position(number: index + 1, total: chain.count)
    }

    /// The step ids from the entry to the end, when the procedure is one straight line; nil when
    /// any step branches or the line loops.
    static func linearChain(_ procedure: Procedure) -> [String]? {
        guard var step = procedure.entry else { return nil }
        var chain: [String] = []
        while true {
            guard !chain.contains(step.id) else { return nil }
            chain.append(step.id)
            if step.terminal { return chain }
            guard step.branches.count <= 1 else { return nil }
            guard let nextId = step.branches.first?.next ?? step.defaultNext else { return chain }
            guard let next = procedure.step(id: nextId) else { return nil }
            step = next
        }
    }

    /// "CO2 2.60 — in spec", "Line clear: yes", "First bottles: 2 photos".
    static func answerLine(_ recorded: RecordedProcedureAnswer) -> String {
        let value = recorded.value.display(for: recorded.answer)
        switch recorded.value.specStatus {
        case .in?: return String(localized: "\(recorded.answer.displayLabel) \(value), in spec")
        case .out?: return String(localized: "\(recorded.answer.displayLabel) \(value), out of spec")
        case nil: return String(localized: "\(recorded.answer.displayLabel): \(value)")
        }
    }

    // MARK: - Facts the screens read

    var answer: StepAnswer? { step.answer?.kind == nil ? nil : step.answer }

    /// The current step's critical answer is out of spec with no corrective note yet.
    var needsCorrectiveNote: Bool { recorded?.needsCorrectiveNote == true }

    /// The step takes an answer and none is recorded or waiting to be confirmed.
    var awaitsAnswer: Bool { answer != nil && recorded == nil && pendingReadBack == nil }

    /// "Recorded: CO2 2.60, in spec" once the step has its answer.
    var recordedLine: String? {
        recorded.map { String(localized: "Recorded: \(Self.answerLine($0))") }
    }

    /// The spec as a hint, when the author wants the person to see it: "Spec 2.4 to 2.8".
    var specHint: String? {
        guard let answer, answer.showSpec == true, let spec = answer.specText else { return nil }
        let unit = answer.unit.map { " \($0)" } ?? ""
        return String(localized: "Spec \(spec)\(unit)")
    }

    /// The reason no rule holds, when the step's rules match none of the answers and there is no
    /// default — the person then chooses from the branches.
    var noRuleMatchedReason: String? {
        guard recorded != nil || answer == nil, case .noRuleMatched(let reason)? = ruleDecision else { return nil }
        return reason
    }

    /// The branches the person picks from now: every branch on a step chosen in words, and on a
    /// step the app decides only when no rule matched. Empty otherwise — the rule decides, and
    /// taking another route is an override with a reason.
    var routeChoices: [Procedure.Branch] {
        switch step.routeDecider {
        case .linear: return []
        case .words: return step.branches
        case .rules: return noRuleMatchedReason == nil ? [] : step.branches
        }
    }

    /// The route the rule gives, in words, once the answer is in: "CO2 2.60 is between 2.4 and 2.8".
    var ruleLine: String? {
        guard recorded != nil, let ruleDecision else { return nil }
        switch ruleDecision {
        case .branch(_, let text), .defaultNext(_, let text): return text
        case .noRuleMatched: return nil
        }
    }

    /// The branch the rule gives, for an override's "the rule says" line.
    var ruleBranchId: String? {
        if case .branch(let branch, _)? = ruleDecision { return branch.id }
        return nil
    }

    /// Whether an override (another route, with a reason) is offered: a step the app decides,
    /// with nothing waiting on the person first.
    var offersOverride: Bool {
        step.isAppDecided && pendingReadBack == nil && !needsCorrectiveNote && step.branches.count > 1
    }

    // MARK: - The lens (Plan MN §4)

    /// The lens button id for an answer option, and the prefix that marks it.
    static let answerButtonPrefix = "answer:"
    /// The lens button ids for a read-back.
    static let readBackYesId = "readback:yes"
    static let readBackNoId = "readback:no"

    /// The lens buttons, in order: a read-back's yes and no; the answer's options on a `choice` or
    /// `yes_no` step still waiting for one; then the branches the person picks now. Ids are
    /// prefixed so a branch named "yes" never answers the step.
    var lensChoices: [HUDChoice] {
        if pendingReadBack != nil {
            return [HUDChoice(id: Self.readBackYesId, label: String(localized: "Yes, that's right")),
                    HUDChoice(id: Self.readBackNoId, label: String(localized: "No, say it again"))]
        }
        if awaitsAnswer, let answer, !answer.buttons.isEmpty {
            return answer.buttons.map { HUDChoice(id: Self.answerButtonPrefix + $0.id, label: $0.label) }
        }
        if needsCorrectiveNote { return [] }
        return routeChoices.map { HUDChoice(id: $0.id, label: $0.condition) }
    }

    /// The step's words on the lens, with what was recorded or what the phone is needed for.
    var lensInstruction: String? {
        var lines: [String] = []
        let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty { lines.append(instruction) }
        if let pendingReadBack {
            lines.append(pendingReadBack.prompt)
        } else if let recordedLine {
            lines.append(recordedLine)
            if needsCorrectiveNote {
                lines.append(String(localized: "Add the corrective note on the phone or by voice."))
            } else if let reason = noRuleMatchedReason {
                lines.append(String(localized: "\(reason). Choose the route."))
            }
        } else if let answer, answer.buttons.isEmpty {
            switch answer.kind {
            case .photo:
                lines.append(String(localized: "Take the photo, then Done."))
            default:
                lines.append(String(localized: "Say or type the \(answer.displayLabel) on the phone."))
            }
            if let specHint { lines.append(specHint) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
