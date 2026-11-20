import Foundation

/// The import checks for typed answers and rule branches (Plan MN §7). Run from
/// `VaultValidator.validateProcedureGraph` (issues) and `VaultValidator.validate` (warnings), so the
/// importer and the authoring screens hold a procedure to the same rules. Pure.
///
/// Issues refuse the pack; warnings install it and tell the author where to look.
enum ProcedureAnswerValidator {

    struct Result: Equatable {
        var issues: [String] = []
        var warnings: [String] = []
    }

    /// Whether any step or branch uses the format, so a pack must set `minAppBuild`.
    static func usesFormat(_ procedure: Procedure) -> Bool {
        procedure.runs != nil
            || procedure.steps.contains { step in step.answer != nil || step.branches.contains { $0.when != nil } }
    }

    static func check(_ procedure: Procedure) -> Result {
        var result = Result()
        // §4: `runs` takes one value. Anything else is refused rather than read as "with the
        // assistant", which would quietly route a rule-only check through a model.
        if let runs = procedure.runs, runs != Procedure.runsWithoutAssistantValue {
            result.issues.append("runs is '\(runs)'; the only value it takes is \"\(Procedure.runsWithoutAssistantValue)\"")
        }
        var stepOfAnswer: [String: String] = [:]
        for step in procedure.steps {
            guard let answer = step.answer else { continue }
            checkAnswer(answer, on: step, into: &result)
            let name = answer.recordAs
            if !name.isEmpty {
                if let first = stepOfAnswer[name] {
                    result.issues.append("answer '\(name)' on step '\(step.id)' is already recorded by step '\(first)'; record_as is unique in a procedure")
                } else {
                    stepOfAnswer[name] = step.id
                }
            }
        }
        let graph = Graph(procedure)
        for step in procedure.steps {
            checkRules(on: step, procedure: procedure, stepOfAnswer: stepOfAnswer, graph: graph, into: &result)
        }
        return result
    }

    // MARK: - Answers

    static func isSnakeCase(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9]*(_[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    private static func checkAnswer(_ answer: StepAnswer, on step: Procedure.Step, into result: inout Result) {
        let at = "step '\(step.id)'"
        if answer.recordAs.isEmpty {
            result.issues.append("the answer on \(at) has no record_as")
        } else if !isSnakeCase(answer.recordAs) {
            result.issues.append("the answer on \(at) is recorded as '\(answer.recordAs)'; record_as is snake_case (letters, digits and underscores)")
        }
        guard let kind = answer.kind else {
            result.issues.append("the answer on \(at) has an unknown kind '\(answer.kindName)'; use number, choice, yes_no, text, photo or code")
            return
        }
        let stray = answer.kindSpecificKeys.filter { !StepAnswer.allowedKeys(for: kind).contains($0) }
        if !stray.isEmpty {
            result.issues.append("the \(kind.rawValue) answer on \(at) has fields of another kind: \(stray.joined(separator: ", "))")
        }
        switch kind {
        case .number:
            if let decimals = answer.decimals, !(0...3).contains(decimals) {
                result.issues.append("the number answer on \(at) has decimals \(decimals); use 0 to 3")
            }
            let plausible = pairIssue(answer.plausible, name: "plausible", strict: true)
            if answer.plausible == nil {
                result.issues.append("the number answer on \(at) needs plausible [lo, hi]: what a reading can be at all")
            } else if let issue = plausible {
                result.issues.append("the number answer on \(at): \(issue)")
            }
            if let issue = pairIssue(answer.spec, name: "spec", strict: false) {
                result.issues.append("the number answer on \(at): \(issue)")
            } else if let spec = answer.specRange, let range = answer.plausibleRange,
                      spec.lowerBound < range.lowerBound || spec.upperBound > range.upperBound {
                result.issues.append("the number answer on \(at): spec lies outside plausible")
            }
            if let unit = answer.unit, !unit.trimmingCharacters(in: .whitespaces).isEmpty,
               UnitNormalizer.canonical(value: 0, unit: unit) == nil,
               !commonUnits.contains(unit.trimmingCharacters(in: .whitespaces).lowercased()) {
                result.warnings.append("the number answer on \(at) has a unit the app doesn't know ('\(unit)'); it is printed as written")
            }
        case .choice:
            let options = answer.options ?? []
            if !(2...12).contains(options.count) {
                result.issues.append("the choice answer on \(at) has \(options.count) option\(options.count == 1 ? "" : "s"); use 2 to 12")
            }
            var ids = Set<String>()
            var owner: [String: String] = [:]
            for option in options {
                if option.id.trimmingCharacters(in: .whitespaces).isEmpty || option.label.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.issues.append("an option on \(at) has no id or no label")
                }
                if !ids.insert(option.id).inserted {
                    result.issues.append("option id '\(option.id)' is used twice on \(at)")
                }
                for word in Set(([option.id, option.label] + (option.says ?? [])).map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
                where !word.isEmpty {
                    if let other = owner[word], other != option.id {
                        result.issues.append("'\(word)' on \(at) is said for both '\(other)' and '\(option.id)'")
                    } else {
                        owner[word] = option.id
                    }
                }
            }
        case .photo:
            let bounds = answer.photoBounds
            if !(1...5).contains(bounds.min) || bounds.max > 5 || bounds.min > bounds.max {
                result.issues.append("the photo answer on \(at) takes min \(bounds.min) and max \(bounds.max); use 1 ≤ min ≤ max ≤ 5")
            }
        case .text:
            let bounds = answer.textBounds
            if bounds.min < 0 || bounds.min > bounds.max {
                result.issues.append("the text answer on \(at) has min_len \(bounds.min) and max_len \(bounds.max); min_len is at most max_len")
            }
        case .code:
            if let symbology = answer.symbology, !["qr", "barcode"].contains(symbology) {
                result.issues.append("the code answer on \(at) has symbology '\(symbology)'; use qr or barcode")
            }
        case .yesNo:
            break
        }
    }

    /// Units a procedure may use that are not conversions `UnitNormalizer` holds — counts and
    /// ratios the app prints as written without warning.
    private static let commonUnits: Set<String> = ["ph", "%", "ppm", "mm", "cm", "m", "ml", "l", "s", "min", "nm", "n·m", "rpm"]

    private static func pairIssue(_ pair: [Double]?, name: String, strict: Bool) -> String? {
        guard let pair else { return nil }
        guard pair.count == 2 else { return "\(name) is [lo, hi]" }
        let lo = ExactDecimal.from(pair[0]), hi = ExactDecimal.from(pair[1])
        if strict ? lo >= hi : lo > hi { return "\(name) has lo \(strict ? "≥" : ">") hi" }
        return nil
    }

    // MARK: - Rules

    private static func checkRules(on step: Procedure.Step, procedure: Procedure,
                                   stepOfAnswer: [String: String], graph: Graph,
                                   into result: inout Result) {
        let ruled = step.branches.filter { $0.when != nil }
        guard !ruled.isEmpty else { return }
        let at = "step '\(step.id)'"
        if ruled.count != step.branches.count {
            result.issues.append("\(at) mixes rule branches and branches chosen from words; give every branch a 'when' rule or none (decision 2)")
        }
        let answers = Dictionary(procedure.steps.compactMap { s in s.answer.map { ($0.recordAs, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        for branch in ruled {
            guard let rule = branch.when else { continue }
            let on = "branch '\(branch.id)' on \(at)"
            for reason in rule.malformedReasons { result.issues.append("\(on): \(reason)") }
            if rule.depth > 3 { result.issues.append("\(on): its rule nests \(rule.depth) deep; at most 3") }
            for test in rule.tests {
                guard let answer = answers[test.answer], let source = stepOfAnswer[test.answer] else {
                    result.issues.append("\(on) reads '\(test.answer)', which no step records")
                    continue
                }
                if source != step.id {
                    if !graph.canReach(from: source, to: step.id) {
                        result.issues.append("\(on) reads '\(test.answer)', which is recorded on step '\(source)' — a step that never comes before it")
                    } else if graph.reachableAvoiding(source, to: step.id) {
                        result.warnings.append("\(on) reads '\(test.answer)', which is recorded only on some paths to it (step '\(source)'); on the others the test is false")
                    }
                }
                if let issue = fitIssue(test, answer: answer) { result.issues.append("\(on): \(issue)") }
            }
            if let warning = conditionWarning(branch, rule: rule, answers: answers) {
                result.warnings.append("\(on): \(warning)")
            }
        }
        for finding in RuleCoverage.check(step) {
            result.warnings.append("\(at): \(finding.message)")
        }
    }

    /// Whether the test's op fits the answer's kind and its operand (§7).
    static func fitIssue(_ test: BranchRule.Test, answer: StepAnswer) -> String? {
        guard let kind = answer.kind else { return nil }   // reported on the answer itself
        let name = "'\(test.op.rawValue)' on the \(kind.rawValue) answer '\(test.answer)'"
        switch test.op {
        case .present:
            return nil
        case .outOfSpec:
            return answer.hasSpec ? nil : "\(name) — the answer has no spec to be out of"
        case .lt, .lte, .gt, .gte, .between, .outside:
            guard kind == .number else { return "\(name) doesn't fit; it compares numbers" }
            if case .pair(let lo, let hi) = test.operand, ExactDecimal.from(lo) > ExactDecimal.from(hi) {
                return "\(name) has lo > hi"
            }
            return nil
        case .eq, .ne:
            switch (kind, test.operand) {
            case (.number, .number): return nil
            case (.choice, .text(let id)), (.yesNo, .text(let id)):
                return answer.buttons.contains { $0.id == id } ? nil : "\(name) names '\(id)', which isn't one of its options"
            case (.text, .text), (.code, .text): return nil
            default: return "\(name) doesn't fit its value"
            }
        case .inList:
            guard kind == .choice else { return "\(name) doesn't fit; 'in' is for a choice" }
            guard case .list(let ids) = test.operand, !ids.isEmpty else { return "\(name) lists no options" }
            let unknown = ids.filter { id in !(answer.options ?? []).contains { $0.id == id } }
            return unknown.isEmpty ? nil : "\(name) names \(unknown.joined(separator: ", ")), not among its options"
        case .isAnswer:
            guard kind == .yesNo else { return "\(name) doesn't fit; 'is' is for a yes_no answer" }
            guard case .text(let value) = test.operand, ["yes", "no"].contains(value.lowercased()) else {
                return "\(name) is \"yes\" or \"no\""
            }
            return nil
        }
    }

    /// A `condition` whose numbers its rule doesn't test ("pH above 4.5" over `gt 4.4`).
    static func conditionWarning(_ branch: Procedure.Branch, rule: BranchRule,
                                 answers: [String: StepAnswer]) -> String? {
        let written = numbers(in: branch.condition)
        guard !written.isEmpty else { return nil }
        var tested = Set<Decimal>()
        for test in rule.tests {
            switch test.operand {
            case .number(let n): tested.insert(ExactDecimal.from(n))
            case .pair(let lo, let hi): tested.insert(ExactDecimal.from(lo)); tested.insert(ExactDecimal.from(hi))
            default: break
            }
            if test.op == .outOfSpec, let spec = answers[test.answer]?.specRange {
                tested.insert(spec.lowerBound); tested.insert(spec.upperBound)
            }
        }
        let untested = written.filter { !tested.contains($0) }
        guard !untested.isEmpty else { return nil }
        let shown = untested.map { ExactDecimal.text($0) }.joined(separator: ", ")
        return "its condition \"\(branch.condition)\" says \(shown), which its rule doesn't test; check the two say the same thing"
    }

    private static func numbers(in text: String) -> [Decimal] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z])-?\d+(?:[.,]\d+)?"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { ExactDecimal.parse(String(text[$0]).replacingOccurrences(of: ",", with: ".")) }
        }
    }

    // MARK: - Graph

    /// The procedure's step graph, for "can this answer come before that rule".
    struct Graph {
        let entry: String?
        let edges: [String: [String]]

        init(_ procedure: Procedure) {
            entry = procedure.entry?.id
            var edges: [String: [String]] = [:]
            for step in procedure.steps {
                edges[step.id] = step.branches.map(\.next) + (step.defaultNext.map { [$0] } ?? [])
            }
            self.edges = edges
        }

        /// Whether a path leads from `from` to `to` (and `from` is reachable from the entry).
        func canReach(from: String, to: String) -> Bool {
            guard let entry, reachable(from: entry, avoiding: nil).contains(from) else { return false }
            return reachable(from: from, avoiding: nil, startExcluded: true).contains(to)
        }

        /// Whether `to` is reachable from the entry without passing through `avoid`.
        func reachableAvoiding(_ avoid: String, to: String) -> Bool {
            guard let entry, entry != avoid else { return false }
            return reachable(from: entry, avoiding: avoid).contains(to)
        }

        private func reachable(from start: String, avoiding: String?, startExcluded: Bool = false) -> Set<String> {
            var seen = Set<String>()
            var queue = startExcluded ? (edges[start] ?? []) : [start]
            while let id = queue.popLast() {
                guard id != avoiding, seen.insert(id).inserted else { continue }
                queue.append(contentsOf: edges[id] ?? [])
            }
            return seen
        }
    }
}
