import XCTest
@testable import OpenGlasses

/// Issue 427 follow-up: turning listening off must END the conversation, not strand it.
///
/// The finish stage used to `return` early when the master toggle was off, leaving
/// `inConversation == true`. `onWakeWordDetected`'s `guard !inConversation && !isProcessing` then
/// dropped every later wake word. Field trace (build 371): `tts finished; wakeWord
/// listenerSkippedDisabled` at 16:11:10, then at 16:11:49 `wakeWord detected` immediately followed
/// by `app alreadyProcessing detail=wakeWord` — and no recovery short of a force-quit.
final class FinishStagePolicyTests: XCTestCase {

    func testListeningOnMidConversationKeepsTheMicOpenForAFollowUp() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: true),
                       .resumeDictation)
    }

    func testListeningOnWithNoConversationGoesBackToWakeWord() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: true, inConversation: false),
                       .endConversation)
    }

    /// The regression proper.
    func testListeningDisabledMidConversationStillEndsTheConversation() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: false, inConversation: true),
                       .endConversation,
                       "a disabled toggle must close the conversation, not leave it open forever")
    }

    func testListeningDisabledWithNoConversationIsAlsoTheEndPath() {
        XCTAssertEqual(FinishStagePolicy.action(listeningEnabled: false, inConversation: false),
                       .endConversation)
    }

    /// There is no input pair that means "do nothing" — that state was the bug.
    func testNoCombinationStrandsTheConversation() {
        for listening in [true, false] {
            for inConversation in [true, false] {
                let action = FinishStagePolicy.action(listeningEnabled: listening,
                                                      inConversation: inConversation)
                if action == .resumeDictation {
                    XCTAssertTrue(listening && inConversation,
                                  "only an enabled toggle inside a conversation may reopen the mic")
                }
            }
        }
    }
}

/// Issue 427 follow-up: a wake word must not be heard while the master toggle is off.
///
/// The toggle was enforced by `AppState.returnToWakeWord()` but not by the foreground restart
/// (`OpenGlassesApp.swift`) and not by `WakeWordService`'s own route-change / interruption
/// restarts. Field trace (build 371): `becameActive; routeChanged reconfigure; engineReused;
/// listenerStarted` at 16:11:46-47 and `wakeWord detected` at 16:11:49 — with the toggle off.
final class WakeAutoRestartPolicyTests: XCTestCase {

    private func restart(listening: Bool = true,
                         silent: Bool = false,
                         connected: Bool = true,
                         muted: Bool = false,
                         already: Bool = false) -> Bool {
        WakeAutoRestartPolicy.shouldRestart(listeningEnabled: listening,
                                            silentMode: silent,
                                            isConnected: connected,
                                            micMuted: muted,
                                            alreadyListening: already)
    }

    func testRestartsWhenEverythingIsReady() {
        XCTAssertTrue(restart())
    }

    /// The regression proper.
    func testTheMasterToggleVetoesTheRestart() {
        XCTAssertFalse(restart(listening: false))
    }

    /// And it vetoes regardless of how favourable everything else is.
    func testTheMasterToggleVetoesEvenWhenEveryOtherConditionIsPerfect() {
        for silent in [true, false] {
            for connected in [true, false] {
                for muted in [true, false] {
                    for already in [true, false] {
                        XCTAssertFalse(restart(listening: false, silent: silent,
                                               connected: connected, muted: muted, already: already),
                                       "listening off must always win")
                    }
                }
            }
        }
    }

    func testPushToTalkSuppressesTheAlwaysOnListener() {
        XCTAssertFalse(restart(silent: true))
    }

    func testDisconnectedGlassesDoNotHandTheListenerThePhoneMic() {
        XCTAssertFalse(restart(connected: false))
    }

    func testMutedMicDoesNotRestart() {
        XCTAssertFalse(restart(muted: true))
    }

    func testAlreadyListeningIsANoOp() {
        XCTAssertFalse(restart(already: true))
    }
}

/// The end-of-turn re-arm, and the reason a field build (407) only ever heard one wake word per
/// launch: `returnToWakeWord()` skipped on a cached `isConnected` that had latched false, logged a
/// line and returned, and nothing was left watching for the condition to clear.
final class WakeRearmPolicyTests: XCTestCase {

    private func decide(listening: Bool = true,
                        silent: Bool = false,
                        wasInConversation: Bool = true,
                        connected: Bool = true,
                        muted: Bool = false) -> WakeRearmPolicy.Decision {
        WakeRearmPolicy.decide(.init(listeningEnabled: listening,
                                     silentMode: silent,
                                     wasInConversation: wasInConversation,
                                     isConnected: connected,
                                     micMuted: muted))
    }

    func testAnOrdinaryTurnEndsWithTheMicReArmed() {
        XCTAssertEqual(decide(), .restart)
    }

    func testTheMasterToggleSkipsAndIsNotRetried() {
        XCTAssertEqual(decide(listening: false), .skip(.masterOff))
        XCTAssertFalse(WakeRearmPolicy.SkipReason.masterOff.isRecoverable,
                       "the wearer turned listening off; retrying would turn the mic back on")
    }

    /// Silent mode suppresses the *initial* auto-start only. Someone who has just been talking
    /// expects the mic back for their next wake word.
    func testPushToTalkStillReArmsAfterAConversation() {
        XCTAssertEqual(decide(silent: true, wasInConversation: true), .restart)
        XCTAssertEqual(decide(silent: true, wasInConversation: false), .skip(.silentMode))
    }

    func testAMutedMicSkipsAndIsNotRetried() {
        XCTAssertEqual(decide(muted: true), .skip(.micMuted))
        XCTAssertFalse(WakeRearmPolicy.SkipReason.micMuted.isRecoverable)
    }

    /// The bug's shape: the one skip the wearer did not ask for, and the only one that may clear
    /// on its own — so it must be the one that schedules another attempt.
    func testADisconnectedLinkIsTheOnlyRecoverableSkip() {
        XCTAssertEqual(decide(connected: false), .skip(.disconnected))
        XCTAssertTrue(WakeRearmPolicy.SkipReason.disconnected.isRecoverable)
        for reason in [WakeRearmPolicy.SkipReason.masterOff, .silentMode, .micMuted] {
            XCTAssertFalse(reason.isRecoverable, "\(reason) is the wearer's decision, not a fault")
        }
    }

    /// Order matters: a wearer with listening off and no glasses must not be retried at, so the
    /// master toggle has to be read before the link.
    func testTheMasterToggleIsReadBeforeTheLink() {
        XCTAssertEqual(decide(listening: false, connected: false), .skip(.masterOff))
    }

    func testEveryReasonIsLoggableAsAStableToken() {
        XCTAssertEqual(WakeRearmPolicy.SkipReason.masterOff.rawValue, "masterOff")
        XCTAssertEqual(WakeRearmPolicy.SkipReason.silentMode.rawValue, "silentMode")
        XCTAssertEqual(WakeRearmPolicy.SkipReason.disconnected.rawValue, "disconnected")
        XCTAssertEqual(WakeRearmPolicy.SkipReason.micMuted.rawValue, "micMuted")
    }

    func testTheRetryScheduleIsBoundedAndAscending() {
        XCTAssertFalse(WakeRearmPolicy.retryDelays.isEmpty)
        XCTAssertEqual(WakeRearmPolicy.retryDelays, WakeRearmPolicy.retryDelays.sorted())
        XCTAssertLessThanOrEqual(WakeRearmPolicy.retryDelays.reduce(0, +), 30,
                                 "a re-arm that keeps trying forever is a mic that turns itself on")
    }
}

/// A job's turns belong in one thread. Tying the saved thread's life to `inConversation` filed
/// every wake-word turn as its own one-turn conversation.
final class ConversationThreadContinuityPolicyTests: XCTestCase {

    private func shouldEnd(persistence: Bool = true,
                           hasThread: Bool = true,
                           fieldSession: Bool = false) -> Bool {
        ConversationThreadContinuityPolicy.shouldEndSavedThread(persistenceEnabled: persistence,
                                                                hasActiveThread: hasThread,
                                                                fieldSessionActive: fieldSession)
    }

    func testAnOrdinaryTurnClosesItsThread() {
        XCTAssertTrue(shouldEnd())
    }

    func testAJobKeepsItsThreadOpenBetweenTurns() {
        XCTAssertFalse(shouldEnd(fieldSession: true),
                       "the next wake word continues the job's conversation")
    }

    func testNothingToEndIsNotAnEnd() {
        XCTAssertFalse(shouldEnd(hasThread: false))
        XCTAssertFalse(shouldEnd(persistence: false))
    }

    /// The rule is scoped to the job being active — finishing it must let the thread close again.
    func testTheThreadClosesOnceTheJobIsOver() {
        XCTAssertFalse(shouldEnd(fieldSession: true))
        XCTAssertTrue(shouldEnd(fieldSession: false))
    }
}
