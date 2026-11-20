import XCTest
@testable import OpenGlasses

/// Plan MN P0: every comparison at its bounds, exact decimals, combinations, and the decision.
final class BranchRuleEvaluatorTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures

    private func holds(_ rule: BranchRule, _ answers: [String: KnownAnswer]) -> Bool {
        BranchRuleEvaluator.holds(rule, answers: answers)
    }

    private func ph(_ text: String) -> [String: KnownAnswer] { ["ph": F.number(text)] }

    func testGreaterThanIsExactAtTheBound() {
        let rule = F.test("ph", .gt, .number(4.4))
        XCTAssertFalse(holds(rule, ph("4.40")), "4.40 against gt 4.4 is false every time")
        XCTAssertFalse(holds(rule, ph("4.4")))
        XCTAssertTrue(holds(rule, ph("4.41")))
        XCTAssertFalse(holds(rule, ph("4.404")), "rounded to the step's 2 places first: 4.40")
        XCTAssertTrue(holds(rule, ph("4.405")), "4.405 rounds to 4.41")
    }

    func testAtLeastBelowAndAtMostAtTheirBounds() {
        XCTAssertTrue(holds(F.test("ph", .gte, .number(4.4)), ph("4.40")))
        XCTAssertFalse(holds(F.test("ph", .gte, .number(4.4)), ph("4.39")))
        XCTAssertFalse(holds(F.test("ph", .lt, .number(3.8)), ph("3.80")))
        XCTAssertTrue(holds(F.test("ph", .lt, .number(3.8)), ph("3.79")))
        XCTAssertTrue(holds(F.test("ph", .lte, .number(3.8)), ph("3.8")))
        XCTAssertFalse(holds(F.test("ph", .lte, .number(3.8)), ph("3.81")))
    }

    func testEqualAndNotEqualCompareExactly() {
        XCTAssertTrue(holds(F.test("ph", .eq, .number(7)), ph("7.00")))
        XCTAssertFalse(holds(F.test("ph", .eq, .number(7)), ph("7.01")))
        XCTAssertTrue(holds(F.test("ph", .ne, .number(7)), ph("7.01")))
        let sum = F.test("ph", .eq, .number(0.3))
        XCTAssertTrue(holds(sum, ph("0.3")), "0.3 is 0.3, never 0.30000000000000004")
    }

    func testBetweenAndOutsideIncludeBothBounds() {
        let between = F.test("ph", .between, .pair(3.8, 4.4))
        let outside = F.test("ph", .outside, .pair(3.8, 4.4))
        for (text, inside) in [("3.79", false), ("3.80", true), ("4.10", true), ("4.40", true), ("4.41", false)] {
            XCTAssertEqual(holds(between, ph(text)), inside, "between at \(text)")
            XCTAssertEqual(holds(outside, ph(text)), !inside, "outside at \(text)")
        }
        XCTAssertFalse(holds(F.test("ph", .between, .pair(4.4, 3.8)), ph("4.0")), "an inverted pair never holds")
    }

    func testInIsAndTextEquality() {
        let label = StepAnswer(recordAs: "label", kind: .choice, options: [
            .init(id: "ok", label: "Straight"), .init(id: "skewed", label: "Skewed")])
        let skewed = KnownAnswer(answer: label, value: .init(kind: .choice, entered: "crooked", option: "skewed"))
        XCTAssertTrue(holds(F.test("label", .inList, .list(["skewed", "missing"])), ["label": skewed]))
        XCTAssertFalse(holds(F.test("label", .inList, .list(["ok"])), ["label": skewed]))
        XCTAssertTrue(holds(F.test("label", .eq, .text("Skewed")), ["label": skewed]), "case-insensitive id")
        let yn = StepAnswer(recordAs: "clear", kind: .yesNo)
        let no = KnownAnswer(answer: yn, value: .init(kind: .yesNo, entered: "nope", option: "no"))
        XCTAssertTrue(holds(F.test("clear", .isAnswer, .text("no")), ["clear": no]))
        XCTAssertFalse(holds(F.test("clear", .isAnswer, .text("yes")), ["clear": no]))
        XCTAssertFalse(holds(F.test("clear", .gt, .number(1)), ["clear": no]), "a comparison that doesn't fit never holds")
    }

    func testOutOfSpecReadsTheRecordedStatus() {
        XCTAssertTrue(holds(F.test("ph", .outOfSpec, .flag(true)), ph("4.6")))
        XCTAssertFalse(holds(F.test("ph", .outOfSpec, .flag(false)), ph("4.6")))
        XCTAssertTrue(holds(F.test("ph", .outOfSpec, .flag(false)), ph("4.4")))
        let noSpec = StepAnswer(recordAs: "n", kind: .number, plausible: [0, 10])
        let five = KnownAnswer(answer: noSpec, value: .init(kind: .number, entered: "5", number: 5))
        XCTAssertFalse(holds(F.test("n", .outOfSpec, .flag(true)), ["n": five]))
        XCTAssertFalse(holds(F.test("n", .outOfSpec, .flag(false)), ["n": five]), "no spec: neither holds")
    }

    func testAMissingAnswerIsFalseExceptPresentFalse() {
        XCTAssertFalse(holds(F.test("brix", .lt, .number(11)), ph("4.0")))
        XCTAssertFalse(holds(F.test("brix", .present, .flag(true)), ph("4.0")))
        XCTAssertTrue(holds(F.test("brix", .present, .flag(false)), ph("4.0")))
        XCTAssertTrue(holds(F.test("ph", .present, .flag(true)), ph("4.0")))
        XCTAssertFalse(holds(F.test("ph", .present, .flag(false)), ph("4.0")))
        XCTAssertFalse(holds(.malformed("unknown"), ph("4.0")), "a rule that can't be read never holds")
    }

    func testAllAnyAndNotCombine() {
        let brix = StepAnswer(recordAs: "brix", kind: .number, label: "Brix", decimals: 1, plausible: [0, 30])
        var answers = ph("4.6")
        answers["brix"] = F.number("10.2", brix)
        let dump = BranchRule.all([F.test("brix", .lt, .number(10.5)), F.test("ph", .gt, .number(4.4))])
        XCTAssertTrue(holds(dump, answers))
        XCTAssertFalse(holds(.all([F.test("brix", .lt, .number(10)), F.test("ph", .gt, .number(4.4))]), answers))
        XCTAssertTrue(holds(.any([F.test("brix", .lt, .number(10)), F.test("ph", .gt, .number(4.4))]), answers))
        XCTAssertFalse(holds(.not(dump), answers))
        XCTAssertEqual(BranchRuleEvaluator.describe(dump, answers: answers),
                       "Brix 10.2 is below 10.5 and pH 4.60 is above 4.4")
    }

    func testTheFirstListedRuleThatHoldsWins() {
        let overlapping: [Procedure.Branch] = [
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
            .init(id: "high", condition: "pH 4.4 or above", next: "adjust_acid", when: F.test("ph", .gte, .number(4.4))),
        ]
        let step = try! XCTUnwrap(F.phProcedure(branches: overlapping).step(id: "check_ph"))
        guard case .branch(let branch, let text) = BranchRuleEvaluator.decide(step, answers: ph("4.40")) else {
            return XCTFail("a rule holds")
        }
        XCTAssertEqual(branch.id, "in_spec")
        XCTAssertEqual(text, "pH 4.40 is between 3.8 and 4.4")
    }

    func testTheRuleTextNamesTheValueAndTheBound() {
        let step = try! XCTUnwrap(F.phProcedure().step(id: "check_ph"))
        guard case .branch(let branch, let text) = BranchRuleEvaluator.decide(step, answers: ph("4.6")) else {
            return XCTFail("high holds")
        }
        XCTAssertEqual(branch.id, "high")
        XCTAssertEqual(text, "pH 4.60 is above 4.4")
    }

    func testNoRuleFollowsTheDefaultOrStopsAndSaysSo() {
        let gappy: [Procedure.Branch] = [
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
        ]
        let stopping = try! XCTUnwrap(F.phProcedure(branches: gappy).step(id: "check_ph"))
        XCTAssertEqual(BranchRuleEvaluator.decide(stopping, answers: ph("3.75")),
                       .noRuleMatched(reason: "pH 3.75 matches none of this step's routes"))
        let defaulting = try! XCTUnwrap(F.phProcedure(defaultNext: "hold_batch", branches: gappy).step(id: "check_ph"))
        XCTAssertEqual(BranchRuleEvaluator.decide(defaulting, answers: ph("3.75")),
                       .defaultNext("hold_batch", ruleText: "pH 3.75 matches none of this step's routes; the step's default route"))
    }

    func testNegatedRulesReadTheRightWayRound() {
        let answers = ph("4.6")
        XCTAssertEqual(BranchRuleEvaluator.describe(.not(F.test("ph", .between, .pair(3.8, 4.4))), answers: answers),
                       "pH 4.60 is not between 3.8 and 4.4")
        XCTAssertEqual(BranchRuleEvaluator.describe(F.test("ph", .outOfSpec, .flag(true)), answers: answers),
                       "pH 4.60 is out of spec (3.8 to 4.4)")
        XCTAssertEqual(BranchRuleEvaluator.describe(F.test("brix", .present, .flag(false)), answers: answers),
                       "no brix was recorded")
    }
}
