import XCTest
@testable import OpenGlasses

/// Phone-first voice entry. The regression these pin: with glasses registered but in their case,
/// the talk capsule read "Connect & Talk", spent 15 s trying to register them and then showed a
/// glasses error instead of listening — talking was blocked by glasses that were not needed.
final class TalkEntryPolicyTests: XCTestCase {

    private let everyPhase: [GlassesConnectionPhase] = [.noGlassesAdded, .addedDisconnected,
                                                        .connecting, .connected]

    // MARK: - Talk capsule / connectAndListen

    func testGlassesAwayOrNeverAddedTalksOnThePhoneAtOnce() {
        for link: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected] {
            let d = TalkEntryPolicy.decide(link: link, stoodDown: false)
            XCTAssertEqual(d.action, .talk, "\(link): no connect attempt, no wait")
            XCTAssertEqual(d.label, "Tap & Talk")
        }
    }

    func testConnectedGlassesTalkAtOnce() {
        XCTAssertEqual(TalkEntryPolicy.decide(link: .connected, stoodDown: false),
                       .init(label: "Tap & Talk", action: .talk))
    }

    func testAConnectingLinkGetsABoundedWaitThenTalks() {
        XCTAssertEqual(TalkEntryPolicy.decide(link: .connecting, stoodDown: false),
                       .init(label: "Tap & Talk", action: .awaitLinkThenTalk))
        XCTAssertLessThanOrEqual(TalkEntryPolicy.linkWaitSeconds, 5,
                                 "a wait for glasses must stay short — the phone can talk now")
    }

    func testStoodDownGlassesAreResumedThenTalk() {
        XCTAssertEqual(TalkEntryPolicy.decide(link: .connected, stoodDown: true),
                       .init(label: "Resume & Talk", action: .resumeGlassesThenTalk))
    }

    func testNoPhaseEverLabelsTheCapsuleAsAConnect() {
        for link in everyPhase {
            for stoodDown in [false, true] {
                let label = TalkEntryPolicy.decide(link: link, stoodDown: stoodDown).label
                XCTAssertFalse(label.localizedCaseInsensitiveContains("connect"),
                               "\(link)/\(stoodDown): \(label)")
                XCTAssertTrue(label.hasSuffix("& Talk"))
            }
        }
    }

    /// Every decision ends in talking: none is a glasses connect, so none can end in a glasses
    /// error. The capsule, the widget, the watch, the Dynamic Island, `avenkin://connect` and the
    /// Siri connect actions all reach this through `connectAndListen()`.
    func testEveryDecisionEndsInTalking() {
        for link in everyPhase {
            for stoodDown in [false, true] {
                let action = TalkEntryPolicy.decide(link: link, stoodDown: stoodDown).action
                XCTAssertTrue([.talk, .awaitLinkThenTalk, .resumeGlassesThenTalk].contains(action))
            }
        }
    }

    // MARK: - Session card headline

    func testTheCardReportsTheSessionWhenNoGlassesConnectIsUnderWay() {
        // The device finding: glasses away and registered left "Waiting for device…" on the card
        // over a phone that was ready to talk.
        for link in everyPhase {
            XCTAssertNil(SessionCardGlassesHeadline.headline(connectAttemptInFlight: false, link: link,
                                                             connectionStatus: "Waiting for device…"))
        }
    }

    func testAWearersGlassesConnectShowsItsProgress() {
        XCTAssertEqual(SessionCardGlassesHeadline.headline(connectAttemptInFlight: true,
                                                           link: .addedDisconnected,
                                                           connectionStatus: "Waiting for device…"),
                       "Waiting for device…")
        XCTAssertEqual(SessionCardGlassesHeadline.headline(connectAttemptInFlight: true,
                                                           link: .noGlassesAdded,
                                                           connectionStatus: "Not connected"),
                       "Glasses Not Connected")
        XCTAssertEqual(SessionCardGlassesHeadline.headline(connectAttemptInFlight: true,
                                                           link: .connecting,
                                                           connectionStatus: "Registering..."),
                       "Connecting…")
    }

    func testOnceConnectedTheCardIsTheSessionsAgain() {
        XCTAssertNil(SessionCardGlassesHeadline.headline(connectAttemptInFlight: true, link: .connected,
                                                         connectionStatus: "Connected to X"))
    }

    // MARK: - Wake word on launch / foreground

    func testLaunchWaitsForRegistrationOnlyForSomeoneWithGlasses() {
        for raw in 0...2 {
            XCTAssertFalse(WakeLaunchPolicy.awaitsRegistrationOnLaunch(stateRaw: raw, glassesAdded: false),
                           "phone-only: nothing to protect, start at once")
            XCTAssertTrue(WakeLaunchPolicy.awaitsRegistrationOnLaunch(stateRaw: raw, glassesAdded: true))
        }
        XCTAssertFalse(WakeLaunchPolicy.awaitsRegistrationOnLaunch(stateRaw: 3, glassesAdded: true))
    }

    func testForegroundHoldsOffOnlyWhileARegistrationIsInFlight() {
        XCTAssertFalse(WakeLaunchPolicy.defersForegroundRestart(stateRaw: 0), "no glasses: start")
        XCTAssertFalse(WakeLaunchPolicy.defersForegroundRestart(stateRaw: 1))
        XCTAssertTrue(WakeLaunchPolicy.defersForegroundRestart(stateRaw: 2))
        XCTAssertFalse(WakeLaunchPolicy.defersForegroundRestart(stateRaw: 3))
    }

    // MARK: - Voice input availability

    func testGlassesAwayNeverCloseTheMicOnlyTheWearersDisconnectDoes() {
        for link in everyPhase {
            var use = GlassesUse()
            use.linkChanged(link)
            XCTAssertTrue(use.voiceInputAvailable, "\(link): the phone's mic is a good device")
        }
        var use = GlassesUse()
        use.linkChanged(.connected)
        use.standDown()
        XCTAssertFalse(use.voiceInputAvailable, "stood down: nothing re-opens a mic")
        use.linkChanged(.addedDisconnected)
        XCTAssertTrue(use.voiceInputAvailable, "the glasses went away; the phone is the device again")
    }

    // MARK: - Session card mode dot

    /// Device feedback: the dot before "Mode: Avenkin" tracked the glasses (green on, grey off) in a
    /// sentence that never mentions them. Muted always wins — the session may be perfectly healthy,
    /// the wearer just turned the input off.
    func testMutedWinsOverEveryRealtimePhase() {
        for phase: SessionCardRealtimePhase in [.disconnected, .connecting, .settingUp, .ready, .error] {
            for sessionActive in [false, true] {
                for reconnecting in [false, true] {
                    XCTAssertEqual(.muted, SessionCardModeDot.realtime(sessionActive: sessionActive,
                                                                       phase: phase, muted: true,
                                                                       reconnecting: reconnecting))
                }
            }
        }
        XCTAssertEqual(.muted, SessionCardModeDot.direct(muted: true))
    }

    func testRealtimeBeforeOrAfterATurnReadsReadyAsActive() {
        // `session.isActive == false`: the card's own headline already reads "Ready" — the dot
        // must not disagree with the sentence beside it.
        for phase: SessionCardRealtimePhase in [.disconnected, .connecting, .settingUp, .ready, .error] {
            XCTAssertEqual(.active, SessionCardModeDot.realtime(sessionActive: false, phase: phase,
                                                                muted: false, reconnecting: false))
        }
    }

    func testRealtimeListeningSpeakingAndLinkingUpAreAllActive() {
        for phase: SessionCardRealtimePhase in [.ready, .connecting, .settingUp] {
            XCTAssertEqual(.active, SessionCardModeDot.realtime(sessionActive: true, phase: phase,
                                                                muted: false, reconnecting: false))
        }
    }

    func testRealtimeErrorIsAlwaysError() {
        XCTAssertEqual(.error, SessionCardModeDot.realtime(sessionActive: true, phase: .error,
                                                           muted: false, reconnecting: false))
    }

    func testRealtimeDisconnectedIsOfflineUnlessItIsRetrying() {
        XCTAssertEqual(.offline, SessionCardModeDot.realtime(sessionActive: true, phase: .disconnected,
                                                             muted: false, reconnecting: false))
        // Reconnecting: the row already reads "Reconnecting…" — the dot stays active rather than
        // repeating the sentence beside it in grey.
        XCTAssertEqual(.active, SessionCardModeDot.realtime(sessionActive: true, phase: .disconnected,
                                                            muted: false, reconnecting: true))
    }

    func testDirectVoiceHasNoOfflineOrErrorTier() {
        XCTAssertEqual(.active, SessionCardModeDot.direct(muted: false))
    }

    func testModeDotTintAndPrefix() {
        XCTAssertEqual(SessionCardModeDot.active.tint, .ok)
        XCTAssertEqual(SessionCardModeDot.muted.tint, .warn)
        XCTAssertEqual(SessionCardModeDot.error.tint, .error)
        XCTAssertEqual(SessionCardModeDot.offline.tint, .quiet)

        XCTAssertTrue(SessionCardModeDot.active.readsAsActiveMode)
        for dot: SessionCardModeDot in [.muted, .error, .offline] {
            XCTAssertFalse(dot.readsAsActiveMode, "\(dot)")
        }
    }

    // MARK: - Session card glasses pill

    func testNeverAddedGlassesShowNoPillInAnyPhaseOrStandDown() {
        for link in everyPhase {
            for stoodDown in [false, true] {
                XCTAssertNil(SessionCardGlassesPill.presentation(link: link, stoodDown: stoodDown,
                                                                  everAdded: false),
                             "\(link)/\(stoodDown): never added means no pill at all")
            }
        }
    }

    func testConnectedAndInUseReadsAttached() {
        let presentation = SessionCardGlassesPill.presentation(link: .connected, stoodDown: false,
                                                                everAdded: true)
        XCTAssertEqual(presentation, .init(word: "Glasses attached", tint: .ok, showsLiveDot: true,
                                           action: .disconnect,
                                           accessibilityHint: "Double-tap to disconnect the glasses."))
    }

    func testStoodDownReadsPausedAndResumesOnTap() {
        let presentation = SessionCardGlassesPill.presentation(link: .connected, stoodDown: true,
                                                                everAdded: true)
        XCTAssertEqual(presentation, .init(word: "Glasses paused", tint: .quiet, showsLiveDot: false,
                                           action: .resume,
                                           accessibilityHint: "Double-tap to resume the glasses."))
    }

    func testConnectingReadsConnectingAndDoesNothingOnTap() {
        let presentation = SessionCardGlassesPill.presentation(link: .connecting, stoodDown: false,
                                                                everAdded: true)
        XCTAssertEqual(presentation, .init(word: "Connecting…", tint: .warn, showsLiveDot: false,
                                           action: .none,
                                           accessibilityHint: "Glasses are linking up."))
    }

    /// The regression this pill redesign exists for: away (added, not connecting) must never carry
    /// the connect-and-wait action — only a plain hint.
    func testAddedButUnreachableReadsAwayAndOnlyHints() {
        for link: GlassesConnectionPhase in [.addedDisconnected, .noGlassesAdded] {
            let presentation = SessionCardGlassesPill.presentation(link: link, stoodDown: false,
                                                                    everAdded: true)
            XCTAssertEqual(presentation,
                           .init(word: "Glasses away", tint: .quiet, showsLiveDot: false,
                                 action: .hint,
                                 accessibilityHint: "Double-tap for help reconnecting the glasses."),
                           "\(link)")
        }
    }

    func testEveryPresentationsAccessibilityLabelMatchesItsVisibleWord() {
        for link in everyPhase {
            for stoodDown in [false, true] {
                guard let presentation = SessionCardGlassesPill.presentation(
                    link: link, stoodDown: stoodDown, everAdded: true) else { continue }
                XCTAssertEqual(presentation.accessibilityLabel, presentation.word, "\(link)/\(stoodDown)")
            }
        }
    }

    func testAwayHintNamesWhatToDoNotTheSDKsInternalState() {
        XCTAssertFalse(SessionCardGlassesPill.awayHint.contains("state"),
                       "must never read like the SDK's own diagnostic text")
        XCTAssertTrue(SessionCardGlassesPill.awayHint.localizedCaseInsensitiveContains("Meta AI"))
    }
}
