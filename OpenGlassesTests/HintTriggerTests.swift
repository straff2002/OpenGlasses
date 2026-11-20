import XCTest
@testable import OpenGlasses

/// Plan MO §4: which final captions ask the wearer for an answer, and why the rest don't.
final class HintTriggerTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func caption(_ text: String, speaker: Int? = nil, language: String = "en-GB",
                         final: Bool = true) -> HintCaption {
        HintCaption(text: text, speaker: speaker, languageCode: language, timestamp: t0, isFinal: final)
    }

    private func evaluate(_ text: String, speaker: Int? = nil, language: String = "en-GB",
                          final: Bool = true, context: HintTrigger.Context? = nil) -> HintTrigger.Outcome {
        HintTrigger.evaluate(caption(text, speaker: speaker, language: language, final: final),
                             context: context ?? HintTrigger.Context(now: t0))
    }

    // MARK: - Asks for an answer

    func testAPlainQuestionIsHinted() {
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?"),
                       .hint(question: "What is the lead time on the larger unit?"))
        XCTAssertEqual(evaluate("  How long does the warranty last?  "),
                       .hint(question: "How long does the warranty last?"))
    }

    /// The cue reads these as polite commands; here they are exactly the questions to hint.
    func testInvitationsToAnswerAreHinted() {
        for text in [
            "Could you explain how the billing works?",
            "Would you describe your biggest project?",
            "Can you walk me through the installation steps?",
            "Walk me through your last migration.",
            "Talk me through the pricing for schools.",
            "Describe a time you handled a difficult customer.",
            "Give me an example of a project that failed.",
            "So, tell me about your experience with heat pumps.",
            "Thanks for coming in. Tell me about your current role.",
            "Great, could you share the delivery schedule with me",
            "I'd like to hear about your support plans.",
        ] {
            guard case .hint = evaluate(text) else {
                return XCTFail("expected a hint for \"\(text)\", got \(evaluate(text))")
            }
        }
    }

    func testAStatementIsNotAQuestion() {
        XCTAssertEqual(evaluate("We moved the office to the new site last spring."),
                       .none(reason: .notAQuestion))
        XCTAssertEqual(evaluate("Could you close the window behind you please."),
                       .none(reason: .notAQuestion), "a polite request for an action is not a question")
    }

    /// The cue answers `true` for any language it has no words for; the trigger must not.
    func testAnUnsupportedLanguageNeedsAQuestionMark() {
        XCTAssertTrue(UtteranceQuestionCue.isQuestion("Wir haben das Büro letztes Jahr verlegt",
                                                      languageCode: "de-DE"),
                      "the cue's fallback, which the trigger must not use")
        XCTAssertEqual(evaluate("Wir haben das Büro letztes Jahr verlegt.", language: "de-DE"),
                       .none(reason: .notAQuestion))
        XCTAssertEqual(evaluate("Wie lange dauert die Lieferung bei Ihnen?", language: "de-DE"),
                       .hint(question: "Wie lange dauert die Lieferung bei Ihnen?"))
        XCTAssertEqual(evaluate("¿Cuánto cuesta el modelo grande ahora", language: "es"),
                       .hint(question: "¿Cuánto cuesta el modelo grande ahora"))
        XCTAssertEqual(evaluate("Πόσο κοστίζει το μεγάλο μοντέλο;", language: "el"),
                       .hint(question: "Πόσο κοστίζει το μεγάλο μοντέλο;"), "the Greek question mark")
        XCTAssertEqual(evaluate("Das ist gut; wir machen weiter so.", language: "de"),
                       .none(reason: .notAQuestion), "a semicolon is only a question mark in Greek")
    }

    /// A language written without spaces is counted in words, not as one long word.
    func testALanguageWithoutSpacesIsNotTooShort() {
        guard case .hint = evaluate("这个型号的保修期是多长时间？", language: "zh-Hans") else {
            return XCTFail("expected a hint, got \(evaluate("这个型号的保修期是多长时间？", language: "zh-Hans"))")
        }
    }

    // MARK: - Skips

    func testInterimCaptionsAreNeverHinted() {
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?", final: false),
                       .none(reason: .notFinal))
    }

    func testVisualNotesAreNotSpeech() {
        XCTAssertEqual(evaluate("[Visual: a whiteboard showing what is the plan?]"),
                       .none(reason: .visualNote))
    }

    func testTheWearersOwnVoiceIsSkipped() {
        let context = HintTrigger.Context(wearerSpeaker: 1, now: t0)
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?", speaker: 1, context: context),
                       .none(reason: .wearer))
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?", speaker: 2, context: context),
                       .hint(question: "What is the lead time on the larger unit?"))
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?", speaker: nil, context: context),
                       .hint(question: "What is the lead time on the larger unit?"),
                       "an unlabelled caption may be anyone")
    }

    func testUntilTheWearerTapsEveryVoiceIsHinted() {
        XCTAssertEqual(evaluate("What is the lead time on the larger unit?", speaker: 1),
                       .hint(question: "What is the lead time on the larger unit?"))
    }

    func testFewerThanFourWordsIsTooShort() {
        XCTAssertEqual(evaluate("Any questions?"), .none(reason: .tooShort))
        XCTAssertEqual(evaluate("Why is that?"), .none(reason: .tooShort))
        XCTAssertEqual(evaluate("   "), .none(reason: .tooShort))
        guard case .hint = evaluate("Why is that so?") else { return XCTFail("four words is enough") }
    }

    func testTagQuestionsAskForAgreement() {
        for text in [
            "It's a long drive from the city, isn't it?",
            "You were at the launch last year, right?",
            "The new model is much quieter, don't you think?",
            "They shipped the order on Friday, didn't they?",
            "That was the old price list wasn't it?",
            "You've used the system before, have you?",
        ] {
            XCTAssertEqual(evaluate(text), .none(reason: .tagQuestion), text)
        }
        XCTAssertEqual(evaluate("Why didn't they ship it?"), .hint(question: "Why didn't they ship it?"),
                       "a question that opens with a question word is not a tag")
        XCTAssertEqual(evaluate("So why isn't it working then?"), .hint(question: "So why isn't it working then?"))
    }

    func testSmallTalkIsSkipped() {
        for text in [
            "How are you doing today?",
            "Hi Sam, how are you?",
            "How was your trip to Denver?",
            "How's it going over there?",
            "So how was your weekend?",
            "Really nice to meet you all.",
        ] {
            XCTAssertEqual(evaluate(text), .none(reason: .smallTalk), text)
        }
        XCTAssertEqual(evaluate("How are you planning to fund the expansion next year?"),
                       .hint(question: "How are you planning to fund the expansion next year?"),
                       "a small-talk opener inside a real question")
    }

    // MARK: - Already hinted

    func testARewordedRepeatIsAlreadyHinted() {
        let context = HintTrigger.Context(hintedQuestions: ["What is the warranty on the compressor?"], now: t0)
        XCTAssertEqual(evaluate("What's the warranty on the compressor?", context: context),
                       .none(reason: .alreadyHinted))
        XCTAssertEqual(evaluate("what is the WARRANTY on the compressor", context: context),
                       .none(reason: .alreadyHinted))
        XCTAssertEqual(evaluate("What is the warranty on the condenser?", context: context),
                       .hint(question: "What is the warranty on the condenser?"), "one content word of three differs")
    }

    /// The threshold, on both sides: four shared words of five is a repeat (0.8), three of four
    /// is not (0.75).
    func testTheOverlapThreshold() {
        let a: Set = ["warranty", "compressor", "outdoor", "unit"]
        XCTAssertEqual(HintText.overlap(a, a.union(["model"])), 0.8, accuracy: 1e-9)
        XCTAssertEqual(HintText.overlap(["warranty", "compressor", "unit"],
                                        ["warranty", "compressor", "unit", "model"]), 0.75, accuracy: 1e-9)

        // 4 shared of 5: {which, warranty, covers, compressors} against the same plus "outdoor".
        XCTAssertTrue(HintTrigger.isAlreadyHinted("Which warranty covers the compressors?",
                                                  hinted: ["Which warranty covers the outdoor compressors?"]))
        // 3 shared of 4: {warranty, cover, compressors} against the same plus "outdoor".
        XCTAssertFalse(HintTrigger.isAlreadyHinted("Does the warranty cover compressors?",
                                                   hinted: ["Does the warranty cover outdoor compressors?"]))
    }

    // MARK: - Spacing

    func testHintsAreSpacedEightSecondsApart() {
        let question = "What is the lead time on the larger unit?"
        let soon = HintTrigger.Context(lastHintAt: t0, now: t0.addingTimeInterval(7.99))
        XCTAssertEqual(evaluate(question, context: soon), .none(reason: .tooSoon))
        let later = HintTrigger.Context(lastHintAt: t0, now: t0.addingTimeInterval(8))
        XCTAssertEqual(evaluate(question, context: later), .hint(question: question))
    }

    func testADifferentSpeakerMayAskSooner() {
        let question = "What is the lead time on the larger unit?"
        let context = HintTrigger.Context(lastHintAt: t0, lastHintSpeaker: 1, now: t0.addingTimeInterval(2))
        XCTAssertEqual(evaluate(question, speaker: 2, context: context), .hint(question: question))
        XCTAssertEqual(evaluate(question, speaker: 1, context: context), .none(reason: .tooSoon))
        XCTAssertEqual(evaluate(question, speaker: nil, context: context), .none(reason: .tooSoon),
                       "an unknown speaker is not a different one")
        let unknownLast = HintTrigger.Context(lastHintAt: t0, now: t0.addingTimeInterval(2))
        XCTAssertEqual(evaluate(question, speaker: 2, context: unknownLast), .none(reason: .tooSoon))
    }

    // MARK: - Modes

    func testLectureModeHintsOnlyQuestions() {
        let context = HintTrigger.Context(mode: .lecture, now: t0)
        XCTAssertEqual(evaluate("The second law says entropy never decreases.", context: context),
                       .none(reason: .lectureMode))
        XCTAssertEqual(evaluate("Does anyone know what entropy measures?", context: context),
                       .hint(question: "Does anyone know what entropy measures?"))
    }

    func testKeywordModeDelegatesToTheMatcher() {
        var keywords = KeywordMatcher(keywords: ["price list", "Müller"])
        let context = HintTrigger.Context(mode: .keyword, wearerSpeaker: 1, now: t0)
        XCTAssertEqual(HintTrigger.evaluate(caption("Send the price list.", speaker: 1), context: context,
                                            keywords: &keywords),
                       .keyword(word: "price list"), "anyone may say a keyword, the wearer too, in any length")
        XCTAssertEqual(HintTrigger.evaluate(caption("What did Mr Muller say about it?"), context: context,
                                            keywords: &keywords),
                       .keyword(word: "Müller"))
        XCTAssertEqual(HintTrigger.evaluate(caption("What did he say about it?"), context: context,
                                            keywords: &keywords),
                       .none(reason: .noKeyword))
        XCTAssertEqual(HintTrigger.evaluate(caption("Send the price list again.", final: false), context: context,
                                            keywords: &keywords),
                       .none(reason: .notFinal))
        XCTAssertEqual(HintTrigger.evaluate(caption("Send the price list.", speaker: 1), context: context),
                       .none(reason: .noKeyword), "no keywords, nothing to match")
    }
}

/// Plan MO §4, "one in flight": a new question replaces a waiting one.
final class HintQueueTests: XCTestCase {

    func testTheFirstQuestionStartsAtOnce() {
        var queue = HintQueue<String>()
        XCTAssertEqual(queue.offer("q1"), .start("q1"))
        XCTAssertEqual(queue.inFlight, "q1")
        XCTAssertNil(queue.pending)
    }

    func testANewQuestionReplacesTheWaitingOne() {
        var queue = HintQueue<String>()
        _ = queue.offer("q1")
        XCTAssertEqual(queue.offer("q2"), .waiting(replaced: nil))
        XCTAssertEqual(queue.offer("q3"), .waiting(replaced: "q2"))
        XCTAssertEqual(queue.inFlight, "q1", "the one in flight is not interrupted")
        XCTAssertEqual(queue.pending, "q3")
    }

    func testFinishingStartsTheWaitingQuestion() {
        var queue = HintQueue<String>()
        _ = queue.offer("q1")
        _ = queue.offer("q2")
        XCTAssertEqual(queue.finish(), "q2")
        XCTAssertEqual(queue.inFlight, "q2")
        XCTAssertNil(queue.pending)
        XCTAssertNil(queue.finish(), "nothing waiting")
        XCTAssertNil(queue.inFlight)
        XCTAssertEqual(queue.offer("q4"), .start("q4"))
    }

    func testResetForgetsEverything() {
        var queue = HintQueue<String>()
        _ = queue.offer("q1")
        _ = queue.offer("q2")
        queue.reset()
        XCTAssertNil(queue.inFlight)
        XCTAssertNil(queue.pending)
        XCTAssertEqual(queue.offer("q3"), .start("q3"))
    }
}
