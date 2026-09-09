import Foundation
@testable import OpenGlasses

/// What a corpus run produced, aggregated the ways a reviewer needs to read it (W08.4).
///
/// Four rates, each with its own denominator and each meaning one thing. There is deliberately no
/// combined score: an average over a false-negative rate and an escalation rate is a number with no
/// referent, and the first thing anyone would do with it is quote it.
struct SafetyEvalReport {

    let corpusVersion: String
    let thresholds: SafetyEvalThresholds
    let outcomes: [SafetyEvalOutcome]

    // MARK: - Aggregation

    struct Aggregate {
        var cases = 0
        var passed = 0

        var hazardCases = 0
        var falseNegatives = 0
        var certaintyCases = 0
        var overconfident = 0
        var abstentionRequired = 0
        var abstentionDelivered = 0
        var escalationRequired = 0
        var escalationPresent = 0

        var failed: Int { cases - passed }

        /// `nil` where the denominator is empty. An absent rate is reported as "—", never as 0:
        /// "no case asked" and "every case passed" are different facts.
        var falseNegativeRate: Double? { rate(falseNegatives, hazardCases) }
        var overconfidenceRate: Double? { rate(overconfident, certaintyCases) }
        var abstentionWhenRequiredRate: Double? { rate(abstentionDelivered, abstentionRequired) }
        var escalationPresentRate: Double? { rate(escalationPresent, escalationRequired) }

        private func rate(_ numerator: Int, _ denominator: Int) -> Double? {
            denominator == 0 ? nil : Double(numerator) / Double(denominator)
        }

        mutating func add(_ outcome: SafetyEvalOutcome) {
            cases += 1
            if outcome.passed { passed += 1 }
            if outcome.hazardExpected {
                hazardCases += 1
                if outcome.falseNegative { falseNegatives += 1 }
            }
            if outcome.certaintyScored {
                certaintyCases += 1
                if outcome.overconfident { overconfident += 1 }
            }
            if outcome.abstentionRequired {
                abstentionRequired += 1
                if outcome.abstentionDelivered { abstentionDelivered += 1 }
            }
            if outcome.escalationRequired {
                escalationRequired += 1
                if outcome.escalationPresent { escalationPresent += 1 }
            }
        }
    }

    var overall: Aggregate {
        outcomes.reduce(into: Aggregate()) { $0.add($1) }
    }

    var byVertical: [(name: String, aggregate: Aggregate)] {
        group(by: \.vertical)
    }

    var byRiskClass: [(name: String, aggregate: Aggregate)] {
        group(by: \.riskClass)
    }

    /// dimension → (value, aggregate), both in a stable order so two runs produce identical reports.
    var bySubgroup: [(dimension: String, rows: [(name: String, aggregate: Aggregate)])] {
        let dimensions = Set(outcomes.flatMap { $0.subgroups.keys }).sorted()
        return dimensions.map { dimension in
            var buckets: [String: Aggregate] = [:]
            for outcome in outcomes {
                guard let value = outcome.subgroups[dimension] else { continue }
                buckets[value, default: Aggregate()].add(outcome)
            }
            return (dimension, buckets.keys.sorted().map { ($0, buckets[$0]!) })
        }
    }

    private func group(by key: KeyPath<SafetyEvalOutcome, String>) -> [(name: String, aggregate: Aggregate)] {
        var buckets: [String: Aggregate] = [:]
        for outcome in outcomes { buckets[outcome[keyPath: key], default: Aggregate()].add(outcome) }
        return buckets.keys.sorted().map { ($0, buckets[$0]!) }
    }

    var failures: [SafetyEvalOutcome] { outcomes.filter { !$0.passed } }

    // MARK: - Thresholds

    struct Breach {
        let riskClass: String
        let metric: String
        let measured: Double
        let limit: Double
        let blocking: Bool

        var line: String {
            "\(riskClass): \(metric) \(SafetyEvalReport.percent(measured)) against a limit of \(SafetyEvalReport.percent(limit))"
        }
    }

    var breaches: [Breach] {
        var found: [Breach] = []
        for (name, aggregate) in byRiskClass {
            guard let limits = thresholds.byRiskClass[name] else {
                continue
            }
            let blocking = thresholds.blockingRiskClasses.contains(name)
            if let rate = aggregate.falseNegativeRate, rate > limits.maxFalseNegativeRate {
                found.append(Breach(riskClass: name, metric: "false-negative rate", measured: rate,
                                    limit: limits.maxFalseNegativeRate, blocking: blocking))
            }
            if let rate = aggregate.overconfidenceRate, rate > limits.maxOverconfidenceRate {
                found.append(Breach(riskClass: name, metric: "overconfidence rate", measured: rate,
                                    limit: limits.maxOverconfidenceRate, blocking: blocking))
            }
            if let rate = aggregate.abstentionWhenRequiredRate, rate < limits.minAbstentionWhenRequiredRate {
                found.append(Breach(riskClass: name, metric: "abstention-when-required rate", measured: rate,
                                    limit: limits.minAbstentionWhenRequiredRate, blocking: blocking))
            }
            if let rate = aggregate.escalationPresentRate, rate < limits.minEscalationPresentRate {
                found.append(Breach(riskClass: name, metric: "escalation-present rate", measured: rate,
                                    limit: limits.minEscalationPresentRate, blocking: blocking))
            }
        }
        return found
    }

    var blockingBreaches: [Breach] { breaches.filter(\.blocking) }

    /// A risk class in the corpus that thresholds.json says nothing about is itself a defect: it
    /// would be evaluated and then silently not gated.
    var riskClassesWithoutThresholds: [String] {
        byRiskClass.map(\.name).filter { thresholds.byRiskClass[$0] == nil }
    }

    // MARK: - Markdown

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func percent(_ value: Double?) -> String {
        value.map(percent) ?? "—"
    }

    var markdown: String {
        var out: [String] = []
        out.append("# Safety evaluation report")
        out.append("")
        out.append("Corpus version **\(corpusVersion)** · \(outcomes.count) cases · \(overall.failed) failing")
        out.append("")
        out.append("> **Thresholds are proposed, not approved.** \(thresholds.status)")
        out.append("")
        out.append("Every rate below is measured over this synthetic corpus only. There is no overall")
        out.append("accuracy figure here, and none should be derived from these numbers.")
        out.append("")

        out.append("## Per vertical")
        out.append("")
        out += table(byVertical, firstColumn: "Vertical")
        out.append("")

        out.append("## Per risk class")
        out.append("")
        out += table(byRiskClass, firstColumn: "Risk class")
        out.append("")

        for (dimension, rows) in bySubgroup {
            out.append("## Subgroup — \(dimension)")
            out.append("")
            out += table(rows, firstColumn: dimension)
            out.append("")
        }

        out.append("## Thresholds")
        out.append("")
        out.append("| Risk class | Max false-negative | Max overconfidence | Min abstention | Min escalation | Blocking | Verdict |")
        out.append("| --- | --- | --- | --- | --- | --- | --- |")
        for (name, _) in byRiskClass {
            guard let limits = thresholds.byRiskClass[name] else {
                out.append("| \(name) | — | — | — | — | — | **no threshold defined** |")
                continue
            }
            let classBreaches = breaches.filter { $0.riskClass == name }
            let verdict = classBreaches.isEmpty ? "within limits" : "**breached**"
            let blocking = thresholds.blockingRiskClasses.contains(name) ? "yes" : "no"
            out.append("| \(name) | \(Self.percent(limits.maxFalseNegativeRate)) | \(Self.percent(limits.maxOverconfidenceRate)) | \(Self.percent(limits.minAbstentionWhenRequiredRate)) | \(Self.percent(limits.minEscalationPresentRate)) | \(blocking) | \(verdict) |")
        }
        out.append("")

        if !breaches.isEmpty {
            out.append("## Breaches")
            out.append("")
            for breach in breaches {
                out.append("- \(breach.blocking ? "**BLOCKING** " : "")\(breach.line)")
            }
            out.append("")
        }

        if !failures.isEmpty {
            out.append("## Failing cases")
            out.append("")
            for failure in failures {
                out.append("### \(failure.caseID) (\(failure.vertical), \(failure.riskClass))")
                for reason in failure.failures { out.append("- \(reason)") }
                if let notes = failure.notes { out.append("") ; out.append("> \(notes)") }
                if !failure.renderedText.isEmpty {
                    out.append("")
                    out.append("```")
                    out.append(failure.renderedText)
                    out.append("```")
                }
                out.append("")
            }
        }

        return out.joined(separator: "\n") + "\n"
    }

    private func table(_ rows: [(name: String, aggregate: Aggregate)], firstColumn: String) -> [String] {
        var out: [String] = []
        out.append("| \(firstColumn) | Cases | Failed | False-negative | Overconfidence | Abstention when required | Escalation present |")
        out.append("| --- | --- | --- | --- | --- | --- | --- |")
        for (name, aggregate) in rows {
            out.append("| \(name) | \(aggregate.cases) | \(aggregate.failed) "
                + "| \(Self.percent(aggregate.falseNegativeRate)) (\(aggregate.falseNegatives)/\(aggregate.hazardCases)) "
                + "| \(Self.percent(aggregate.overconfidenceRate)) (\(aggregate.overconfident)/\(aggregate.certaintyCases)) "
                + "| \(Self.percent(aggregate.abstentionWhenRequiredRate)) (\(aggregate.abstentionDelivered)/\(aggregate.abstentionRequired)) "
                + "| \(Self.percent(aggregate.escalationPresentRate)) (\(aggregate.escalationPresent)/\(aggregate.escalationRequired)) |")
        }
        return out
    }

    // MARK: - Where the run leaves it

    /// `<repo>/.safety-eval/safety-eval-report.md`, so `Scripts/safety-eval-report.sh` can print the
    /// same summary a CI failure attaches. Gitignored: it is a run artefact, not a tracked one.
    @discardableResult
    func write(named name: String) -> URL? {
        let directory = SafetyEvalCorpusLoader.directory
            .deletingLastPathComponent()      // Fixtures
            .deletingLastPathComponent()      // OpenGlassesTests
            .deletingLastPathComponent()      // <repo>
            .appendingPathComponent(".safety-eval", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
