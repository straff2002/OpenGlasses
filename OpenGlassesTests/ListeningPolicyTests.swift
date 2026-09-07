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
