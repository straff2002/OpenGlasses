import XCTest
@testable import OpenGlasses

/// Plan MN P3 — the *conditions to rules* prompt kit and its reply: what the prompt asks, what the
/// parser takes (tolerant of fences and prose, strict on the shape), what it refuses and why, and
/// the review that lands each proposal beside its sentence and changes nothing until it is
/// accepted. Invented procedures and replies only.
@MainActor
final class RuleProposalParserTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures

    /// check_ph chooses its route from words and has no answer; seal_check chooses from words
    /// with a yes/no answer of its own.
    private func procedure() -> Procedure {
        let base = F.phProcedure()
        let step = base.step(id: "check_ph")!
        let words = step.with(answer: nil).with(branches: step.branches.map { $0.with(when: nil) })
        let seal = Procedure.Step(id: "seal_check", title: "Check the seal", instruction: "Look at the seal.",
                                  branches: [.init(id: "sealed", condition: "Seal is fine", next: "done"),
                                             .init(id: "broken", condition: "Seal is broken", next: "hold_batch")],
                                  answer: StepAnswer(recordAs: "seal_ok", kind: .yesNo, label: "Seal OK"))
        var steps = base.replacing(words).steps
        steps.insert(seal, at: 2)
        let brix = steps.firstIndex { $0.id == "record_brix" }!
        steps[brix] = Procedure.Step(id: "record_brix", title: "Record the Brix", instruction: "Read the refractometer.",
                                     defaultNext: "seal_check")
        return base.with(steps: steps)
    }

    private let phReply = """
    {"steps": [{"step": "check_ph",
      "answer": {"record_as": "ph", "kind": "number", "label": "pH", "decimals": 2, "plausible": [0, 14], "spec": [3.8, 4.4]},
      "branches": [
        {"branch": "in_spec", "when": {"answer": "ph", "between": [3.8, 4.4]}},
        {"branch": "high", "when": {"answer": "ph", "gt": 4.4}},
        {"branch": "low", "when": {"answer": "ph", "lt": 3.8}}]}]}
    """

    // MARK: - The prompt

    func testThePromptNamesEachStepChosenFromWordsWithItsRoutesAndTheShape() {
        let prompt = OpenGlasses.PromptKit.conditionsToRules(procedure())
        XCTAssertTrue(prompt.contains("Step check_ph: Check the pH"))
        XCTAssertTrue(prompt.contains("- high: \"pH above 4.4\""))
        XCTAssertTrue(prompt.contains("Its answer: none yet"))
        XCTAssertTrue(prompt.contains("record_as seal_ok, yes_no"), "an answer already recorded is listed for rules to read")
        XCTAssertTrue(prompt.contains("all rules or none"))
        XCTAssertTrue(prompt.contains(OpenGlasses.PromptKit.conditionsToRulesFormat))
        XCTAssertFalse(prompt.contains("Step record_brix"), "a step with no routes isn't asked about")
    }

    func testAStepAlreadyDecidedByRulesIsLeftOutOfThePrompt() {
        let prompt = OpenGlasses.PromptKit.conditionsToRules(F.phProcedure())
        XCTAssertFalse(prompt.contains("Step check_ph"))
        XCTAssertTrue(OpenGlasses.PromptKit.stepsToRule(F.phProcedure()).isEmpty)
    }

    // MARK: - Tolerant around the JSON

    func testAReplyInAFenceWithProseAroundItIsRead() {
        let reply = "Sure! Here are the rules:\n\n```json\n\(phReply)\n```\n\nLet me know if you need more."
        let parsed = RuleProposalParser.parse(reply, procedure: procedure())
        XCTAssertEqual(parsed.rejected, [])
        XCTAssertEqual(parsed.steps.count, 1)
        XCTAssertEqual(parsed.steps.first?.answer?.recordAs, "ph")
        XCTAssertEqual(parsed.steps.first?.rules.map(\.branchId), ["in_spec", "high", "low"])
        XCTAssertEqual(parsed.steps.first?.rules[1].rule, F.test("ph", .gt, .number(4.4)))
    }

    func testAReplyWithNoJSONSaysSo() {
        let parsed = RuleProposalParser.parse("I couldn't find any rules.", procedure: procedure())
        XCTAssertTrue(parsed.steps.isEmpty)
        XCTAssertEqual(parsed.rejected.first?.stepId, nil)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("no JSON") == true)
    }

    // MARK: - Strict inside it

    func testAnUnknownKeyAnywhereIsRefusedWithItsName() {
        let top = RuleProposalParser.parse(#"{"steps": [], "notes": "x"}"#, procedure: procedure())
        XCTAssertTrue(top.rejected.first?.reason.contains("\"notes\"") == true)
        let step = RuleProposalParser.parse(#"{"steps": [{"step": "check_ph", "why": "x", "branches": []}]}"#, procedure: procedure())
        XCTAssertTrue(step.rejected.first?.reason.contains("\"why\"") == true)
        let answer = RuleProposalParser.parse(#"""
        {"steps": [{"step": "check_ph", "answer": {"record_as": "ph", "kind": "number", "plausible": [0, 14], "range": [1, 2]}}]}
        """#, procedure: procedure())
        XCTAssertTrue(answer.rejected.first?.reason.contains("\"range\"") == true)
        XCTAssertTrue(answer.steps.isEmpty)
    }

    func testAnUnknownStepOrRouteIsRefused() {
        let step = RuleProposalParser.parse(#"{"steps": [{"step": "check_ph2", "branches": []}]}"#, procedure: procedure())
        XCTAssertEqual(step.rejected.first?.stepId, "check_ph2")
        XCTAssertTrue(step.rejected.first?.reason.contains("no step") == true)
        let route = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "branches": [
          {"branch": "sealed", "when": {"answer": "seal_ok", "is": "yes"}},
          {"branch": "cracked", "when": {"answer": "seal_ok", "is": "no"}}]}]}
        """#, procedure: procedure())
        XCTAssertTrue(route.rejected.first?.reason.contains("no route 'cracked'") == true)
    }

    func testAnUnknownComparisonIsRefusedWithTheReason() {
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "branches": [
          {"branch": "sealed", "when": {"answer": "seal_ok", "equals": "yes"}},
          {"branch": "broken", "when": {"answer": "seal_ok", "is": "no"}}]}]}
        """#, procedure: procedure())
        XCTAssertTrue(parsed.steps.isEmpty)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("unknown comparison 'equals'") == true, "\(parsed.rejected)")
    }

    func testAnAnswerNoStepRecordsIsRefused() {
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "branches": [
          {"branch": "sealed", "when": {"answer": "lid", "is": "yes"}},
          {"branch": "broken", "when": {"answer": "lid", "is": "no"}}]}]}
        """#, procedure: procedure())
        XCTAssertTrue(parsed.steps.isEmpty)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("'lid', which no step records") == true)
    }

    func testRulesOnSomeRoutesOfAStepAreRefusedAllOrNone() {
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "branches": [{"branch": "sealed", "when": {"answer": "seal_ok", "is": "yes"}}]}]}
        """#, procedure: procedure())
        XCTAssertTrue(parsed.steps.isEmpty)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("all rules or none") == true)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("broken") == true, "the route left without a rule is named")
    }

    func testARuleTheValidatorWouldRefuseIsRefusedWithItsWords() {
        // gt on a yes/no answer doesn't fit.
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "branches": [
          {"branch": "sealed", "when": {"answer": "seal_ok", "gt": 1}},
          {"branch": "broken", "when": {"answer": "seal_ok", "is": "no"}}]}]}
        """#, procedure: procedure())
        XCTAssertTrue(parsed.steps.isEmpty)
        XCTAssertTrue(parsed.rejected.first?.reason.contains("doesn't fit") == true, "\(parsed.rejected)")
    }

    func testAProposedAnswerOnAStepThatHasOneIsRefused() {
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "seal_check", "answer": {"record_as": "seal", "kind": "yes_no"}}]}
        """#, procedure: procedure())
        XCTAssertTrue(parsed.rejected.first?.reason.contains("already has an answer") == true)
    }

    func testAStepAlreadyDecidedByRulesIsRefused() {
        let parsed = RuleProposalParser.parse(#"""
        {"steps": [{"step": "check_ph", "branches": [{"branch": "high", "when": {"answer": "ph", "gt": 5}}]}]}
        """#, procedure: F.phProcedure())
        XCTAssertTrue(parsed.rejected.first?.reason.contains("already decided by rules") == true)
    }

    func testOneStepsFailureDoesNotTakeTheOthersWithIt() {
        let reply = """
        {"steps": [
          {"step": "nowhere", "branches": []},
          \(phReply.dropFirst("{\"steps\": [".count).dropLast(2))
        ]}
        """
        let parsed = RuleProposalParser.parse(reply, procedure: procedure())
        XCTAssertEqual(parsed.steps.map(\.stepId), ["check_ph"])
        XCTAssertEqual(parsed.rejected.map(\.stepId), ["nowhere"])
    }

    func testAProposalCarriesTheValidatorsWarningsOnItsStep() {
        // A gap: nothing takes 3.80 to 3.89 once low is below 3.8 and in_spec starts at 3.9.
        let reply = phReply.replacingOccurrences(of: #""between": [3.8, 4.4]"#, with: #""between": [3.9, 4.4]"#)
        let parsed = RuleProposalParser.parse(reply, procedure: procedure())
        XCTAssertEqual(parsed.steps.count, 1)
        XCTAssertTrue(parsed.steps.first?.warnings.contains { $0.contains("matches no route") } == true,
                      "\(parsed.steps.first?.warnings ?? [])")
    }

    // MARK: - The review

    func testNothingChangesUntilASuggestionIsAccepted() {
        var review = ProcedureRuleReview(procedure())
        review.readReply(phReply)
        XCTAssertEqual(review.openSuggestionCount, 4)
        XCTAssertFalse(review.editing.isChanged, "a suggestion is not an edit")
        XCTAssertNotNil(review.answerSuggestion(forStep: "check_ph"))
        let high = try? XCTUnwrap(review.ruleSuggestion(forBranch: "high", step: "check_ph"))
        XCTAssertEqual(high.map(review.words), "pH is above 4.4", "the rule is shown in words beside its sentence")
    }

    func testARuleWaitsForTheAnswerItReadsAndThenTheStepIsDecided() throws {
        var review = ProcedureRuleReview(procedure())
        review.readReply(phReply)
        let high = try XCTUnwrap(review.ruleSuggestion(forBranch: "high", step: "check_ph"))
        XCTAssertNotNil(review.blockedReason(high.id), "the rule reads an answer the procedure doesn't record yet")
        review.accept(high.id)
        XCTAssertFalse(review.editing.isChanged, "a blocked suggestion isn't accepted")

        review.accept("check_ph#answer")
        XCTAssertNil(review.blockedReason(high.id))
        review.accept(high.id)
        XCTAssertTrue(review.editing.isMixed("check_ph"))
        XCTAssertFalse(review.editing.canSave, "one rule of three can't be saved")
        review.accept("check_ph#in_spec")
        review.accept("check_ph#low")
        XCTAssertEqual(review.openSuggestionCount, 0)
        XCTAssertTrue(review.editing.canSave)
        XCTAssertTrue(review.procedure.step(id: "check_ph")?.isAppDecided == true)
        XCTAssertNil(review.editing.readiness.first { $0.stepId == "check_ph" })
    }

    func testARejectedSuggestionLeavesTheProcedureAsItWas() {
        var review = ProcedureRuleReview(procedure())
        review.readReply(phReply)
        review.reject("check_ph#answer")
        XCTAssertNil(review.answerSuggestion(forStep: "check_ph"))
        XCTAssertNil(review.procedure.step(id: "check_ph")?.answer)
        // Reading the same reply again doesn't bring back what was decided.
        review.readReply(phReply)
        XCTAssertNil(review.answerSuggestion(forStep: "check_ph"))
        XCTAssertNotNil(review.ruleSuggestion(forBranch: "low", step: "check_ph"))
    }

    func testAnAnswerSuggestionIsBlockedOnceTheStepHasOneByHand() {
        var review = ProcedureRuleReview(procedure())
        review.readReply(phReply)
        review.setAnswer(F.phAnswer, onStep: "check_ph")
        XCTAssertNotNil(review.blockedReason("check_ph#answer"))
    }

    func testAfterASaveTheSavedProcedureIsTheNewStart() {
        var review = ProcedureRuleReview(procedure())
        review.readReply(phReply)
        for id in ["check_ph#answer", "check_ph#in_spec", "check_ph#high", "check_ph#low"] { review.accept(id) }
        review.saved()
        XCTAssertFalse(review.editing.isChanged)
        XCTAssertTrue(review.suggestions.isEmpty)
        XCTAssertTrue(review.hasStepsToRule, "seal_check still chooses from words")
    }

    func testAnAnswerReadsInALine() {
        XCTAssertEqual(ProcedureRuleReview.describe(F.phAnswer),
                       "Number “pH”, 2 decimals, can be 0 to 14, should be 3.8 to 4.4, critical, recorded as ph")
    }

    func testTheScreenshotFixturesReplyIsReadWithItsPartialStepRefused() {
        #if DEBUG
        let parsed = RuleProposalParser.parse(UITestProcedureRules.reply, procedure: UITestProcedureRules.procedure)
        XCTAssertEqual(parsed.steps.map(\.stepId), ["read_ph"])
        XCTAssertEqual(parsed.rejected.map(\.stepId), ["seal"])
        #endif
    }
}
