import XCTest
@testable import OpenGlasses

/// Whole-token command matching (`PhraseMatcher`) and the demotion rules layered on it
/// (`VoiceCommandParser`), per docs/plans/CD-fork-surfaced-remediation.md P2.
///
/// Both directions are measured throughout. Tightening a predicate moves risk from false-positive
/// to false-negative, so every corpus that proves a misfire is gone is paired with one proving the
/// genuine cases still fire.
final class PhraseMatchingTests: XCTestCase {

    private let parser = VoiceCommandParser.default

    // The barge-in phrase list: "stop" plus the persona-qualified variants.
    private let bargeInPhrases = ["stop", "stop stop", "hey claude stop", "claude stop"]

    /// The predicate this replaces, kept verbatim so the corpora below can prove they reproduce the
    /// original bug. A corpus that cannot produce the bug proves nothing by not producing it.
    private func legacyContainsStopPhrase(_ transcript: String, phrases: [String]) -> Bool {
        for phrase in phrases where transcript.contains(phrase) { return true }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "stop" || trimmed.hasSuffix(" stop")
    }

    // MARK: - Tokenization

    func testTokenizeDropsPunctuationAndKeepsInWordApostrophes() {
        XCTAssertEqual(PhraseMatcher.tokenize("Stop."), ["stop"])
        XCTAssertEqual(PhraseMatcher.tokenize("okay, stop!"), ["okay", "stop"])
        XCTAssertEqual(PhraseMatcher.tokenize("that's all"), ["that's", "all"])
    }

    func testRangesFindsEveryWholeTokenOccurrence() {
        let tokens = PhraseMatcher.tokenize("stop it and then stop again")
        XCTAssertEqual(PhraseMatcher.ranges(of: "stop", in: tokens), [0..<1, 4..<5])
        XCTAssertEqual(PhraseMatcher.ranges(of: "stop it", in: tokens), [0..<2])
        XCTAssertTrue(PhraseMatcher.ranges(of: "nonexistent", in: tokens).isEmpty)
    }

    // MARK: - Stop: false positives (the reported defect)

    /// Strings that must NOT read as a stop command.
    private let stopFalsePositives = [
        "it stopped working yesterday",
        "the lift stopped between floors",
        "nonstop music",
        "we listened to nonstop jazz",
        "it stops at the next station",
        "the bus stops here",
        "that was unstoppable",
        "an unstoppable force",
        "he stopped by the shop",
        "stopping is not an option",
    ]

    func testStopDoesNotFireOnWordsMerelyContainingIt() {
        for text in stopFalsePositives {
            XCTAssertFalse(
                PhraseMatcher.containsStopPhrase(text, phrases: bargeInPhrases, position: .anywhere),
                "must not fire: '\(text)'"
            )
        }
    }

    /// Positive control: the corpus above really did reproduce the bug under the old predicate.
    /// Without this, the test above could pass on a corpus that never triggered anything.
    func testLegacyPredicateDidFireOnTheFalsePositiveCorpus() {
        let fired = stopFalsePositives.filter { legacyContainsStopPhrase($0, phrases: bargeInPhrases) }
        XCTAssertGreaterThanOrEqual(
            fired.count, 8,
            "corpus must reproduce the original defect; only \(fired.count) of \(stopFalsePositives.count) fired"
        )
    }

    // MARK: - Stop: recall (the dangerous direction)

    /// Shapes that MUST still fire — a missed stop means the user cannot interrupt.
    private let genuineStops = [
        "stop",
        "Stop",
        "stop.",
        "stop,",
        "stop!",
        "stop it",
        "stopit",
        "stop now",
        "stopnow",
        "please stop",
        "okay stop",
        "no no stop",
        "stop stop",
        "hey claude stop",
        "claude stop",
        "wait, stop, that's wrong",
    ]

    func testGenuineStopsStillFire() {
        for text in genuineStops {
            XCTAssertTrue(
                PhraseMatcher.containsStopPhrase(text, phrases: bargeInPhrases, position: .anywhere),
                "must fire: '\(text)'"
            )
        }
    }

    /// Recall is compared case-by-case against the old predicate: anything it caught and the new one
    /// misses is a regression, not an improvement.
    func testNewPredicateLosesNoRecallVersusLegacy() {
        for text in genuineStops + stopFalsePositives {
            let legacy = legacyContainsStopPhrase(text, phrases: bargeInPhrases)
            let current = PhraseMatcher.containsStopPhrase(text, phrases: bargeInPhrases, position: .anywhere)
            if legacy && !current {
                XCTAssertTrue(
                    stopFalsePositives.contains(text),
                    "lost a genuine stop the old predicate caught: '\(text)'"
                )
            }
        }
    }

    func testStopJoinSuffixesAdmitNoInflections() {
        // "stopped"/"stopping"/"stops" are the original bug. If an inflection ever enters this list
        // the false positives come straight back, so pin it directly.
        for inflection in ["ped", "ping", "s", "page", "watch", "light"] {
            XCTAssertFalse(
                PhraseMatcher.stopJoinSuffixes.contains(inflection),
                "'stop\(inflection)' must not be treated as a stop command"
            )
        }
        XCTAssertTrue(PhraseMatcher.stopJoinSuffixes.contains("it"))
    }

    // MARK: - Stop: the two positions differ deliberately

    func testUtteranceEdgeDoesNotSwallowASentenceMentioningAStopWord() {
        // "quiet" is in the parser's list but not the barge-in list. At `.utteranceEdge` a mid-
        // sentence mention is answered rather than consumed.
        XCTAssertFalse(parser.isStop("I need peace and quiet to concentrate on this"))
        XCTAssertFalse(parser.isStop("they discussed cancel culture at length"))
        // A leading command word still fires, as it did before — "cancel my alarm" is a command.
        XCTAssertTrue(parser.isStop("cancel my alarm"))
        // Still fires at either edge.
        XCTAssertTrue(parser.isStop("quiet"))
        XCTAssertTrue(parser.isStop("be quiet"))
        XCTAssertTrue(parser.isStop("cancel that"))
        XCTAssertTrue(parser.isStop("stop the timer"))
        XCTAssertTrue(parser.isStop("please stop"))
    }

    func testAnywherePositionIsGreedierThanUtteranceEdge() {
        let midSentence = "okay stop that's wrong"
        XCTAssertTrue(PhraseMatcher.containsStopPhrase(midSentence, phrases: ["stop"], position: .anywhere))
        XCTAssertFalse(PhraseMatcher.containsStopPhrase(midSentence, phrases: ["stop"], position: .utteranceEdge))
    }

    func testStopStillRejectsSubwordAtUtteranceEdge() {
        XCTAssertFalse(parser.isStop("nonstop music"))
        XCTAssertFalse(parser.isStop("what's the weather"))
    }

    // MARK: - Rule A: interrogative frame

    func testQuestionAboutTakingAPhotoDoesNotFireTheCamera() {
        // The defect this closes: the camera is on someone's face, the person in front of it never
        // agreed to be photographed, and the user was asking how the glasses work.
        for text in [
            "how do i take a photo with these glasses",
            "how do you take a picture on this thing",
            "how does take photo work",
            "how to take a picture with the glasses",
            "what happens if i take a photo while streaming",
            "is it possible to take a picture without the app",
        ] {
            XCTAssertFalse(parser.isPhoto(text), "must not fire the shutter: '\(text)'")
            XCTAssertEqual(parser.match(.photo, in: text)?.demotedBy, .interrogativeFrame, text)
        }
    }

    func testPoliteImperativesAreStillCommands() {
        // "can you" / "could you" / "please" are NOT interrogative lead-ins: listing them would turn
        // the politest phrasing of a real command into a no-op.
        for text in [
            "can you take a photo",
            "could you take a picture of this",
            "please take a photo",
            "take a picture",
            "take a photo of the sunset",
            "hey, take a photo of this",
        ] {
            XCTAssertTrue(parser.isPhoto(text), "must remain a command: '\(text)'")
        }
    }

    /// Positive control for Rule A: the old substring predicate fired on all of these.
    func testLegacySubstringMatchFiredOnTheQuestionCorpus() {
        let questions = [
            "how do i take a photo with these glasses",
            "how do you take a picture on this thing",
            "how to take a picture with the glasses",
        ]
        for text in questions {
            let lower = text.lowercased()
            XCTAssertTrue(
                VoiceCommandParser.default.photoPhrases.contains { lower.contains($0) },
                "corpus must reproduce the original defect: '\(text)'"
            )
        }
    }

    // MARK: - Rule B: non-final close

    func testSignOffMustEndTheUtterance() {
        let text = "that's all i wanted to ask about the weather"
        XCTAssertFalse(parser.isGoodbye(text))
        XCTAssertEqual(parser.match(.goodbye, in: text)?.demotedBy, .nonFinalClose)

        // Positive control: the old substring predicate ended the conversation here.
        let lower = text.lowercased()
        XCTAssertTrue(VoiceCommandParser.default.goodbyePhrases.contains { lower.contains($0) })
    }

    func testGenuineSignOffsStillEndTheConversation() {
        for text in [
            "goodbye",
            "good bye",
            "bye",
            "okay, thanks Claude, bye",
            "that's all",
            "that's all, thanks for the help",
            "that's all for now",
            "I'm done",
            "go to sleep",
            "end conversation",
        ] {
            XCTAssertTrue(parser.isGoodbye(text), "must end the conversation: '\(text)'")
        }
    }

    func testASurvivingOccurrenceWinsOverADemotedOne() {
        // Demoted "that's all" followed by a real farewell — still a farewell.
        XCTAssertTrue(parser.isGoodbye("that's all i wanted to ask about the weather, goodbye"))
    }

    func testGoodbyeInsideAQuestionIsDemoted() {
        let text = "how do i end conversation on these glasses"
        XCTAssertFalse(parser.isGoodbye(text))
        XCTAssertEqual(parser.match(.goodbye, in: text)?.demotedBy, .interrogativeFrame)
    }

    // MARK: - Shape rules generalise beyond the reported corpus

    /// Invented for the purpose: the rules are about utterance shape, so they should predict
    /// utterances that appear in no bug report.
    func testRulesGeneraliseToUnreportedUtterances() {
        XCTAssertFalse(parser.isPhoto("how do i snap a photo hands free"))
        XCTAssertFalse(parser.isGoodbye("bye is such a strange word to end on"))
        XCTAssertTrue(parser.isPhoto("snap a photo now"))
    }

    // MARK: - No match at all

    func testUnrelatedSpeechMatchesNothing() {
        for command in [VoiceCommandParser.Command.stop, .goodbye, .photo] {
            XCTAssertNil(parser.match(command, in: "what's the weather in wellington"), command.rawValue)
        }
        XCTAssertNil(parser.match(.photo, in: ""))
    }

    func testStopIsNeverDemoted() {
        // Deliberate asymmetry: a demoted stop costs the user the ability to interrupt.
        for text in ["how do i stop the timer", "stop", "please stop"] {
            if let match = parser.match(.stop, in: text) {
                XCTAssertNil(match.demotedBy, "stop must never be demoted: '\(text)'")
            }
        }
    }
}
