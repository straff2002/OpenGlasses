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
}
