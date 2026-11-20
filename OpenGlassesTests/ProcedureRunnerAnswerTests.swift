import XCTest
@testable import OpenGlasses

/// Plan MN P1: the runner takes answers, lets the rules decide, refuses a disagreeing choice,
/// reads back a spoken critical answer, wants a corrective note, and records an override.
@MainActor
final class ProcedureRunnerAnswerTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var logger: SessionLogger!
    private let en = Locale(identifier: "en_US")

    override func setUp() {
        super.setUp()
        tempRoot = F.temporaryRoot("ProcedureRunnerAnswerTests")
        logger = F.makeLogger(root: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func runner(_ procedure: Procedure? = nil) throws -> ProcedureRunner {
        try ProcedureRunner(starting: procedure ?? F.phProcedure(), logger: logger)
    }

    private func lastStepPayload() -> [String: Any] {
        let events = logger.readEvents().filter { $0.kind == .procedureStep }
        return (events.last?.payload ?? [:]).mapValues(\.value)
    }

    private func expectError(_ body: () throws -> Void, _ check: (ProcedureRunner.RunnerError) -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as ProcedureRunner.RunnerError {
            XCTAssertTrue(check(error), "\(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - The rule decides

    func testATypedAnswerIsRecordedAndTheRuleTakesTheRoute() throws {
        let r = try runner()
        guard case .recorded(let recorded) = r.answer("4.3", method: .typed, locale: en) else { return XCTFail() }
        XCTAssertEqual(recorded.value.number, Decimal(string: "4.30"))
        guard case .moved(let step) = try r.advance(choice: nil) else { return XCTFail() }
        XCTAssertEqual(step.id, "record_brix")
        let payload = lastStepPayload()
        XCTAssertEqual(payload["decided_by"] as? String, "rule")
        XCTAssertEqual(payload["rule_text"] as? String, "pH 4.30 is between 3.8 and 4.4")
        XCTAssertEqual(payload["branch_taken"] as? String, "in_spec")
        XCTAssertEqual(payload["from_step"] as? String, "check_ph")
        let answer = try XCTUnwrap(payload["answer"] as? [String: Any])
        XCTAssertEqual(answer["value"] as? String, "4.30")
        XCTAssertEqual(answer["entered"] as? String, "4.3")
        XCTAssertEqual(answer["method"] as? String, "typed")
        XCTAssertEqual(answer["spec_status"] as? String, "in")
    }

    func testARequiredAnswerComesBeforeNext() throws {
        let r = try runner()
        expectError({ try r.advance(choice: nil) }) {
            if case .answerRequired(let line) = $0 { return line.contains("needs the pH") }
            return false
        }
        XCTAssertEqual(r.currentStepId, "check_ph")
    }

    func testAChoiceThatDisagreesWithTheRuleIsRefusedWithTheReason() throws {
        let r = try runner()
        _ = r.answer("4.3", locale: en)
        expectError({ try r.advance(choice: "high") }) {
            guard case .ruleDecides(let line) = $0 else { return false }
            return line.hasPrefix("The reading decides: pH 4.30 is between 3.8 and 4.4, so the next step is Record the Brix.")
        }
        XCTAssertEqual(r.currentStepId, "check_ph", "a refused choice moves nothing")
        XCTAssertNoThrow(try r.advance(choice: "in_spec"), "the rule's own choice is accepted")
        XCTAssertEqual(r.currentStepId, "record_brix")
    }

    func testAnImplausibleAnswerIsAskedAgainAndNothingIsRecorded() throws {
        let r = try runner()
        guard case .askAgain(let line) = r.answer("42", locale: en) else { return XCTFail() }
        XCTAssertTrue(line.contains("Read it again"))
        XCTAssertNil(r.currentAnswer)
    }

    func testAnAnswerOnAStepWithoutOneIsNotAccepted() throws {
        let r = try runner()
        _ = r.answer("4.3", locale: en)
        try r.advance(choice: nil)
        guard case .notAccepted = r.answer("12", locale: en) else { return XCTFail() }
    }

    // MARK: - Critical answers

    func testASpokenCriticalAnswerIsReadBackBeforeItDecides() throws {
        let r = try runner()
        guard case .readBack(let prompt) = r.answer("four point six", method: .spoken, locale: en) else { return XCTFail() }
        XCTAssertEqual(prompt, "pH 4.60, out of spec, is that right?")
        XCTAssertNil(r.currentAnswer, "nothing is recorded until it is confirmed")
        expectError({ try r.advance(choice: nil) }) { if case .awaitingReadBack = $0 { return true }; return false }
        guard case .needsNote = r.confirmReadBack(true) else { return XCTFail("out of spec and critical: a note is owed") }
        XCTAssertEqual(r.currentAnswer?.method, .spoken)
    }

    func testARejectedReadBackRecordsNothing() throws {
        let r = try runner()
        _ = r.answer("4.6", method: .spoken, locale: en)
        guard case .askAgain = r.confirmReadBack(false) else { return XCTFail() }
        XCTAssertNil(r.currentAnswer)
        XCTAssertNil(r.pendingReadBack)
    }

    func testATypedCriticalAnswerIsNotReadBack() throws {
        let r = try runner()
        guard case .recorded = r.answer("4.2", method: .typed, locale: en) else { return XCTFail() }
        XCTAssertNil(r.pendingReadBack)
    }

    func testAnOutOfSpecCriticalAnswerNeedsACorrectiveNote() throws {
        let r = try runner()
        guard case .needsNote(let prompt) = r.answer("4.6", locale: en) else { return XCTFail() }
        XCTAssertTrue(prompt.hasPrefix("pH 4.60 is out of spec (3.8 to 4.4)."))
        XCTAssertTrue(r.awaitingCorrectiveNote)
        expectError({ try r.advance(choice: nil) }) { if case .correctiveNoteRequired = $0 { return true }; return false }
        guard case .askAgain = r.addCorrectiveNote("   ") else { return XCTFail("an empty note is refused") }
        guard case .recorded = r.addCorrectiveNote("  added 2 L acid, retesting ") else { return XCTFail() }
        guard case .moved(let step) = try r.advance(choice: nil) else { return XCTFail() }
        XCTAssertEqual(step.id, "adjust_acid")
        let answer = try XCTUnwrap(lastStepPayload()["answer"] as? [String: Any])
        XCTAssertEqual(answer["note"] as? String, "added 2 L acid, retesting")
        XCTAssertEqual(answer["spec_status"] as? String, "out")
    }

    func testANoteGivenWithTheAnswerIsKept() throws {
        let r = try runner()
        guard case .recorded(let recorded) = r.answer("4.6", note: "dosed acid", locale: en) else { return XCTFail() }
        XCTAssertEqual(recorded.note, "dosed acid")
    }

    // MARK: - Overrides and no rule

    func testAnOverrideNeedsAReasonAndIsRecordedAgainstTheRulesBranch() throws {
        let r = try runner()
        _ = r.answer("4.3", locale: en)
        expectError({ try r.override(branch: "high", reason: "  \n ") }) { if case .overrideNeedsReason = $0 { return true }; return false }
        expectError({ try r.override(branch: "sideways", reason: "x") }) { if case .unknownBranch = $0 { return true }; return false }
        guard case .moved(let step) = try r.override(branch: "high", reason: "meter reads low, known fault") else { return XCTFail() }
        XCTAssertEqual(step.id, "adjust_acid")
        let payload = lastStepPayload()
        XCTAssertEqual(payload["decided_by"] as? String, "override")
        XCTAssertEqual(payload["rule_branch"] as? String, "in_spec")
        XCTAssertEqual(payload["reason"] as? String, "meter reads low, known fault")
        XCTAssertEqual(payload["branch_taken"] as? String, "high")
    }

    func testAnOverrideOnAStepNoRuleDecidesIsRefused() throws {
        let words = Procedure(id: "w", title: "W", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Look.", branches: [
                .init(id: "x", condition: "x", next: "b"), .init(id: "y", condition: "y", next: "b")]),
            .init(id: "b", title: "B", instruction: "Done.", terminal: true),
        ])
        let r = try runner(words)
        expectError({ try r.override(branch: "x", reason: "because") }) { if case .notRuleDecided = $0 { return true }; return false }
        try r.advance(choice: "y", by: .person)
        XCTAssertEqual(lastStepPayload()["decided_by"] as? String, "person")
    }

    func testWhenNoRuleHoldsThePersonChoosesAndTheAssistantMayNot() throws {
        let gappy = F.phProcedure(branches: [
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
            .init(id: "high", condition: "pH above 4.4", next: "adjust_acid", when: F.test("ph", .gt, .number(4.4))),
        ])
        let r = try runner(gappy)
        _ = r.answer("3.75", note: "sample retaken", locale: en)
        expectError({ try r.advance(choice: "in_spec", by: .assistant) }) {
            guard case .noRuleMatched(let line) = $0 else { return false }
            return line.hasPrefix("pH 3.75 matches none of this step's routes.") && line.contains("don't choose for them")
        }
        expectError({ try r.advance(choice: nil, by: .person) }) { if case .noRuleMatched = $0 { return true }; return false }
        try r.advance(choice: "high", by: .person)
        let payload = lastStepPayload()
        XCTAssertEqual(payload["decided_by"] as? String, "person")
        XCTAssertEqual(payload["reason"] as? String, "no rule matched")
        XCTAssertEqual(payload["rule_text"] as? String, "pH 3.75 matches none of this step's routes")
    }

    func testARuleCanReadAnEarlierStepsAnswer() throws {
        let example = try F.exampleProcedure()
        let r = try runner(example)
        _ = r.answer("yes", method: .lens, locale: en)
        try r.advance(choice: nil)
        XCTAssertEqual(r.currentStepId, "check_co2")
        _ = r.answer("2.45", locale: en)
        try r.advance(choice: nil)
        XCTAssertEqual(r.currentStepId, "check_brix")
        _ = r.answer("10.1", note: "syrup pump stalled; batch tagged", locale: en)
        guard case .arrivedAtTerminal(let step) = try r.advance(choice: nil) else { return XCTFail() }
        XCTAssertEqual(step.id, "hold_batch")
        XCTAssertEqual(lastStepPayload()["rule_text"] as? String, "Brix 10.1 °Bx is below 10.5 and CO2 2.45 is below 2.5")
    }

    func testSteppingBackDropsTheAnswerOfTheStepLeft() throws {
        let example = try F.exampleProcedure()
        let r = try runner(example)
        _ = r.answer("yes", locale: en)
        try r.advance(choice: nil)
        _ = r.answer("2.6", locale: en)
        XCTAssertNotNil(r.currentAnswer)
        try r.goBack()
        XCTAssertNil(r.answers["check_co2"])
        XCTAssertNotNil(r.answers["confirm_line_clear"])
        XCTAssertEqual(r.pathAnswers.keys.sorted(), ["line_clear"])
    }

    // MARK: - The record

    func testTheRunsAnswersFoldIntoOneCaptureRecord() throws {
        let r = try runner()
        _ = r.answer("4.6", note: "dosed", locale: en)
        try r.advance(choice: nil)
        let record = try XCTUnwrap(r.captureRecord(sessionId: "job-1"))
        XCTAssertEqual(record.flowId, "procedure:ph_check@2.1.0")
        XCTAssertEqual(record.fields.count, 1)
        let field = try XCTUnwrap(record.fields.first)
        XCTAssertEqual(field.field, "ph")
        XCTAssertEqual(field.value.display, "4.60")
        XCTAssertEqual(field.entered, "4.6")
        XCTAssertEqual(field.specStatus, "out")
        XCTAssertEqual(field.note, "dosed")
        XCTAssertEqual(field.stepId, "check_ph")
        XCTAssertEqual(field.provenance.method, "typed")
        XCTAssertNotNil(record.finishedAt)
        XCTAssertNil(try runner().captureRecord(sessionId: "job-1"), "no answers, no record")
    }

    func testCaptureRecordsWrittenBeforeTheNewKeysStillDecode() throws {
        let old = #"{"flowId":"asset_inspection_v1","sessionId":"s","fields":[{"field":"gauge_psi","value":{"kind":"number","number":118,"unit":"psig"},"provenance":{"method":"voice_number","at":0}}],"startedAt":0}"#
        let record = try JSONDecoder().decode(CaptureRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.fields.first?.entered)
        XCTAssertNil(record.fields.first?.specStatus)
        XCTAssertEqual(record.fields.first?.value.display, "118 psig", "a capture flow's number prints as before")
        let r = try runner()
        _ = r.answer("4.2", locale: en)
        let fresh = try XCTUnwrap(r.captureRecord(sessionId: "s"))
        XCTAssertEqual(try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(fresh)), fresh)
        let event = fresh.auditEvent
        let fields = event.payload?["fields"]?.value as? [[String: Any]]
        XCTAssertEqual(fields?.first?["spec_status"] as? String, "in")
        XCTAssertEqual(fields?.first?["step_id"] as? String, "check_ph")
    }

    func testTheLastStepsAnswerRidesTheCompletion() throws {
        let signOff = Procedure(id: "s", title: "S", version: "1", steps: [
            .init(id: "sign", title: "Sign off", instruction: "Sign.", terminal: true, outcome: "released",
                  answer: StepAnswer(recordAs: "signed", kind: .yesNo)),
        ])
        let r = try runner(signOff)
        expectError({ try r.advance(choice: nil) }) { if case .answerRequired = $0 { return true }; return false }
        _ = r.answer("yes", locale: en)
        guard case .completed(let outcome) = try r.advance(choice: nil) else { return XCTFail() }
        XCTAssertEqual(outcome, "released")
        let completion = logger.readEvents().last { $0.kind == .procedureCompleted }
        let answer = completion?.payload?["answer"]?.value as? [String: Any]
        XCTAssertEqual(answer?["value"] as? String, "yes")
    }

    func testARebuiltRunnerKeepsTheAnswersTheLogCarries() throws {
        let example = try F.exampleProcedure()
        let r = try runner(example)
        _ = r.answer("yes", locale: en)
        try r.advance(choice: nil)
        _ = r.answer("2.5", locale: en)
        try r.advance(choice: nil)
        let restored = ProcedureRunner.restoredAnswers(from: logger.readEvents(), procedure: example)
        XCTAssertEqual(restored["check_co2"]?.value.number, Decimal(string: "2.50"))
        XCTAssertEqual(restored["confirm_line_clear"]?.value.option, "yes")
        let rebuilt = ProcedureRunner(restoring: example, visited: r.visited, logger: logger, answers: restored)
        XCTAssertEqual(rebuilt.pathAnswers["co2"]?.value.specStatus, .in)
    }

    // MARK: - What the model is told

    func testThePromptTellsTheModelToAnswerAndNotToChoose() throws {
        let r = try runner()
        let before = r.promptContext()
        XCTAssertTrue(before.contains("This step takes an answer: a number, the pH (required)."))
        XCTAssertTrue(before.contains("call procedure_runner action 'answer' with value set to exactly what they said"))
        XCTAssertTrue(before.contains("The route follows from the answer: the app decides it, and you don't choose it."))
        XCTAssertFalse(before.contains("advance by calling procedure_runner action 'next' with one of these choices"))
        _ = r.answer("4.6", method: .spoken, locale: en)
        XCTAssertTrue(r.promptContext().contains("Read this back to the technician and wait: \"pH 4.60, out of spec, is that right?\""))
        _ = r.confirmReadBack(true)
        XCTAssertTrue(r.promptContext().contains("call procedure_runner 'answer' with note set to their words"))
    }
}
