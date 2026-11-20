import Foundation

/// An answer a rule can read: the step's answer definition and the value recorded for it.
struct KnownAnswer: Equatable {
    let answer: StepAnswer
    let value: ProcedureAnswerValue
}

/// Decides a step's route from its rules (Plan MN §2). Pure.
///
/// - Branches are tried in listed order; the first rule that holds wins.
/// - None holds: `default_next` when the step has one, otherwise a stop that says so — it never
///   guesses.
/// - A number is compared as the exact `Decimal` of what was entered, rounded to the step's
///   `decimals`, against the bound exactly as written: 4.40 against `gt 4.4` is false every time.
/// - A rule may read this step's answer or any earlier one on the path taken (`answers`, keyed by
///   `record_as`). An answer that is not there makes a test false, except `present: false`.
enum BranchRuleEvaluator {

    enum Decision: Equatable {
        /// A rule held: take this branch. `ruleText` is the rule in words ("pH 4.60 is above 4.4").
        case branch(Procedure.Branch, ruleText: String)
        /// No rule held; the step's `default_next`.
        case defaultNext(String, ruleText: String)
        /// No rule held and there is no default: stop, and offer the branches to the person.
        case noRuleMatched(reason: String)

        var ruleText: String {
            switch self {
            case .branch(_, let text), .defaultNext(_, let text): return text
            case .noRuleMatched(let reason): return reason
            }
        }
    }

    static func decide(_ step: Procedure.Step, answers: [String: KnownAnswer]) -> Decision {
        for branch in step.branches {
            guard let rule = branch.when, holds(rule, answers: answers) else { continue }
            return .branch(branch, ruleText: describe(rule, answers: answers))
        }
        let reason = noMatchReason(step, answers: answers)
        if let next = step.defaultNext {
            return .defaultNext(next, ruleText: "\(reason); the step's default route")
        }
        return .noRuleMatched(reason: reason)
    }

    /// "pH 3.75 matches none of this step's routes".
    static func noMatchReason(_ step: Procedure.Step, answers: [String: KnownAnswer]) -> String {
        if let answer = step.answer, let known = answers[answer.recordAs] {
            return "\(answer.displayLabel) \(known.value.display(for: answer)) matches none of this step's routes"
        }
        return "The answers match none of this step's routes"
    }

    // MARK: - Holding

    static func holds(_ rule: BranchRule, answers: [String: KnownAnswer]) -> Bool {
        switch rule {
        case .test(let test): return holds(test, answers: answers)
        case .all(let rules): return rules.allSatisfy { holds($0, answers: answers) }
        case .any(let rules): return rules.contains { holds($0, answers: answers) }
        case .not(let rule): return !holds(rule, answers: answers)
        case .malformed: return false
        }
    }

    static func holds(_ test: BranchRule.Test, answers: [String: KnownAnswer]) -> Bool {
        guard let known = answers[test.answer] else {
            // Not on the path taken (or never given): only "not present" holds.
            if test.op == .present, case .flag(false) = test.operand { return true }
            return false
        }
        let value = known.value
        switch (test.op, test.operand) {
        case (.present, .flag(let wanted)):
            return wanted
        case (.outOfSpec, .flag(let wanted)):
            guard let status = value.specStatus else { return false }
            return (status == .out) == wanted
        case (.eq, .number(let bound)), (.ne, .number(let bound)),
             (.lt, .number(let bound)), (.lte, .number(let bound)),
             (.gt, .number(let bound)), (.gte, .number(let bound)):
            guard let number = value.number else { return false }
            return compare(number, test.op, ExactDecimal.from(bound))
        case (.between, .pair(let lo, let hi)), (.outside, .pair(let lo, let hi)):
            guard let number = value.number else { return false }
            let low = ExactDecimal.from(lo), high = ExactDecimal.from(hi)
            guard low <= high else { return false }
            let inside = number >= low && number <= high
            return test.op == .between ? inside : !inside
        case (.eq, .text(let wanted)), (.ne, .text(let wanted)):
            guard let actual = value.option ?? value.text else { return false }
            let same = actual.caseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespaces)) == .orderedSame
            return test.op == .eq ? same : !same
        case (.inList, .list(let ids)):
            guard let option = value.option else { return false }
            return ids.contains(option)
        case (.isAnswer, .text(let wanted)):
            guard value.kind == .yesNo, let option = value.option else { return false }
            return option == wanted.lowercased()
        default:
            // An op that does not fit its operand (the validator's issue) never holds.
            return false
        }
    }

    private static func compare(_ value: Decimal, _ op: BranchRule.Op, _ bound: Decimal) -> Bool {
        switch op {
        case .eq: return value == bound
        case .ne: return value != bound
        case .lt: return value < bound
        case .lte: return value <= bound
        case .gt: return value > bound
        case .gte: return value >= bound
        default: return false
        }
    }

    // MARK: - In words

    /// Why `rule` holds — or, with `negated`, why it does not — in words, with the values put in:
    /// "pH 4.60 is above 4.4", "Brix 10.2 is below 11 and pH 4.60 is above 4.4". It is the record's
    /// `rule_text` and the reason a disagreeing choice is refused.
    static func describe(_ rule: BranchRule, answers: [String: KnownAnswer], negated: Bool = false) -> String {
        switch rule {
        case .test(let test):
            return describe(test, answers: answers, negated: negated)
        case .malformed(let reason):
            return "a rule this app can't read (\(reason))"
        case .not(let inner):
            return describe(inner, answers: answers, negated: !negated)
        case .all(let rules):
            if negated {
                // Not all hold: name the first that fails.
                guard let failing = rules.first(where: { !holds($0, answers: answers) }) ?? rules.first else { return "" }
                return describe(failing, answers: answers, negated: true)
            }
            return rules.map { describe($0, answers: answers) }.joined(separator: " and ")
        case .any(let rules):
            if negated {
                return rules.map { describe($0, answers: answers, negated: true) }.joined(separator: " and ")
            }
            guard let holding = rules.first(where: { holds($0, answers: answers) }) ?? rules.first else { return "" }
            return describe(holding, answers: answers)
        }
    }

    private static func describe(_ test: BranchRule.Test, answers: [String: KnownAnswer], negated: Bool) -> String {
        guard let known = answers[test.answer] else {
            return "no \(test.answer.replacingOccurrences(of: "_", with: " ")) was recorded"
        }
        let answer = known.answer
        let label = answer.displayLabel
        let subject = "\(label) \(known.value.display(for: answer))"
        let not = negated ? " not" : ""
        func bound(_ value: Double) -> String { ExactDecimal.text(ExactDecimal.from(value)) }
        switch (test.op, test.operand) {
        case (.gt, .number(let b)): return "\(subject) is\(not) above \(bound(b))"
        case (.gte, .number(let b)): return negated ? "\(subject) is below \(bound(b))" : "\(subject) is at least \(bound(b))"
        case (.lt, .number(let b)): return "\(subject) is\(not) below \(bound(b))"
        case (.lte, .number(let b)): return negated ? "\(subject) is above \(bound(b))" : "\(subject) is at most \(bound(b))"
        case (.eq, .number(let b)): return "\(subject) is\(not) \(bound(b))"
        case (.ne, .number(let b)): return negated ? "\(subject) is \(bound(b))" : "\(subject) is not \(bound(b))"
        case (.between, .pair(let lo, let hi)):
            return "\(subject) is\(not) between \(bound(lo)) and \(bound(hi))"
        case (.outside, .pair(let lo, let hi)):
            return negated ? "\(subject) is between \(bound(lo)) and \(bound(hi))"
                : "\(subject) is outside \(bound(lo)) to \(bound(hi))"
        case (.eq, .text(let wanted)):
            return "\(label) is\(not) \(answer.optionLabel(wanted))"
        case (.ne, .text(let wanted)):
            return negated ? "\(label) is \(answer.optionLabel(wanted))" : "\(label) is not \(answer.optionLabel(wanted))"
        case (.inList, .list(let ids)):
            let labels = ids.map(answer.optionLabel)
            if negated { return "\(label) is \(known.value.display(for: answer)), not \(labels.joined(separator: " or "))" }
            return "\(label) is \(known.value.display(for: answer))"
        case (.isAnswer, .text):
            return "\(label): \(known.value.display(for: answer))"
        case (.outOfSpec, .flag(let wanted)):
            let out = wanted != negated
            let spec = answer.specText.map { " (\($0))" } ?? ""
            return "\(subject) is \(out ? "out of" : "in") spec\(spec)"
        case (.present, .flag(let wanted)):
            return (wanted != negated) ? "\(label) was recorded" : "no \(label) was recorded"
        default:
            return "\(label): a rule that does not fit this answer"
        }
    }
}
