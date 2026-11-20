import XCTest
@testable import OpenGlasses

/// Plan MN P2 (§4): the voice with no model. What an utterance means on a step is a pure decision
/// — a step word, the step's answer, a read-back's yes or no, a corrective note, or the one fixed
/// line — and the loop carries it out on a real runner and says what happened.
@MainActor
final class ProcedureVoiceLoopTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var logger: SessionLogger!
    private let en = Locale(identifier: "en_US")

    override func setUp() {
        super.setUp()
        tempRoot = F.temporaryRoot("ProcedureVoiceLoopTests")
        logger = F.makeLogger(root: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func host(_ procedure: Procedure? = nil) throws -> ProcedureRunnerHost {
        try ProcedureRunnerHost(procedure ?? F.exampleProcedure(), logger: logger)
    }

    private func decide(_ text: String, _ h: ProcedureRunnerHost) throws -> ProcedureVoiceIntent {
        ProcedureVoiceDecider.decide(text, on: try XCTUnwrap(h.activeProcedurePresentation), locale: en)
    }

    /// The example, moved on to its CO2 step.
    private func atCO2() throws -> ProcedureRunnerHost {
        let h = try host()
        _ = try h.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try h.advanceProcedure(choice: nil)
        return h
    }

    // MARK: - The decision

    func testStepWordsAreCommands() throws {
        let h = try atCO2()
        XCTAssertEqual(try decide("next", h), .next)
        XCTAssertEqual(try decide("OK next step", h), .next)
        XCTAssertEqual(try decide("go back", h), .back)
        XCTAssertEqual(try decide("previous", h), .back)
        XCTAssertEqual(try decide("repeat", h), .repeatStep)
        XCTAssertEqual(try decide("say that again please", h), .repeatStep)
    }

    func testANumberStepTakesTheReadingInDigitsOrWords() throws {
        let h = try atCO2()
        XCTAssertEqual(try decide("2.6", h), .answer("2.6"))
        XCTAssertEqual(try decide("two point six", h), .answer("two point six"))
        XCTAssertEqual(try decide("it's 42", h), .answer("it's 42"),
                       "an implausible number still goes to the runner, which says why and asks again")
    }

    func testAYesNoStepTakesDoneAsItsAnswerNotAsNext() throws {
        let h = try host()
        XCTAssertEqual(try decide("done", h), .answer("done"))
        XCTAssertEqual(try decide("yes", h), .answer("yes"))
        XCTAssertEqual(try decide("nope", h), .answer("nope"))
        XCTAssertEqual(try decide("next", h), .next, "next is not a yes or a no")
        XCTAssertEqual(try decide("OK next", h), .next, "a leading ok is filler, not a yes")
    }

    func testAChoiceStepTakesALabelOrASynonym() throws {
        let procedure = Procedure(id: "c", title: "C", version: "1", steps: [
            .init(id: "seal", title: "Seal", instruction: "Look at the seal.",
                  defaultNext: "end",
                  answer: StepAnswer(recordAs: "seal", kind: .choice, label: "Seal",
                                     options: [.init(id: "good", label: "Good", says: ["fine"]),
                                               .init(id: "worn", label: "Worn")])),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true),
        ])
        let h = try host(procedure)
        XCTAssertEqual(try decide("fine", h), .answer("fine"))
        XCTAssertEqual(try decide("worn", h), .answer("worn"))
        XCTAssertEqual(try decide("what is this", h), .fallback,
                       "words that name no option are never guessed into one")
    }

    func testAnythingElseGetsTheOneFixedLine() throws {
        let h = try atCO2()
        XCTAssertEqual(try decide("what's the right carbonation for this line?", h), .fallback)
        XCTAssertEqual(try decide("", h), .fallback)
        XCTAssertEqual(ProcedureVoiceDecider.fallbackLine,
                       "I can take the answer to this step, or next, back or repeat.")
    }

    func testAReadBackIsAnsweredYesOrNoAndANewNumberReplacesIt() throws {
        let h = try host(F.phProcedure())
        _ = try h.answerProcedure(value: "4.6", method: .spoken, note: nil, confirmed: false, locale: en)
        XCTAssertEqual(try decide("yes", h), .confirmReadBack(true))
        XCTAssertEqual(try decide("no", h), .confirmReadBack(false))
        XCTAssertEqual(try decide("4.5", h), .answer("4.5"))
    }

    func testAnOwedNoteTakesTheWordsButStillHearsStepWords() throws {
        let h = try atCO2()
        _ = try h.answerProcedure(value: "2.9", method: .typed, note: nil, confirmed: false, locale: en)
        XCTAssertEqual(try decide("adjusted the carbonator and drained ten bottles", h),
                       .note("adjusted the carbonator and drained ten bottles"))
        XCTAssertEqual(try decide("repeat", h), .repeatStep)
    }

    // MARK: - The loop

    func testTheLoopRunsTheExampleByVoice() throws {
        let h = try host()
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { true })
        XCTAssertEqual(loop.handle("yes", locale: en), "Recorded: Line clear: yes. Say next to go on.")
        let next = try XCTUnwrap(loop.handle("next", locale: en))
        XCTAssertTrue(next.hasPrefix("Step 2. Check the carbonation."), next)
        XCTAssertTrue(next.contains("Say or type the CO2."), next)
        XCTAssertTrue(next.contains("Spec 2.4 to 2.8."), next)

        // Spoken and critical: read back before anything is recorded.
        XCTAssertEqual(loop.handle("two point six", locale: en), "CO2 2.60, in spec, is that right?")
        XCTAssertNil(h.runner?.currentAnswer)
        XCTAssertEqual(loop.handle("yes", locale: en), "Recorded: CO2 2.60, in spec. Say next to go on.")
        let brix = try XCTUnwrap(loop.handle("next", locale: en))
        XCTAssertTrue(brix.contains("Check the Brix"), brix)
        XCTAssertEqual(loop.handle("back", locale: en)?.hasPrefix("Step 2. Check the carbonation."), true)
    }

    func testTheLoopSaysWhyAStepCantGoOn() throws {
        let h = try atCO2()
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { true })
        let refused = try XCTUnwrap(loop.handle("next", locale: en))
        XCTAssertTrue(refused.contains("needs the CO2"), refused)
        XCTAssertEqual(loop.handle("tell me about carbonation", locale: en), ProcedureVoiceDecider.fallbackLine)
        let implausible = try XCTUnwrap(loop.handle("42", locale: en))
        XCTAssertNil(h.runner?.currentAnswer, "an implausible reading records nothing")
        XCTAssertFalse(implausible.isEmpty)
    }

    func testTheLoopTakesACorrectiveNoteByVoice() throws {
        let h = try atCO2()
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { true })
        XCTAssertTrue(loop.handle("2.9", locale: en)?.contains("is that right?") == true)
        let owed = try XCTUnwrap(loop.handle("yes", locale: en))
        XCTAssertTrue(owed.contains("corrective note"), owed)
        XCTAssertEqual(loop.handle("reset the carbonator", locale: en), "Note added. Say next to go on.")
        XCTAssertEqual(h.runner?.currentAnswer?.note, "reset the carbonator")
        let moved = try XCTUnwrap(loop.handle("next", locale: en))
        XCTAssertTrue(moved.contains("Adjust the carbonation"), moved)
    }

    func testAPhotoStepAttachesThePhotosTakenOnItOnNext() throws {
        let procedure = Procedure(id: "ph", title: "Photo", version: "1", steps: [
            .init(id: "shot", title: "Photograph it", instruction: "Take a photo.", defaultNext: "end",
                  answer: StepAnswer(recordAs: "shot", kind: .photo, label: "Photo")),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true, outcome: "resolved"),
        ])
        let h = try host(procedure)
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { true })
        XCTAssertEqual(loop.handle("next", locale: en), "This step needs a photo; none taken so far.")
        h.photoIds = ["p1"]
        let end = try XCTUnwrap(loop.handle("next", locale: en))
        XCTAssertTrue(end.contains("This is the last step. Say next to finish."), end)
        XCTAssertEqual(loop.handle("next", locale: en), "The procedure is finished.")
        XCTAssertEqual(h.finishedOutcome, "resolved")
    }

    func testWithoutOnDeviceRecognitionTheScreenIsNamedOnceARun() throws {
        let h = try atCO2()
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { false })
        XCTAssertTrue(loop.handle("repeat", locale: en)?.hasPrefix(ProcedureVoiceDecider.screenIsTheWayInLine) == true)
        XCTAssertFalse(loop.handle("repeat", locale: en)?.hasPrefix(ProcedureVoiceDecider.screenIsTheWayInLine) == true)
    }

    func testNoProcedureLeavesTheWordsAlone() throws {
        let h = try host(Procedure(id: "one", title: "One", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "i", terminal: true, outcome: "resolved"),
        ]))
        let loop = ProcedureVoiceLoop(host: h, supportsOnDeviceRecognition: { true })
        XCTAssertEqual(loop.handle("next", locale: en), "The procedure is finished.")
        XCTAssertNil(loop.handle("what's the weather", locale: en), "nothing running: the words go on")
    }

    func testTheSpokenLinesNameNoPlanOrProvider() throws {
        let h = try atCO2()
        let lines = [ProcedureVoiceDecider.fallbackLine, ProcedureVoiceDecider.screenIsTheWayInLine,
                     ProcedureVoiceDecider.stepLine(try XCTUnwrap(h.activeProcedurePresentation))]
        for line in lines {
            for banned in ["Plan ", "Claude", "Gemini", "OpenAI", "model"] {
                XCTAssertFalse(line.contains(banned), line)
            }
        }
    }
}
