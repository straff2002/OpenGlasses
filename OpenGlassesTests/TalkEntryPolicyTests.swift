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
        XCTAssertTrue(SessionCardGlassesPill.awayHint.contains("put them on"),
                      "the usual reason is a pair in its case, so that comes first")
        XCTAssertTrue(SessionCardGlassesPill.awayHint.contains("Settings › Devices & Privacy › Glasses"),
                      "the tap is only a hint, so it names where the row to press is (Plan HX P3a)")
    }

    // MARK: - Session card: job pill

    func testNoOpenJobShowsNoJobPill() {
        XCTAssertNil(SessionCardJobPill.presentation(jobOpen: false, paused: false))
        XCTAssertNil(SessionCardJobPill.presentation(jobOpen: false, paused: true),
                     "a stale pause on a job that is not open is not news")
        XCTAssertNil(SessionCardJobPill.presentation(session: nil),
                     "without Field Assist there is never a session, so never a pill")
    }

    func testARunningJobReadsRunningAndOpensTheJob() {
        XCTAssertEqual(SessionCardJobPill.presentation(jobOpen: true, paused: false),
                       .init(word: "Job running", systemImage: "checklist", tint: .ok,
                             action: .openJob,
                             accessibilityHint: "Double-tap to open the job, where you can pause or end it."))
    }

    /// The case the pill exists for: a job paused when the app closed, restored paused, and
    /// otherwise invisible from the home screen.
    func testAPausedJobReadsPausedAndOpensTheJob() {
        XCTAssertEqual(SessionCardJobPill.presentation(jobOpen: true, paused: true),
                       .init(word: "Job paused", systemImage: "pause.circle", tint: .warn,
                             action: .openJob,
                             accessibilityHint: "Double-tap to open the job, where you can resume or end it."))
    }

    func testTheJobPillsTwoStatesDifferInShapeAsWellAsColour() {
        let running = SessionCardJobPill.presentation(jobOpen: true, paused: false)
        let paused = SessionCardJobPill.presentation(jobOpen: true, paused: true)
        XCTAssertNotEqual(running?.systemImage, paused?.systemImage)
        XCTAssertNotEqual(running?.tint, paused?.tint)
    }

    func testTheJobPillsLabelIsItsWordAndItsHintNamesTheTap() {
        for paused in [false, true] {
            guard let presentation = SessionCardJobPill.presentation(jobOpen: true, paused: paused) else {
                return XCTFail("an open job always has a pill")
            }
            XCTAssertEqual(presentation.accessibilityLabel, presentation.word)
            XCTAssertTrue(presentation.accessibilityHint.hasPrefix("Double-tap to open the job"))
            XCTAssertFalse(presentation.word.localizedCaseInsensitiveContains("tap"))
        }
    }

    private func session(_ json: String) throws -> FieldSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FieldSession.self, from: Data(json.utf8))
    }

    /// Read off the session the same way the Job tab's presence is: not ended, not cancelled —
    /// and paused by `pausedAt`, the field pause, resume and the launch restore all write.
    func testTheJobPillReadsTheOpenSession() throws {
        let base = #""id":"s1","vaultId":"refrigeration","mode":"ai_only","startedAt":"2026-10-03T08:00:00Z","escalations":[],"billableSeconds":0"#
        let running = try session("{\(base),\"outcome\":\"in_progress\"}")
        let paused = try session("{\(base),\"outcome\":\"paused\",\"pausedAt\":\"2026-10-03T09:00:00Z\"}")
        let ended = try session("{\(base),\"outcome\":\"resolved\",\"endedAt\":\"2026-10-03T10:00:00Z\"}")
        let cancelled = try session("{\(base),\"outcome\":\"cancelled\"}")

        XCTAssertEqual(SessionCardJobPill.presentation(session: running)?.word, "Job running")
        XCTAssertEqual(SessionCardJobPill.presentation(session: paused)?.word, "Job paused")
        XCTAssertNil(SessionCardJobPill.presentation(session: ended))
        XCTAssertNil(SessionCardJobPill.presentation(session: cancelled))
    }

    // MARK: - Session card: wake word off

    /// The master switch can be turned off from the Lock Screen, Control Center, a widget or Siri,
    /// and the card used to keep saying "Ready". It says so now — unless push-to-talk is the
    /// wearer's own choice, when the wake phrase being off is expected.
    func testTheCardSaysTheWakeWordIsOffOnlyWhenItIsExpected() {
        XCTAssertTrue(SessionCardWakeWordNotice.shows(listeningEnabled: false, pushToTalk: false))
        XCTAssertFalse(SessionCardWakeWordNotice.shows(listeningEnabled: false, pushToTalk: true),
                       "Push-to-talk is a choice, not a fault")
        XCTAssertFalse(SessionCardWakeWordNotice.shows(listeningEnabled: true, pushToTalk: false))
        XCTAssertFalse(SessionCardWakeWordNotice.shows(listeningEnabled: true, pushToTalk: true))
    }

    func testTheWakeWordNoticeSaysWhatATapDoes() {
        XCTAssertTrue(SessionCardWakeWordNotice.text.localizedCaseInsensitiveContains("wake word off"))
        XCTAssertTrue(SessionCardWakeWordNotice.text.localizedCaseInsensitiveContains("tap to turn on"))
        XCTAssertFalse(SessionCardWakeWordNotice.accessibilityLabel.localizedCaseInsensitiveContains("tap"),
                       "VoiceOver's gesture is a double-tap; the spoken name should not instruct one")
        XCTAssertFalse(SessionCardWakeWordNotice.accessibilityHint.isEmpty)
    }
}
