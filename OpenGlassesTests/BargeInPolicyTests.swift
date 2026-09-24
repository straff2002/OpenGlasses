import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan FE P3 — what speech heard over the assistant's own voice is allowed to do, and what the
/// wearer's switch does and does not reach.
final class BargeInPolicyTests: XCTestCase {

    private func decide(_ transcript: String,
                        isStopPhrase: Bool = false,
                        matchedWakePhrase: String? = nil,
                        generalBargeInEnabled: Bool = true,
                        assistantSpeech: BargeInPolicy.AssistantSpeech = .silent) -> BargeInPolicy.Decision {
        BargeInPolicy.decide(transcript: transcript,
                             isStopPhrase: isStopPhrase,
                             matchedWakePhrase: matchedWakePhrase,
                             generalBargeInEnabled: generalBargeInEnabled,
                             assistantSpeech: assistantSpeech)
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

    // MARK: - Echo, while the assistant is speaking

    /// Nothing is playing ⇒ nothing to mistake for the wearer. The floor is the only filter.
    func testWithNothingPlayingAnyClearUtteranceInterrupts() {
        let words = "the next train is at ten past"
        XCTAssertEqual(decide(words), .interrupt(text: words))
        XCTAssertEqual(decide(words, generalBargeInEnabled: false), .ignore,
                       "the switch is the wearer's answer to background talk")
    }

    /// The field failure (build 407): the recogniser hears the assistant read its own answer back
    /// and cuts it off a second in. There is no echo cancellation on that path, so the policy has
    /// to refuse the interrupt itself.
    func testTheAssistantReadingItsOwnAnswerBackDoesNotCutItOff() {
        let spoken = "The next train to Wellington is at ten past four from platform two."
        XCTAssertEqual(decide("the next train to wellington is at ten past",
                              assistantSpeech: .speaking(text: spoken)),
                       .ignore)
        XCTAssertEqual(decide("at ten past four from platform two",
                              assistantSpeech: .speaking(text: spoken)),
                       .ignore)
    }

    /// The wearer talking over the answer still gets through — the refusal is about echo, not
    /// about playback.
    func testTheWearerSayingSomethingElseStillInterrupts() {
        let spoken = "The next train to Wellington is at ten past four from platform two."
        XCTAssertEqual(decide("actually I need the bus", assistantSpeech: .speaking(text: spoken)),
                       .interrupt(text: "actually I need the bus"))
    }

    /// Playback with no idea what is being said is no evidence either way, and the answer to no
    /// evidence is to leave the answer running — "stop" and the wake phrase are still the way out.
    func testPlaybackWithoutTheSpokenTextRefusesGeneralInterrupts() {
        XCTAssertEqual(decide("no wait", assistantSpeech: .speaking(text: nil)), .ignore)
        XCTAssertEqual(decide("stop", isStopPhrase: true, assistantSpeech: .speaking(text: nil)),
                       .stop)
        XCTAssertEqual(decide("hey claude", matchedWakePhrase: "hey claude",
                              assistantSpeech: .speaking(text: nil)),
                       .newConversation(phrase: "hey claude"))
    }

    /// The explicit signals are never echo-tested, even when the assistant is literally saying the
    /// word. Being unable to stop a reply that is talking about stopping would be the trap this
    /// policy's contract exists to forbid.
    func testTheExplicitSignalsAreNeverEchoTested() {
        let spoken = "Say stop at any time and I will stop talking."
        XCTAssertEqual(decide("stop", isStopPhrase: true, assistantSpeech: .speaking(text: spoken)),
                       .stop)
    }

    func testEchoDetectionIsAWordOverlapNotASubstring() {
        let spoken = "Check the suction pressure before you top up the refrigerant."
        // Same words, recognised out of order and with a word missing: still the assistant.
        XCTAssertTrue(BargeInPolicy.echoesSpokenText("the suction pressure before you", spoken: spoken))
        // Shares a word or two with what is playing, but is a question of its own.
        XCTAssertFalse(BargeInPolicy.echoesSpokenText("what pressure should it be at", spoken: spoken))
    }

    /// Background conversation is the other case the switch exists for, and it is indistinguishable
    /// here from deliberate speech — which is exactly why the plan refuses a cleverer threshold.
    func testBackgroundConversationIsIndistinguishableAndThatIsThePoint() {
        let background = "did you see the game last night"
        XCTAssertEqual(decide(background), .interrupt(text: background))
        XCTAssertEqual(decide(background, generalBargeInEnabled: false), .ignore)
    }

    // MARK: - Build 420: the reply cut off on the phone's loudspeaker

    /// The field trace: phone speaker and phone mic, six replies in a row cut off two to six
    /// seconds in, mostly on a two-word partial. Over the loudspeaker nothing general interrupts —
    /// not the echo, and not the room either.
    func testNothingGeneralInterruptsOverThePhonesLoudspeaker() {
        let spoken = "I've taken a photo of the condenser. The fan motor looks seized."
        let speaker = BargeInPolicy.AssistantSpeech.speaking(text: spoken, openSpeaker: true)
        for heard in ["i have taken", "the fan motor", "actually I need the bus",
                      "did you see the game last night"] {
            XCTAssertEqual(decide(heard, assistantSpeech: speaker), .ignore, heard)
        }
    }

    /// The way out does not depend on the route.
    func testStopAndTheWakePhraseStillCutThroughTheLoudspeaker() {
        let speaker = BargeInPolicy.AssistantSpeech.speaking(text: "Anything at all.", openSpeaker: true)
        XCTAssertEqual(decide("stop", isStopPhrase: true, assistantSpeech: speaker), .stop)
        XCTAssertEqual(decide("hey claude", matchedWakePhrase: "hey claude", assistantSpeech: speaker),
                       .newConversation(phrase: "hey claude"))
    }

    /// Off the loudspeaker (glasses, a headset) the wearer can still talk over the answer.
    func testTheWearerStillInterruptsOffTheLoudspeaker() {
        let spoken = "I've taken a photo of the condenser. The fan motor looks seized."
        XCTAssertEqual(decide("what about the capacitor",
                              assistantSpeech: .speaking(text: spoken, openSpeaker: false)),
                       .interrupt(text: "what about the capacitor"))
    }

    /// Two words, one of them misheard, is not a sample: half "not the reply" by one word.
    func testOneStrayWordInAShortPartialIsNotTheWearer() {
        let spoken = "The suction line is frosting up near the compressor."
        XCTAssertEqual(decide("the fraction", assistantSpeech: .speaking(text: spoken)), .ignore)
        XCTAssertFalse(BargeInPolicy.readsAsWearer("the fraction", spoken: spoken))
    }

    /// The recogniser writes a contraction however it likes; all of them are still the reply.
    func testContractionsAreHeardAsTheReply() {
        let spoken = "It's the capacitor, and you don't need a new motor."
        for heard in ["it is the capacitor", "its the capacitor", "you do not need",
                      "and you dont need"] {
            XCTAssertTrue(BargeInPolicy.echoesSpokenText(heard, spoken: spoken), heard)
            XCTAssertEqual(decide(heard, assistantSpeech: .speaking(text: spoken)), .ignore, heard)
        }
    }

    /// One letter misheard in a long word is the reply; a short word gets no such allowance, so
    /// the wearer's own short words are not swallowed.
    func testAOneLetterMishearingOfALongWordIsTheReply() {
        let vocabulary = BargeInPolicy.spokenVocabulary("Replace the condenser fan motor.")
        XCTAssertTrue(BargeInPolicy.isEcho("condensor", of: vocabulary))
        XCTAssertTrue(BargeInPolicy.isEcho("motors", of: vocabulary))
        XCTAssertFalse(BargeInPolicy.isEcho("fin", of: vocabulary), "three letters: exact only")
        XCTAssertFalse(BargeInPolicy.isEcho("capacitor", of: vocabulary))
    }

    /// A sentence in a script without word spacing is one token; it must still be able to
    /// interrupt off the loudspeaker, or the novel-word minimum is a rule those speakers can never
    /// meet.
    func testAnUnspacedSentenceCanStillInterruptOverPlayback() {
        let heard = "我想问一下今天的天气"
        XCTAssertEqual(decide(heard, assistantSpeech: .speaking(text: "The fan motor looks seized.")),
                       .interrupt(text: heard))
    }

    func testOnlyTheLoudspeakerCountsAsOpen() {
        XCTAssertTrue(MicRoutePolicy.isOpenSpeaker([.builtInSpeaker]))
        XCTAssertFalse(MicRoutePolicy.isOpenSpeaker([.builtInReceiver]))
        XCTAssertFalse(MicRoutePolicy.isOpenSpeaker([.bluetoothHFP]))
        XCTAssertFalse(MicRoutePolicy.isOpenSpeaker([.bluetoothA2DP]))
        XCTAssertFalse(MicRoutePolicy.isOpenSpeaker([]))
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
