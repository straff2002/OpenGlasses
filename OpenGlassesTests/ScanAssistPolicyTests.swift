import XCTest
@testable import OpenGlasses

/// The deterministic half of Scan Assist (docs/plans/FB-scan-assist.md P1).
///
/// Every test drives a fake monotonic clock by hand, so "thirty seconds later" is an assignment
/// rather than a wait. What is being pinned here is not that a timer fires — it is that a cue
/// belonging to a side, a rhythm or a session the wearer has moved on from can never be produced.
@MainActor
final class ScanAssistPolicyTests: XCTestCase {

    /// A settable monotonic clock. Class so the policy's captured closure sees the test's writes.
    final class FakeClock {
        var now: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var clock = FakeClock()

    override func setUp() {
        super.setUp()
        clock = FakeClock()
    }

    private func makePolicy(side: ScanAssistSide? = .left,
                            interval: ScanAssistInterval = .thirtySeconds,
                            duration: ScanAssistSessionDuration = .fiveMinutes) -> ScanAssistPolicy {
        ScanAssistPolicy(side: side, interval: interval, sessionDuration: duration,
                         now: { [clock] in clock.now })
    }

    // MARK: - Starting

    func testStartWithoutASideDoesNothing() {
        var policy = makePolicy(side: nil)
        XCTAssertEqual(policy.handle(.start), [])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertNil(policy.nextCueDeadline)
        XCTAssertNil(policy.sessionExpiry)
    }

    func testStartSchedulesTheFirstCueOneIntervalOutAndTheExpiryOneSessionOut() {
        var policy = makePolicy()
        clock.now = 100
        XCTAssertEqual(policy.handle(.start), [])
        XCTAssertEqual(policy.state, .running)
        XCTAssertEqual(policy.nextCueDeadline, 130)
        XCTAssertEqual(policy.sessionExpiry, 400)
        XCTAssertEqual(policy.nextWakeDeadline, 130)
    }

    func testRepeatedStartLeavesTheOneSessionAlone() {
        var policy = makePolicy()
        policy.handle(.start)
        let expiry = policy.sessionExpiry
        let generation = policy.generation

        clock.advance(10)
        XCTAssertEqual(policy.handle(.start), [])
        XCTAssertEqual(policy.sessionExpiry, expiry, "a second Start must not hand back a fresh session length")
        XCTAssertEqual(policy.nextCueDeadline, 30)
        XCTAssertEqual(policy.generation, generation, "no new generation means nothing scheduled was invalidated")
    }

    // MARK: - Cues

    func testTickBeforeTheDeadlineEmitsNothing() {
        var policy = makePolicy()
        policy.handle(.start)
        clock.advance(29)
        XCTAssertEqual(policy.handle(.tick), [])
    }

    func testTickAtTheDeadlineEmitsTheChosenSideAndSchedulesTheNext() {
        var policy = makePolicy(side: .left)
        policy.handle(.start)
        clock.advance(30)
        XCTAssertEqual(policy.handle(.tick), [.emitCue(side: .left, generation: policy.generation)])
        XCTAssertEqual(policy.nextCueDeadline, 60)

        clock.advance(30)
        XCTAssertEqual(policy.handle(.tick), [.emitCue(side: .left, generation: policy.generation)])
    }

    func testRightSideEmitsTheRightSide() {
        var policy = makePolicy(side: .right)
        policy.handle(.start)
        clock.advance(30)
        XCTAssertEqual(policy.handle(.tick), [.emitCue(side: .right, generation: policy.generation)])
    }

    /// A wake-up that arrives late must not try to catch up: the next gap is measured from the cue
    /// that actually happened, not from the deadline it slipped past.
    func testALateTickSchedulesAFullIntervalFromWhenItFired() {
        var policy = makePolicy()
        policy.handle(.start)
        clock.advance(47)
        policy.handle(.tick)
        XCTAssertEqual(policy.nextCueDeadline, 77)
    }

    // MARK: - Side changes

    func testChangingSideInvalidatesTheQueuedCueAndKeepsTheRhythm() {
        var policy = makePolicy(side: .left)
        policy.handle(.start)
        let startGeneration = policy.generation

        clock.advance(10)
        XCTAssertEqual(policy.handle(.sideChanged(.right)), [.cancelQueuedCue])
        XCTAssertNotEqual(policy.generation, startGeneration,
                          "the queued left cue must be recognisable as stale")
        XCTAssertEqual(policy.nextCueDeadline, 30, "changing side changes the word, not the rhythm")

        clock.advance(20)
        XCTAssertEqual(policy.handle(.tick), [.emitCue(side: .right, generation: policy.generation)])
    }

    func testChoosingTheSameSideAgainChangesNothing() {
        var policy = makePolicy(side: .left)
        policy.handle(.start)
        let generation = policy.generation
        XCTAssertEqual(policy.handle(.sideChanged(.left)), [])
        XCTAssertEqual(policy.generation, generation)
    }

    func testClearingTheSideMidSessionEndsItRatherThanGuessing() {
        var policy = makePolicy(side: .left)
        policy.handle(.start)
        XCTAssertEqual(policy.handle(.sideChanged(nil)),
                       [.cancelQueuedCue, .sessionEnded(reason: .stopped)])
        XCTAssertEqual(policy.state, .ended(.stopped))
        XCTAssertNil(policy.nextWakeDeadline)
    }

    func testChangingSideWhileIdleJustRecordsIt() {
        var policy = makePolicy(side: nil)
        XCTAssertEqual(policy.handle(.sideChanged(.right)), [])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.side, .right)
    }

    // MARK: - Timing changes

    func testChangingTimingReschedulesFromTheChange() {
        var policy = makePolicy(interval: .thirtySeconds, duration: .fiveMinutes)
        policy.handle(.start)
        clock.advance(20)
        XCTAssertEqual(policy.handle(.timingChanged(interval: .oneMinute, duration: .tenMinutes)),
                       [.cancelQueuedCue])
        XCTAssertEqual(policy.nextCueDeadline, 80, "a longer gap must not still owe the shorter gap's cue")
        XCTAssertEqual(policy.sessionExpiry, 620)
    }

    func testChangingOnlyTheSessionLengthStillRestartsTheRhythmFromNow() {
        var policy = makePolicy(interval: .thirtySeconds, duration: .fiveMinutes)
        policy.handle(.start)
        clock.advance(10)
        XCTAssertEqual(policy.handle(.timingChanged(interval: .thirtySeconds, duration: .twoMinutes)),
                       [.cancelQueuedCue])
        XCTAssertEqual(policy.sessionExpiry, 130)
        XCTAssertEqual(policy.nextCueDeadline, 40)
    }

    func testUnchangedTimingIsNotAChange() {
        var policy = makePolicy(interval: .thirtySeconds, duration: .fiveMinutes)
        policy.handle(.start)
        let generation = policy.generation
        XCTAssertEqual(policy.handle(.timingChanged(interval: .thirtySeconds, duration: .fiveMinutes)), [])
        XCTAssertEqual(policy.generation, generation)
    }

    // MARK: - Pause and resume

    func testPauseCancelsTheQueuedCueAndFreezesTheRemainingTime() {
        var policy = makePolicy(duration: .fiveMinutes)
        policy.handle(.start)
        clock.advance(25)
        XCTAssertEqual(policy.handle(.pause), [.cancelQueuedCue])
        XCTAssertEqual(policy.state, .paused)
        XCTAssertNil(policy.nextWakeDeadline, "a paused session owns no scheduled work")
        XCTAssertEqual(policy.remainingSeconds, 275)

        clock.advance(600)
        XCTAssertEqual(policy.remainingSeconds, 275, "a paused session does not spend its own time")
    }

    func testPausedTicksEmitNothing() {
        var policy = makePolicy()
        policy.handle(.start)
        policy.handle(.pause)
        clock.advance(300)
        XCTAssertEqual(policy.handle(.tick), [])
    }

    func testResumeGivesAFreshIntervalAndNoBacklog() {
        var policy = makePolicy(interval: .thirtySeconds, duration: .fiveMinutes)
        policy.handle(.start)
        clock.advance(25)
        policy.handle(.pause)
        clock.advance(1000)

        XCTAssertEqual(policy.handle(.resume), [.cancelQueuedCue])
        XCTAssertEqual(policy.state, .running)
        XCTAssertEqual(policy.nextCueDeadline, 1055, "one whole interval from the resume, not five seconds")
        XCTAssertEqual(policy.sessionExpiry, 1300, "the frozen 275 seconds continue from here")

        // Nothing is owed for the sixteen intervals that elapsed while paused.
        clock.advance(30)
        XCTAssertEqual(policy.handle(.tick), [.emitCue(side: .left, generation: policy.generation)])
    }

    func testResumeWithoutAPauseDoesNothing() {
        var policy = makePolicy()
        policy.handle(.start)
        let generation = policy.generation
        XCTAssertEqual(policy.handle(.resume), [])
        XCTAssertEqual(policy.generation, generation)
    }

    // MARK: - Stopping and expiry

    func testStopEndsTheSessionAndCancelsEverythingItOwned() {
        var policy = makePolicy()
        policy.handle(.start)
        XCTAssertEqual(policy.handle(.stop), [.cancelQueuedCue, .sessionEnded(reason: .stopped)])
        XCTAssertEqual(policy.state, .ended(.stopped))
        XCTAssertNil(policy.nextCueDeadline)
        XCTAssertNil(policy.sessionExpiry)
        XCTAssertNil(policy.remainingSeconds)
    }

    func testRepeatedStopIsHarmless() {
        var policy = makePolicy()
        policy.handle(.start)
        policy.handle(.stop)
        let generation = policy.generation
        XCTAssertEqual(policy.handle(.stop), [], "a second Stop must not report a second ending")
        XCTAssertEqual(policy.generation, generation)
    }

    func testStopBeforeAnySessionIsHarmless() {
        var policy = makePolicy()
        XCTAssertEqual(policy.handle(.stop), [])
        XCTAssertEqual(policy.state, .idle)
    }

    func testAPausedSessionCanStillBeStopped() {
        var policy = makePolicy()
        policy.handle(.start)
        policy.handle(.pause)
        XCTAssertEqual(policy.handle(.stop), [.cancelQueuedCue, .sessionEnded(reason: .stopped)])
    }

    func testTickAtTheSessionExpiryEndsItInsteadOfCueing() {
        var policy = makePolicy(interval: .twoMinutes, duration: .twoMinutes)
        policy.handle(.start)
        clock.advance(120)
        XCTAssertEqual(policy.handle(.tick), [.cancelQueuedCue, .sessionEnded(reason: .expired)],
                       "when a cue and the end of the session coincide, the session is over")
        XCTAssertEqual(policy.state, .ended(.expired))
    }

    /// The reason expiry is folded into `nextWakeDeadline`: with a session shorter than the gap
    /// between reminders, nothing would ever wake up to notice the session had finished.
    func testTheWakeDeadlineIsTheEarlierOfTheCueAndTheExpiry() {
        var policy = makePolicy(interval: .twoMinutes, duration: .twoMinutes)
        policy.handle(.start)
        XCTAssertEqual(policy.nextWakeDeadline, 120)

        var longer = makePolicy(interval: .twoMinutes, duration: .tenMinutes)
        longer.handle(.start)
        XCTAssertEqual(longer.nextWakeDeadline, 120)
    }

    func testExpiryEventEndsTheSession() {
        var policy = makePolicy()
        policy.handle(.start)
        XCTAssertEqual(policy.handle(.expired), [.cancelQueuedCue, .sessionEnded(reason: .expired)])
        XCTAssertEqual(policy.state, .ended(.expired))
    }

    func testAnEndedSessionCanBeStartedAgain() {
        var policy = makePolicy()
        policy.handle(.start)
        policy.handle(.stop)
        clock.advance(5)
        XCTAssertEqual(policy.handle(.start), [])
        XCTAssertEqual(policy.state, .running)
        XCTAssertEqual(policy.nextCueDeadline, 35)
    }

    // MARK: - Generations

    func testEveryInvalidatingTransitionMovesTheGeneration() {
        var policy = makePolicy()
        var seen: Set<Int> = [policy.generation]

        for event: ScanAssistEvent in [.start, .sideChanged(.right),
                                       .timingChanged(interval: .oneMinute, duration: .twoMinutes),
                                       .pause, .resume, .stop] {
            policy.handle(event)
            XCTAssertFalse(seen.contains(policy.generation),
                           "\(event) left scheduled work indistinguishable from fresh work")
            seen.insert(policy.generation)
        }
    }
}
