import Foundation

/// Plan MN P3 — editing a procedure's typed answers (§1) and the rules on its branches (§2) on the
/// authoring screen. Pure: the screen holds a `ProcedureEditing`, every edit is a new copy of the
/// procedure, and every copy is checked by the same validator the importer runs
/// (`VaultValidator.validateProcedureGraph` and `ProcedureAnswerValidator`), so an issue or a
/// warning shows beside the step it is about the moment the author makes it.

// MARK: - Copies with one thing changed

extension Procedure {
    /// This procedure with another step list, and everything else as it is.
    func with(steps: [Step]) -> Procedure {
        Procedure(id: id, title: title, version: version, vault: vault, description: description,
                  safetyNotes: safetyNotes, entryStep: entryStep, steps: steps, runs: runs, coaching: coaching)
    }

    /// This procedure with `step` in place of the step of the same id.
    func replacing(_ step: Step) -> Procedure {
        with(steps: steps.map { $0.id == step.id ? step : $0 })
    }

    /// Every answer the procedure records, by `record_as` (the first step's, if two share a name —
    /// the validator's issue).
    var answersByName: [String: StepAnswer] {
        var answers: [String: StepAnswer] = [:]
        for step in steps { if let answer = step.answer, answers[answer.recordAs] == nil { answers[answer.recordAs] = answer } }
        return answers
    }
}

extension Procedure.Step {
    func with(answer: StepAnswer?) -> Procedure.Step {
        Procedure.Step(id: id, title: title, instruction: instruction, expectedInput: expectedInput,
                       safetyNote: safetyNote, calcRef: calcRef, citations: citations, branches: branches,
                       defaultNext: defaultNext, terminal: terminal, outcome: outcome,
                       requiresConfirmation: requiresConfirmation, videoURL: videoURL, answer: answer,
                       cautionPhrases: cautionPhrases)
    }

    func with(branches: [Procedure.Branch]) -> Procedure.Step {
        Procedure.Step(id: id, title: title, instruction: instruction, expectedInput: expectedInput,
                       safetyNote: safetyNote, calcRef: calcRef, citations: citations, branches: branches,
                       defaultNext: defaultNext, terminal: terminal, outcome: outcome,
                       requiresConfirmation: requiresConfirmation, videoURL: videoURL, answer: answer,
                       cautionPhrases: cautionPhrases)
    }
}

extension Procedure.Branch {
    func with(when rule: BranchRule?) -> Procedure.Branch {
        Procedure.Branch(id: id, condition: condition, next: next, when: rule)
    }
}

// MARK: - An answer being edited

/// One step's answer as the form holds it: every field as typed, so a half-typed number is still
/// the author's text. `build()` turns it into the `StepAnswer` the file carries, or says which
/// field doesn't read.
struct AnswerDraft: Equatable {

    struct OptionDraft: Equatable, Identifiable {
        var id = UUID()
        var optionId: String
        var label: String
        /// The words a person may say for it, comma-separated.
        var says: String

        init(optionId: String = "", label: String = "", says: String = "") {
            self.optionId = optionId
            self.label = label
            self.says = says
        }
    }

    enum Problem: Error, Equatable {
        case noRecordName
        case notANumber(String)
        case halfARange(String)
        case notAWholeNumber(String)
        case incompleteOption(Int)

        var message: String {
            switch self {
            case .noRecordName: return String(localized: "Give the answer a record name.")
            case .notANumber(let field): return String(localized: "\(field) isn't a number.")
            case .halfARange(let field): return String(localized: "Give both ends of \(field), or neither.")
            case .notAWholeNumber(let field): return String(localized: "\(field) is a whole number.")
            case .incompleteOption(let number): return String(localized: "Option \(number) needs an id and a label.")
            }
        }
    }

    var kind: StepAnswer.Kind
    var recordAs: String
    var label = ""
    var required = true
    var critical = false
    // number
    var unit = ""
    var decimals = 0
    var plausibleLow = ""
    var plausibleHigh = ""
    var specLow = ""
    var specHigh = ""
    var showSpec = false
    // choice
    var options: [OptionDraft] = []
    // text
    var minLength = ""
    var maxLength = ""
    // photo
    var minPhotos = ""
    var maxPhotos = ""
    // code
    /// "", "qr" or "barcode".
    var symbology = ""
    var expected = ""

    /// A new answer of `kind`. A choice starts with two empty options, the fewest it takes.
    init(kind: StepAnswer.Kind, recordAs: String = "") {
        self.kind = kind
        self.recordAs = recordAs
        if kind == .choice { options = [OptionDraft(), OptionDraft()] }
    }

    /// The form for an answer the procedure already has. Nil for a kind this build doesn't read:
    /// that answer is left as written, never rewritten through a form that can't hold it.
    init?(_ answer: StepAnswer) {
        guard let kind = answer.kind else { return nil }
        self.kind = kind
        recordAs = answer.recordAs
        label = answer.label ?? ""
        required = answer.isRequired
        critical = answer.isCritical
        unit = answer.unit ?? ""
        decimals = answer.decimals ?? 0
        plausibleLow = Self.text(answer.plausible, 0)
        plausibleHigh = Self.text(answer.plausible, 1)
        specLow = Self.text(answer.spec, 0)
        specHigh = Self.text(answer.spec, 1)
        showSpec = answer.showSpec == true
        options = (answer.options ?? []).map {
            OptionDraft(optionId: $0.id, label: $0.label, says: ($0.says ?? []).joined(separator: ", "))
        }
        minLength = answer.minLen.map(String.init) ?? ""
        maxLength = answer.maxLen.map(String.init) ?? ""
        minPhotos = answer.minPhotos.map(String.init) ?? ""
        maxPhotos = answer.maxPhotos.map(String.init) ?? ""
        symbology = answer.symbology ?? ""
        expected = answer.expected ?? ""
    }

    private static func text(_ pair: [Double]?, _ index: Int) -> String {
        guard let pair, pair.count == 2 else { return "" }
        return ExactDecimal.text(ExactDecimal.from(pair[index]))
    }

    /// The answer as the file writes it. Only this kind's fields are written; a field left empty, a
    /// default (required, no decimals) and an unset toggle are left out, as an author writes them.
    func build() -> Result<StepAnswer, Problem> {
        let name = recordAs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.noRecordName) }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var unit: String?
        var decimals: Int?
        var plausible: [Double]?
        var spec: [Double]?
        var showSpec: Bool?
        var options: [StepAnswer.Option]?
        var minLen: Int?, maxLen: Int?, minPhotos: Int?, maxPhotos: Int?
        var symbology: String?, expected: String?
        do {
            switch kind {
            case .number:
                unit = Self.nonEmpty(self.unit)
                decimals = self.decimals == 0 ? nil : self.decimals
                plausible = try Self.pair(plausibleLow, plausibleHigh, field: String(localized: "Can be"))
                spec = try Self.pair(specLow, specHigh, field: String(localized: "Should be"))
                showSpec = spec != nil && self.showSpec ? true : nil
            case .choice:
                var made: [StepAnswer.Option] = []
                for (index, option) in self.options.enumerated() {
                    let id = option.optionId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let says = option.says.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if id.isEmpty && label.isEmpty && says.isEmpty { continue }   // an empty row is no option
                    guard !id.isEmpty, !label.isEmpty else { throw Problem.incompleteOption(index + 1) }
                    made.append(StepAnswer.Option(id: id, label: label, says: says.isEmpty ? nil : says))
                }
                options = made
            case .text:
                minLen = try Self.whole(minLength, field: String(localized: "Shortest"))
                maxLen = try Self.whole(maxLength, field: String(localized: "Longest"))
            case .photo:
                minPhotos = try Self.whole(self.minPhotos, field: String(localized: "Fewest photos"))
                maxPhotos = try Self.whole(self.maxPhotos, field: String(localized: "Most photos"))
            case .code:
                symbology = Self.nonEmpty(self.symbology)
                expected = Self.nonEmpty(self.expected)
            case .yesNo:
                break
            }
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(.noRecordName)
        }
        return .success(StepAnswer(
            recordAs: name, kind: kind, label: trimmedLabel.isEmpty ? nil : trimmedLabel,
            required: required ? nil : false, critical: critical ? true : nil,
            unit: unit, decimals: decimals, plausible: plausible, spec: spec, showSpec: showSpec,
            options: options, minLen: minLen, maxLen: maxLen, minPhotos: minPhotos, maxPhotos: maxPhotos,
            symbology: symbology, expected: expected))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A number as typed, with a decimal comma read as a point. Nil for anything else.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let exact = ExactDecimal.parse(trimmed) else { return nil }
        return Double(ExactDecimal.text(exact))
    }

    private static func pair(_ low: String, _ high: String, field: String) throws -> [Double]? {
        let lo = low.trimmingCharacters(in: .whitespaces), hi = high.trimmingCharacters(in: .whitespaces)
        if lo.isEmpty && hi.isEmpty { return nil }
        guard !lo.isEmpty, !hi.isEmpty else { throw Problem.halfARange(field) }
        guard let a = number(lo), let b = number(hi) else { throw Problem.notANumber(field) }
        return [a, b]
    }

    private static func whole(_ text: String, field: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let value = Int(trimmed) else { throw Problem.notAWholeNumber(field) }
        return value
    }
}

// MARK: - A rule being edited

/// A branch's `when` as the form holds it: a list of tests joined by *all* or *any*, optionally
/// negated as a whole — `{test}`, `{"all": [tests]}`, `{"any": [tests]}`, and `not` of any of them.
/// That covers what a step needs without a general tree editor; a rule shaped otherwise in the file
/// (nested combinations) is shown in words and kept as written unless the author replaces it.
struct RuleDraft: Equatable {

    enum Joining: String, CaseIterable, Equatable { case all, any }

    struct TestDraft: Equatable, Identifiable {
        var id = UUID()
        var answer: String
        var op: BranchRule.Op
        /// The number, the option id, the text or `yes` / `no`, as typed.
        var value = ""
        /// The second bound of `between` / `outside`.
        var upper = ""
        /// The option ids of `in`.
        var ids: [String] = []
        /// `out_of_spec` / `present`.
        var flag = true

        init(answer: String, op: BranchRule.Op) {
            self.answer = answer
            self.op = op
        }

        init(_ test: BranchRule.Test) {
            answer = test.answer
            op = test.op
            switch test.operand {
            case .number(let n): value = ExactDecimal.text(ExactDecimal.from(n))
            case .text(let s): value = s
            case .pair(let lo, let hi):
                value = ExactDecimal.text(ExactDecimal.from(lo)); upper = ExactDecimal.text(ExactDecimal.from(hi))
            case .list(let list): ids = list
            case .flag(let b): flag = b
            }
        }
    }

    enum Problem: Error, Equatable {
        case noTests
        case noAnswer(Int)
        case notANumber(Int)
        case noValue(Int)
        case noOptions(Int)

        var message: String {
            switch self {
            case .noTests: return String(localized: "A rule needs at least one test.")
            case .noAnswer(let n): return String(localized: "Test \(n) doesn't say which answer it reads.")
            case .notANumber(let n): return String(localized: "Test \(n) needs a number.")
            case .noValue(let n): return String(localized: "Test \(n) needs a value.")
            case .noOptions(let n): return String(localized: "Test \(n) needs at least one option.")
            }
        }
    }

    var joining: Joining = .all
    var negated = false
    var tests: [TestDraft]

    /// A first test on `answer`, with the comparison that kind usually takes.
    init(answer: StepAnswer?) {
        guard let answer else { tests = []; return }
        let op = Self.ops(for: answer).first ?? .present
        var test = TestDraft(answer: answer.recordAs, op: op)
        if op == .isAnswer { test.value = "yes" }
        tests = [test]
    }

    /// The form for a rule the branch already has. Nil for a shape the form can't hold.
    init?(_ rule: BranchRule) {
        switch rule {
        case .not(let inner):
            guard let draft = RuleDraft(flat: inner) else { return nil }
            self = draft
            negated = true
        default:
            guard let draft = RuleDraft(flat: rule) else { return nil }
            self = draft
        }
    }

    private init?(flat rule: BranchRule) {
        switch rule {
        case .test(let test):
            tests = [TestDraft(test)]
        case .all(let rules), .any(let rules):
            var made: [TestDraft] = []
            for rule in rules {
                guard case .test(let test) = rule else { return nil }
                made.append(TestDraft(test))
            }
            tests = made
            if case .any = rule { joining = .any }
        case .not, .malformed:
            return nil
        }
    }

    /// The comparisons that fit `answer`, the usual one first (§7: the op fits the kind).
    static func ops(for answer: StepAnswer?) -> [BranchRule.Op] {
        guard let answer, let kind = answer.kind else { return BranchRule.Op.allCases }
        var ops: [BranchRule.Op]
        switch kind {
        case .number: ops = [.between, .outside, .gt, .gte, .lt, .lte, .eq, .ne]
        case .choice: ops = [.inList, .eq, .ne]
        case .yesNo: ops = [.isAnswer]
        case .text: ops = [.eq, .ne]
        case .code: ops = [.eq, .ne]
        case .photo: ops = []
        }
        if answer.hasSpec { ops.append(.outOfSpec) }
        ops.append(.present)
        return ops
    }

    /// The rule as the file writes it. `answers` are the procedure's, by `record_as`: `eq` / `ne`
    /// compare a number on a number answer and an id or text on the others.
    func build(answers: [String: StepAnswer]) -> Result<BranchRule, Problem> {
        guard !tests.isEmpty else { return .failure(.noTests) }
        var made: [BranchRule] = []
        for (index, draft) in tests.enumerated() {
            let n = index + 1
            let name = draft.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.noAnswer(n)) }
            let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let operand: BranchRule.Operand
            switch draft.op {
            case .eq, .ne:
                if answers[name]?.kind == .number {
                    guard let number = AnswerDraft.number(value) else { return .failure(.notANumber(n)) }
                    operand = .number(number)
                } else {
                    guard !value.isEmpty else { return .failure(.noValue(n)) }
                    operand = .text(value)
                }
            case .lt, .lte, .gt, .gte:
                guard let number = AnswerDraft.number(value) else { return .failure(.notANumber(n)) }
                operand = .number(number)
            case .between, .outside:
                guard let lo = AnswerDraft.number(value), let hi = AnswerDraft.number(draft.upper) else {
                    return .failure(.notANumber(n))
                }
                operand = .pair(lo, hi)
            case .inList:
                let ids = draft.ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !ids.isEmpty else { return .failure(.noOptions(n)) }
                operand = .list(ids)
            case .isAnswer:
                let said = value.lowercased()
                guard said == "yes" || said == "no" else { return .failure(.noValue(n)) }
                operand = .text(said)
            case .outOfSpec, .present:
                operand = .flag(draft.flag)
            }
            made.append(.test(.init(answer: name, op: draft.op, operand: operand)))
        }
        let joined: BranchRule = made.count == 1 ? made[0] : (joining == .all ? .all(made) : .any(made))
        return .success(negated ? .not(joined) : joined)
    }
}

// MARK: - The procedure being edited

/// A procedure on the authoring screen: what the file held, what the author has made of it, and the
/// validator's verdict on every edit, placed beside the step and the branch it is about.
struct ProcedureEditing: Equatable {

    /// What the validator says, in its own words.
    struct Messages: Equatable {
        var issues: [String] = []
        var warnings: [String] = []
        var isEmpty: Bool { issues.isEmpty && warnings.isEmpty }
    }

    /// The procedure as the file held it.
    let original: Procedure
    /// The procedure with the author's edits. Nothing is written until it is saved.
    private(set) var procedure: Procedure
    /// The validator's issues (refuse a save, as they refuse an import) and warnings.
    private(set) var messages = Messages()

    init(_ procedure: Procedure) {
        original = procedure
        self.procedure = procedure
        messages = Self.validate(procedure)
    }

    var isChanged: Bool { procedure != original }
    /// Saved only when the validator raises no issue: the importer would refuse it otherwise.
    var canSave: Bool { isChanged && messages.issues.isEmpty }
    var answers: [String: StepAnswer] { procedure.answersByName }

    static func validate(_ procedure: Procedure) -> Messages {
        Messages(issues: VaultValidator.validateProcedureGraph(procedure),
                 warnings: ProcedureAnswerValidator.check(procedure).warnings)
    }

    // MARK: Where a message belongs

    /// The step a validator message is about: the first `step '<id>'` it names.
    static func stepId(of message: String) -> String? {
        name(after: "step '", in: message)
    }

    /// The branch a validator message is about: the `branch '<id>'` it opens with.
    static func branchId(of message: String) -> String? {
        guard message.hasPrefix("branch '") else { return nil }
        return name(after: "branch '", in: message)
    }

    private static func name(after marker: String, in message: String) -> String? {
        guard let start = message.range(of: marker) else { return nil }
        guard let end = message[start.upperBound...].firstIndex(of: "'") else { return nil }
        return String(message[start.upperBound..<end])
    }

    /// The messages about `stepId` that aren't about one of its branches.
    func messages(forStep stepId: String) -> Messages {
        select { Self.stepId(of: $0) == stepId && Self.branchId(of: $0) == nil }
    }

    /// The messages about one branch of a step: its rule, its answer reference, its condition.
    func messages(forBranch branchId: String, step stepId: String) -> Messages {
        select { Self.stepId(of: $0) == stepId && Self.branchId(of: $0) == branchId }
    }

    /// The messages about no step in particular ("no terminal step is reachable from entry").
    var procedureMessages: Messages {
        let ids = Set(procedure.steps.map(\.id))
        return select { message in Self.stepId(of: message).map { !ids.contains($0) } ?? true }
    }

    private func select(_ keep: (String) -> Bool) -> Messages {
        Messages(issues: messages.issues.filter(keep), warnings: messages.warnings.filter(keep))
    }

    // MARK: What the screen states

    /// Whether the procedure runs with no assistant, and the steps that stop it (§6).
    var readiness: [ProcedureReadiness.Blocker] { ProcedureReadiness.blockers(procedure) }

    /// A branch's rule in words, with no values yet; nil for a branch chosen from words.
    func ruleWords(_ branch: Procedure.Branch) -> String? {
        branch.when.map { BranchRuleEvaluator.words($0, answers: answers) }
    }

    func step(_ id: String) -> Procedure.Step? { procedure.step(id: id) }

    // MARK: Edits

    /// Give `stepId` this answer, or take its answer away with nil.
    mutating func setAnswer(_ answer: StepAnswer?, onStep stepId: String) {
        guard let step = procedure.step(id: stepId) else { return }
        apply(procedure.replacing(step.with(answer: answer)))
    }

    /// Give a branch this rule, or take its rule away with nil.
    mutating func setRule(_ rule: BranchRule?, branch branchId: String, step stepId: String) {
        guard let step = procedure.step(id: stepId), step.branches.contains(where: { $0.id == branchId }) else { return }
        let branches = step.branches.map { $0.id == branchId ? $0.with(when: rule) : $0 }
        apply(procedure.replacing(step.with(branches: branches)))
    }

    /// Take every rule off a step, so the person or the assistant chooses its route again.
    mutating func removeRules(onStep stepId: String) {
        guard let step = procedure.step(id: stepId) else { return }
        apply(procedure.replacing(step.with(branches: step.branches.map { $0.with(when: nil) })))
    }

    /// Back to what the file held.
    mutating func revert() { apply(original) }

    private mutating func apply(_ edited: Procedure) {
        procedure = edited
        messages = Self.validate(edited)
    }

    /// A step whose branches are part rules, part words — refused on save (decision 2).
    func isMixed(_ stepId: String) -> Bool {
        guard let step = procedure.step(id: stepId) else { return false }
        let ruled = step.branches.filter { $0.when != nil }.count
        return ruled > 0 && ruled < step.branches.count
    }

    /// The file's bytes for the edited procedure.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(procedure)
    }
}
