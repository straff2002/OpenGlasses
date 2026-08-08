import XCTest
@testable import OpenGlasses

/// Plan CO Items 2–4: the three pure cores.
final class TurnAdmissionAndBudgetTests: XCTestCase {

    // MARK: - Item 2: Gemini budget

    /// The defect: on a thinking model, reasoning and the answer share one allowance. A tool turn
    /// must reserve room for the reply, or it can come back with a STOP finish and zero tokens.
    func testToolTurnLeavesRoomForTheAnswerAfterThinking() {
        let budget = GeminiBudgetPolicy.budget(includesTools: true, configuredMaxTokens: 800)
        XCTAssertNotNil(budget.thinkingBudget, "a tool turn must bound its thinking")
        XCTAssertGreaterThan(budget.answerAllowance, budget.thinkingBudget ?? 0,
                             "the answer must get more room than the thinking that precedes it")
        XCTAssertGreaterThanOrEqual(budget.answerAllowance, 1024,
                                    "the old ceiling was 1024 for everything; the answer alone should now clear it")
    }

    /// Non-zero by deliberate choice: this is the turn that selects among 36+ tools and fills in
    /// their arguments, which is exactly the step that benefits from a moment's deliberation.
    func testToolTurnThinkingBudgetIsNonZero() {
        let budget = GeminiBudgetPolicy.budget(includesTools: true, configuredMaxTokens: 800)
        XCTAssertEqual(budget.thinkingBudget, GeminiBudgetPolicy.toolTurnThinkingBudget)
        XCTAssertGreaterThan(GeminiBudgetPolicy.toolTurnThinkingBudget, 0)
    }

    /// A plain turn is untouched — nothing has been observed to go wrong there, and silently
    /// changing every Gemini call would be a bigger change than the defect warrants.
    func testPlainTurnKeepsConfiguredTokensAndOmitsThinkingConfig() {
        let budget = GeminiBudgetPolicy.budget(includesTools: false, configuredMaxTokens: 777)
        XCTAssertEqual(budget.maxOutputTokens, 777)
        XCTAssertNil(budget.thinkingBudget)

        let config = GeminiBudgetPolicy.generationConfig(includesTools: false, configuredMaxTokens: 777)
        XCTAssertNil(config["thinkingConfig"], "no thinkingConfig key at all on a plain turn")
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 777)
    }

    func testToolTurnGenerationConfigCarriesTheThinkingBudget() {
        let config = GeminiBudgetPolicy.generationConfig(includesTools: true, configuredMaxTokens: 800)
        let thinking = config["thinkingConfig"] as? [String: Any]
        XCTAssertEqual(thinking?["thinkingBudget"] as? Int, GeminiBudgetPolicy.toolTurnThinkingBudget)
        XCTAssertEqual(config["maxOutputTokens"] as? Int, GeminiBudgetPolicy.toolTurnMaxOutputTokens)
    }

    // MARK: - Item 3: turn admission

    func testIdleUtteranceIsAccepted() {
        XCTAssertEqual(TurnAdmissionPolicy.decide(isProcessing: false, turnElapsed: nil, utterance: "what's this"),
                       .accept)
    }

    /// The behaviour change: mid-turn speech is held, not silently discarded.
    func testMidTurnUtteranceIsHeldNotDropped() {
        XCTAssertEqual(TurnAdmissionPolicy.decide(isProcessing: true, turnElapsed: 3, utterance: "and the label?"),
                       .deferToQueue)
    }

    /// Past the hold age the user has waited long enough that a replay would confuse; refuse
    /// audibly instead.
    func testLongRunningTurnRejectsWithACue() {
        let elapsed = TurnAdmissionPolicy.maxHoldAge + 1
        XCTAssertEqual(TurnAdmissionPolicy.decide(isProcessing: true, turnElapsed: elapsed, utterance: "hello"),
                       .rejectWithCue(.turnTooLong))
    }

    /// A missing elapsed time must not be read as "brand new" — fail toward the cue, which the
    /// user can hear, rather than toward a hold they cannot.
    func testUnknownElapsedTimeRejectsRatherThanHolds() {
        XCTAssertEqual(TurnAdmissionPolicy.decide(isProcessing: true, turnElapsed: nil, utterance: "hello"),
                       .rejectWithCue(.turnTooLong))
    }

    func testEmptyUtteranceIsRejectedQuietly() {
        XCTAssertEqual(TurnAdmissionPolicy.decide(isProcessing: false, turnElapsed: nil, utterance: "   "),
                       .rejectWithCue(.emptyUtterance))
    }

    func testHeldUtteranceExpiresOnTheSameClockAsAdmission() {
        let now = Date()
        let fresh = now.addingTimeInterval(-(TurnAdmissionPolicy.maxHoldAge - 1))
        let stale = now.addingTimeInterval(-(TurnAdmissionPolicy.maxHoldAge + 1))
        XCTAssertTrue(TurnAdmissionPolicy.heldUtteranceIsStillFresh(heldAt: fresh, now: now))
        XCTAssertFalse(TurnAdmissionPolicy.heldUtteranceIsStillFresh(heldAt: stale, now: now))
    }

    // MARK: - Item 4: silence window

    func testQuestionEarnsALongerWindowThanAStatement() {
        let question = SpeechContinuationPolicy.silenceWindow(afterSpeaking: "Which Sam do you mean?")
        let statement = SpeechContinuationPolicy.silenceWindow(afterSpeaking: "It's 14 degrees outside.")
        XCTAssertGreaterThan(question, statement)
        XCTAssertEqual(statement, SpeechContinuationPolicy.baseWindow)
    }

    /// TTS sanitisation strips punctuation, so a terminal `?` cannot be the only signal.
    func testPunctuationStrippedQuestionsAreStillDetected() {
        XCTAssertTrue(SpeechContinuationPolicy.isQuestionShaped("Which one did you mean"))
        XCTAssertTrue(SpeechContinuationPolicy.isQuestionShaped("Should I save that"))
        XCTAssertTrue(SpeechContinuationPolicy.isQuestionShaped("Want me to call them"))
    }

    /// The interrogative opener is judged on the *final* clause — an answer that mentions a
    /// question earlier but ends in a statement is not asking anything.
    func testStatementFollowingAQuestionIsNotQuestionShaped() {
        XCTAssertFalse(SpeechContinuationPolicy.isQuestionShaped(
            "You asked which train is next. The next one is at ten past."))
    }

    /// The item 1 phrasing this ships alongside must trip the longer window, or the user gets cut
    /// off answering the very question the ambiguity fix introduced.
    func testAmbiguousRecognitionPhrasingEarnsTheLongerWindow() {
        let spoken = FaceRecognitionService.ambiguityPrompt(names: ["Sam", "Alex"])
        XCTAssertEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: spoken),
                       SpeechContinuationPolicy.questionWindow,
                       "the ambiguity prompt asks the user something; the window must let them answer")
    }

    /// The policy may lengthen the wait, never shorten it — no input may drop below today's 2.0 s.
    func testWindowIsNeverShorterThanTheOldFlatValue() {
        let inputs = ["", "ok", "Which one?", "Done.", "How many would you like",
                      "That might be Sam or Alex — I can't tell them apart."]
        for input in inputs {
            XCTAssertGreaterThanOrEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: input), 2.0, input)
        }
        XCTAssertGreaterThanOrEqual(SpeechContinuationPolicy.silenceWindow(afterSpeaking: nil), 2.0)
    }
}
