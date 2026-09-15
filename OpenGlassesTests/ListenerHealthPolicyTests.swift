import XCTest
@testable import OpenGlasses

/// Plan FE P2: the wake-word listener's health decision, as a table.
///
/// `WakeWordService.startListening()` used to open with `guard !isListening else { return }`, and
/// that flag was the only health check in the service. Every auto-start path in the app funnels
/// through it, so a flag left `true` by an audio disruption turned all of them into silent no-ops.
/// These tests pin the replacement: the decision reads the engine, the tap and the recognition task
/// together, and the rule that matters most is that **a running engine does not prove recognition
/// works**.
final class ListenerHealthPolicyTests: XCTestCase {

    // MARK: - Helpers

    private func state(
        flag: Bool = false,
        engine: Bool = false,
        tap: Bool = false,
        recognition: ListenerRecognitionState = .none,
        shared: Bool = false,
        paused: ListenerPauseReason? = nil,
        lease: Bool = true,
        intent: Bool = true,
        silent: Bool = false,
        permission: ListenerHealthState.Permission = .granted,
        origin: ListenerStartOrigin = .explicit
    ) -> ListenerHealthState {
        ListenerHealthState(
            flagSaysListening: flag,
            graph: ListenerGraphSnapshot(engineRunning: engine, tapInstalled: tap,
                                         recognition: recognition),
            captureShared: shared,
            deliberatelyPaused: paused,
            leaseHeld: lease,
            intent: intent,
            silentMode: silent,
            permission: permission,
            origin: origin)
    }

    private var healthy: ListenerHealthState {
        state(flag: true, engine: true, tap: true, recognition: .running)
    }

    // MARK: - Refusals

    func testSilentModeIsRefusedEvenWhenEverythingElseIsReady() {
        var s = healthy
        s.silentMode = true
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .refuse(.silentMode))
    }

    func testSilentModeOutranksIntentAndPermission() {
        let s = state(intent: false, silent: true, permission: .denied)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .refuse(.silentMode),
                       "push-to-talk is the chokepoint; it must not be reported as something else")
    }

    func testNoIntentIsRefused() {
        XCTAssertEqual(ListenerHealthPolicy.decide(state(intent: false)), .refuse(.noIntent))
    }

    /// An explicit stop is not undone by a glasses reconnect or an ended interruption.
    func testAutomaticRestartAfterAnExplicitStopIsRefused() {
        let s = state(intent: false, origin: .automatic)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .refuse(.noIntent))
    }

    func testDeniedPermissionIsRefused() {
        XCTAssertEqual(ListenerHealthPolicy.decide(state(permission: .denied)),
                       .refuse(.noPermission))
    }

    /// The pre-flight pass runs before authorization has been asked for, so `unknown` must not be
    /// read as a refusal — otherwise no start could ever get as far as asking.
    func testUnknownPermissionDoesNotRefuse() {
        XCTAssertEqual(ListenerHealthPolicy.decide(state(permission: .unknown)), .startFresh)
    }

    // MARK: - Healthy

    func testFullyHealthyListenerIsKept() {
        XCTAssertEqual(ListenerHealthPolicy.decide(healthy), .healthy)
    }

    func testRepeatedStartOnAHealthyListenerStaysHealthy() {
        // The same state asked twice answers the same way — this is what "coalesce the request"
        // means for a caller that only wants to be listening.
        XCTAssertEqual(ListenerHealthPolicy.decide(healthy), .healthy)
        XCTAssertEqual(ListenerHealthPolicy.decide(healthy), .healthy)
    }

    func testAutomaticStartOnAHealthyListenerIsAlsoHealthy() {
        var s = healthy
        s.origin = .automatic
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .healthy)
    }

    // MARK: - Broken

    /// The headline defect: the flag says listening, the engine has stopped, and the old guard
    /// returned at `guard !isListening` without rebuilding anything.
    func testFlagTrueWithStoppedEngineRebuilds() {
        let s = state(flag: true, engine: false, tap: false, recognition: .none)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.engineStopped))
    }

    /// Engine running alone does not prove recognition works.
    func testRunningEngineWithEndedRecognitionRebuilds() {
        let s = state(flag: true, engine: true, tap: true, recognition: .ended(failed: false))
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.recognitionEnded))
    }

    func testRunningEngineWithFailedRecognitionRebuildsForTheSameReason() {
        // `failed` is recorded for logging; it must not change the answer, so a future branch on
        // it has to be deliberate.
        let s = state(flag: true, engine: true, tap: true, recognition: .ended(failed: true))
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.recognitionEnded))
    }

    func testEndedRecognitionRebuildsEvenWhenTheFlagNeverClaimedAListener() {
        let s = state(flag: false, engine: true, tap: true, recognition: .ended(failed: false))
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.recognitionEnded))
    }

    func testFlagTrueWithRunningEngineButNoTaskRebuilds() {
        let s = state(flag: true, engine: true, tap: true, recognition: .none)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.noRecognitionTask))
    }

    func testRunningEngineWithNoTapRebuilds() {
        let s = state(flag: false, engine: true, tap: false, recognition: .none)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.tapMissing))
    }

    func testRecognitionTaskOutlivingItsEngineRebuilds() {
        let s = state(flag: false, engine: false, tap: false, recognition: .running)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.staleRecognitionTask))
    }

    // MARK: - Deliberate pauses

    /// The shared-engine handoff: dictation owns the capture, and an automatic restart must not
    /// barge in on it. The consumer that paused it resumes it by asking explicitly.
    func testAutomaticStartDuringASharedEnginePauseIsDeclined() {
        let s = state(flag: false, engine: true, tap: true, recognition: .none,
                      shared: true, paused: .sharedEngine, origin: .automatic)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .pausedDeliberately(.sharedEngine))
    }

    /// …and the explicit ask goes through without a rebuild: the engine and its tap stay up, and
    /// starting recognition reuses them, which is the existing resume path.
    func testExplicitStartDuringASharedEnginePauseStartsWithoutRebuilding() {
        let s = state(flag: false, engine: true, tap: true, recognition: .none,
                      shared: true, paused: .sharedEngine, origin: .explicit)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .startFresh,
                       "the consumer's engine must not be torn down to restart the recognizer")
    }

    /// A silence pause is recorded but never blocks: the only signal that ends one is audio
    /// arriving, and audio only arrives while the listener runs.
    func testSilencePauseDoesNotBlockAnAutomaticRestart() {
        let s = state(flag: true, engine: false, tap: false, recognition: .none,
                      paused: .silence, origin: .automatic)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.engineStopped))
    }

    /// A silence pause does not take the recognizer down, so a listener that is still running
    /// through one is still healthy. The graph is the truth; the pause flag is not believed over it.
    func testSilencePauseOnARunningListenerIsStillHealthy() {
        var s = healthy
        s.deliberatelyPaused = .silence
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .healthy)
    }

    /// Shared capture that is *not* paused is just other consumers riding the tap. It must not
    /// stop a broken listener from being rebuilt — the forwarder set is re-published into the new
    /// tap, so they survive it.
    func testSharedCaptureDoesNotPreventRebuildingABrokenListener() {
        let s = state(flag: true, engine: false, shared: true)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .rebuild(.engineStopped))
    }

    // MARK: - Start fresh

    func testColdStartWithNothingRunningStartsFresh() {
        XCTAssertEqual(ListenerHealthPolicy.decide(state()), .startFresh)
    }

    func testEngineRunningWithTapAndNoRecognizerStartsFresh() {
        // `ensureAudioEngineRunningForConsumers()` leaves exactly this: a live engine feeding the
        // shared consumers with no wake-word recognizer on it.
        let s = state(flag: false, engine: true, tap: true, recognition: .none, shared: true)
        XCTAssertEqual(ListenerHealthPolicy.decide(s), .startFresh)
    }

    // MARK: - Start generation

    func testStopInvalidatesAStartInFlightAndWithdrawsIntent() {
        var generation = ListenerStartGeneration()
        generation.recordIntent()
        let token = generation.beginStart()
        XCTAssertEqual(generation.checkpoint(token), .proceed)

        generation.recordStop()
        XCTAssertEqual(generation.checkpoint(token), .abandon)
        XCTAssertFalse(generation.wantsListening)
    }

    func testPauseInvalidatesAStartInFlightButKeepsIntent() {
        var generation = ListenerStartGeneration()
        generation.recordIntent()
        let token = generation.beginStart()

        generation.recordPause()
        XCTAssertEqual(generation.checkpoint(token), .abandon)
        XCTAssertTrue(generation.wantsListening,
                      "a route flap is not the wearer deciding the microphone should stay shut")
    }

    func testAStartBegunAfterAStopHasNoIntent() {
        var generation = ListenerStartGeneration()
        generation.recordIntent()
        generation.recordStop()
        let token = generation.beginStart()
        XCTAssertEqual(generation.checkpoint(token), .abandon)
    }

    func testIntentGrantedAgainRevivesStarts() {
        var generation = ListenerStartGeneration()
        generation.recordStop()
        generation.recordIntent()
        let token = generation.beginStart()
        XCTAssertEqual(generation.checkpoint(token), .proceed)
    }

    func testConcurrentStartsAreEachInvalidatedByOneStop() {
        var generation = ListenerStartGeneration()
        generation.recordIntent()
        let first = generation.beginStart()
        let second = generation.beginStart()
        generation.recordStop()
        XCTAssertEqual(generation.checkpoint(first), .abandon)
        XCTAssertEqual(generation.checkpoint(second), .abandon)
    }
}
