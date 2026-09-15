import XCTest
@testable import OpenGlasses

/// Plan FF P0/PR2 — what a blind wearer actually *hears* across a session's lifetime.
///
/// The rule under test is not "a cue exists". It is that **every cue is true at the moment it is
/// heard**. A tone that says the connection dropped, played after it came back, is worse than
/// silence for someone whose only channel is audio: they stop what they are doing, they wait, and
/// nothing further happens. So the assertions here are about ordering and expiry, not about copy.
///
/// The coordinator is driven through the same `handle(_:)` the two realtime managers call, with a
/// fake clock, a fake route and a recording sink, so the order of tones and lines is the assertion.
@MainActor
final class AudibleLifecycleTests: XCTestCase {

    // MARK: - Harness

    /// Records the interleaving of tones and speech. The sequence *is* the test.
    private final class Harness {
        var clock = Date(timeIntervalSince1970: 1_000)
        var active = true
        var style: AudibleLifecyclePolicy.CueStyle = .tonesAndSpeech
        var route = AudibleLifecyclePolicy.SpeechRoute()
        var freshFrame = false
        var events: [String] = []
        var spoken: [(line: String, interrupts: Bool)] = []

        /// Tones only, for the cases where the wording is irrelevant.
        var tones: [AudibleLifecyclePolicy.Earcon] = []
    }

    private func makeCoordinator(_ h: Harness) -> AudibleLifecycleCoordinator {
        AudibleLifecycleCoordinator(
            isActive: { h.active },
            style: { h.style },
            route: { h.route },
            visualEvidence: { h.freshFrame },
            now: { h.clock },
            autoPump: false,
            playEarcon: { earcon in
                h.tones.append(earcon)
                h.events.append("tone(\(earcon.rawValue))")
            },
            speak: { line, interrupts in
                h.spoken.append((line, interrupts))
                h.events.append("say(\(line))")
            })
    }

    private func usableStart() -> AudibleLifecycleCoordinator.Signal {
        .sessionStarted(.init(audioSessionActive: true,
                              sessionConnected: true,
                              microphoneListening: true))
    }

    // MARK: - Start → usable

    func testSessionBecomesUsableOnlyWhenAudioConnectionAndMicrophoneAllHold() {
        let h = Harness()
        let coordinator = makeCoordinator(h)

        coordinator.handle(usableStart())

        XCTAssertEqual(h.tones, [.ready])
        XCTAssertEqual(h.spoken.first?.line, "Ready. I'm listening.")
        XCTAssertEqual(h.spoken.first?.interrupts, false)
    }

    /// A connected socket with no microphone is not an assistant. Saying "ready" there sends the
    /// wearer talking into a void and waiting for an answer that cannot come.
    func testAConnectedSessionWithNoMicrophoneSaysNothing() {
        let h = Harness()
        let coordinator = makeCoordinator(h)

        coordinator.handle(.sessionStarted(.init(audioSessionActive: true,
                                                 sessionConnected: true,
                                                 microphoneListening: false)))

        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testASocketThatNeverFinishedSetupIsNotReportedAsReady() {
        let h = Harness()
        let coordinator = makeCoordinator(h)

        coordinator.handle(.sessionStarted(.init(audioSessionActive: true,
                                                 sessionConnected: false,
                                                 microphoneListening: true)))

        XCTAssertTrue(h.events.isEmpty)
    }

    // MARK: - Loss → retry → recovery

    func testLossThenRecoveryPlaysOneLossCueAndOneRecoveryCue() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        coordinator.handle(.connectionLost)
        h.clock.addTimeInterval(3)
        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: false))

        XCTAssertEqual(h.tones, [.lost, .restored])
        XCTAssertEqual(h.spoken.map(\.line),
                       ["Connection lost. Trying to get it back.", "Back. I'm listening."])
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    /// The headline failure: the loss notice waited behind the assistant's speech, the socket came
    /// back while it waited, and the queued line was no longer true by the time the route freed.
    func testDisconnectedCannotPlayAfterASuccessfulRecovery() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)
        XCTAssertTrue(h.events.isEmpty, "a busy route queues rather than talks over the assistant")
        XCTAssertTrue(coordinator.isPending(.connectionLost))

        h.clock.addTimeInterval(2)
        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: false))

        h.route.assistantSpeaking = false
        h.clock.addTimeInterval(1)
        coordinator.pump()
        coordinator.pump()

        XCTAssertFalse(h.spoken.contains { $0.line.contains("Connection lost") },
                       "a loss that stopped being true must never be spoken")
        // The wearer heard no interruption at all — the assistant talked through it — so a
        // "back, I'm listening" would answer a question nobody asked.
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testALossAfterARecoveryIsANewNotice() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())

        coordinator.handle(.connectionLost)
        h.clock.addTimeInterval(5)
        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: false))
        h.clock.addTimeInterval(30)
        coordinator.handle(.connectionLost)

        XCTAssertEqual(h.tones, [.ready, .lost, .restored, .lost])
    }

    // MARK: - Recovery shape

    /// The reason the cue is not fired from the reconnect callback: at callback time the camera has
    /// by construction produced nothing, so deciding there reports every healthy recovery as
    /// camera-unavailable and teaches the wearer to ignore the distinction.
    func testARecoveryIsNotDecidedAtCallbackTime() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        coordinator.handle(.connectionLost)
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.freshFrame = false
        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: true))
        XCTAssertTrue(h.events.isEmpty, "nothing is claimed before the camera has had a chance")
        XCTAssertTrue(coordinator.hasPendingWork)

        // The stream comes back inside the window.
        h.clock.addTimeInterval(1)
        h.freshFrame = true
        coordinator.pump()

        XCTAssertEqual(h.tones, [.restored])
        XCTAssertEqual(h.spoken.map(\.line), ["Back. I'm listening."])
    }

    func testARecoveryWithAudioButNoFreshFrameSaysTheCameraIsNotBack() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        coordinator.handle(.connectionLost)
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.freshFrame = false
        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: true))
        h.clock.addTimeInterval(AudibleLifecycleCoordinator.recoveryEvidenceWindow + 0.1)
        coordinator.pump()

        XCTAssertEqual(h.tones, [.restored])
        XCTAssertEqual(h.spoken.first?.line,
                       "Audio is back. The camera isn't — I can hear you, but I can't see.")
    }

    /// An audio-only session has no camera claim to make, so it never waits for one.
    func testAnAudioOnlySessionRecoversImmediately() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        coordinator.handle(.connectionLost)
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: false))

        XCTAssertEqual(h.spoken.map(\.line), ["Back. I'm listening."])
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    /// The restart that used to be a log line and nothing else.
    func testAReconnectWhoseMicrophoneDidNotComeBackIsReportedAsDegraded() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        coordinator.handle(.connectionLost)
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        coordinator.handle(.reconnected(audioRestored: false, needsVisualEvidence: true))

        XCTAssertEqual(h.tones, [.failed])
        XCTAssertEqual(h.spoken.first?.line,
                       "Connected again, but the microphone didn't come back. Stop and start the session to try again.")
    }

    /// A degraded recovery is new information regardless of what the wearer heard before it, so it
    /// is not subject to the "no heard loss, no recovery line" rule.
    func testADegradedRecoveryIsSaidEvenWhenTheLossWasNeverHeard() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)
        coordinator.handle(.reconnected(audioRestored: false, needsVisualEvidence: true))
        h.route.assistantSpeaking = false
        coordinator.pump()

        XCTAssertEqual(h.tones, [.failed])
        XCTAssertFalse(h.spoken.contains { $0.line.contains("Connection lost") })
    }

    // MARK: - Exhaustion

    func testTheTerminalFailurePlaysEvenWhileTheAssistantIsSpeaking() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)
        coordinator.handle(.reconnectExhausted)
        XCTAssertTrue(h.events.isEmpty, "it waits first — landing on an answer the wearer asked for is its own harm")

        h.clock.addTimeInterval(AudibleLifecyclePolicy.maxQueuedWait)
        coordinator.pump()

        XCTAssertEqual(h.tones, [.failed])
        XCTAssertEqual(h.spoken.first?.line, "Connection lost. I couldn't get it back.")
        XCTAssertEqual(h.spoken.first?.interrupts, true,
                       "a terminal failure is the one notice allowed to take the floor")
    }

    /// "Trying to get it back" after "I gave up" is nonsense, so exhaustion clears the retry notice.
    func testExhaustionSupersedesAQueuedLossNotice() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)
        coordinator.handle(.reconnectExhausted)

        XCTAssertFalse(coordinator.isPending(.connectionLost))
        XCTAssertEqual(coordinator.pendingCount, 1)
    }

    func testTheOnlyFailureNoticeIsNotDroppedIndefinitely() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)

        // Long past anything a non-failure notice would survive.
        h.clock.addTimeInterval(AudibleLifecyclePolicy.maxQueuedWait + 60)
        coordinator.pump()

        XCTAssertEqual(h.tones, [.lost])
        XCTAssertEqual(h.spoken.first?.interrupts, false,
                       "a retry report waits its bound but does not seize the floor")
    }

    // MARK: - Requested capture

    func testARequestedCaptureThatSucceededPlaysTheCaptureCue() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        coordinator.handle(.requestedCaptureSucceeded)

        XCTAssertEqual(h.tones, [.captured])
        XCTAssertEqual(h.spoken.first?.line, "Photo taken.")
    }

    /// "Photo taken" is a statement about a moment. Ten seconds later it describes the wrong one,
    /// and a wearer who has moved on would go looking for a picture of something else.
    func testACaptureCueThatWaitedTooLongIsDroppedRatherThanPlayedLate() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(usableStart())
        h.events.removeAll(); h.tones.removeAll(); h.spoken.removeAll()

        h.route.assistantSpeaking = true
        coordinator.handle(.requestedCaptureSucceeded)
        h.clock.addTimeInterval(10)
        h.route.assistantSpeaking = false
        coordinator.pump()

        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    // MARK: - Queueing

    func testACueThatArrivesWhileTheAssistantSpeaksIsQueuedThenDelivered() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route.assistantSpeaking = true

        coordinator.handle(usableStart())
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertEqual(coordinator.pendingCount, 1)

        h.route.assistantSpeaking = false
        h.clock.addTimeInterval(1)
        coordinator.pump()

        XCTAssertEqual(h.tones, [.ready])
    }

    /// VoiceOver reading one of this app's own announcements occupies the same ear. It is a reason
    /// to wait, never a reason to stay silent — which is the difference between this and
    /// `SessionAnnouncementPolicy`, whose first rule is that VoiceOver has to be running at all.
    func testAnAnnouncementInFlightCountsAsABusyRoute() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route.voiceOverAnnouncing = true

        coordinator.handle(.connectionLost)
        XCTAssertTrue(h.events.isEmpty)

        h.route.voiceOverAnnouncing = false
        coordinator.pump()
        XCTAssertEqual(h.tones, [.lost])
    }

    /// The cue is audible with VoiceOver off. That is the whole reason this exists beside the
    /// announcer, whose every decision begins by requiring VoiceOver.
    func testCuesAreHeardWithVoiceOverOff() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route = .init(assistantSpeaking: false, voiceOverAnnouncing: false)

        coordinator.handle(.connectionLost)

        XCTAssertEqual(h.tones, [.lost])
        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .reconnecting(mode: "Gemini Live"),
            context: AnnouncementContext(voiceOverRunning: false)),
                     "VoiceOver off means the screen reader says nothing — the tone is what carries it")
    }

    /// …and with VoiceOver on, the screen reader stops reading the transitions the lifecycle now
    /// owns, so one event is not narrated twice by two voices.
    func testVoiceOverStopsReadingTheTransitionsTheLifecycleNowOwns() {
        let withCues = AnnouncementContext(voiceOverRunning: true, blindAssistantCuesActive: true)
        let withoutCues = AnnouncementContext(voiceOverRunning: true, blindAssistantCuesActive: false)

        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .liveSession(mode: "Gemini Live", active: true), context: withCues))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .reconnecting(mode: "Gemini Live"), context: withCues))

        // Without the lifecycle running, nothing else makes a sound for them, so they stay announced.
        XCTAssertEqual(SessionAnnouncementPolicy.announcement(
            for: .liveSession(mode: "Gemini Live", active: true), context: withoutCues)?.message,
                       "Gemini Live session started")
        XCTAssertEqual(SessionAnnouncementPolicy.announcement(
            for: .reconnecting(mode: "Gemini Live"), context: withoutCues)?.message,
                       "Gemini Live reconnecting")

        // The events the lifecycle does *not* cover are unaffected in both directions.
        XCTAssertEqual(SessionAnnouncementPolicy.announcement(
            for: .cameraStreaming(true), context: withCues)?.message, "Camera started")
        XCTAssertEqual(SessionAnnouncementPolicy.announcement(
            for: .micMuted(true), context: withCues)?.message, "Microphone muted")
    }

    func testTheQueueIsBounded() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route.assistantSpeaking = true

        for _ in 0..<6 { coordinator.handle(.requestedCaptureSucceeded) }
        coordinator.handle(.connectionLost)

        XCTAssertLessThanOrEqual(coordinator.pendingCount, AudibleLifecyclePolicy.maxQueueDepth)
        XCTAssertTrue(coordinator.isPending(.connectionLost),
                      "a backlog of cosmetic cues must never push the failure out")
    }

    func testAFailureGoesFirstWhenTheRouteFrees() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route.assistantSpeaking = true
        coordinator.handle(.requestedCaptureSucceeded)
        coordinator.handle(.connectionLost)

        h.route.assistantSpeaking = false
        coordinator.pump()

        XCTAssertEqual(h.tones, [.lost])
    }

    func testANoticeFromAReplacedSessionIsDroppedRatherThanSpokenAboutTheNewOne() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        h.route.assistantSpeaking = true
        coordinator.handle(.connectionLost)
        XCTAssertTrue(coordinator.isPending(.connectionLost))
        let firstGeneration = coordinator.generation

        // A new session starts. Whatever was waiting was about a session that no longer exists.
        coordinator.handle(usableStart())
        XCTAssertGreaterThan(coordinator.generation, firstGeneration)
        XCTAssertFalse(coordinator.isPending(.connectionLost))

        h.route.assistantSpeaking = false
        coordinator.pump()
        XCTAssertEqual(h.tones, [.ready])
    }

    func testAnIdenticalNoticeInsideTheRepeatWindowIsSuppressed() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        coordinator.handle(.connectionLost)
        h.clock.addTimeInterval(AudibleLifecyclePolicy.repeatWindow / 2)
        coordinator.handle(.connectionLost)

        XCTAssertEqual(h.tones, [.lost], "a republished flag is not a second drop")

        h.clock.addTimeInterval(AudibleLifecyclePolicy.repeatWindow * 2)
        coordinator.handle(.connectionLost)
        XCTAssertEqual(h.tones, [.lost, .lost], "a genuine second drop is still reported")
    }

    // MARK: - Settings and gating

    func testTonesOnlyStillPlaysTheEarcon() {
        let h = Harness()
        h.style = .tonesOnly
        let coordinator = makeCoordinator(h)

        coordinator.handle(usableStart())

        XCTAssertEqual(h.tones, [.ready])
        XCTAssertTrue(h.spoken.isEmpty, "turning the words off never makes an event silent")
    }

    /// Any preset other than Blind Assistant keeps the behaviour it had: the managers' own local
    /// cue, and no new noise. The return value is what tells them so.
    func testAnotherPresetLeavesTheExistingBehaviourAlone() {
        let h = Harness()
        h.active = false
        let coordinator = makeCoordinator(h)

        XCTAssertFalse(coordinator.handle(.connectionLost))
        XCTAssertFalse(coordinator.handle(.reconnectExhausted))
        XCTAssertFalse(coordinator.handle(usableStart()))
        XCTAssertTrue(h.events.isEmpty)
    }

    func testAClaimedCueIsReportedAsClaimedSoTheManagerStaysQuiet() {
        let h = Harness()
        let coordinator = makeCoordinator(h)
        // Even queued — the route is busy — the coordinator owns the delivery, so the manager's
        // own spoken fallback must not fire beside it.
        h.route.assistantSpeaking = true
        XCTAssertTrue(coordinator.handle(.reconnectExhausted))
        XCTAssertTrue(coordinator.isPending(.recoveryFailed))
    }

    // MARK: - The cue-learning flow

    func testTheCueTourPlaysEverySoundWithItsMeaning() async {
        let h = Harness()
        let coordinator = makeCoordinator(h)

        await coordinator.playCueTour(gap: 0).value

        XCTAssertEqual(h.tones, AudibleLifecyclePolicy.lessons.map(\.earcon))
        XCTAssertEqual(h.spoken.map(\.line), AudibleLifecyclePolicy.lessons.map(\.meaning))
        // Sound first, then its meaning — the pairing is the lesson.
        XCTAssertEqual(h.events.first, "tone(ready)")
        XCTAssertEqual(h.events[1], "say(\(AudibleLifecyclePolicy.lessons[0].meaning))")
    }

    func testEveryEarconHasALesson() {
        let taught = Set(AudibleLifecyclePolicy.lessons.map(\.earcon))
        XCTAssertEqual(taught, Set(AudibleLifecyclePolicy.Earcon.allCases),
                       "a cue the wearer can hear but cannot look up is a cue they will ignore")
        for lesson in AudibleLifecyclePolicy.lessons {
            XCTAssertTrue(lesson.meaning.contains("This sound means"))
        }
    }

    /// The tour runs from a settings control, so it must work for a wearer who is deciding whether
    /// to turn Blind Assistant on at all — not only for one who already has.
    func testTheCueTourRunsWhicheverPresetIsSelected() async {
        let h = Harness()
        h.active = false
        let coordinator = makeCoordinator(h)

        await coordinator.playCueTour(gap: 0).value

        XCTAssertEqual(h.tones.count, AudibleLifecyclePolicy.lessons.count)
    }

    // MARK: - The pure policy

    func testRecoveryEvidenceTable() {
        typealias P = AudibleLifecyclePolicy
        XCTAssertEqual(P.recoveryNotice(for: .init(audioRestored: false, needsVisualEvidence: false,
                                                   hasFreshVisualEvidence: true)),
                       .recoveryIncomplete)
        XCTAssertEqual(P.recoveryNotice(for: .init(audioRestored: true, needsVisualEvidence: false,
                                                   hasFreshVisualEvidence: false)),
                       .serviceRestored(.full))
        XCTAssertEqual(P.recoveryNotice(for: .init(audioRestored: true, needsVisualEvidence: true,
                                                   hasFreshVisualEvidence: true)),
                       .serviceRestored(.full))
        XCTAssertEqual(P.recoveryNotice(for: .init(audioRestored: true, needsVisualEvidence: true,
                                                   hasFreshVisualEvidence: false)),
                       .serviceRestored(.cameraUnavailable))
    }

    func testOnlyTheTerminalFailureMayInterrupt() {
        typealias P = AudibleLifecyclePolicy
        XCTAssertTrue(P.cue(for: .recoveryFailed, style: .tonesAndSpeech).interrupts)
        for notice: P.Notice in [.sessionUsable, .connectionLost, .serviceRestored(.full),
                                 .serviceRestored(.cameraUnavailable), .captureSucceeded,
                                 .recoveryIncomplete] {
            XCTAssertFalse(P.cue(for: notice, style: .tonesAndSpeech).interrupts,
                           "\(notice) must not seize the floor")
        }
    }

    func testFailureNoticesNeverGoStaleByTime() {
        typealias P = AudibleLifecyclePolicy
        for notice: P.Notice in [.connectionLost, .recoveryIncomplete, .recoveryFailed] {
            XCTAssertTrue(P.isFailure(notice))
            XCTAssertNil(P.staleAfter(notice), "a failure the wearer was never told about is still true")
        }
        XCTAssertNotNil(P.staleAfter(.captureSucceeded))
        XCTAssertNotNil(P.staleAfter(.sessionUsable))
    }

    /// The spoken half is held to the same rule the contract puts on the model: report what is
    /// observed, never assure.
    func testTheCameraUnavailableLineSaysPlainlyThatItCannotSee() {
        let line = AudibleLifecyclePolicy.spokenLine(for: .serviceRestored(.cameraUnavailable))
        XCTAssertTrue(line.lowercased().contains("can't see"))
        XCTAssertFalse(line.lowercased().contains("safe"))
    }

    func testEveryEarconIsDistinct() {
        typealias P = AudibleLifecyclePolicy
        let notices: [P.Notice] = [.sessionUsable, .connectionLost, .serviceRestored(.full),
                                   .captureSucceeded, .recoveryFailed]
        XCTAssertEqual(Set(notices.map(P.earcon(for:))).count, notices.count,
                       "four feedbacks the wearer cannot tell apart are one feedback")
    }
}
