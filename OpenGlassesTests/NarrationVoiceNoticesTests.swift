import XCTest
@testable import OpenGlasses

/// Tests for what continuous scene narration says out loud when it stops (Plan CV P3).
///
/// The rules under test are about **restraint**, not copy: who hears an explanation, and how often.
/// Announcing too little is the failure the phase exists to fix; announcing too much turns an
/// accessibility feature into something that interrupts a wearer to talk about itself.
final class NarrationVoiceNoticesTests: XCTestCase {

    /// Drive a real policy so the transitions are the ones the service actually sees, rather than
    /// hand-built structs that could drift from it.
    private func transition(_ events: [NarrationSessionPolicy.Event])
        -> (NarrationSessionPolicy, NarrationSessionPolicy.Transition) {
        var policy = NarrationSessionPolicy()
        var last: NarrationSessionPolicy.Transition!
        for event in events { last = policy.apply(event) }
        return (policy, last)
    }

    // MARK: - Announcing a halt

    func testAnnouncesAHaltToSomeoneBeingNarratedTo() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([.startNarrating, .interruption(.backgrounded, active: true)])

        let copy = notices.notice(for: t, requestedMode: policy.requestedMode)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.contains("background"), "It must say why, not just that it stopped")
        XCTAssertEqual(notices.announcedHalt, .backgrounded)
    }

    func testHaltCopyNamesTheCause() {
        XCTAssertTrue(NarrationVoiceNotices.haltCopy(.backgrounded).contains("background"))
        XCTAssertTrue(NarrationVoiceNotices.haltCopy(.cameraUnavailable).contains("camera"))
    }

    /// Silence only reads as a failure if the wearer expected sound. In `.watching` the loop was
    /// silent by design, so a spoken notice would be the app talking to someone who never asked.
    func testSaysNothingToAWearerWhoWasOnlyWatching() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([.start, .interruption(.backgrounded, active: true)])

        XCTAssertNil(notices.notice(for: t, requestedMode: policy.requestedMode))
        XCTAssertNil(notices.announcedHalt)
    }

    /// A wearer who asked for narration and is momentarily quiet because they asked a question is
    /// still someone relying on narration — which is why the rule keys on the requested mode rather
    /// than on whether speech happened to be live at that instant.
    func testAnnouncesAHaltThatLandsDuringAUserTurn() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([
            .startNarrating,
            .interruption(.userTurn, active: true),
            .interruption(.cameraUnavailable, active: true),
        ])

        let copy = notices.notice(for: t, requestedMode: policy.requestedMode)
        XCTAssertNotNil(copy, "The wearer still asked for narration")
        XCTAssertTrue(copy!.contains("camera"))
    }

    func testDoesNotAnnounceTheSameHaltTwice() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)

        let first = policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertNotNil(notices.notice(for: first, requestedMode: policy.requestedMode))

        // A second interruption arriving while already halted must not re-announce.
        let second = policy.apply(.interruption(.cameraUnavailable, active: true))
        XCTAssertNil(notices.notice(for: second, requestedMode: policy.requestedMode),
                     "A running commentary about being halted is not an explanation")
    }

    // MARK: - Announcing a resume

    func testAnnouncesAResumeOnlyAfterAnAnnouncedHalt() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)

        let halted = policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertNotNil(notices.notice(for: halted, requestedMode: policy.requestedMode))

        let resumed = policy.apply(.interruption(.backgrounded, active: false))
        XCTAssertEqual(notices.notice(for: resumed, requestedMode: policy.requestedMode),
                       NarrationVoiceNotices.resumeCopy)
        XCTAssertNil(notices.announcedHalt)
    }

    /// Otherwise "narration is back on" arrives out of nowhere, explaining a silence the wearer
    /// never noticed.
    func testSilentHaltResumesSilently() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.start)                                  // watching — halt goes unannounced

        let halted = policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertNil(notices.notice(for: halted, requestedMode: policy.requestedMode))

        let resumed = policy.apply(.interruption(.backgrounded, active: false))
        XCTAssertNil(notices.notice(for: resumed, requestedMode: policy.requestedMode))
    }

    // MARK: - Nothing to say

    func testOrdinaryModeChangesAreSilent() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()

        for event in [NarrationSessionPolicy.Event.start, .startNarrating, .stopNarrating, .stop] {
            let t = policy.apply(event)
            XCTAssertNil(notices.notice(for: t, requestedMode: policy.requestedMode),
                         "The wearer's own commands need no explanation: \(event)")
        }
    }

    /// Leaving the mode is the wearer's own doing, so the pending explanation is dropped rather
    /// than delivered later against a session that no longer exists.
    func testStoppingClearsAPendingAnnouncedHalt() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        _ = notices.notice(for: policy.apply(.interruption(.backgrounded, active: true)),
                           requestedMode: policy.requestedMode)
        XCTAssertEqual(notices.announcedHalt, .backgrounded)

        _ = notices.notice(for: policy.apply(.stop), requestedMode: policy.requestedMode)
        XCTAssertNil(notices.announcedHalt)
    }

    func testRefusalCopyCarriesTheGatesReason() {
        let reason = "Scene Narration needs a live camera feed from the glasses, and the connected glasses don't provide one."
        let copy = NarrationVoiceNotices.refusalCopy(reason)
        XCTAssertTrue(copy.contains(reason))
        XCTAssertTrue(copy.hasPrefix("Can't start scene narration."))
    }

    // MARK: - Standing conditions (ambient captions)

    /// The reason this needs announcing at all: a wearer who switched captions on hours ago has
    /// nothing to attribute the silence to, and "narration is broken" is the conclusion they will
    /// reach. The copy has to name the cause *and* the switch that undoes it.
    func testAnnouncesACaptionSilenceAndNamesTheCause() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([.startNarrating, .interruption(.ambientCaptions, active: true)])

        let copy = notices.notice(for: t, requestedMode: policy.requestedMode)
        XCTAssertNotNil(copy)
        XCTAssertTrue(copy!.contains("captions"), "It must say what took the ear")
        XCTAssertTrue(copy!.contains("watching"),
                      "…and that the loop is still watching, so questions still get grounded answers")
        XCTAssertEqual(notices.announcedSilence, .ambientCaptions)
    }

    /// Same restraint rule as a halt: a watching wearer was silent by design.
    func testSaysNothingAboutCaptionsToAWearerWhoWasOnlyWatching() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([.start, .interruption(.ambientCaptions, active: true)])

        XCTAssertNil(notices.notice(for: t, requestedMode: policy.requestedMode))
        XCTAssertNil(notices.announcedSilence)
    }

    /// Captions restarting between utterances must not produce a running commentary about them.
    func testNeverAnnouncesTheSameCaptionSilenceTwice() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)

        let first = policy.apply(.interruption(.ambientCaptions, active: true))
        XCTAssertNotNil(notices.notice(for: first, requestedMode: policy.requestedMode))
        let again = policy.apply(.interruption(.ambientCaptions, active: true))
        XCTAssertNil(notices.notice(for: again, requestedMode: policy.requestedMode))
    }

    /// A resume is only owed to someone who heard the silence explained.
    func testAnnouncesSpeakingAgainOnlyIfTheSilenceWasAnnounced() {
        var announced = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let began = policy.apply(.interruption(.ambientCaptions, active: true))
        _ = announced.notice(for: began, requestedMode: policy.requestedMode)
        let ended = policy.apply(.interruption(.ambientCaptions, active: false))
        XCTAssertEqual(announced.notice(for: ended, requestedMode: policy.requestedMode),
                       NarrationVoiceNotices.speakingAgainCopy)

        var silent = NarrationVoiceNotices()
        var quiet = NarrationSessionPolicy()
        quiet.apply(.start)                                  // watching: the silence went unannounced
        quiet.apply(.interruption(.ambientCaptions, active: true))
        let clearing = quiet.apply(.interruption(.ambientCaptions, active: false))
        XCTAssertNil(silent.notice(for: clearing, requestedMode: quiet.requestedMode))
    }

    /// Distinct copy on purpose: nothing was ever off, so "back on" would describe a state the
    /// loop was never in.
    func testSpeakingAgainIsNotTheHaltResumeCopy() {
        XCTAssertNotEqual(NarrationVoiceNotices.speakingAgainCopy, NarrationVoiceNotices.resumeCopy)
    }

    /// A moment the wearer created explains itself. Announcing it would make the app interrupt
    /// someone to tell them it is not interrupting them.
    func testAUserTurnIsNeverAnnounced() {
        var notices = NarrationVoiceNotices()
        let (policy, t) = transition([.startNarrating, .interruption(.userTurn, active: true)])
        XCTAssertNil(notices.notice(for: t, requestedMode: policy.requestedMode))
    }

    // MARK: - The two grades of silence interacting

    /// Backgrounding while already quiet for captions: the halt is the bigger fact and is the one
    /// spoken, and the caption silence is forgotten so it can be announced afresh if it outlives
    /// the halt.
    func testAHaltIsAnnouncedOverAnAlreadyAnnouncedCaptionSilence() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let silence = policy.apply(.interruption(.ambientCaptions, active: true))
        _ = notices.notice(for: silence, requestedMode: policy.requestedMode)

        let halt = policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertEqual(notices.notice(for: halt, requestedMode: policy.requestedMode),
                       NarrationVoiceNotices.haltCopy(.backgrounded))
        XCTAssertNil(notices.announcedSilence)
    }

    /// Coming back from the background into a still-live transcript. "Narration is back on" would
    /// be a lie the wearer then spends the next minute disproving — say why it is still quiet.
    func testUnhaltingIntoLiveCaptionsExplainsTheRemainingSilence() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.ambientCaptions, active: true))
        let halt = policy.apply(.interruption(.backgrounded, active: true))
        _ = notices.notice(for: halt, requestedMode: policy.requestedMode)

        let back = policy.apply(.interruption(.backgrounded, active: false))
        let copy = notices.notice(for: back, requestedMode: policy.requestedMode)
        XCTAssertNotEqual(copy, NarrationVoiceNotices.resumeCopy)
        XCTAssertEqual(copy, NarrationVoiceNotices.silenceCopy(.ambientCaptions))

        // …and the halt bookkeeping cleared, so a second backgrounding is still announced.
        XCTAssertNil(notices.announcedHalt)
    }

    /// Turning speech off and back on with captions still running must announce again — the wearer
    /// asked a fresh question of the feature and deserves the same answer.
    func testStopAndStartNarratingReAnnouncesTheCaptionSilence() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let began = policy.apply(.interruption(.ambientCaptions, active: true))
        _ = notices.notice(for: began, requestedMode: policy.requestedMode)

        let stopped = policy.apply(.stopNarrating)
        _ = notices.notice(for: stopped, requestedMode: policy.requestedMode)
        XCTAssertNil(notices.announcedSilence, "A stopped wearer is no longer owed this explanation")

        let restarted = policy.apply(.startNarrating)
        XCTAssertEqual(notices.notice(for: restarted, requestedMode: policy.requestedMode),
                       NarrationVoiceNotices.silenceCopy(.ambientCaptions))
    }


    // MARK: - Asking into a halt already in force

    /// The two-switch Settings flow. The wearer was silent by design while watching, so nothing
    /// was owed then; the moment they ask to be spoken to, the reason is owed in full.
    func testAskingToNarrateIntoAStandingHaltIsAnnounced() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.interruption(.cameraUnavailable, active: true))

        let watching = policy.apply(.start)
        XCTAssertNil(notices.notice(for: watching, requestedMode: policy.requestedMode),
                     "Watching was silent by design; nobody is waiting on it")

        let narrating = policy.apply(.startNarrating)
        XCTAssertEqual(notices.notice(for: narrating, requestedMode: policy.requestedMode),
                       NarrationVoiceNotices.haltCopy(.cameraUnavailable))
    }

    /// Same restraint as every other halt: toggling the switch must not produce a running
    /// commentary about a camera that has been off the whole time.
    func testAStandingHaltIsStillOnlyAnnouncedOnce() {
        var notices = NarrationVoiceNotices()
        var policy = NarrationSessionPolicy()
        policy.apply(.interruption(.cameraUnavailable, active: true))
        policy.apply(.start)
        _ = notices.notice(for: policy.apply(.startNarrating), requestedMode: policy.requestedMode)

        let again = policy.apply(.startNarrating)
        XCTAssertNil(notices.notice(for: again, requestedMode: policy.requestedMode))
    }

}
