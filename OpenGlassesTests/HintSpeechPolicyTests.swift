import XCTest
@testable import OpenGlasses

/// Plan MO §6: speak-when-quiet. Quiet before speaking, stop on speech, newest only, drop after
/// 5 s, never the phone speaker; repeat and skip.
final class HintSpeechPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A policy on a private route (glasses or a headset).
    private func earPolicy() -> HintSpeechPolicy { HintSpeechPolicy(isPhoneSpeaker: false) }

    // MARK: - Quiet before speaking

    func testAHintInSilenceIsSpokenAtOnce() {
        var policy = earPolicy()
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(0))), .speak("12 weeks"))
        XCTAssertEqual(policy.speaking, "12 weeks")
    }

    func testAHintWaitsFor400MillisecondsOfQuiet() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(0.5))), .none, "someone is speaking")
        XCTAssertEqual(policy.handle(.speechActivity(isSpeaking: false, at: at(1))), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(1.399))), .none, "399 ms of quiet")
        XCTAssertEqual(policy.handle(.tick(at: at(1.4))), .speak("12 weeks"), "400 ms of quiet")
    }

    func testAHintRightAfterSpeechEndsWaits() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(2)))
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(2.1))), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(2.3))), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(2.4))), .speak("12 weeks"))
    }

    func testSpeechResumingRestartsTheQuiet() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(0.1)))
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0.2)))
        XCTAssertEqual(policy.handle(.tick(at: at(1))), .none, "still speaking")
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(1.5)))
        XCTAssertEqual(policy.handle(.tick(at: at(1.8))), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(1.9))), .speak("12 weeks"))
    }

    // MARK: - Stop on speech

    func testSomeoneSpeakingStopsTheHintAndKeepsItForRepeat() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        XCTAssertEqual(policy.handle(.speechActivity(isSpeaking: true, at: at(0.3))), .stopSpeaking)
        XCTAssertNil(policy.speaking)
        XCTAssertEqual(policy.lastHint, "12 weeks")
        XCTAssertEqual(policy.handle(.tick(at: at(3))), .none, "not resumed by itself")
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(4)))
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(4.5))), .speak("12 weeks"))
    }

    func testSpeechWithNothingPlayingStopsNothing() {
        var policy = earPolicy()
        XCTAssertEqual(policy.handle(.speechActivity(isSpeaking: true, at: at(0))), .none)
    }

    // MARK: - Newest only, dropped after 5 s

    func testANewHintReplacesTheWaitingOne() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("first", at: at(0.1)))
        _ = policy.handle(.hintArrived("second", at: at(0.2)))
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(1)))
        XCTAssertEqual(policy.handle(.tick(at: at(1.4))), .speak("second"))
        XCTAssertEqual(policy.handle(.tick(at: at(2))), .none, "the first is gone")
    }

    func testAHintArrivingWhileOneIsPlayingWaitsForIt() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("first", at: at(0)))
        XCTAssertEqual(policy.handle(.hintArrived("second", at: at(0.5))), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(0.8))), .none, "the first is still playing")
        XCTAssertEqual(policy.handle(.speechFinished), .none)
        XCTAssertEqual(policy.handle(.tick(at: at(1))), .speak("second"))
    }

    func testAHintNotStartedWithinFiveSecondsIsDropped() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(1)))
        XCTAssertEqual(policy.handle(.tick(at: at(5.99))), .none, "4.99 s: still waiting")
        XCTAssertEqual(policy.waiting, "12 weeks")
        XCTAssertEqual(policy.handle(.tick(at: at(6))), .drop(.stale), "5 s")
        XCTAssertNil(policy.waiting)
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(6.5)))
        XCTAssertEqual(policy.handle(.tick(at: at(7))), .none)
        XCTAssertEqual(policy.lastHint, "12 weeks", "still on the screen")
    }

    func testAHintCanStartAtFourPointNineNineSeconds() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(1)))
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(5.5)))
        XCTAssertEqual(policy.handle(.tick(at: at(5.99))), .speak("12 weeks"), "490 ms quiet, 4.99 s old")
    }

    func testQuietAtFiveSecondsIsTooLate() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(1)))
        XCTAssertEqual(policy.handle(.speechActivity(isSpeaking: false, at: at(6))), .drop(.stale))
    }

    // MARK: - Never the phone speaker

    func testThePolicyStartsOnThePhoneSpeaker() {
        var policy = HintSpeechPolicy()
        XCTAssertTrue(policy.isPhoneSpeaker)
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(0))), .drop(.phoneSpeaker))
    }

    func testOnThePhoneSpeakerAHintIsForTheScreenOnly() {
        var policy = HintSpeechPolicy(isPhoneSpeaker: true)
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(0))), .drop(.phoneSpeaker))
        XCTAssertEqual(policy.lastHint, "12 weeks", "kept for the screen")
        XCTAssertNil(policy.waiting)
        XCTAssertEqual(policy.handle(.tick(at: at(1))), .none)
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(2))), .drop(.phoneSpeaker))
    }

    func testFallingBackToTheSpeakerStopsAHintMidWay() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        XCTAssertEqual(policy.handle(.outputRoute(isPhoneSpeaker: true)), .stopSpeaking)
        XCTAssertNil(policy.speaking)
    }

    func testFallingBackToTheSpeakerDropsAWaitingHint() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(0.1)))
        XCTAssertEqual(policy.handle(.outputRoute(isPhoneSpeaker: true)), .drop(.phoneSpeaker))
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(0.5)))
        XCTAssertEqual(policy.handle(.tick(at: at(1))), .none)
    }

    func testAHeadsetArrivingLetsTheNextHintSpeak() {
        var policy = HintSpeechPolicy(isPhoneSpeaker: true)
        XCTAssertEqual(policy.handle(.outputRoute(isPhoneSpeaker: false)), .none)
        XCTAssertEqual(policy.handle(.hintArrived("12 weeks", at: at(0))), .speak("12 weeks"))
    }

    // MARK: - Repeat and skip

    func testRepeatSpeaksTheLastHintAgain() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        _ = policy.handle(.speechFinished)
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(30))), .speak("12 weeks"),
                       "a repeat is fresh from the moment it's asked for")
    }

    func testRepeatFollowsTheQuietRule() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        _ = policy.handle(.speechFinished)
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(10)))
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(10.5))), .none)
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(11)))
        XCTAssertEqual(policy.handle(.tick(at: at(11.4))), .speak("12 weeks"))
    }

    func testRepeatWithNothingToSay() {
        var policy = earPolicy()
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(0))), .drop(.nothingToRepeat))
    }

    func testRepeatWhilePlayingDoesNotStartItTwice() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        XCTAssertEqual(policy.handle(.repeatRequested(at: at(0.5))), .none)
    }

    func testSkipStopsTheHint() {
        var policy = earPolicy()
        _ = policy.handle(.hintArrived("12 weeks", at: at(0)))
        XCTAssertEqual(policy.handle(.skipRequested), .stopSpeaking)
        XCTAssertNil(policy.speaking)
        XCTAssertEqual(policy.handle(.skipRequested), .none)
    }

    func testSkipDropsAWaitingHint() {
        var policy = earPolicy()
        _ = policy.handle(.speechActivity(isSpeaking: true, at: at(0)))
        _ = policy.handle(.hintArrived("12 weeks", at: at(0.1)))
        XCTAssertEqual(policy.handle(.skipRequested), .drop(.skipped))
        _ = policy.handle(.speechActivity(isSpeaking: false, at: at(0.5)))
        XCTAssertEqual(policy.handle(.tick(at: at(1))), .none)
    }

    func testTheTimingsAreThePlans() {
        XCTAssertEqual(HintLimits.quietBeforeSpeaking, 0.4)
        XCTAssertEqual(HintLimits.speakWithin, 5)
    }
}
