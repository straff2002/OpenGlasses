import Foundation

/// Plan MN P3 — the prompt kit that turns a procedure's `condition` sentences into proposed `when`
/// rules with the author's own model, by copy and paste (Plan LW §4a: Avenkin provides no model),
/// the parser that reads the reply back, and the review that lands each proposal beside its
/// sentence. Pure. Nothing here changes a procedure: a proposal is a suggestion until the author
/// accepts it, and an accepted one is an edit until they save.

// MARK: - The prompt

extension PromptKit {

    /// The kit's return shape, as the prompt states it and `RuleProposalParser` reads it.
    static let conditionsToRulesFormat = """
    {
      "steps": [
        {
          "step": "<step id>",
          "answer": { "record_as": "<snake_case name>", "kind": "number", "label": "<short name>", "decimals": 1, "plausible": [0, 100] },
          "branches": [
            { "branch": "<route id>", "when": { "answer": "<record_as>", "gt": 4.4 } }
          ]
        }
      ]
    }
    """

    /// The steps the kit asks about: those whose route is chosen from words today.
    static func stepsToRule(_ procedure: Procedure) -> [Procedure.Step] {
        procedure.steps.filter { $0.routeDecider == .words }
    }

    /// The prompt an author copies to turn `procedure`'s route sentences into rules: each answer the
    /// procedure records, then each step chosen from words with its routes' ids and sentences, the
    /// rules for writing a rule, and the exact JSON to return.
    static func conditionsToRules(_ procedure: Procedure) -> String {
        var lines = [
            "I am writing a step-by-step check for a phone app. Some steps branch, and each branch (a route) says in words when to take it. Turn those words into small rules the app can check by itself, from the answers the person records.",
            "",
            "The procedure: \(procedure.title)",
        ]
        let recorded = procedure.steps.compactMap { step in step.answer.map { (step, $0) } }
        if !recorded.isEmpty {
            lines += ["", "Answers it already records (a rule reads one by its record_as):"]
            for (step, answer) in recorded {
                lines.append("- \(answerLine(answer)) — recorded on step \(step.id)")
            }
        }
        lines += ["", "Steps to turn into rules:"]
        for step in stepsToRule(procedure) {
            lines.append("")
            lines.append("Step \(step.id): \(step.title)")
            lines.append("  Instruction: \(oneLine(step.instruction))")
            if let expected = step.expectedInput, !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  The person reports: \(oneLine(expected))")
            }
            if let answer = step.answer {
                lines.append("  Its answer: \(answerLine(answer))")
            } else {
                lines.append("  Its answer: none yet")
            }
            lines.append("  Routes:")
            for branch in step.branches {
                lines.append("  - \(branch.id): \"\(oneLine(branch.condition))\"")
            }
        }
        lines += [
            "",
            "Rules:",
            "- Only write a rule the route's words clearly say. Never guess a number or an option the words don't give.",
            "- A step's routes are all rules or none. If any route on a step can't be written as a rule, leave that whole step out.",
            "- A rule reads this step's answer or one recorded on an earlier step, by its record_as. Don't name any other.",
            "- When a step has no answer yet and its routes compare a number or pick from a few options, propose one in \"answer\": a number (with \"plausible\" [lo, hi], what a reading can be at all, and \"decimals\" 0 to 3) or a choice (with \"options\", 2 to 12 of {\"id\", \"label\"}). Leave \"answer\" out when the step has one.",
            "- record_as is snake_case: lowercase letters, digits and underscores.",
            "- A test is {\"answer\": \"<record_as>\", <comparison>: <value>}. The comparisons: eq, ne, lt, lte, gt, gte (a number); between and outside ([lo, hi], both ends included); in (a list of option ids); is (\"yes\" or \"no\"); out_of_spec (true or false, only where the answer has a spec); present (true or false).",
            "- Combine tests with {\"all\": [...]}, {\"any\": [...]} or {\"not\": {...}}, at most three deep.",
            "- Use the step and route ids exactly as written above. Don't invent steps, routes or answers.",
            "",
            "Return only JSON, with nothing before or after it, in exactly this shape:",
            conditionsToRulesFormat,
        ]
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// An answer as the prompt names it: its record name, kind, label and the facts a rule needs.
    private static func answerLine(_ answer: StepAnswer) -> String {
        var parts = ["record_as \(answer.recordAs)", answer.kindName]
        if let label = answer.label, !label.isEmpty { parts.append("\"\(label)\"") }
        if let unit = answer.unit, !unit.isEmpty { parts.append("in \(unit)") }
        if answer.kind == .number {
            parts.append("\(answer.places) decimal place\(answer.places == 1 ? "" : "s")")
            if let range = answer.plausibleRange {
                parts.append("can be \(ExactDecimal.text(range.lowerBound)) to \(ExactDecimal.text(range.upperBound))")
            }
        }
        if let spec = answer.specText { parts.append("spec \(spec)") }
        if let options = answer.options, !options.isEmpty {
            parts.append("options " + options.map { "\($0.id) (\($0.label))" }.joined(separator: ", "))
        }
        if let expected = answer.expected, !expected.isEmpty { parts.append("expected \(expected)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - The reply

/// What a pasted reply proposes, step by step, and what it couldn't use, each with its reason.
struct RuleProposals: Equatable {

    struct BranchRuleProposal: Equatable {
        let branchId: String
        let rule: BranchRule
    }

    /// One step's proposals: an answer when the step has none, and a rule for every route.
    struct StepProposal: Equatable {
        let stepId: String
        let answer: StepAnswer?
        let rules: [BranchRuleProposal]
        /// The validator's warnings on the step once these are in (a gap, an overlap, a sentence
        /// that says another number than its rule): the proposal stands, and the author is told.
        let warnings: [String]
    }

    /// A part of the reply that isn't proposed, and why. `stepId` is nil for the reply as a whole.
    struct Rejection: Equatable {
        let stepId: String?
        let reason: String
    }

    var steps: [StepProposal] = []
    var rejected: [Rejection] = []
}

/// Reads a reply to `PromptKit.conditionsToRules`. Tolerant of how a model wraps JSON (code fences,
/// a line of prose before or after it), strict on what is inside: only the kit's keys, only the
/// procedure's steps and routes, only comparisons this build reads, a rule on every route of a step
/// or none, and nothing the validator would refuse. Whatever fails is rejected with its reason,
/// never quietly dropped or bent into shape.
enum RuleProposalParser {

    private static let stepKeys: Set<String> = ["step", "answer", "branches"]
    private static let branchKeys: Set<String> = ["branch", "when"]
    private static let answerKeys: Set<String> = [
        "record_as", "kind", "label", "required", "critical", "unit", "decimals", "plausible", "spec",
        "show_spec", "options", "min_len", "max_len", "min", "max", "symbology", "expected",
    ]
    private static let optionKeys: Set<String> = ["id", "label", "says"]

    /// The JSON object in a reply: from its first `{` to its last `}`, so fences and prose around it
    /// don't matter. Nil when there is none.
    static func jsonObject(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        return String(text[open...close])
    }

    static func parse(_ text: String, procedure: Procedure) -> RuleProposals {
        var result = RuleProposals()
        func reject(_ stepId: String?, _ reason: String) { result.rejected.append(.init(stepId: stepId, reason: reason)) }

        guard let json = jsonObject(in: text), let data = json.data(using: .utf8) else {
            reject(nil, "The reply has no JSON object in it.")
            return result
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reject(nil, "The reply's JSON doesn't read. Ask your AI to return only the JSON, exactly in the shape the prompt gives.")
            return result
        }
        let extra = Set(root.keys).subtracting(["steps"])
        guard extra.isEmpty else {
            reject(nil, "The reply has \(listed(extra)) beside \"steps\"; it holds only \"steps\".")
            return result
        }
        guard let steps = root["steps"] as? [Any] else {
            reject(nil, "The reply's \"steps\" isn't a list.")
            return result
        }

        // Each step is checked on the procedure as it would be with the steps before it in the
        // reply already in, so a rule may read an answer proposed on an earlier step.
        var trial = procedure
        var seen = Set<String>()
        for (index, element) in steps.enumerated() {
            guard let entry = element as? [String: Any] else {
                reject(nil, "Entry \(index + 1) in \"steps\" isn't an object."); continue
            }
            guard let stepId = entry["step"] as? String, !stepId.isEmpty else {
                reject(nil, "Entry \(index + 1) in \"steps\" names no \"step\"."); continue
            }
            let stray = Set(entry.keys).subtracting(stepKeys)
            guard stray.isEmpty else { reject(stepId, "It has \(listed(stray)), which the reply doesn't take."); continue }
            guard let step = procedure.step(id: stepId) else {
                reject(stepId, "This procedure has no step '\(stepId)'."); continue
            }
            guard seen.insert(stepId).inserted else { reject(stepId, "The step is in the reply twice."); continue }
            switch read(entry, step: step, on: trial) {
            case .failure(let refusal):
                reject(stepId, refusal.reason)
            case .success(let proposal):
                let edited = applying(proposal, to: trial)
                let before = Set(VaultValidator.validateProcedureGraph(trial))
                let introduced = VaultValidator.validateProcedureGraph(edited).filter { !before.contains($0) }
                if !introduced.isEmpty {
                    reject(stepId, introduced.joined(separator: "; "))
                    continue
                }
                let warningsBefore = Set(ProcedureAnswerValidator.check(trial).warnings)
                let warnings = ProcedureAnswerValidator.check(edited).warnings
                    .filter { !warningsBefore.contains($0) && ProcedureEditing.stepId(of: $0) == stepId }
                result.steps.append(.init(stepId: stepId, answer: proposal.answer, rules: proposal.rules, warnings: warnings))
                trial = edited
            }
        }
        if steps.isEmpty { reject(nil, "The reply proposes no rules.") }
        return result
    }

    /// Why part of a reply isn't proposed, written as a sentence for the author.
    struct Refusal: Error, Equatable, ExpressibleByStringInterpolation {
        let reason: String
        init(stringLiteral value: String) { reason = value }
    }

    private struct Read {
        let stepId: String
        let answer: StepAnswer?
        let rules: [RuleProposals.BranchRuleProposal]
    }

    private static func read(_ entry: [String: Any], step: Procedure.Step, on trial: Procedure) -> Result<Read, Refusal> {
        if step.routeDecider == .rules {
            return .failure("Its routes are already decided by rules; edit them on the screen.")
        }
        var answer: StepAnswer?
        if let raw = entry["answer"], !(raw is NSNull) {
            guard step.answer == nil else { return .failure("It already has an answer; the reply may only propose one for a step that has none.") }
            guard let object = raw as? [String: Any] else { return .failure("Its \"answer\" isn't an object.") }
            switch readAnswer(object) {
            case .failure(let reason): return .failure(reason)
            case .success(let read): answer = read
            }
        }
        var rules: [RuleProposals.BranchRuleProposal] = []
        if let raw = entry["branches"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { return .failure("Its \"branches\" isn't a list.") }
            var named = Set<String>()
            for element in list {
                guard let object = element as? [String: Any] else { return .failure("An entry in its \"branches\" isn't an object.") }
                guard let branchId = object["branch"] as? String, !branchId.isEmpty else {
                    return .failure("An entry in its \"branches\" names no \"branch\".")
                }
                let stray = Set(object.keys).subtracting(branchKeys)
                guard stray.isEmpty else { return .failure("Route '\(branchId)' has \(listed(stray)), which the reply doesn't take.") }
                guard step.branches.contains(where: { $0.id == branchId }) else {
                    return .failure("The step has no route '\(branchId)'.")
                }
                guard named.insert(branchId).inserted else { return .failure("Route '\(branchId)' is in the reply twice.") }
                guard let when = object["when"], let data = try? JSONSerialization.data(withJSONObject: when, options: [.fragmentsAllowed]),
                      let rule = try? JSONDecoder().decode(BranchRule.self, from: data) else {
                    return .failure("Route '\(branchId)' has no rule in \"when\".")
                }
                if let reason = rule.malformedReasons.first { return .failure("Route '\(branchId)': \(reason).") }
                rules.append(.init(branchId: branchId, rule: rule))
            }
            let missing = step.branches.map(\.id).filter { !named.contains($0) }
            if !rules.isEmpty, !missing.isEmpty {
                return .failure("It proposes rules for \(rules.count) of the step's \(step.branches.count) routes (none for \(missing.joined(separator: ", "))); a step's routes are all rules or none.")
            }
        }
        if answer == nil && rules.isEmpty { return .failure("It proposes nothing for the step.") }
        // Every answer a rule names exists once this is in: here, or recorded on another step.
        var known = trial.answersByName
        if let answer { known[answer.recordAs] = known[answer.recordAs] ?? answer }
        for proposal in rules {
            for test in proposal.rule.tests where known[test.answer] == nil {
                return .failure("Route '\(proposal.branchId)' reads '\(test.answer)', which no step records.")
            }
        }
        return .success(Read(stepId: step.id, answer: answer, rules: rules))
    }

    private static func readAnswer(_ object: [String: Any]) -> Result<StepAnswer, Refusal> {
        let stray = Set(object.keys).subtracting(answerKeys)
        guard stray.isEmpty else { return .failure("Its proposed answer has \(listed(stray)), which an answer doesn't take.") }
        if let options = object["options"] as? [Any] {
            for option in options {
                guard let fields = option as? [String: Any] else { return .failure("An option in its proposed answer isn't an object.") }
                let extra = Set(fields.keys).subtracting(optionKeys)
                guard extra.isEmpty else { return .failure("An option in its proposed answer has \(listed(extra)), which an option doesn't take.") }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let answer = try? JSONDecoder().decode(StepAnswer.self, from: data) else {
            return .failure("Its proposed answer doesn't read.")
        }
        guard answer.kind != nil else {
            return .failure("Its proposed answer has the kind '\(answer.kindName)'; use number, choice, yes_no, text, photo or code.")
        }
        return .success(answer)
    }

    private static func applying(_ read: Read, to procedure: Procedure) -> Procedure {
        guard let step = procedure.step(id: read.stepId) else { return procedure }
        var edited = read.answer.map { step.with(answer: $0) } ?? step
        let rules = Dictionary(read.rules.map { ($0.branchId, $0.rule) }, uniquingKeysWith: { first, _ in first })
        if !rules.isEmpty { edited = edited.with(branches: edited.branches.map { $0.with(when: rules[$0.id]) }) }
        return procedure.replacing(edited)
    }

    private static func listed(_ keys: Set<String>) -> String {
        keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
    }
}

// MARK: - The review

/// The authoring screen's state for one procedure: the edits, the pending suggestions from a pasted
/// reply (each beside the step or the sentence it is for), and what the reply couldn't propose.
/// A suggestion changes nothing until it is accepted; an accepted one is an edit like any other,
/// and nothing reaches the vault until the author saves.
struct ProcedureRuleReview: Equatable {

    struct Suggestion: Equatable, Identifiable {
        enum Target: Equatable {
            case answer(StepAnswer)
            case rule(branchId: String, BranchRule)
        }

        enum State: Equatable { case open, accepted, rejected }

        let id: String
        let stepId: String
        let target: Target
        /// The validator's warnings on the step with the reply's proposals in.
        let warnings: [String]
        var state: State = .open

        var branchId: String? {
            if case .rule(let id, _) = target { return id }
            return nil
        }
    }

    private(set) var editing: ProcedureEditing
    private(set) var suggestions: [Suggestion] = []
    private(set) var rejected: [RuleProposals.Rejection] = []

    init(_ procedure: Procedure) {
        editing = ProcedureEditing(procedure)
    }

    var procedure: Procedure { editing.procedure }

    /// The prompt for the author's own AI, on the procedure as edited so far.
    var prompt: String { PromptKit.conditionsToRules(editing.procedure) }

    /// Whether any step's route is still chosen from words, so the kit has something to ask.
    var hasStepsToRule: Bool { !PromptKit.stepsToRule(editing.procedure).isEmpty }

    // MARK: Reading a reply

    /// Read a pasted reply. Its proposals replace the open suggestions of an earlier reply; ones
    /// already accepted or rejected stay as they were decided.
    mutating func readReply(_ text: String) {
        let parsed = RuleProposalParser.parse(text, procedure: editing.procedure)
        suggestions.removeAll { $0.state == .open }
        var made: [Suggestion] = []
        for step in parsed.steps {
            if let answer = step.answer {
                made.append(Suggestion(id: "\(step.stepId)#answer", stepId: step.stepId, target: .answer(answer),
                                       warnings: step.warnings))
            }
            for rule in step.rules {
                made.append(Suggestion(id: "\(step.stepId)#\(rule.branchId)", stepId: step.stepId,
                                       target: .rule(branchId: rule.branchId, rule.rule), warnings: step.warnings))
            }
        }
        let decided = Set(suggestions.map(\.id))
        suggestions += made.filter { !decided.contains($0.id) }
        rejected = parsed.rejected
    }

    func answerSuggestion(forStep stepId: String) -> Suggestion? {
        suggestions.first { $0.stepId == stepId && $0.branchId == nil && $0.state == .open }
    }

    func ruleSuggestion(forBranch branchId: String, step stepId: String) -> Suggestion? {
        suggestions.first { $0.stepId == stepId && $0.branchId == branchId && $0.state == .open }
    }

    var openSuggestionCount: Int { suggestions.filter { $0.state == .open }.count }

    /// The suggestion in words: "Number “pH”, 2 decimals, can be 0 to 14" or "pH is above 4.4".
    func words(_ suggestion: Suggestion) -> String {
        switch suggestion.target {
        case .answer(let answer): return Self.describe(answer)
        case .rule(_, let rule):
            var answers = editing.answers
            for case .answer(let proposed) in suggestions.filter({ $0.stepId == suggestion.stepId }).map(\.target)
            where answers[proposed.recordAs] == nil {
                answers[proposed.recordAs] = proposed
            }
            return BranchRuleEvaluator.words(rule, answers: answers)
        }
    }

    /// Why a suggestion can't be accepted yet, or nil when it can.
    func blockedReason(_ id: String) -> String? {
        guard let suggestion = suggestions.first(where: { $0.id == id }), suggestion.state == .open else { return nil }
        switch suggestion.target {
        case .answer:
            return editing.step(suggestion.stepId)?.answer == nil
                ? nil : String(localized: "This step has an answer now. Reject the suggestion, or remove that answer first.")
        case .rule(_, let rule):
            let answers = editing.answers
            let missing = rule.answersNamed.filter { answers[$0] == nil }
            guard let first = missing.first else { return nil }
            return String(localized: "Accept the suggested answer \(first) first; this rule reads it.")
        }
    }

    // MARK: Deciding

    mutating func accept(_ id: String) {
        guard blockedReason(id) == nil, let index = suggestions.firstIndex(where: { $0.id == id }),
              suggestions[index].state == .open else { return }
        let suggestion = suggestions[index]
        switch suggestion.target {
        case .answer(let answer): editing.setAnswer(answer, onStep: suggestion.stepId)
        case .rule(let branchId, let rule): editing.setRule(rule, branch: branchId, step: suggestion.stepId)
        }
        suggestions[index].state = .accepted
    }

    mutating func reject(_ id: String) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), suggestions[index].state == .open else { return }
        suggestions[index].state = .rejected
    }

    // MARK: Editing by hand

    mutating func setAnswer(_ answer: StepAnswer?, onStep stepId: String) {
        editing.setAnswer(answer, onStep: stepId)
    }

    mutating func setRule(_ rule: BranchRule?, branch branchId: String, step stepId: String) {
        editing.setRule(rule, branch: branchId, step: stepId)
    }

    mutating func removeRules(onStep stepId: String) {
        editing.removeRules(onStep: stepId)
    }

    /// After a save: what was saved is the new original, and the decided suggestions are cleared.
    mutating func saved() {
        editing = ProcedureEditing(editing.procedure)
        suggestions.removeAll { $0.state != .open }
    }

    // MARK: In words

    /// An answer in a line: its kind, label and the facts that matter for a rule.
    static func describe(_ answer: StepAnswer) -> String {
        var parts: [String] = []
        let label = answer.displayLabel
        switch answer.kind {
        case .number:
            parts.append(String(localized: "Number “\(label)”"))
            if let unit = answer.unit, !unit.isEmpty { parts.append(String(localized: "in \(unit)")) }
            parts.append(answer.places == 1 ? String(localized: "1 decimal") : String(localized: "\(answer.places) decimals"))
            if let range = answer.plausibleRange {
                parts.append(String(localized: "can be \(ExactDecimal.text(range.lowerBound)) to \(ExactDecimal.text(range.upperBound))"))
            }
            if let spec = answer.specText { parts.append(String(localized: "should be \(spec)")) }
        case .choice:
            let options = (answer.options ?? []).map(\.label).joined(separator: ", ")
            parts.append(String(localized: "Choice “\(label)”: \(options)"))
        case .yesNo:
            parts.append(String(localized: "Yes or no “\(label)”"))
        case .text:
            parts.append(String(localized: "Text “\(label)”"))
        case .photo:
            let bounds = answer.photoBounds
            parts.append(bounds.min == bounds.max
                ? String(localized: "\(bounds.min) photos “\(label)”")
                : String(localized: "\(bounds.min) to \(bounds.max) photos “\(label)”"))
        case .code:
            parts.append(answer.symbology == "qr" ? String(localized: "QR code “\(label)”") : String(localized: "Code “\(label)”"))
            if let expected = answer.expected, !expected.isEmpty { parts.append(String(localized: "expected \(expected)")) }
        case nil:
            parts.append(String(localized: "An answer of a kind this app doesn't read (\(answer.kindName))"))
        }
        if answer.isCritical { parts.append(String(localized: "critical")) }
        if !answer.isRequired { parts.append(String(localized: "optional")) }
        parts.append(String(localized: "recorded as \(answer.recordAs)"))
        return parts.joined(separator: ", ")
    }
}
