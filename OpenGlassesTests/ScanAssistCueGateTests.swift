import XCTest
@testable import OpenGlasses

/// Plan FB P2 — whether a reminder plays, waits, or is thrown away.
///
/// The property these tests exist to pin is the one a wearer feels: **a reminder that had to wait
/// is worth playing only while it is still the newest thing the session has to say.** Everything
/// else here — the priority order of the reasons, the budget, the stale checks — is in service of
/// never producing the burst of reminders that arrives when a phone call ends.
final class ScanAssistCueGateTests: XCTestCase {

    private func busy(_ reason: ScanAssistDeferralReason) -> ScanAssistAudioSignals {
        var signals = ScanAssistAudioSignals()
        switch reason {
        case .userSpeaking: signals.userIsSpeaking = true
        case .assistantSpeaking: signals.assistantIsSpeaking = true
        case .voiceOverSpeaking: signals.voiceOverIsSpeaking = true
        case .lifecycleAnnouncement: signals.lifecycleAnnouncementInFlight = true
        case .higherPriorityNotice: signals.higherPriorityNoticeInFlight = true
        }
        return signals
    }

    private func offer(_ gate: inout ScanAssistCueGate,
                       side: ScanAssistSide = .left,
                       generation: Int = 1,
                       current: Int = 1,
                       running: Bool = true,
                       signals: ScanAssistAudioSignals = .clear,
                       at now: TimeInterval = 0) -> ScanAssistCueDecision {
        gate.offer(side: side, generation: generation, currentGeneration: current,
                   isRunning: running, signals: signals, at: now)
    }

    // MARK: - A free route

    func testAFreeRouteDeliversImmediatelyAndHoldsNothing() {
        var gate = ScanAssistCueGate()
        XCTAssertEqual(offer(&gate), .deliver(side: .left, generation: 1))
        XCTAssertNil(gate.held, "a delivered reminder is not also a waiting one")
    }

    // MARK: - Every reason to wait

    func testEveryBusySignalDefersWithItsOwnReason() {
        for reason in ScanAssistDeferralReason.allCases {
            var gate = ScanAssistCueGate()
            XCTAssertEqual(offer(&gate, signals: busy(reason)), .deferred(reason),
                           "\(reason) must hold the reminder back")
            XCTAssertEqual(gate.held?.side, .left)
        }
    }

    /// The wearer's own voice outranks everything. A reminder spoken over someone mid-sentence is
    /// the one interruption this feature must never cause.
    func testTheWearersOwnSpeechOutranksTheOtherReasons() {
        var signals = ScanAssistAudioSignals()
        signals.userIsSpeaking = true
        signals.assistantIsSpeaking = true
        signals.higherPriorityNoticeInFlight = true
        XCTAssertEqual(signals.busyReason, .userSpeaking)
    }

    func testAClearRouteHasNoReasonToWait() {
        XCTAssertNil(ScanAssistAudioSignals.clear.busyReason)
    }

    // MARK: - The deferred cue is only ever the newest one

    func testASecondCueReplacesTheWaitingOneSoOnlyOnePlays() {
        var gate = ScanAssistCueGate(deferralBudget: 100)
        XCTAssertEqual(offer(&gate, generation: 1, current: 1,
                             signals: busy(.assistantSpeaking), at: 0),
                       .deferred(.assistantSpeaking))
        // The session ticks on: a new reminder comes due while the route is still busy.
        XCTAssertEqual(offer(&gate, generation: 2, current: 2,
                             signals: busy(.assistantSpeaking), at: 30),
                       .deferred(.assistantSpeaking))
        XCTAssertEqual(gate.held?.generation, 2, "only the newest reminder is worth keeping")

        // The route frees. Exactly one reminder plays, and nothing is left owed.
        XCTAssertEqual(gate.recheck(currentGeneration: 2, isRunning: true,
                                    signals: .clear, at: 31),
                       .deliver(side: .left, generation: 2))
        XCTAssertEqual(gate.recheck(currentGeneration: 2, isRunning: true,
                                    signals: .clear, at: 32),
                       .nothingWaiting,
                       "there is no backlog to replay")
    }

    func testTheWaitingCueSurvivesRepeatedBusyRechecks() {
        var gate = ScanAssistCueGate(deferralBudget: 10)
        _ = offer(&gate, signals: busy(.userSpeaking), at: 0)
        for moment in [1.0, 2.0, 3.0] {
            XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true,
                                        signals: busy(.userSpeaking), at: moment),
                           .deferred(.userSpeaking))
        }
        XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true, signals: .clear, at: 4),
                       .deliver(side: .left, generation: 1))
    }

    // MARK: - Stale

    func testACueForAGenerationThatHasMovedOnIsDropped() {
        var gate = ScanAssistCueGate()
        XCTAssertEqual(offer(&gate, generation: 1, current: 4), .dropped(.stale))
        XCTAssertNil(gate.held)
    }

    func testACueOfferedAfterTheSessionStoppedIsDropped() {
        var gate = ScanAssistCueGate()
        XCTAssertEqual(offer(&gate, running: false), .dropped(.stale))
        XCTAssertNil(gate.held)
    }

    /// A stop, a pause or a side change lands here: the reminder was for a session that no longer
    /// exists, so it is not owed however long it waited.
    func testAWaitingCueIsDroppedWhenTheSessionMovesOnUnderIt() {
        var gate = ScanAssistCueGate()
        _ = offer(&gate, signals: busy(.assistantSpeaking))
        XCTAssertEqual(gate.recheck(currentGeneration: 2, isRunning: true, signals: .clear, at: 1),
                       .dropped(.stale))
        XCTAssertNil(gate.held)
    }

    func testAWaitingCueIsDroppedWhenTheSessionStops() {
        var gate = ScanAssistCueGate()
        _ = offer(&gate, signals: busy(.assistantSpeaking))
        XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: false, signals: .clear, at: 1),
                       .dropped(.stale))
    }

    func testCancelHeldThrowsTheWaitingCueAway() {
        var gate = ScanAssistCueGate()
        _ = offer(&gate, signals: busy(.lifecycleAnnouncement))
        gate.cancelHeld()
        XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true, signals: .clear, at: 1),
                       .nothingWaiting)
    }

    // MARK: - The budget

    func testAReminderThatWaitsTooLongIsDroppedRatherThanPlayedLate() {
        var gate = ScanAssistCueGate(deferralBudget: 5)
        _ = offer(&gate, signals: busy(.higherPriorityNotice), at: 0)
        XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true,
                                    signals: busy(.higherPriorityNotice), at: 5),
                       .dropped(.waitedTooLong))
        XCTAssertNil(gate.held)
    }

    /// The budget runs from when the reminder came due, not from the last recheck — otherwise a
    /// route that is busy over and over keeps a stale reminder alive indefinitely.
    func testTheBudgetRunsFromWhenTheCueCameDueNotFromTheLastCheck() {
        var gate = ScanAssistCueGate(deferralBudget: 5)
        _ = offer(&gate, signals: busy(.userSpeaking), at: 0)
        for moment in [2.0, 4.0] {
            XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true,
                                        signals: busy(.userSpeaking), at: moment),
                           .deferred(.userSpeaking))
        }
        XCTAssertEqual(gate.recheck(currentGeneration: 1, isRunning: true,
                                    signals: busy(.userSpeaking), at: 6),
                       .dropped(.waitedTooLong))
    }

    /// The default budget must not outlive the shortest interval the wearer can choose, or a held
    /// reminder could land on top of the next one — the burst, one cue at a time.
    func testTheDefaultBudgetIsShorterThanTheShortestInterval() {
        XCTAssertLessThan(ScanAssistCueGate.defaultDeferralBudget,
                          ScanAssistInterval.fifteenSeconds.seconds)
    }

    // MARK: - The VoiceOver fallback

    /// iOS reports whether VoiceOver is *running*, never whether it is mid-utterance. Treating
    /// "running" as "speaking" would silence the feature for the people most likely to use it.
    func testVoiceOverRunningAloneIsNotAReasonToWait() {
        XCTAssertFalse(ScanAssistAudioSignals.voiceOverLikelySpeaking(
            voiceOverRunning: true, lastAnnouncementAt: nil, now: 100))
    }

    func testVoiceOverIsAssumedBusyForABoundedWindowAfterAnAnnouncement() {
        XCTAssertTrue(ScanAssistAudioSignals.voiceOverLikelySpeaking(
            voiceOverRunning: true, lastAnnouncementAt: 100, now: 101, window: 2.5))
        XCTAssertFalse(ScanAssistAudioSignals.voiceOverLikelySpeaking(
            voiceOverRunning: true, lastAnnouncementAt: 100, now: 103, window: 2.5),
                       "the wait is bounded — it never becomes a permanent silence")
    }

    func testNoWindowAppliesWhenVoiceOverIsOff() {
        XCTAssertFalse(ScanAssistAudioSignals.voiceOverLikelySpeaking(
            voiceOverRunning: false, lastAnnouncementAt: 100, now: 100.1))
    }
}

/// Plan FB P2 — what an audio or lifecycle event does to a session, and what it takes to start it
/// again.
final class ScanAssistInterruptionPolicyTests: XCTestCase {

    private func recovery(_ event: ScanAssistAudioEvent,
                          _ state: ScanAssistState,
                          _ reason: ScanAssistPauseReason? = nil) -> ScanAssistRecovery {
        ScanAssistInterruptionPolicy.recovery(for: event, state: state, pauseReason: reason)
    }

    // MARK: - Pausing, with a reason

    func testEachInterruptionPausesWithItsOwnReason() {
        XCTAssertEqual(recovery(.callBegan, .running), .pause(.call))
        XCTAssertEqual(recovery(.interruptionBegan, .running), .pause(.audioInterrupted))
        XCTAssertEqual(recovery(.outputLost, .running), .pause(.outputChanged))
        XCTAssertEqual(recovery(.enteredBackground, .running), .pause(.background))
    }

    func testNothingHappensToASessionThatIsNotRunning() {
        for state in [ScanAssistState.idle, .ended(.stopped), .ended(.expired)] {
            XCTAssertEqual(recovery(.callBegan, state), .none)
            XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: true), state),
                           .none)
            XCTAssertEqual(recovery(.becameActive, state), .none)
        }
    }

    func testASecondInterruptionDoesNotRewriteTheFirstReason() {
        XCTAssertEqual(recovery(.interruptionBegan, .paused, .call), .none,
                       "the wearer keeps being told the thing that actually stopped their session")
    }

    // MARK: - Certain recovery

    func testAnInterruptionThatEndsCleanlyOnTheSameRouteResumes() {
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: true),
                                .paused, .call), .resume)
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: true),
                                .paused, .audioInterrupted), .resume)
    }

    // MARK: - Uncertain recovery

    func testAnInterruptionEndingWithoutShouldResumeStaysPaused() {
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: false, routeUnchanged: true),
                                .paused, .call),
                       .requireExplicitResume(.call))
    }

    func testComingBackOnADifferentRouteStaysPaused() {
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: false),
                                .paused, .call),
                       .requireExplicitResume(.call))
    }

    /// The route came back, but nothing says it came back to what the wearer was listening with.
    func testAnOutputLossIsNeverACertainRecovery() {
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: true),
                                .paused, .outputChanged),
                       .requireExplicitResume(.outputChanged))
    }

    func testReturningToTheForegroundDoesNotRestartTheSession() {
        XCTAssertEqual(recovery(.becameActive, .paused, .background),
                       .requireExplicitResume(.background))
        XCTAssertEqual(recovery(.interruptionEnded(shouldResume: true, routeUnchanged: true),
                                .paused, .background),
                       .requireExplicitResume(.background))
    }

    // MARK: - The wearer's own pause is theirs

    func testNoAudioEventLiftsAPauseTheWearerAskedFor() {
        for event: ScanAssistAudioEvent in [.interruptionEnded(shouldResume: true, routeUnchanged: true),
                                            .becameActive] {
            XCTAssertEqual(recovery(event, .paused, nil), .none,
                           "resuming someone's own pause would be the app deciding they are ready")
        }
    }
}
