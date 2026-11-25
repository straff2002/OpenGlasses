import XCTest
@testable import OpenGlasses

/// Plan NH P0 — the pure core: the decision and its notice threshold, a turn's floor and ceiling,
/// when a turn's time stops, the Live session at zero, and first aid.
final class DailyAllowancePolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The decision

    func testFifteenMinutesADay() {
        XCTAssertEqual(DailyAllowancePolicy.allowanceSeconds, 900)
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 0, exempt: false), .proceed)
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 900, exempt: false), .exhausted)
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 2_000, exempt: false), .exhausted)
    }

    func testTheNoticeStartsBelowThreeMinutes() {
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 900 - 180, exempt: false), .proceed,
                       "exactly three minutes left is not yet below three")
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 900 - 179, exempt: false),
                       .proceedWithNotice(remainingSeconds: 179))
        XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: 899, exempt: false),
                       .proceedWithNotice(remainingSeconds: 1))
    }

    func testAnExemptUserIsNeverRefusedOrNoticed() {
        for used in [0, 800, 900, 10_000] {
            XCTAssertEqual(DailyAllowancePolicy.decide(usedSeconds: used, exempt: true), .proceed)
        }
    }

    func testRemainingNeverGoesNegative() {
        XCTAssertEqual(DailyAllowancePolicy.remaining(usedSeconds: 1_000), 0)
        XCTAssertEqual(DailyAllowancePolicy.remaining(usedSeconds: -5), 900)
    }

    // MARK: - A turn's floor and ceiling

    func testAQuickTurnCountsFiveSeconds() {
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0), 5)
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(1.2)), 5)
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(4.01)), 5)
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(-30)), 5,
                       "a clock that went backwards still charges the floor")
    }

    func testATurnIsChargedWholeSecondsRoundedUp() {
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(12.1)), 13)
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(60)), 60)
    }

    func testAStuckTurnCountsThreeMinutesAtMost() {
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(180)), 180)
        XCTAssertEqual(DailyAllowancePolicy.turnCharge(startedAt: t0, finishedAt: t0.addingTimeInterval(3_600)), 180)
    }

    // MARK: - The Home line

    func testTheHomeLineWaitsForTheFirstTurnAndHidesWhenExempt() {
        XCTAssertNil(DailyAllowancePolicy.homeStatus(usedSeconds: 0, exempt: false), "nothing run today")
        XCTAssertNil(DailyAllowancePolicy.homeStatus(usedSeconds: 600, exempt: true), "exempt: no counter")
        let started = DailyAllowancePolicy.homeStatus(usedSeconds: 5, exempt: false)
        XCTAssertEqual(started?.remainingSeconds, 895)
        XCTAssertEqual(started?.isLow, false)
        XCTAssertEqual(started?.text, "14 min left today")
    }

    func testTheHomeLineIsAmberBelowThreeMinutes() {
        XCTAssertEqual(DailyAllowancePolicy.homeStatus(usedSeconds: 720, exempt: false)?.isLow, false)
        XCTAssertEqual(DailyAllowancePolicy.homeStatus(usedSeconds: 721, exempt: false)?.isLow, true)
        XCTAssertEqual(DailyAllowancePolicy.homeStatus(usedSeconds: 870, exempt: false)?.text,
                       "Less than a minute left today")
        XCTAssertEqual(DailyAllowancePolicy.homeStatus(usedSeconds: 900, exempt: false)?.text,
                       "No free minutes left today")
    }

    func testTheExhaustedLineIsTheOneThePlanSays() {
        XCTAssertEqual(DailyAllowancePolicy.exhaustedLine,
                       "That's today's 15 free minutes. Unlimited is in Settings, under Subscription, or the minutes come back at midnight.")
    }

    // MARK: - When a turn's time stops

    func testAShownReplyIsChargedWhenItCameBack() {
        var tracker = TurnChargeTracker()
        XCTAssertNil(tracker.begin(at: t0))
        tracker.replyReturned(at: t0.addingTimeInterval(20), speaking: false)
        XCTAssertNil(tracker.tick(at: t0.addingTimeInterval(21)), "speech may still start")
        XCTAssertEqual(tracker.tick(at: t0.addingTimeInterval(22)), 20)
        XCTAssertTrue(tracker.isIdle)
    }

    func testASpokenReplyIsChargedWhenTheSpeechStops() {
        var tracker = TurnChargeTracker()
        _ = tracker.begin(at: t0)
        tracker.replyReturned(at: t0.addingTimeInterval(10), speaking: false)
        XCTAssertNil(tracker.speech(active: true, at: t0.addingTimeInterval(10.5)))
        XCTAssertNil(tracker.tick(at: t0.addingTimeInterval(30)), "still speaking")
        XCTAssertEqual(tracker.speech(active: false, at: t0.addingTimeInterval(40)), 40)
    }

    func testSpeechThatStartedBeforeTheReplyCameBackCounts() {
        var tracker = TurnChargeTracker()
        _ = tracker.begin(at: t0)
        tracker.replyReturned(at: t0.addingTimeInterval(8), speaking: true)
        XCTAssertEqual(tracker.speech(active: false, at: t0.addingTimeInterval(25)), 25)
    }

    func testSpeechLongAfterTheReplyIsNotThisTurns() {
        var tracker = TurnChargeTracker()
        _ = tracker.begin(at: t0)
        tracker.replyReturned(at: t0.addingTimeInterval(6), speaking: false)
        XCTAssertNil(tracker.speech(active: true, at: t0.addingTimeInterval(9)))
        XCTAssertEqual(tracker.tick(at: t0.addingTimeInterval(9.1)), 6)
    }

    func testAStuckTurnStopsAtTheCeiling() {
        var tracker = TurnChargeTracker()
        _ = tracker.begin(at: t0)
        XCTAssertNil(tracker.tick(at: t0.addingTimeInterval(179)))
        XCTAssertEqual(tracker.tick(at: t0.addingTimeInterval(180)), 180)
        XCTAssertTrue(tracker.isIdle)

        _ = tracker.begin(at: t0)
        tracker.replyReturned(at: t0.addingTimeInterval(10), speaking: true)
        XCTAssertEqual(tracker.tick(at: t0.addingTimeInterval(500)), 180, "speech that never reports its end")
    }

    func testANewTurnEndsTheOneWaitingOnItsSpeech() {
        var tracker = TurnChargeTracker()
        _ = tracker.begin(at: t0)
        tracker.replyReturned(at: t0.addingTimeInterval(10), speaking: true)
        XCTAssertEqual(tracker.begin(at: t0.addingTimeInterval(14)), 14)
    }

    // MARK: - A Live session at zero

    func testTheLiveWarningIsSaidOnceAtAMinuteLeft() {
        var session = LiveAllowanceSession()
        XCTAssertEqual(session.tick(remainingSeconds: 61, answerInProgress: false, now: t0), [])
        XCTAssertEqual(session.tick(remainingSeconds: 60, answerInProgress: false, now: t0), [.warn])
        XCTAssertEqual(session.tick(remainingSeconds: 59, answerInProgress: false, now: t0), [])
        XCTAssertEqual(session.tick(remainingSeconds: 30, answerInProgress: true, now: t0), [])
    }

    func testLiveAtZeroWaitsForTheAnswerThenClosesWithinTheGrace() {
        var session = LiveAllowanceSession()
        _ = session.tick(remainingSeconds: 60, answerInProgress: true, now: t0)
        XCTAssertEqual(session.tick(remainingSeconds: 0, answerInProgress: true, now: t0), [])
        XCTAssertEqual(session.tick(remainingSeconds: 0, answerInProgress: true, now: t0.addingTimeInterval(59)), [])
        XCTAssertEqual(session.tick(remainingSeconds: 0, answerInProgress: true, now: t0.addingTimeInterval(60)), [.close])
        XCTAssertEqual(session.tick(remainingSeconds: 0, answerInProgress: false, now: t0.addingTimeInterval(61)), [],
                       "closed once")
    }

    func testLiveAtZeroClosesWhenTheAnswerFinishes() {
        var session = LiveAllowanceSession()
        _ = session.tick(remainingSeconds: 0, answerInProgress: true, now: t0)
        XCTAssertEqual(session.tick(remainingSeconds: 0, answerInProgress: false, now: t0.addingTimeInterval(12)), [.close])
    }

    // MARK: - First aid

    func testEmergencyPhrasesAreRecognised() {
        for phrase in ["Someone is choking", "start CPR", "where's the nearest AED?", "he's not breathing",
                       "She collapsed and is unresponsive", "first aid for a burn", "call an ambulance",
                       "my friend took an overdose", "I think it's a heart attack", "they're BLEEDING badly",
                       "how do I do the recovery position", "Call 911"] {
            XCTAssertTrue(FirstAidTurnRecognizer.isFirstAid(phrase), phrase)
        }
    }

    func testOrdinaryTurnsAreNot() {
        for phrase in ["what's the weather", "set a timer for ten minutes", "read my email", "",
                       "play some music", "aedes mosquitoes", "chocolate cake recipe"] {
            XCTAssertFalse(FirstAidTurnRecognizer.isFirstAid(phrase), phrase)
        }
    }
}
