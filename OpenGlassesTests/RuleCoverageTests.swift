import XCTest
@testable import OpenGlasses

/// Plan MN P0: gaps and overlaps in a number step's rules, across `plausible` at `decimals`.
final class RuleCoverageTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures

    private func step(_ branches: [Procedure.Branch], defaultNext: String? = nil) -> Procedure.Step {
        F.phProcedure(defaultNext: defaultNext, branches: branches).step(id: "check_ph")!
    }

    func testThePlansOwnStepCoversEveryReading() {
        let full = F.phProcedure().step(id: "check_ph")!
        XCTAssertTrue(RuleCoverage.applies(to: full))
        XCTAssertEqual(RuleCoverage.check(full), [])
    }

    func testAGapIsFoundAtTheFirstValueNoRuleTakes() {
        let gappy = step([
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
            .init(id: "high", condition: "pH above 4.4", next: "adjust_acid", when: F.test("ph", .gt, .number(4.4))),
        ])
        let findings = RuleCoverage.check(gappy)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.kind, .gap)
        XCTAssertEqual(findings.first?.value, 0, "the stretch from the bottom of plausible")
        XCTAssertEqual(findings.first?.message, "a pH of 0.00 matches no route and there is no default")
    }

    func testAGapInTheMiddleNamesItsFirstValue() {
        let gappy = step([
            .init(id: "low", condition: "pH below 3.8", next: "hold_batch", when: F.test("ph", .lt, .number(3.8))),
            .init(id: "rest", condition: "pH 3.8 to 14", next: "record_brix", when: F.test("ph", .gte, .number(3.81))),
        ])
        XCTAssertEqual(RuleCoverage.check(gappy).map(\.message), ["a pH of 3.80 matches no route and there is no default"])
    }

    func testAnOverlapIsAWarningThatTheFirstWins() {
        let overlapping = step([
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
            .init(id: "high", condition: "pH 4.4 or above", next: "adjust_acid", when: F.test("ph", .gte, .number(4.4))),
            .init(id: "low", condition: "pH below 3.8", next: "hold_batch", when: F.test("ph", .lt, .number(3.8))),
        ])
        let findings = RuleCoverage.check(overlapping)
        XCTAssertEqual(findings.map(\.kind), [.overlap])
        XCTAssertEqual(findings.first?.message, "4.40 matches both in_spec and high; the first listed wins")
        XCTAssertEqual(findings.first?.branchIds, ["in_spec", "high"])
    }

    func testADefaultMeansNoGap() {
        let defaulted = step([
            .init(id: "high", condition: "pH above 4.4", next: "adjust_acid", when: F.test("ph", .gt, .number(4.4))),
        ], defaultNext: "record_brix")
        XCTAssertEqual(RuleCoverage.check(defaulted), [])
    }

    func testRulesThatReadAnotherAnswerAreNotChecked() {
        let crossing = step([
            .init(id: "dump", condition: "pH above 4.4 and brix low", next: "hold_batch",
                  when: .all([F.test("ph", .gt, .number(4.4)), F.test("brix", .lt, .number(10.5))])),
        ])
        XCTAssertFalse(RuleCoverage.applies(to: crossing))
        XCTAssertEqual(RuleCoverage.check(crossing), [])
    }

    func testOutOfSpecRulesCoverTheWholeRange() throws {
        let example = try F.exampleProcedure()
        for id in ["check_co2", "check_fill_height", "check_cap_torque"] {
            let step = try XCTUnwrap(example.step(id: id))
            XCTAssertTrue(RuleCoverage.applies(to: step), id)
            XCTAssertEqual(RuleCoverage.check(step), [], id)
        }
    }
}
