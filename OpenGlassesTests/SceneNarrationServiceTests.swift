import UIKit
import XCTest
@testable import OpenGlasses

/// Tests for the continuous scene narration loop (Plan CV P2).
///
/// Every decision the loop makes belongs to a P1 core that is tested on its own; what is tested
/// here is the wiring between them — which is where this feature's real failure modes live: a
/// heartbeat re-send producing a fresh announcement, the speech gate being scored while nobody is
/// listening, or an interruption stopping perception without saying so.
///
/// Driven entirely through injected seams with a fake clock and no timer. Never touches `.shared`:
/// that pulls in the real camera and `Wearables`, which fatals headlessly.
@MainActor
final class SceneNarrationServiceTests: XCTestCase {

    /// A 1×1 image is enough — the hash seam is injected, so pixels never matter.
    private func makeImage() -> UIImage {
        UIGraphicsBeginImageContext(CGSize(width: 1, height: 1))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }

    /// A service wired to fakes, plus the handles the test drives it with.
    private final class Rig {
        let service: SceneNarrationService
        var now: TimeInterval = 0
        /// The hash the camera "sees". Change it to change the scene.
        var sceneHash: UInt64 = 0x0000_0000_0000_0000
        /// Descriptions handed back by the model, in order; the last one repeats when exhausted.
        var descriptions: [String] = []
        private var descriptionIndex = 0
        var spoken: [String] = []
        var ttsBusy = false
        var describeCallCount = 0
        /// Spoken system notices (Plan CV P3) — halt explanations and refusals, kept apart from
        /// `spoken` because they travel a different path and must not be arbitrated.
        var notices: [String] = []
        var cameraVerdict: CameraFeatureAvailability = .available

        init(service: SceneNarrationService) {
            self.service = service
        }

        func nextDescription() -> String? {
            guard !descriptions.isEmpty else { return nil }
            let i = min(descriptionIndex, descriptions.count - 1)
            descriptionIndex += 1
            return descriptions[i]
        }
    }

    private func makeRig(descriptions: [String] = ["A kitchen with a table and two chairs."]) -> Rig {
        let service = SceneNarrationService.makeForTesting()
        let rig = Rig(service: service)
        rig.descriptions = descriptions

        let image = makeImage()
        service.clock = { [weak rig] in rig?.now ?? 0 }
        service.currentFrame = { image }
        service.hashFrame = { [weak rig] _ in rig?.sceneHash ?? 0 }
        service.describeFrame = { [weak rig] _ in
            rig?.describeCallCount += 1
            return rig?.nextDescription()
        }
        service.speakUtterance = { [weak rig] text in rig?.spoken.append(text) }
        service.isTTSBusy = { [weak rig] in rig?.ttsBusy ?? false }
        service.speakNotice = { [weak rig] text in rig?.notices.append(text) }
        service.cameraAvailability = { [weak rig] in rig?.cameraVerdict ?? .available }
        return rig
    }

    /// Advance the clock and run one pass.
    private func tick(_ rig: Rig, to time: TimeInterval) async {
        rig.now = time
        await rig.service.tickOnce(at: time)
    }

    // MARK: - Mode

    func testStartsSilentlyInWatching() {
        let rig = makeRig()
        rig.service.start()
        XCTAssertEqual(rig.service.mode, .watching)
        XCTAssertTrue(rig.service.isPerceiving)
        XCTAssertFalse(rig.service.isSpeakingMode, "Entering the mode never starts speaking on its own")
    }

    func testDoesNothingWhileOff() async {
        let rig = makeRig()
        await tick(rig, to: 0)
        await tick(rig, to: 10)
        XCTAssertEqual(rig.describeCallCount, 0)
        XCTAssertEqual(rig.service.describedCount, 0)
    }

    func testStopNarratingFallsBackToWatchingNotOff() {
        let rig = makeRig()
        rig.service.startNarrating()
        XCTAssertTrue(rig.service.isSpeakingMode)

        rig.service.stopNarrating()
        XCTAssertEqual(rig.service.mode, .watching)
        XCTAssertTrue(rig.service.isPerceiving, "Grounding is the cheap half and keeps running")
        XCTAssertFalse(rig.service.isSpeakingMode)
    }

    // MARK: - Watching accumulates grounding silently

    func testWatchingDescribesButNeverSpeaks() async {
        let rig = makeRig()
        rig.service.start()

        await tick(rig, to: 0)          // first frame → scene change noted
        await tick(rig, to: 2)          // dwell satisfied → generate

        XCTAssertEqual(rig.service.describedCount, 1)
        XCTAssertTrue(rig.spoken.isEmpty, "Watching is silent by design")
        XCTAssertNotNil(rig.service.groundingFragment(), "…but the description is retained as grounding")
    }

    func testNarratingSpeaksTheDescription() async {
        let rig = makeRig()
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)

        XCTAssertEqual(rig.spoken, ["A kitchen with a table and two chairs."])
        XCTAssertEqual(rig.service.spokenCount, 1)
    }

    // MARK: - The heartbeat must not announce

    /// The whole reason `NarrationGate` exists. `FrameGate` forces a periodic re-send of an
    /// unchanged scene so a consumer's context can't go stale; if the loop treated that as a new
    /// scene, a wearer sitting still would be told about the same room every heartbeat.
    func testUnchangedSceneIsDescribedOnceNotOnEveryHeartbeat() async {
        let rig = makeRig()
        rig.service.frameHeartbeat = 5      // force heartbeats quickly
        rig.service.startNarrating()

        // Twelve passes over a completely static scene, well past several heartbeats and past the
        // duty-cycle floor many times over.
        for step in 0...12 {
            await tick(rig, to: Double(step) * 5)
        }

        XCTAssertEqual(rig.service.describedCount, 1,
                       "A static scene is described once; heartbeat re-sends are not scene changes")
        XCTAssertEqual(rig.spoken.count, 1)
    }

    func testAGenuineSceneChangeIsDescribedAgain() async {
        let rig = makeRig(descriptions: [
            "A kitchen with a table and two chairs.",
            "A busy street crossing with traffic and a red light.",
        ])
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.service.describedCount, 1)

        rig.sceneHash = 0xFFFF_FFFF_FFFF_FFFF     // the wearer walked somewhere else
        await tick(rig, to: 20)
        await tick(rig, to: 22)

        XCTAssertEqual(rig.service.describedCount, 2)
        XCTAssertEqual(rig.spoken.count, 2)
        XCTAssertTrue(rig.spoken[1].contains("street"))
    }

    /// A rephrase reaching the speech gate is suppressed, but still counts as described — the
    /// grounding half and the narration half are separable.
    func testRephraseOfASpokenSceneIsNotSpokenAgain() async {
        let rig = makeRig(descriptions: [
            "A man is sitting at a desk in front of a computer.",
            "A person sitting at a desk working on a computer.",
        ])
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.spoken.count, 1)

        // A different scene by the pixels, but the model says nearly the same thing.
        rig.sceneHash = 0xFFFF_FFFF_FFFF_FFFF
        await tick(rig, to: 20)
        await tick(rig, to: 22)

        XCTAssertEqual(rig.service.describedCount, 2, "It was described…")
        XCTAssertEqual(rig.spoken.count, 1, "…but saying it again is chatter")
    }

    // MARK: - The speech gate must not be scored while nobody is listening

    /// The subtle one. If the loop scored `evaluateSpeech` during silent watching, the spoken
    /// baseline would move against something nobody heard — and the first description after
    /// "start narrating" would be suppressed as a rephrase of a silence.
    func testFirstDescriptionAfterStartNarratingIsSpokenEvenIfWatchingSawIt() async {
        let rig = makeRig(descriptions: [
            "A man is sitting at a desk in front of a computer.",
            "A person sitting at a desk working on a computer.",
        ])
        rig.service.start()                 // silent

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.service.describedCount, 1)
        XCTAssertTrue(rig.spoken.isEmpty)

        rig.service.startNarrating()
        rig.sceneHash = 0xFFFF_FFFF_FFFF_FFFF
        await tick(rig, to: 20)
        await tick(rig, to: 22)

        XCTAssertEqual(rig.spoken.count, 1, "The wearer has heard nothing yet — this must be said")
    }

    // MARK: - Duty-cycle floor

    func testDutyCycleFloorHoldsBackRapidSceneChanges() async {
        let rig = makeRig(descriptions: [
            "A kitchen with a table and two chairs.",
            "A busy street crossing with traffic and a red light.",
        ])
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.describeCallCount, 1)

        // A new scene one second later — inside the 6s floor.
        rig.sceneHash = 0x00FF_00FF_00FF_00FF
        await tick(rig, to: 3)
        await tick(rig, to: 4)
        XCTAssertEqual(rig.describeCallCount, 1, "The floor keeps the model answerable while it describes")

        await tick(rig, to: 12)
        XCTAssertEqual(rig.describeCallCount, 2)
    }

    // MARK: - Arbitration

    func testNothingIsSpokenWhileTTSOwnsTheFloor() async {
        let rig = makeRig()
        rig.service.startNarrating()
        rig.ttsBusy = true

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.service.describedCount, 1)
        XCTAssertTrue(rig.spoken.isEmpty, "The description waits for the floor rather than talking over it")

        rig.ttsBusy = false
        await tick(rig, to: 3)
        XCTAssertEqual(rig.spoken.count, 1)
    }

    // MARK: - Interruptions

    func testUserTurnTakesTheEarButNotTheLoop() async {
        let rig = makeRig(descriptions: [
            "A kitchen with a table and two chairs.",
            "A busy street crossing with traffic and a red light.",
        ])
        rig.service.startNarrating()
        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.spoken.count, 1)

        rig.service.noteInterruption(.userTurn, active: true)
        XCTAssertTrue(rig.service.isPerceiving, "Grounding continues while the wearer's answer owns the floor")
        XCTAssertFalse(rig.service.isSpeakingMode)
        XCTAssertNil(rig.service.haltReason, "A user turn is not a halt owed an explanation")

        rig.sceneHash = 0xFFFF_FFFF_FFFF_FFFF
        await tick(rig, to: 20)
        await tick(rig, to: 22)
        XCTAssertEqual(rig.service.describedCount, 2, "Still watching")
        XCTAssertEqual(rig.spoken.count, 1, "Still quiet")

        rig.service.noteInterruption(.userTurn, active: false)
        XCTAssertTrue(rig.service.isSpeakingMode, "The requested mode survives the interruption")
    }

    func testBackgroundingHaltsPerceptionAndRecordsWhy() async {
        let rig = makeRig()
        rig.service.startNarrating()
        await tick(rig, to: 0)
        await tick(rig, to: 2)

        rig.service.noteInterruption(.backgrounded, active: true)
        XCTAssertFalse(rig.service.isPerceiving)
        XCTAssertEqual(rig.service.haltReason, .backgrounded,
                       "Unexplained silence is the worst failure this feature has — P3 renders this")

        let before = rig.describeCallCount
        rig.sceneHash = 0xFFFF_FFFF_FFFF_FFFF
        await tick(rig, to: 20)
        await tick(rig, to: 22)
        XCTAssertEqual(rig.describeCallCount, before, "On-device inference genuinely cannot run there")

        rig.service.noteInterruption(.backgrounded, active: false)
        XCTAssertTrue(rig.service.isPerceiving)
        XCTAssertNil(rig.service.haltReason)
        XCTAssertEqual(rig.service.mode, .narrating, "Recovery restores what the wearer asked for")
    }

    func testStopBeatsAnActiveInterruption() {
        let rig = makeRig()
        rig.service.startNarrating()
        rig.service.noteInterruption(.cameraUnavailable, active: true)
        rig.service.stop()

        XCTAssertEqual(rig.service.mode, .off)
        rig.service.noteInterruption(.cameraUnavailable, active: false)
        XCTAssertEqual(rig.service.mode, .off, "A cleared interruption must not resurrect a stopped session")
        XCTAssertFalse(rig.service.isPerceiving)
    }

    func testStopClearsGrounding() async {
        let rig = makeRig()
        rig.service.start()
        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertNotNil(rig.service.groundingFragment())

        rig.service.stop()
        XCTAssertNil(rig.service.groundingFragment())
        XCTAssertEqual(rig.service.describedCount, 0)
    }

    // MARK: - Commands

    func testVoiceCommandsDriveTheMode() {
        let rig = makeRig()
        rig.service.handle(.start)
        XCTAssertEqual(rig.service.mode, .watching)

        rig.service.handle(.startNarrating)
        XCTAssertEqual(rig.service.mode, .narrating)

        rig.service.handle(.stopNarrating)
        XCTAssertEqual(rig.service.mode, .watching)

        rig.service.handle(.stop)
        XCTAssertEqual(rig.service.mode, .off)
    }

    // MARK: - Robustness

    func testNoFrameMeansNoInferenceRatherThanAnError() async {
        let rig = makeRig()
        rig.service.currentFrame = { nil }
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.describeCallCount, 0)
        XCTAssertEqual(rig.service.describedCount, 0)
    }

    /// `evaluateGeneration` consumes the pending scene change and restarts the duty-cycle clock, so
    /// it must not be asked on a tick that was never going to describe anything — otherwise a
    /// genuine scene change is swallowed and the wearer is never told about it.
    func testASceneChangeIsNotSwallowedByATickThatCannotDescribe() async {
        let rig = makeRig()
        rig.service.describeFrame = nil          // nothing can be described yet
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.service.describedCount, 0)

        // Now it can. The scene has not changed again — if the earlier tick consumed the pending
        // change, nothing will ever describe this room.
        rig.service.describeFrame = { [weak rig] _ in
            rig?.describeCallCount += 1
            return rig?.nextDescription()
        }
        await tick(rig, to: 4)

        XCTAssertEqual(rig.service.describedCount, 1, "The pending scene change survived")
        XCTAssertEqual(rig.spoken.count, 1)
    }

    func testAModelReturningNothingIsNotSpoken() async {
        let rig = makeRig(descriptions: [])
        rig.service.startNarrating()

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.describeCallCount, 1)
        XCTAssertEqual(rig.service.describedCount, 0)
        XCTAssertTrue(rig.spoken.isEmpty)
    }

    // MARK: - Honest limits (Plan CV P3)

    /// The phase's whole reason for existing: a wearer relying on narration cannot tell an
    /// unexplained silence from "nothing changed", and those mean opposite things.
    func testBackgroundingIsExplainedAloud() async {
        let rig = makeRig()
        rig.service.startNarrating()
        await tick(rig, to: 0)
        await tick(rig, to: 2)

        rig.service.noteInterruption(.backgrounded, active: true)

        XCTAssertEqual(rig.service.noticeLog.count, 1)
        XCTAssertTrue(rig.service.noticeLog[0].contains("background"), "It must say why: \(rig.service.noticeLog)")
    }

    func testWatchingHaltsQuietly() async {
        let rig = makeRig()
        rig.service.start()                     // silent watching
        await tick(rig, to: 0)
        await tick(rig, to: 2)

        rig.service.noteInterruption(.backgrounded, active: true)

        XCTAssertTrue(rig.service.noticeLog.isEmpty,
                      "Nobody was waiting to hear anything, so there is no silence to explain")
    }

    func testResumeIsAnnouncedAfterAnAnnouncedHalt() async {
        let rig = makeRig()
        rig.service.startNarrating()
        rig.service.noteInterruption(.backgrounded, active: true)
        rig.service.noteInterruption(.backgrounded, active: false)

        XCTAssertEqual(rig.service.noticeLog.count, 2)
        XCTAssertEqual(rig.service.noticeLog[1], NarrationVoiceNotices.resumeCopy)
    }

    /// A notice must not be queued behind the arbiter, which flushes on exactly the transitions
    /// these notices explain — it would be dropped by the very halt it was announcing.
    func testNoticesBypassTheSpeechArbiter() async {
        let rig = makeRig()
        rig.service.startNarrating()
        rig.ttsBusy = true                      // the arbiter would hold anything given to it

        rig.service.noteInterruption(.cameraUnavailable, active: true)

        XCTAssertEqual(rig.service.noticeLog.count, 1, "The explanation is not ambient narration")
        XCTAssertTrue(rig.spoken.isEmpty)
    }

    /// The decision record above is deterministic; this is the one test that the notice actually
    /// reaches the speech seam. Bounded yields rather than a single one, so it can't go flaky on a
    /// scheduling detail.
    func testANoticeReachesTheSpeechSeam() async {
        let rig = makeRig()
        rig.service.startNarrating()
        rig.service.noteInterruption(.backgrounded, active: true)

        for _ in 0..<50 where rig.notices.isEmpty { await Task.yield() }
        XCTAssertEqual(rig.notices, rig.service.noticeLog)
    }

    // MARK: - Camera tier

    func testRefusesToStartWithoutLiveFramesAndSaysWhy() async {
        let rig = makeRig()
        rig.cameraVerdict = .unavailable("Scene Narration needs a live camera feed from the glasses.")

        rig.service.startNarrating()

        XCTAssertEqual(rig.service.mode, .off, "A switch that flips itself back explains nothing")
        XCTAssertNotNil(rig.service.unavailableReason)
        XCTAssertEqual(rig.service.noticeLog.count, 1)
        XCTAssertTrue(rig.service.noticeLog[0].contains("live camera feed"))

        await tick(rig, to: 0)
        await tick(rig, to: 2)
        XCTAssertEqual(rig.describeCallCount, 0)
    }

    /// `.degraded` means the camera works differently, not that it can't feed this loop.
    func testDegradedCameraStillStarts() {
        let rig = makeRig()
        rig.cameraVerdict = .degraded("Captures take several seconds.")

        rig.service.start()
        XCTAssertEqual(rig.service.mode, .watching)
        XCTAssertNil(rig.service.unavailableReason)
        XCTAssertTrue(rig.service.noticeLog.isEmpty)
    }

    func testUnavailableReasonClearsOnceTheHardwareCan() {
        let rig = makeRig()
        rig.cameraVerdict = .unavailable("No live feed.")
        rig.service.start()
        XCTAssertNotNil(rig.service.unavailableReason)

        rig.cameraVerdict = .available
        rig.service.start()
        XCTAssertNil(rig.service.unavailableReason)
        XCTAssertEqual(rig.service.mode, .watching)
    }
}
