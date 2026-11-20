import XCTest
@testable import OpenGlasses

/// Plan MN P2: what the phone step screen, the lens and the no-model voice read about the current
/// step — its position, the trail, the answer waiting, the route and the lens buttons.
@MainActor
final class ProcedureStepPresentationTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var logger: SessionLogger!
    private let en = Locale(identifier: "en_US")

    override func setUp() {
        super.setUp()
        tempRoot = F.temporaryRoot("ProcedureStepPresentationTests")
        logger = F.makeLogger(root: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func host(_ procedure: Procedure? = nil) throws -> ProcedureRunnerHost {
        try ProcedureRunnerHost(procedure ?? F.exampleProcedure(), logger: logger)
    }

    private func linear() -> Procedure {
        Procedure(id: "lin", title: "Linear", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "First.", defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "Second.",
                  branches: [.init(id: "only", condition: "Go on", next: "c")]),
            .init(id: "c", title: "C", instruction: "Last.", terminal: true, outcome: "resolved"),
        ])
    }

    // MARK: - Position

    func testALinearProcedureCountsStepsOfTheWhole() throws {
        let h = try host(linear())
        XCTAssertEqual(h.activeProcedurePresentation?.position.text, "Step 1 of 3")
        try h.advanceProcedure(choice: nil)
        XCTAssertEqual(h.activeProcedurePresentation?.position, .init(number: 2, total: 3))
        XCTAssertEqual(ProcedureStepPresentation.linearChain(linear()), ["a", "b", "c"])
    }

    func testABranchingProcedureCountsTheStepsTaken() throws {
        let example = try F.exampleProcedure()
        XCTAssertNil(ProcedureStepPresentation.linearChain(example))
        let h = try host(example)
        XCTAssertEqual(h.activeProcedurePresentation?.position.text, "Step 1")
        _ = try h.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)
        XCTAssertEqual(h.activeProcedurePresentation?.position.text, "Step 2")
    }

    func testALoopIsNotLinear() {
        let looped = Procedure(id: "l", title: "L", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "i", defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "i", defaultNext: "a"),
        ])
        XCTAssertNil(ProcedureStepPresentation.linearChain(looped))
    }

    // MARK: - The answer and the route

    func testAYesNoStepOffersItsAnswerAndThenTheRuleDecides() throws {
        let h = try host()
        var p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertTrue(p.awaitsAnswer)
        XCTAssertEqual(p.lensChoices.map(\.id), ["answer:yes", "answer:no"])
        XCTAssertTrue(p.routeChoices.isEmpty, "the rule decides; the person doesn't pick a branch")
        XCTAssertTrue(p.offersOverride)
        XCTAssertEqual(p.safetyNotes, ["Lock out the filler and the capper before reaching into either."])

        _ = try h.answerProcedure(value: "yes", method: .lens, note: nil, confirmed: false, locale: en)
        p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertFalse(p.awaitsAnswer)
        XCTAssertEqual(p.recordedLine, "Recorded: Line clear: yes")
        XCTAssertEqual(p.ruleBranchId, "clear")
        XCTAssertNotNil(p.ruleLine)
        XCTAssertTrue(p.lensChoices.isEmpty, "answered: the lens shows Done, Skip and Back")
    }

    func testANumberStepShowsItsSpecHintAndWhatWasRecorded() throws {
        let h = try host()
        _ = try h.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)
        var p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertEqual(p.step.id, "check_co2")
        XCTAssertEqual(p.specHint, "Spec 2.4 to 2.8")
        XCTAssertTrue(p.lensChoices.isEmpty, "a number is spoken or typed on the phone")
        XCTAssertEqual(p.lensInstruction?.components(separatedBy: "\n").last, "Spec 2.4 to 2.8")
        XCTAssertTrue(p.lensInstruction?.contains("Say or type the CO2 on the phone.") == true)

        _ = try h.answerProcedure(value: "2.6", method: .typed, note: nil, confirmed: false, locale: en)
        p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertEqual(p.recordedLine, "Recorded: CO2 2.60, in spec")
        XCTAssertTrue(p.lensInstruction?.hasSuffix("Recorded: CO2 2.60, in spec") == true)
        XCTAssertEqual(p.trail.map(\.title), ["Line clear"])
        XCTAssertEqual(p.trail.first?.answerLine, "Line clear: yes")
    }

    func testAnOutOfSpecCriticalNumberAsksForTheNoteAndOffersNoOverrideUntilThen() throws {
        let h = try host()
        _ = try h.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)
        _ = try h.answerProcedure(value: "2.9", method: .typed, note: nil, confirmed: false, locale: en)
        var p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertTrue(p.needsCorrectiveNote)
        XCTAssertFalse(p.offersOverride)
        XCTAssertTrue(p.lensChoices.isEmpty)
        XCTAssertTrue(p.lensInstruction?.contains("corrective note") == true)
        _ = try h.answerProcedure(value: nil, method: .typed, note: "Reset the carbonator", confirmed: false, locale: en)
        p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertFalse(p.needsCorrectiveNote)
        XCTAssertEqual(p.recorded?.note, "Reset the carbonator")
    }

    func testAStepChosenInWordsOffersItsBranches() throws {
        let words = Procedure(id: "w", title: "W", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Look.",
                  branches: [.init(id: "x", condition: "Looks like x", next: "b"),
                             .init(id: "y", condition: "Looks like y", next: "b")]),
            .init(id: "b", title: "B", instruction: "End.", terminal: true),
        ])
        let p = try XCTUnwrap(try host(words).activeProcedurePresentation)
        XCTAssertEqual(p.routeChoices.map(\.id), ["x", "y"])
        XCTAssertEqual(p.lensChoices.map(\.label), ["Looks like x", "Looks like y"])
        XCTAssertFalse(p.offersOverride)
    }

    func testNoRuleMatchedOffersTheBranchesToThePerson() throws {
        // pH with only the high and low rules: 4.0 matches none and there is no default.
        let procedure = F.phProcedure(branches: [
            .init(id: "high", condition: "pH above 4.4", next: "adjust_acid", when: F.test("ph", .gt, .number(4.4))),
            .init(id: "low", condition: "pH below 3.8", next: "hold_batch", when: F.test("ph", .lt, .number(3.8))),
        ])
        let h = try host(procedure)
        _ = try h.answerProcedure(value: "4.0", method: .typed, note: nil, confirmed: false, locale: en)
        let p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertEqual(p.noRuleMatchedReason, "pH 4.00 matches none of this step's routes")
        XCTAssertEqual(p.routeChoices.map(\.id), ["high", "low"])
        XCTAssertEqual(p.lensChoices.map(\.id), ["high", "low"])
        guard case .arrivedAtTerminal(let next) = try h.advanceProcedure(choice: "low") else { return XCTFail() }
        XCTAssertEqual(next.id, "hold_batch", "the person's choice is taken when no rule holds")
    }

    func testASpokenCriticalAnswerShowsItsReadBackOnTheLens() throws {
        let h = try host(F.phProcedure())
        _ = try h.answerProcedure(value: "4.6", method: .spoken, note: nil, confirmed: false, locale: en)
        let p = try XCTUnwrap(h.activeProcedurePresentation)
        XCTAssertNotNil(p.pendingReadBack)
        XCTAssertEqual(p.lensChoices.map(\.id), [ProcedureStepPresentation.readBackYesId,
                                                 ProcedureStepPresentation.readBackNoId])
        XCTAssertTrue(p.lensInstruction?.contains("is that right?") == true)
        XCTAssertFalse(p.offersOverride)
    }

    func testARetestLoopShowsTheAnswerOnlyAtItsLastVisit() throws {
        let h = try host()
        _ = try h.answerProcedure(value: "no", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)            // → clear_line
        try h.advanceProcedure(choice: nil)            // → confirm_line_clear again
        _ = try h.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)            // → check_co2
        let trail = try XCTUnwrap(h.activeProcedurePresentation?.trail)
        XCTAssertEqual(trail.map(\.stepId), ["confirm_line_clear", "clear_line", "confirm_line_clear"])
        XCTAssertNil(trail[0].answerLine, "the first visit's answer was replaced by the retest")
        XCTAssertEqual(trail[2].answerLine, "Line clear: yes")
        XCTAssertEqual(Set(trail.map(\.id)).count, 3, "ids stay unique when a step repeats")
    }
}
