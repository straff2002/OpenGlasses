import XCTest
@testable import OpenGlasses

/// Tests for the narration mode state machine (Plan CV P1). The invariants here are the ones that
/// decide whether the feature is usable: silent by default, grounding survives everything short of
/// a real halt, and narration never holds the floor against a reply.
final class NarrationSessionPolicyTests: XCTestCase {

    // MARK: - Modes

    func testStartsOffAndStaysOffUntilAsked() {
        let policy = NarrationSessionPolicy()
        XCTAssertEqual(policy.state, .off)
        XCTAssertFalse(policy.state.isPerceiving)
    }

    /// Silent is the default: perception is context, not narration. Entering the mode must never
    /// start talking on its own — continuous narration is a specific accessibility need, not
    /// something anyone would want switched on for them.
    func testStartEntersSilentWatchingNotNarrating() {
        var policy = NarrationSessionPolicy()
        let t = policy.apply(.start)
        XCTAssertEqual(t.to.mode, .watching)
        XCTAssertTrue(t.to.isPerceiving)
        XCTAssertFalse(t.to.isSpeaking)
    }

    func testStartNarratingSpeaksAndImpliesStart() {
        var policy = NarrationSessionPolicy()
        let t = policy.apply(.startNarrating)   // straight from `.off` — the command is unambiguous
        XCTAssertEqual(t.to.mode, .narrating)
        XCTAssertTrue(t.to.isPerceiving)
        XCTAssertTrue(t.to.isSpeaking)
    }

    /// "Stop narrating" stops the speaking, not the watching. The grounding context is the cheap
    /// half and there is no reason to throw it away.
    func testStopNarratingFallsBackToWatchingNotOff() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let t = policy.apply(.stopNarrating)
        XCTAssertEqual(t.to.mode, .watching)
        XCTAssertTrue(t.to.isPerceiving)
        XCTAssertFalse(t.to.isSpeaking)
        XCTAssertTrue(t.flushSpeechQueue, "Queued descriptions must not surface after stopping.")
    }

    func testStopLeavesTheModeEntirely() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let t = policy.apply(.stop)
        XCTAssertEqual(t.to, .off)
        XCTAssertTrue(t.flushSpeechQueue)
    }

    // MARK: - Speech-only interruptions

    /// The hard constraint: if the wearer asked something, the answer owns the floor. A scene
    /// description cutting into a reply is worse than no description at all — but watching
    /// continues, so the answer is grounded in a scene the model has already seen.
    func testUserTurnSilencesNarrationButKeepsWatching() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)

        let held = policy.apply(.interruption(.userTurn, active: true))
        XCTAssertFalse(held.to.isSpeaking)
        XCTAssertTrue(held.to.isPerceiving, "Grounding must survive a question.")
        XCTAssertTrue(held.flushSpeechQueue)
        XCTAssertNil(held.haltBegan, "A held floor is not a halt — nothing to announce.")

        let resumed = policy.apply(.interruption(.userTurn, active: false))
        XCTAssertTrue(resumed.to.isSpeaking)
        XCTAssertEqual(resumed.to.mode, .narrating)
    }

    func testRealtimeSessionSilencesNarration() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        XCTAssertFalse(policy.apply(.interruption(.realtimeSession, active: true)).to.isSpeaking)
        XCTAssertTrue(policy.state.isPerceiving)
    }

    func testSilencingInterruptionDoesNotStartSpeechInWatchingMode() {
        var policy = NarrationSessionPolicy()
        policy.apply(.start)
        let t = policy.apply(.interruption(.userTurn, active: false))
        XCTAssertEqual(t.to.mode, .watching)
        XCTAssertFalse(t.to.isSpeaking)
    }

    // MARK: - Halting interruptions

    /// On-device MLX cannot run while backgrounded, so this is a real stop, not a quiet spell —
    /// and for someone relying on narration, silence that isn't explained is indistinguishable
    /// from silence because nothing changed.
    func testBackgroundingHaltsPerceptionAndOwesTheWearerAReason() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)

        let halted = policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertFalse(halted.to.isPerceiving)
        XCTAssertFalse(halted.to.isSpeaking)
        XCTAssertEqual(halted.to.haltReason, .backgrounded)
        XCTAssertEqual(halted.haltBegan, .backgrounded)
        XCTAssertTrue(halted.flushSpeechQueue)

        let resumed = policy.apply(.interruption(.backgrounded, active: false))
        XCTAssertEqual(resumed.to.mode, .narrating, "The wearer's mode must survive the halt.")
        XCTAssertEqual(resumed.haltEnded, .backgrounded)
        XCTAssertNil(resumed.to.haltReason)
    }

    func testCameraUnavailableHaltsWithItsOwnReason() {
        var policy = NarrationSessionPolicy()
        policy.apply(.start)
        let t = policy.apply(.interruption(.cameraUnavailable, active: true))
        XCTAssertEqual(t.to.haltReason, .cameraUnavailable)
        XCTAssertEqual(t.haltBegan, .cameraUnavailable)
        XCTAssertFalse(t.to.isPerceiving)
    }

    /// Asking for narration while it cannot possibly run still owes an explanation — the wearer
    /// gave a command and nothing happened.
    func testStartingWhileHaltedStillAnnouncesWhy() {
        var policy = NarrationSessionPolicy()
        policy.apply(.interruption(.backgrounded, active: true))
        let t = policy.apply(.startNarrating)
        XCTAssertEqual(t.haltBegan, .backgrounded)
        XCTAssertFalse(t.to.isPerceiving)
    }

    func testHaltingInterruptionWinsOverASilencingOne() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.userTurn, active: true))
        policy.apply(.interruption(.backgrounded, active: true))
        XCTAssertEqual(policy.state.haltReason, .backgrounded)

        // Clearing only the halt leaves the floor still held by the question.
        policy.apply(.interruption(.backgrounded, active: false))
        XCTAssertTrue(policy.state.isPerceiving)
        XCTAssertFalse(policy.state.isSpeaking)
    }

    func testHaltReasonIsStableWhenTwoHaltsOverlap() {
        var policy = NarrationSessionPolicy()
        policy.apply(.start)
        policy.apply(.interruption(.cameraUnavailable, active: true))
        policy.apply(.interruption(.backgrounded, active: true))
        // `allCases` order decides, so the reported reason doesn't flap with insertion order.
        XCTAssertEqual(policy.state.haltReason, .backgrounded)
    }

    // MARK: - Stopping beats everything

    /// Stopping while halted must not leave the session lurking: when the halt clears, narration
    /// stays off, and clearing it is not a "narration resumed" announcement.
    func testStoppingWhileHaltedDoesNotResurrectOnRecovery() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.backgrounded, active: true))

        let stopped = policy.apply(.stop)
        XCTAssertEqual(stopped.to, .off)
        XCTAssertNil(stopped.haltEnded, "The wearer stopped it; that is not a recovery.")

        let cleared = policy.apply(.interruption(.backgrounded, active: false))
        XCTAssertEqual(cleared.to, .off)
        XCTAssertNil(cleared.haltEnded)
    }

    func testResetClearsRequestedModeAndEnvironment() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.backgrounded, active: true))
        policy.reset()
        XCTAssertEqual(policy.state, .off)
        XCTAssertTrue(policy.interruptions.isEmpty)
        XCTAssertEqual(policy.requestedMode, .off)
    }

    // MARK: - Transition bookkeeping

    func testFlushIsOnlyAskedForWhenSpeechActuallyStops() {
        var policy = NarrationSessionPolicy()
        XCTAssertFalse(policy.apply(.start).flushSpeechQueue)
        XCTAssertFalse(policy.apply(.startNarrating).flushSpeechQueue)
        XCTAssertFalse(policy.apply(.interruption(.userTurn, active: false)).flushSpeechQueue)
        XCTAssertTrue(policy.apply(.interruption(.userTurn, active: true)).flushSpeechQueue)
        XCTAssertFalse(policy.apply(.interruption(.userTurn, active: true)).flushSpeechQueue)
    }

    func testDidChangeReportsNoOpEvents() {
        var policy = NarrationSessionPolicy()
        policy.apply(.start)
        XCTAssertFalse(policy.apply(.start).didChange)
        XCTAssertFalse(policy.apply(.stopNarrating).didChange, "Already not narrating.")
        XCTAssertTrue(policy.apply(.startNarrating).didChange)
    }

    // MARK: - Ambient captions (caption/narration arbitration)

    /// The decision this models: a live transcript takes the ear and nothing else. Perception
    /// keeps running, so a question asked mid-captions is still answered against a scene the model
    /// has already looked at — the cheap half was never the thing in contention.
    func testAmbientCaptionsTakeTheEarAndNotTheLoop() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let t = policy.apply(.interruption(.ambientCaptions, active: true))

        XCTAssertTrue(t.to.isPerceiving, "Grounding is not what captions contend for")
        XCTAssertFalse(t.to.isSpeaking)
        XCTAssertNil(t.to.haltReason, "Captions do not stop the loop, so nothing was halted")
        XCTAssertEqual(t.to.silenceReason, .ambientCaptions)
        XCTAssertEqual(t.silenceBegan, .ambientCaptions)
        XCTAssertTrue(t.flushSpeechQueue,
                      "Anything queued is stale by the time the transcript ends; late delivery is worse")
    }

    func testClearingCaptionsRestoresSpeech() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.ambientCaptions, active: true))
        let t = policy.apply(.interruption(.ambientCaptions, active: false))

        XCTAssertTrue(t.to.isSpeaking, "The requested mode survives the interruption")
        XCTAssertNil(t.to.silenceReason)
        XCTAssertEqual(t.silenceEnded, .ambientCaptions)
    }

    /// The axis that makes the caption case different from a user turn. A user turn is a moment the
    /// wearer created and hears end; captions are a standing condition they may have switched on
    /// hours ago, and silence they cannot attribute to anything is the failure P3 exists to fix.
    func testAUserTurnIsAMomentAndReportsNoSilence() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        let t = policy.apply(.interruption(.userTurn, active: true))

        XCTAssertFalse(t.to.isSpeaking)
        XCTAssertNil(t.to.silenceReason, "A moment the wearer created needs no explaining")
        XCTAssertNil(t.silenceBegan)
    }

    /// A watching wearer was silent by design. Reporting them as *silenced* would invent a
    /// grievance they don't have, and the UI would then owe them an explanation for nothing.
    func testAWatchingWearerIsNeverReportedAsSilenced() {
        var policy = NarrationSessionPolicy()
        policy.apply(.start)
        let t = policy.apply(.interruption(.ambientCaptions, active: true))

        XCTAssertTrue(t.to.isPerceiving)
        XCTAssertNil(t.to.silenceReason)
        XCTAssertNil(t.silenceBegan)
    }

    /// "Stop narrating" also ends the silence, but the wearer chose that — reporting it as a
    /// resume would have narration announce itself coming back at the moment it was switched off.
    func testStopNarratingDuringCaptionsIsNotAResume() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.ambientCaptions, active: true))
        let t = policy.apply(.stopNarrating)

        XCTAssertNil(t.silenceEnded)
        XCTAssertNil(t.to.silenceReason)
    }

    /// A halt is the bigger fact and supersedes the silence: the loop is not merely quiet, it has
    /// stopped, and the wearer must not be told two different stories about one silence.
    func testAHaltSupersedesACaptionSilence() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.ambientCaptions, active: true))
        let t = policy.apply(.interruption(.backgrounded, active: true))

        XCTAssertEqual(t.to.haltReason, .backgrounded)
        XCTAssertNil(t.to.silenceReason)
        XCTAssertEqual(t.haltBegan, .backgrounded)
    }

    /// Coming back from the background into a still-live transcript is not narration resuming.
    /// The transition has to say so, or the wearer is told it is back and then hears nothing.
    func testUnhaltingIntoLiveCaptionsIsStillSilenced() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.ambientCaptions, active: true))
        policy.apply(.interruption(.backgrounded, active: true))
        let t = policy.apply(.interruption(.backgrounded, active: false))

        XCTAssertEqual(t.haltEnded, .backgrounded)
        XCTAssertTrue(t.to.isPerceiving, "The loop is watching again")
        XCTAssertFalse(t.to.isSpeaking, "…but the transcript still owns the ear")
        XCTAssertEqual(t.silenceBegan, .ambientCaptions)
    }

    /// The two axes are independent, and a future interruption has to answer both.
    func testInterruptionAxesAreIndependent() {
        XCTAssertFalse(NarrationSessionPolicy.Interruption.ambientCaptions.haltsPerception)
        XCTAssertTrue(NarrationSessionPolicy.Interruption.ambientCaptions.isStandingCondition)
        XCTAssertFalse(NarrationSessionPolicy.Interruption.userTurn.isStandingCondition)
        XCTAssertTrue(NarrationSessionPolicy.Interruption.backgrounded.isStandingCondition)
    }


    // MARK: - Asking for narration into a halt that is already in force

    /// The primary Settings flow: "Watch the scene", then "Speak descriptions aloud". If the halt
    /// was already in force, nothing *begins* on the second switch — so without this the most
    /// likely path into a halted loop is the one that explains itself least, and the wearer asks
    /// for descriptions and hears nothing at all.
    func testAskingToNarrateIntoAStandingHaltIsReported() {
        var policy = NarrationSessionPolicy()
        policy.apply(.interruption(.cameraUnavailable, active: true))
        policy.apply(.start)                      // watching, halted, silent by design
        let t = policy.apply(.startNarrating)

        XCTAssertNil(t.haltBegan, "Nothing began — the halt was already in force")
        XCTAssertEqual(t.haltBlockedRequest, .cameraUnavailable)
        XCTAssertEqual(t.to.haltReason, .cameraUnavailable)
    }

    /// Starting straight into a standing halt reports it the ordinary way, and must not report it
    /// twice over.
    func testStartingStraightIntoAStandingHaltReportsHaltBeganOnly() {
        var policy = NarrationSessionPolicy()
        policy.apply(.interruption(.backgrounded, active: true))
        let t = policy.apply(.startNarrating)

        XCTAssertEqual(t.haltBegan, .backgrounded)
        XCTAssertNil(t.haltBlockedRequest, "One debt, reported once")
    }

    /// An interruption clearing into a *different* still-active halt is the world changing, not
    /// the wearer asking for anything.
    func testClearingOneHaltIntoAnotherIsNotABlockedRequest() {
        var policy = NarrationSessionPolicy()
        policy.apply(.startNarrating)
        policy.apply(.interruption(.backgrounded, active: true))
        policy.apply(.interruption(.cameraUnavailable, active: true))
        let t = policy.apply(.interruption(.backgrounded, active: false))

        XCTAssertNil(t.haltBlockedRequest)
        XCTAssertEqual(t.to.haltReason, .cameraUnavailable)
    }

}
