import Foundation

/// Gaps and overlaps in a step's number rules (Plan MN §7). Pure.
///
/// For a step whose rules test only its own `number` answer, every value a reading can take —
/// `plausible`, at the step's `decimals` — is checked against the rules. A value no rule takes,
/// on a step with no `default_next`, is a gap ("a pH of 3.75 matches no route and there is no
/// default"); a value two rules take is an overlap ("4.4 matches both in_spec and high; the first
/// listed wins"). Both are warnings: the author may mean them, and the run never guesses either way.
///
/// The rules only change their answer at a bound, so instead of walking every value it checks each
/// bound, the values one place either side of it, the ends of `plausible` and one value inside
/// every stretch between those — the same verdict on every value, in a few dozen evaluations.
enum RuleCoverage {

    struct Finding: Equatable {
        enum Kind: Equatable { case gap, overlap }
        let kind: Kind
        /// The first value of the stretch the finding is about.
        let value: Decimal
        /// The branches that match it (empty for a gap).
        let branchIds: [String]
        let message: String
    }

    /// Whether `step` is one this check covers: a number answer with a plausible range, and rules
    /// on every branch that read only that answer.
    static func applies(to step: Procedure.Step) -> Bool {
        guard let answer = step.answer, answer.kind == .number, answer.plausibleRange != nil,
              step.isAppDecided else { return false }
        return step.branches.allSatisfy { branch in
            guard let rule = branch.when, rule.malformedReasons.isEmpty else { return false }
            return rule.tests.allSatisfy { test in
                test.answer == answer.recordAs && test.op != .inList && test.op != .isAnswer
            }
        }
    }

    static func check(_ step: Procedure.Step) -> [Finding] {
        guard applies(to: step), let answer = step.answer, let plausible = answer.plausibleRange else { return [] }
        let places = answer.places
        let unit = ExactDecimal.unit(places: places)
        let low = ExactDecimal.rounded(plausible.lowerBound, places: places)
        let high = ExactDecimal.rounded(plausible.upperBound, places: places)
        guard low <= high else { return [] }

        var bounds: [Decimal] = []
        for branch in step.branches {
            for test in branch.when?.tests ?? [] {
                switch test.operand {
                case .number(let b): bounds.append(ExactDecimal.from(b))
                case .pair(let lo, let hi): bounds.append(ExactDecimal.from(lo)); bounds.append(ExactDecimal.from(hi))
                default: break
                }
            }
        }
        if let spec = answer.specRange { bounds.append(spec.lowerBound); bounds.append(spec.upperBound) }

        var points = Set<Decimal>([low, high, low + unit, high - unit])
        for bound in bounds {
            let r = ExactDecimal.rounded(bound, places: places)
            points.formUnion([r - unit, r, r + unit])
        }
        var sorted = points.filter { $0 >= low && $0 <= high }.sorted()
        // One value inside every stretch between two checked values.
        var interior: [Decimal] = []
        for (a, c) in zip(sorted, sorted.dropFirst()) where c - a > unit { interior.append(a + unit) }
        sorted = Array(Set(sorted + interior)).sorted()

        var findings: [Finding] = []
        var previous: [String]? = nil
        for value in sorted {
            let known = KnownAnswer(answer: answer, value: ProcedureAnswerValue(
                kind: .number, entered: ExactDecimal.text(value, places: places), number: value,
                specStatus: answer.specRange.map { $0.contains(value) ? .in : .out }))
            let answers = [answer.recordAs: known]
            let matching = step.branches.filter { branch in
                branch.when.map { BranchRuleEvaluator.holds($0, answers: answers) } ?? false
            }.map(\.id)
            defer { previous = matching }
            guard matching != previous else { continue }   // the same stretch, already reported
            let shown = ExactDecimal.text(value, places: places)
            if matching.isEmpty, step.defaultNext == nil {
                findings.append(Finding(kind: .gap, value: value, branchIds: [],
                                        message: "a \(answer.displayLabel) of \(shown) matches no route and there is no default"))
            } else if matching.count > 1 {
                findings.append(Finding(kind: .overlap, value: value, branchIds: matching,
                                        message: "\(shown) matches \(listed(matching)); the first listed wins"))
            }
        }
        return findings
    }

    private static func listed(_ ids: [String]) -> String {
        if ids.count == 2 { return "both \(ids[0]) and \(ids[1])" }
        return ids.dropLast().joined(separator: ", ") + " and " + (ids.last ?? "")
    }
}

/// Whether a procedure runs on this phone with no assistant (Plan MN §6), as a fact the app states
/// rather than an opinion. Pure.
///
/// It runs without a model when every step that branches has rule branches or exactly one way on,
/// every answer it records is a typed one, and nothing depends on what only a model can do —
/// today, a branch chosen from words, or an observation asked for in words (`expected_input`)
/// with no typed answer to record it.
enum ProcedureReadiness: Equatable {
    case runsWithoutModel
    /// Step id → why that step needs a model.
    case needsModel([String: String])

    /// Why one step needs a model.
    enum Reason: Equatable {
        case choosesFromWords, asksInWords, unknownAnswerKind

        /// The stable English wording: what `of(_:)` returns and the tests read.
        var english: String {
            switch self {
            case .choosesFromWords: return "chooses its route from words"
            case .asksInWords: return "asks for an answer in words that it can't record without an assistant"
            case .unknownAnswerKind: return "has an answer of a kind this version of the app doesn't read"
            }
        }

        /// The same words in the app's language, for the lines that show them ("Step 4 chooses its
        /// route from words"). Kept word for word with `english`, which the tests check.
        var localized: String {
            switch self {
            case .choosesFromWords:
                return String(localized: "chooses its route from words",
                              comment: "Completes \"Step 4 …\": why a procedure step needs an assistant to run")
            case .asksInWords:
                return String(localized: "asks for an answer in words that it can't record without an assistant",
                              comment: "Completes \"Step 4 …\": why a procedure step needs an assistant to run")
            case .unknownAnswerKind:
                return String(localized: "has an answer of a kind this version of the app doesn't read",
                              comment: "Completes \"Step 4 …\": why a procedure step needs an assistant to run")
            }
        }
    }

    /// One step that stops a procedure running without a model.
    struct Blocker: Equatable {
        let stepId: String
        /// 1-based position in the procedure's step list.
        let stepNumber: Int
        let kind: Reason
        /// The English wording; a screen shows `kind.localized`.
        var reason: String { kind.english }
    }

    static let choosesFromWords = Reason.choosesFromWords.english
    static let asksInWords = Reason.asksInWords.english
    static let unknownAnswerKind = Reason.unknownAnswerKind.english

    static func of(_ procedure: Procedure) -> ProcedureReadiness {
        let found = blockers(procedure)
        guard !found.isEmpty else { return .runsWithoutModel }
        var reasons: [String: String] = [:]
        for blocker in found where reasons[blocker.stepId] == nil { reasons[blocker.stepId] = blocker.reason }
        return .needsModel(reasons)
    }

    /// The steps that need a model, in step order, one reason each.
    static func blockers(_ procedure: Procedure) -> [Blocker] {
        procedure.steps.enumerated().compactMap { index, step in
            guard let kind = reason(step) else { return nil }
            return Blocker(stepId: step.id, stepNumber: index + 1, kind: kind)
        }
    }

    private static func reason(_ step: Procedure.Step) -> Reason? {
        if let answer = step.answer, answer.kind == nil { return .unknownAnswerKind }
        if step.branches.count > 1, !step.isAppDecided { return .choosesFromWords }
        if step.answer == nil, let expected = step.expectedInput,
           !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .asksInWords
        }
        return nil
    }

    /// The import summary line: "8 procedures, 6 run with no assistant; Line changeover step 4
    /// chooses its route from words". Nil when there are none. Shown after an import, so it is in
    /// the app's language; each count's sentence is whole, for the catalog's plural forms.
    static func importSummary(_ procedures: [Procedure]) -> String? {
        guard !procedures.isEmpty else { return nil }
        let blocked = procedures.compactMap { procedure -> (Procedure, Blocker)? in
            blockers(procedure).first.map { (procedure, $0) }
        }
        let runs = procedures.count - blocked.count
        let total = procedures.count == 1
            ? String(localized: "1 procedure", comment: "Vault import summary: how many procedures the vault has")
            : String(localized: "\(procedures.count) procedures", comment: "Vault import summary: how many procedures the vault has")
        var line: String
        switch runs {
        case 0:
            line = String(localized: "\(total), none run with no assistant",
                          comment: "Vault import summary: '3 procedures, none run with no assistant'")
        case 1:
            line = String(localized: "\(total), 1 runs with no assistant",
                          comment: "Vault import summary: '3 procedures, 1 runs with no assistant'")
        default:
            line = String(localized: "\(total), \(runs) run with no assistant",
                          comment: "Vault import summary: '3 procedures, 2 run with no assistant'")
        }
        for (procedure, blocker) in blocked.prefix(3) {
            let named = String(localized: "\(procedure.title) step \(blocker.stepNumber) \(blocker.kind.localized)",
                               comment: "Vault import summary: a procedure, the step that needs an assistant, and why")
            line = String(localized: "\(line); \(named)", comment: "Vault import summary: the next part, after a semicolon")
        }
        if blocked.count > 3 {
            let more = String(localized: "and \(blocked.count - 3) more",
                              comment: "Vault import summary: how many more procedures need an assistant")
            line = String(localized: "\(line); \(more)", comment: "Vault import summary: the next part, after a semicolon")
        }
        return line
    }
}
