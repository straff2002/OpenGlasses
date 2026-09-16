import XCTest
@testable import OpenGlasses

/// Plan FE P3 — what speech heard over the assistant's own voice is allowed to do, and what the
/// wearer's switch does and does not reach.
final class BargeInPolicyTests: XCTestCase {

    private func decide(_ transcript: String,
                        isStopPhrase: Bool = false,
                        matchedWakePhrase: String? = nil,
                        generalBargeInEnabled: Bool = true) -> BargeInPolicy.Decision {
        BargeInPolicy.decide(transcript: transcript,
                             isStopPhrase: isStopPhrase,
                             matchedWakePhrase: matchedWakePhrase,
                             generalBargeInEnabled: generalBargeInEnabled)
    }

    // MARK: - The two signals the switch cannot disable

    /// The way out of a long answer. An interruption control that could turn this off would be a
    /// trap, so it is asserted in both settings rather than only the default one.
    func testAnExplicitStopAlwaysStops() {
        for enabled in [true, false] {
            XCTAssertEqual(decide("stop", isStopPhrase: true, generalBargeInEnabled: enabled),
                           .stop, "general barge-in \(enabled) must not change the stop phrase")
        }
    }

    /// A single-word stop is below the noise floor, and must still cut through it — the floor
    /// applies to general speech only.
    func testAShortStopIsNotFilteredByTheNoiseFloor() {
        XCTAssertEqual(decide("stop", isStopPhrase: true, generalBargeInEnabled: false), .stop)
    }

    func testTheWakePhraseAlwaysStartsAFreshConversation() {
        for enabled in [true, false] {
            XCTAssertEqual(decide("hey claude what's the time",
                                  matchedWakePhrase: "hey claude",
                                  generalBargeInEnabled: enabled),
                           .newConversation(phrase: "hey claude"))
        }
    }

    /// A transcript that is both a stop and a wake phrase is a stop: stopping is the safer, more
    /// reversible of the two, and it is what the wearer said first in every ordering that matters.
    func testStopWinsOverAWakePhraseInTheSameTranscript() {
        XCTAssertEqual(decide("stop hey claude",
                              isStopPhrase: true,
                              matchedWakePhrase: "hey claude"),
                       .stop)
    }

    // MARK: - General speech, and the switch

    func testGeneralSpeechInterruptsWhenEnabled() {
        XCTAssertEqual(decide("actually I meant tomorrow"),
                       .interrupt(text: "actually I meant tomorrow"))
    }

    func testGeneralSpeechIsIgnoredWhenDisabled() {
        XCTAssertEqual(decide("actually I meant tomorrow", generalBargeInEnabled: false), .ignore)
    }

    /// Whitespace is trimmed before the text is handed on, so the barge-in query is the words and
    /// nothing else.
    func testTheInterruptTextIsTrimmed() {
        XCTAssertEqual(decide("  what about friday \n"), .interrupt(text: "what about friday"))
    }

    // MARK: - The noise floor

    func testEmptyAndWhitespaceOnlyTranscriptsAreIgnored() {
        XCTAssertEqual(decide(""), .ignore)
        XCTAssertEqual(decide("   \n\t "), .ignore)
    }

    /// A single short token is a stray partial, not an utterance. This is the floor, and it is all
    /// the floor claims to be.
    func testSingleShortTokensAreIgnored() {
        for fragment in ["um", "uh", "ok", "hmm", "yeah", "the"] {
            XCTAssertEqual(decide(fragment), .ignore, fragment)
        }
    }

    /// Two tokens clear it, which is the behaviour that shipped before this policy existed.
    func testTwoTokensClearTheFloor() {
        XCTAssertEqual(decide("no wait"), .interrupt(text: "no wait"))
    }

    /// The floor must not be a rule that a language written without spaces can never satisfy: a
    /// sentence is a sentence whether or not the recognizer puts spaces in it. This is the whole
    /// reason the floor has two signals rather than a word count.
    func testAScriptWithoutWordSpacingCanStillInterrupt() {
        XCTAssertEqual(decide("我想问一下今天的天气"), .interrupt(text: "我想问一下今天的天气"))
        XCTAssertEqual(decide("ちょっと待ってください"), .interrupt(text: "ちょっと待ってください"))
    }

    /// The counterpart: the policy reaches its verdict from structure alone. Two transcripts with
    /// the same shape get the same answer regardless of the language they are in, and no input
    /// routes through a locale, a script test or a per-language threshold.
    func testTheDecisionDoesNotDependOnWhichLanguageTheTextIsIn() {
        let sameShape = ["no wait", "attends un peu", "espera un momento", "почекай трохи"]
        for transcript in sameShape {
            XCTAssertEqual(decide(transcript), .interrupt(text: transcript), transcript)
            XCTAssertEqual(decide(transcript, generalBargeInEnabled: false), .ignore, transcript)
        }
    }

    // MARK: - Echo and background speech stay someone else's problem

    /// The assistant's own words returning through the mic are suppressed upstream — the
    /// recognition pause around playback and `SpeechActivityGate`. If they reach this policy it
    /// treats them like any other speech, deliberately: a second, weaker echo test here would mask
    /// failures in the real one and would be the thing that eventually gets tuned per language.
    func testAnEchoedAssistantPhraseGetsNoSpecialTreatment() {
        let echoed = "the next train is at ten past"
        XCTAssertEqual(decide(echoed), .interrupt(text: echoed),
                       "echo suppression is upstream; this policy must not second-guess it")
        XCTAssertEqual(decide(echoed, generalBargeInEnabled: false), .ignore,
                       "the switch is the wearer's answer to echo and background talk, not a heuristic")
    }

    /// Background conversation is the other case the switch exists for, and it is indistinguishable
    /// here from deliberate speech — which is exactly why the plan refuses a cleverer threshold.
    func testBackgroundConversationIsIndistinguishableAndThatIsThePoint() {
        let background = "did you see the game last night"
        XCTAssertEqual(decide(background), .interrupt(text: background))
        XCTAssertEqual(decide(background, generalBargeInEnabled: false), .ignore)
    }

    // MARK: - The floor itself

    func testTheNoiseFloorIsStructuralNotLinguistic() {
        XCTAssertFalse(BargeInPolicy.clearsNoiseFloor("ok"))
        XCTAssertTrue(BargeInPolicy.clearsNoiseFloor("ok then"))
        XCTAssertTrue(BargeInPolicy.clearsNoiseFloor(String(repeating: "あ",
                                                            count: BargeInPolicy.minimumCharacters)))
        XCTAssertFalse(BargeInPolicy.clearsNoiseFloor(String(repeating: "あ",
                                                             count: BargeInPolicy.minimumCharacters - 1)))
    }
}
