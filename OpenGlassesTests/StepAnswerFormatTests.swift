import XCTest
@testable import OpenGlasses

/// Plan MN P0: `answer` on a step and `when` on a branch read and write without disturbing any
/// procedure that doesn't use them.
final class StepAnswerFormatTests: XCTestCase {

    private func encode(_ procedure: Procedure) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(procedure)
    }

    func testAStepWithAnAnswerAndRuleBranchesDecodes() throws {
        let json = #"""
        {"id":"check_ph","title":"Check the pH","instruction":"Read it.",
         "answer":{"record_as":"ph","kind":"number","label":"pH","decimals":2,"plausible":[0,14],"spec":[3.8,4.4],"critical":true},
         "branches":[{"id":"high","condition":"pH above 4.4","when":{"answer":"ph","gt":4.4},"next":"x"}]}
        """#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(json.utf8))
        let answer = try XCTUnwrap(step.answer)
        XCTAssertEqual(answer.recordAs, "ph")
        XCTAssertEqual(answer.kind, .number)
        XCTAssertEqual(answer.places, 2)
        XCTAssertTrue(answer.isCritical)
        XCTAssertTrue(answer.isRequired, "required defaults to true")
        XCTAssertEqual(answer.specRange, Decimal(string: "3.8")!...Decimal(string: "4.4")!)
        XCTAssertEqual(step.branches.first?.when, .test(.init(answer: "ph", op: .gt, operand: .number(4.4))))
        XCTAssertEqual(step.routeDecider, .rules)
    }

    func testAStepWithoutTheNewKeysReadsAndWritesAsBefore() throws {
        let json = #"{"id":"a","title":"A","instruction":"Do it.","branches":[{"id":"x","condition":"looks like x","next":"b"}],"default_next":"b"}"#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(json.utf8))
        XCTAssertNil(step.answer)
        XCTAssertNil(step.branches.first?.when)
        XCTAssertEqual(step.routeDecider, .words)
        let encoded = String(decoding: try JSONEncoder().encode(step), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"answer\""))
        XCTAssertFalse(encoded.contains("\"when\""))
    }

    func testUnknownKeysInAnAnswerAndARuleAreIgnored() throws {
        let json = #"""
        {"id":"s","title":"S","instruction":"I.",
         "answer":{"record_as":"seal","kind":"yes_no","future_field":7},
         "branches":[{"id":"ok","condition":"Sealed","when":{"answer":"seal","is":"yes"},"next":"t","colour":"green"}]}
        """#
        let step = try JSONDecoder().decode(Procedure.Step.self, from: Data(json.utf8))
        XCTAssertEqual(step.answer?.kind, .yesNo)
        XCTAssertEqual(step.branches.first?.when, .test(.init(answer: "seal", op: .isAnswer, operand: .text("yes"))))
    }

    func testEveryShippedProcedureRoundTripsUnchanged() throws {
        let files = try ProcedureAnswerFixtures.allShippedProcedureFiles()
        XCTAssertGreaterThanOrEqual(files.count, 12, "bundled and example procedures found")
        for url in files {
            let decoded = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
            let once = try encode(decoded)
            let again = try JSONDecoder().decode(Procedure.self, from: once)
            XCTAssertEqual(again, decoded, url.lastPathComponent)
            XCTAssertEqual(try encode(again), once, "\(url.lastPathComponent) encodes byte-identically")
            if !ProcedureAnswerValidator.usesFormat(decoded) {
                let text = String(decoding: once, as: UTF8.self)
                XCTAssertFalse(text.contains("\"answer\"") || text.contains("\"when\""), url.lastPathComponent)
            }
        }
    }

    func testTheExampleKeepsItsAnswersAndRulesThroughARoundTrip() throws {
        let procedure = try ProcedureAnswerFixtures.exampleProcedure()
        let again = try JSONDecoder().decode(Procedure.self, from: try encode(procedure))
        XCTAssertEqual(again.step(id: "check_co2")?.answer, procedure.step(id: "check_co2")?.answer)
        XCTAssertEqual(again.step(id: "check_brix")?.branches.map(\.when), procedure.step(id: "check_brix")?.branches.map(\.when))
        XCTAssertEqual(procedure.steps.compactMap(\.answer).count, 8)
    }

    func testARuleThisBuildCannotReadIsMalformedNotADecodingFailure() throws {
        let cases: [(String, String)] = [
            (#"{"answer":"ph","gtt":4}"#, "unknown comparison"),
            (#"{"answer":"ph","gt":4,"lt":5}"#, "more than one comparison"),
            (#"{"gt":4}"#, "names the answer"),
            (#"{"answer":"ph","gt":"high"}"#, "needs a number"),
            (#"{"all":[]}"#, "at least one rule"),
            (#"{"all":[{"answer":"a","present":true}],"any":[]}"#, "one of all, any or not"),
            (#""text""#, "is an object"),
        ]
        for (json, expected) in cases {
            let rule = try JSONDecoder().decode(BranchRule.self, from: Data(json.utf8))
            guard case .malformed(let reason) = rule else { return XCTFail("\(json) read as \(rule)") }
            XCTAssertTrue(reason.contains(expected), "\(json): \(reason)")
        }
    }

    func testCombinationsDecodeAndCountTheirDepth() throws {
        let json = #"{"all":[{"answer":"brix","lt":10.5},{"not":{"any":[{"answer":"co2","gte":2.5},{"answer":"co2","present":false}]}}]}"#
        let rule = try JSONDecoder().decode(BranchRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.depth, 3)
        XCTAssertEqual(rule.answersNamed, ["brix", "co2", "co2"])
        let again = try JSONDecoder().decode(BranchRule.self, from: try JSONEncoder().encode(rule))
        XCTAssertEqual(again, rule)
    }

    func testAnUnknownKindIsKeptAsWrittenForTheValidator() throws {
        let answer = try JSONDecoder().decode(StepAnswer.self, from: Data(#"{"record_as":"x","kind":"slider"}"#.utf8))
        XCTAssertNil(answer.kind)
        XCTAssertEqual(answer.kindName, "slider")
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(answer), as: UTF8.self).contains("slider"))
    }

    func testRouteDeciderIsAllRulesOrWords() {
        let rule = BranchRule.test(.init(answer: "a", op: .present, operand: .flag(true)))
        let linear = Procedure.Step(id: "l", title: "L", instruction: "i", defaultNext: "n")
        let ruled = Procedure.Step(id: "r", title: "R", instruction: "i",
                                   branches: [.init(id: "x", condition: "c", next: "n", when: rule)])
        let mixed = Procedure.Step(id: "m", title: "M", instruction: "i",
                                   branches: [.init(id: "x", condition: "c", next: "n", when: rule),
                                              .init(id: "y", condition: "d", next: "n")])
        XCTAssertEqual(linear.routeDecider, .linear)
        XCTAssertEqual(ruled.routeDecider, .rules)
        XCTAssertEqual(mixed.routeDecider, .words, "a half-and-half step is never decided by rule")
    }

    func testExactDecimalsAreTheTextTheAuthorWrote() {
        XCTAssertEqual(ExactDecimal.from(4.4), Decimal(string: "4.4"))
        XCTAssertEqual(ExactDecimal.from(2.8), Decimal(string: "2.8"), "never 2.7999999999999998")
        XCTAssertEqual(ExactDecimal.text(Decimal(string: "4.6")!, places: 2), "4.60")
        XCTAssertEqual(ExactDecimal.text(Decimal(string: "4.449")!, places: 2), "4.45")
        XCTAssertEqual(ExactDecimal.text(Decimal(string: "-0.5")!, places: 0), "-1")
        XCTAssertEqual(ExactDecimal.text(Decimal(string: "12")!, places: 1), "12.0")
        XCTAssertNil(ExactDecimal.parse("4,2"))
    }

    func testTheFirstBuildThatReadsTheFormatIsTheNextOne() {
        XCTAssertEqual(ProcedureAnswerFormat.firstAppBuild, 738)
    }
}
