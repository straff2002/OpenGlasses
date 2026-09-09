import XCTest
@testable import OpenGlasses

/// The safety-evaluation gate (W08.4).
///
/// One test per vertical, each running the corpus through the real handling path and failing when a
/// blocking threshold is breached — with the whole report attached, because a gate that says only
/// "false-negative rate 8.3%" makes the reader run it again locally to find out which case.
///
/// The thresholds these tests enforce are PROPOSED, not approved. `thresholds.json` says so in a
/// field this suite asserts is present and non-empty, and the attached report repeats it at the top.
/// A green run here means the app did not regress against a corpus of invented scenes; it does not
/// mean an approved bar was met, and it is not evidence about any real scene.
final class SafetyEvalGateTests: XCTestCase {

    // MARK: - Per-vertical gates

    func testSafetyAssessmentVerticalMeetsThresholds() throws {
        try assertVertical("safety_assessment")
    }

    func testFirstAidTriageVerticalMeetsThresholds() throws {
        try assertVertical("first_aid_triage")
    }

    func testInstrumentReadingVerticalMeetsThresholds() throws {
        try assertVertical("instrument_reading")
    }

    func testHealthSafetyAdvisorVerticalMeetsThresholds() throws {
        try assertVertical("health_safety_advisor")
    }

    /// The whole corpus in one report, written where `Scripts/safety-eval-report.sh` reads it.
    func testWholeCorpusReportIsProducedAndCarriesNoBlockingBreach() throws {
        let (corpus, thresholds) = try load()
        let report = SafetyEvalHarness.run(corpus, thresholds: thresholds)
        report.write(named: "safety-eval-report.md")
        attach(report, named: "safety-eval-report-full")

        XCTAssertTrue(report.riskClassesWithoutThresholds.isEmpty,
                      "risk classes with no threshold defined: \(report.riskClassesWithoutThresholds.joined(separator: ", "))")
        XCTAssertTrue(report.blockingBreaches.isEmpty, failureMessage(report))
    }

    /// A case failing outside the blocking risk classes is a review item, not a safety regression —
    /// so it fails here, by itself, and a reader of a red run can tell the two apart by which test
    /// went red.
    func testNoCaseFailsOutsideTheBlockingRiskClasses() throws {
        let (corpus, thresholds) = try load()
        let report = SafetyEvalHarness.run(corpus, thresholds: thresholds)
        let strays = report.failures.filter { !thresholds.blockingRiskClasses.contains($0.riskClass) }
        guard !strays.isEmpty else { return }
        attach(report, named: "safety-eval-report-non-blocking-failures")
        XCTFail("""
        \(strays.count) non-blocking case(s) failed. These do not breach a safety threshold, but the \
        corpus says the app should behave differently from how it now does:
        \(strays.map { "  \($0.caseID): \($0.failures.joined(separator: "; "))" }.joined(separator: "\n"))
        """)
    }

    // MARK: - Corpus integrity

    func testCorpusAndThresholdsParseAndEveryCaseIdIsUnique() throws {
        let (corpus, thresholds) = try load()

        XCTAssertFalse(corpus.version.isEmpty)
        XCTAssertFalse(corpus.schemaVersion.isEmpty)
        XCTAssertFalse(corpus.licence.isEmpty, "the corpus must state its licence")
        XCTAssertTrue(corpus.licence.lowercased().contains("synthetic"),
                      "the licence statement must say the cases are synthetic")
        XCTAssertFalse(thresholds.status.isEmpty, "thresholds must state their approval status")
        XCTAssertTrue(thresholds.status.lowercased().contains("not approved"),
                      "thresholds must not be presented as approved until they are")

        XCTAssertGreaterThanOrEqual(corpus.cases.count, 40,
                                    "the corpus is smaller than the coverage this row claims")

        var seen: Set<String> = []
        for testCase in corpus.cases {
            XCTAssertTrue(seen.insert(testCase.id).inserted, "duplicate case id '\(testCase.id)'")
            XCTAssertTrue(corpus.verticals.contains(testCase.vertical),
                          "\(testCase.id): undeclared vertical '\(testCase.vertical)'")
            XCTAssertTrue(corpus.riskClasses.contains(testCase.riskClass),
                          "\(testCase.id): undeclared risk class '\(testCase.riskClass)'")
            XCTAssertNotNil(thresholds.byRiskClass[testCase.riskClass],
                            "\(testCase.id): risk class '\(testCase.riskClass)' has no threshold")
        }

        for vertical in corpus.verticals {
            XCTAssertFalse(corpus.cases(inVertical: vertical).isEmpty,
                           "vertical '\(vertical)' is declared and has no cases")
        }
    }

    func testEverySubgroupTagHasAtLeastOneCase() throws {
        let (corpus, _) = try load()

        for (dimension, declared) in corpus.subgroupDimensions.sorted(by: { $0.key < $1.key }) {
            let used = Set(corpus.cases.compactMap { $0.subgroups[dimension] })
            for value in declared {
                XCTAssertTrue(used.contains(value),
                              "subgroup \(dimension)=\(value) is declared and has no case — a coverage claim the corpus does not meet")
            }
            for value in used.sorted() {
                XCTAssertTrue(declared.contains(value),
                              "subgroup \(dimension)=\(value) is used by a case and is not declared in corpus.json")
            }
            XCTAssertEqual(Set(corpus.cases.compactMap { $0.subgroups[dimension] }).count, used.count)
        }

        // Every case carries every declared dimension: a case with no language tag would silently
        // vanish from that subgroup's denominator rather than showing up as uncovered.
        for testCase in corpus.cases {
            for dimension in corpus.subgroupDimensions.keys {
                XCTAssertNotNil(testCase.subgroups[dimension],
                                "\(testCase.id) has no '\(dimension)' subgroup tag")
            }
        }
    }

    // MARK: - Helpers

    private func load() throws -> (SafetyEvalCorpus, SafetyEvalThresholds) {
        (try SafetyEvalCorpusLoader.load(), try SafetyEvalCorpusLoader.loadThresholds())
    }

    private func assertVertical(_ vertical: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (corpus, thresholds) = try load()
        let cases = corpus.cases(inVertical: vertical)
        XCTAssertFalse(cases.isEmpty, "no cases for '\(vertical)'", file: file, line: line)

        let report = SafetyEvalHarness.run(corpus, thresholds: thresholds, verticals: [vertical])
        report.write(named: "safety-eval-report-\(vertical).md")
        attach(report, named: "safety-eval-report-\(vertical)")

        let blockingFailures = report.failures.filter { thresholds.blockingRiskClasses.contains($0.riskClass) }
        XCTAssertTrue(report.blockingBreaches.isEmpty && blockingFailures.isEmpty,
                      failureMessage(report), file: file, line: line)
    }

    private func attach(_ report: SafetyEvalReport, named name: String) {
        let attachment = XCTAttachment(string: report.markdown)
        attachment.name = "\(name).md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Markdown summary a reviewer reads in the failure itself, so a red CI job is actionable
    /// without downloading the result bundle.
    private func failureMessage(_ report: SafetyEvalReport) -> String {
        var lines = ["", "Safety evaluation gate failed.", ""]
        if !report.blockingBreaches.isEmpty {
            lines.append("Blocking threshold breaches:")
            lines += report.blockingBreaches.map { "  - \($0.line)" }
            lines.append("")
        }
        let failures = report.failures
        if !failures.isEmpty {
            lines.append("Failing cases:")
            for failure in failures {
                lines.append("  - \(failure.caseID) (\(failure.riskClass)): \(failure.failures.joined(separator: "; "))")
            }
            lines.append("")
        }
        lines.append("Full report:")
        lines.append("")
        lines.append(report.markdown)
        return lines.joined(separator: "\n")
    }
}
