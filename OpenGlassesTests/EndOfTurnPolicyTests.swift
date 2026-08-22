import XCTest
@testable import OpenGlasses

/// Plan CU P2 — the four rules that decide when the wearer has finished talking. Each test below
/// pins one, and rule 3's tests are written to fail loudly: it is the rule that looks like a
/// latency win while quietly re-breaking the case CO shipped to fix.
final class EndOfTurnPolicyTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private func input(now: TimeInterval,
                       detectorAvailable: Bool = true,
                       speechObserved: Bool = true,
                       lastRecognizerActivity: TimeInterval? = nil,
                       acousticSpeechEnded: TimeInterval? = nil,
                       timerWindow: TimeInterval = SpeechContinuationPolicy.baseWindow)
    -> EndOfTurnPolicy.Input {
        .init(now: at(now),
              detectorAvailable: detectorAvailable,
              speechObserved: speechObserved,
              lastRecognizerActivityAt: lastRecognizerActivity.map(at),
              acousticSpeechEndedAt: acousticSpeechEnded.map(at),
              timerWindow: timerWindow)
    }

    // MARK: - Rule 1: no detector ⇒ byte-for-byte today

    func testWithoutADetectorTheTimerDecidesAlone() {
        let waiting = EndOfTurnPolicy.decide(input(now: 1.0,
                                                   detectorAvailable: false,
                                                   lastRecognizerActivity: 0.0))
        XCTAssertEqual(waiting, .wait(until: at(2.0)),
                       "the deadline must still be the last partial plus CO's window, exactly as before P2")

        let fired = EndOfTurnPolicy.decide(input(now: 2.0,
                                                 detectorAvailable: false,
                                                 lastRecognizerActivity: 0.0))
        XCTAssertEqual(fired, .commit(.silenceTimer))
    }

    /// A detector that is installed but has not loaded is the same as no detector — soft-fail is
    /// the whole contract of the seam, and it is the state a wearer is in when the model is missing.
    func testAnUnavailableDetectorIsIndistinguishableFromNone() {
        let withNone = EndOfTurnPolicy.decide(input(now: 1.0, detectorAvailable: false,
                                                    lastRecognizerActivity: 0.0))
        let withUnavailable = EndOfTurnPolicy.decide(input(now: 1.0, detectorAvailable: false,
                                                           speechObserved: true,
                                                           lastRecognizerActivity: 0.0,
                                                           acousticSpeechEnded: 0.5))
        XCTAssertEqual(withNone, withUnavailable,
                       "an acoustic stamp from an unavailable detector must not change a single decision")
    }

    // MARK: - Rule 2: speech observed then ended ⇒ short grace

    func testAcousticEndCommitsOnTheGraceNotTheWindow() {
        // Speech ended at 0.5 s; the recognizer's last partial was at 0.4 s, so the old floor would
        // have held this turn until 2.4 s.
        let early = EndOfTurnPolicy.decide(input(now: 0.6,
                                                 lastRecognizerActivity: 0.4,
                                                 acousticSpeechEnded: 0.5))
        XCTAssertEqual(early, .wait(until: at(0.5 + EndOfTurnPolicy.acousticGrace)))

        let committed = EndOfTurnPolicy.decide(input(now: 0.5 + EndOfTurnPolicy.acousticGrace,
                                                     lastRecognizerActivity: 0.4,
                                                     acousticSpeechEnded: 0.5))
        XCTAssertEqual(committed, .commit(.acoustic),
                       "this is the case the plan exists for: 0.9 s instead of 2.4 s of dead air")
    }

    /// Once the detector agrees speech is over, an earlier timer deadline is strictly faster and is
    /// what would have happened anyway — there is nothing to protect the wearer from, so it wins.
    func testAnEarlierTimerDeadlineStillWinsOnceSpeechHasEnded() {
        let decision = EndOfTurnPolicy.decide(input(now: 2.0,
                                                    lastRecognizerActivity: 0.0,
                                                    acousticSpeechEnded: 1.9))
        XCTAssertEqual(decision, .commit(.silenceTimer),
                       "the timer's 2.0 s deadline beats the acoustic 2.3 s, and the reason must say so")
    }

    // MARK: - Rule 3: speech never started ⇒ the timer keeps CO's window

    /// The subtle half. `questionWindow` exists for a wearer who is *thinking*, and acoustic
    /// endpointing has nothing to say about someone who has not spoken. If the detector's silence
    /// were allowed to commit here, the 6 s window would collapse to the grace and CO Item 4 would
    /// be silently undone.
    func testAWearerWhoHasNotSpokenYetKeepsTheFullQuestionWindow() {
        let decision = EndOfTurnPolicy.decide(input(now: 1.0,
                                                    speechObserved: false,
                                                    lastRecognizerActivity: 0.0,
                                                    acousticSpeechEnded: 0.1,
                                                    timerWindow: SpeechContinuationPolicy.questionWindow))
        XCTAssertEqual(decision, .wait(until: at(SpeechContinuationPolicy.questionWindow)),
                       "silence from someone who never started talking is thinking, not an end of turn")
    }

    func testTheQuestionWindowStillEndsTheTurnWhenItExpires() {
        let decision = EndOfTurnPolicy.decide(input(now: SpeechContinuationPolicy.questionWindow,
                                                    speechObserved: false,
                                                    lastRecognizerActivity: 0.0,
                                                    timerWindow: SpeechContinuationPolicy.questionWindow))
        XCTAssertEqual(decision, .commit(.silenceTimer),
                       "a wearer who walked away must not be left with a hot mic either")
    }

    // MARK: - Rule 4: a stuck detector never gets an unbounded hold

    /// While the detector claims speech is still going, the timer must not cut — that firing is the
    /// mid-sentence bug P2 removes.
    func testTheTimerDoesNotCutWhileTheDetectorSaysTheWearerIsStillTalking() {
        let decision = EndOfTurnPolicy.decide(input(now: 3.0,
                                                    lastRecognizerActivity: 0.0,
                                                    acousticSpeechEnded: nil))
        XCTAssertEqual(decision, .wait(until: at(EndOfTurnPolicy.stuckDetectorBackstop)),
                       "the recognizer's burst gap is not silence; the detector is the authority here")
    }

    /// But a noisy HFP link scoring as speech forever would otherwise hang the turn with a hot mic.
    func testAStuckDetectorHandsTheDecisionBackAtTheBackstop() {
        let decision = EndOfTurnPolicy.decide(input(now: EndOfTurnPolicy.stuckDetectorBackstop,
                                                    lastRecognizerActivity: 0.0,
                                                    acousticSpeechEnded: nil))
        XCTAssertEqual(decision, .commit(.detectorBackstop),
                       "the reason must be distinct — a rising share of these is how a bad threshold announces itself")
    }

    /// The backstop is past the longest window CO can ask for, so rule 4 can never pre-empt rule 3.
    func testTheBackstopCannotPreemptTheQuestionWindow() {
        XCTAssertGreaterThan(EndOfTurnPolicy.stuckDetectorBackstop,
                             SpeechContinuationPolicy.questionWindow)
    }

    // MARK: - Degenerate inputs

    /// Before the first partial there is no timer deadline to compute. The no-speech timeout owns
    /// that turn; the policy must return a bounded re-check rather than committing on nothing.
    func testNoRecognizerActivityYetIsAWaitNotACommit() {
        let decision = EndOfTurnPolicy.decide(input(now: 0.0,
                                                    detectorAvailable: false,
                                                    speechObserved: false,
                                                    lastRecognizerActivity: nil))
        XCTAssertEqual(decision, .wait(until: at(SpeechContinuationPolicy.baseWindow)))
    }

    /// A detector that heard a voice the recognizer never parsed still holds the turn — and with no
    /// partial to measure from, the hold is bounded from now.
    func testSpeechHeardOnlyByTheDetectorIsStillSpeech() {
        let decision = EndOfTurnPolicy.decide(input(now: 1.0,
                                                    speechObserved: true,
                                                    lastRecognizerActivity: nil,
                                                    acousticSpeechEnded: nil))
        XCTAssertEqual(decision, .wait(until: at(1.0 + EndOfTurnPolicy.stuckDetectorBackstop)))
    }
}
