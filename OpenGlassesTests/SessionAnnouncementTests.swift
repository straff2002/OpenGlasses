import XCTest
@testable import OpenGlasses

/// The rule this suite exists to protect: **a blind user must be told what the app is doing, and
/// must be told it once, by one voice.**
///
/// Both halves are failures. Rendering "Camera started" into a status card a hands-free user is
/// not touching tells nobody. Announcing "Listening" a half-second after the app has already
/// played its listen chime puts two voices in one ear — which is the failure that would make a
/// user switch VoiceOver off, and so is worse than the silence it was meant to fix.
final class SessionAnnouncementTests: XCTestCase {

    private func voiceOverOn(speaking: Bool = false, thinking: Bool = false) -> AnnouncementContext {
        AnnouncementContext(voiceOverRunning: true,
                            assistantIsSpeaking: speaking,
                            thinkingSoundPlaying: thinking)
    }

    // MARK: - The silent transitions, which are the ones worth saying

    func testALiveSessionStartingAndEndingIsAnnounced() {
        let started = SessionAnnouncementPolicy.announcement(
            for: .liveSession(mode: "Gemini Live", active: true), context: voiceOverOn())
        XCTAssertEqual(started?.message, "Gemini Live session started")
        XCTAssertEqual(started?.interrupts, false)

        let ended = SessionAnnouncementPolicy.announcement(
            for: .liveSession(mode: "OpenAI Realtime", active: false), context: voiceOverOn())
        XCTAssertEqual(ended?.message, "OpenAI Realtime session ended")
    }

    /// The camera is the clearest case of state a sighted user reads off a badge and a blind user
    /// has no access to at all — nothing about the glasses camera is audible.
    func testCameraStartAndStopAreAnnounced() {
        XCTAssertEqual(
            SessionAnnouncementPolicy.announcement(for: .cameraStreaming(true),
                                                   context: voiceOverOn())?.message,
            "Camera started")
        XCTAssertEqual(
            SessionAnnouncementPolicy.announcement(for: .cameraStreaming(false),
                                                   context: voiceOverOn())?.message,
            "Camera stopped")
    }

    /// Muting is a long-press on the capsule with no sound of its own — the only feedback is a
    /// small badge on an icon, so without this the user cannot tell a muted mic from a dead one.
    func testMicMuteIsAnnouncedBothWays() {
        XCTAssertEqual(
            SessionAnnouncementPolicy.announcement(for: .micMuted(true),
                                                   context: voiceOverOn())?.message,
            "Microphone muted")
        XCTAssertEqual(
            SessionAnnouncementPolicy.announcement(for: .micMuted(false),
                                                   context: voiceOverOn())?.message,
            "Microphone on")
    }

    func testReconnectingIsAnnounced() {
        XCTAssertEqual(
            SessionAnnouncementPolicy.announcement(for: .reconnecting(mode: "Gemini Live"),
                                                   context: voiceOverOn())?.message,
            "Gemini Live reconnecting")
    }

    /// An error is the one line allowed to interrupt: the thing the user asked for did not happen,
    /// and queueing that behind whatever VoiceOver is reading loses it.
    func testAnErrorInterrupts() {
        let announcement = SessionAnnouncementPolicy.announcement(
            for: .error("Camera: the glasses are not connected"), context: voiceOverOn())
        XCTAssertEqual(announcement?.message, "Camera: the glasses are not connected")
        XCTAssertEqual(announcement?.interrupts, true)
    }

    /// Raw error text has reached the user's ear before (a decoder's `keyNotFound(path: […` was
    /// read aloud on the glasses), which is why the wording goes through the same prose gate.
    func testACodeyErrorIsNotReadOutVerbatim() {
        let announcement = SessionAnnouncementPolicy.announcement(
            for: .error("keyNotFound(CodingKeys(stringValue: \"model\"), [_0])"),
            context: voiceOverOn())
        XCTAssertEqual(announcement?.message, "Something went wrong")
    }

    // MARK: - The subtraction: what the app already says out loud

    /// Every turn is already bracketed by an acknowledgment chime and an end tone.
    func testListeningIsNotAnnouncedBecauseItAlreadyChimes() {
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .listening(true),
                                                            context: voiceOverOn()))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .listening(false),
                                                            context: voiceOverOn()))
    }

    /// The worst possible double-up: announcing "Speaking" over the speech.
    func testSpeakingIsNeverAnnounced() {
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .speaking(true),
                                                            context: voiceOverOn()))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .speaking(false),
                                                            context: voiceOverOn()))
    }

    /// Ascending cue on attach, descending cue on drop — both already audible.
    func testGlassesConnectionIsNotAnnouncedBecauseItAlreadyPlaysACue() {
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .glassesConnected(true),
                                                            context: voiceOverOn()))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .glassesConnected(false),
                                                            context: voiceOverOn()))
    }

    /// "Thinking" is the interesting one: it is covered by the ambient pad *while the pad plays*,
    /// and genuinely silent when something stopped it. The cue's presence decides, not the event.
    func testThinkingIsAnnouncedOnlyWhenThePadIsNotPlaying() {
        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .thinking(true), context: voiceOverOn(thinking: true)))
        XCTAssertEqual(SessionAnnouncementPolicy.announcement(
            for: .thinking(true), context: voiceOverOn(thinking: false))?.message, "Thinking")
        // The end of thinking is the start of the answer — the answer is the cue.
        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .thinking(false), context: voiceOverOn(thinking: false)))
    }

    /// The dynamic half of the dedup: anything at all is withheld while the assistant has the
    /// floor, including an error, because the app is already talking to the user.
    func testNothingIsAnnouncedWhileTheAssistantIsSpeaking() {
        let speaking = voiceOverOn(speaking: true)
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .cameraStreaming(true),
                                                            context: speaking))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(
            for: .liveSession(mode: "Gemini Live", active: true), context: speaking))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .error("It did not work"),
                                                            context: speaking))
    }

    /// Nobody is listening with VoiceOver off, and gating here is what makes a mis-wire visible
    /// in a test rather than a silent no-op in a running app.
    func testNothingIsAnnouncedWithVoiceOverOff() {
        let off = AnnouncementContext(voiceOverRunning: false)
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .cameraStreaming(true), context: off))
        XCTAssertNil(SessionAnnouncementPolicy.announcement(for: .error("It did not work"), context: off))
    }

    // MARK: - The announcer: said once

    @MainActor
    func testARepublishedTransitionIsNotAnnouncedTwice() {
        var posted: [String] = []
        let announcer = SessionAnnouncer(context: { self.voiceOverOn() },
                                         now: { Date(timeIntervalSince1970: 100) },
                                         post: { posted.append($0.message) })

        announcer.announce(.cameraStreaming(true))
        announcer.announce(.cameraStreaming(true))
        announcer.announce(.cameraStreaming(true))

        XCTAssertEqual(posted, ["Camera started"])
    }

    /// The guard is a window, not a permanent mute: a user hunting for the camera button really
    /// can stop and restart it, and the second stop has to be reported.
    @MainActor
    func testTheSameLineIsAnnouncedAgainOnceTheWindowPasses() {
        var posted: [String] = []
        var clock = Date(timeIntervalSince1970: 100)
        let announcer = SessionAnnouncer(context: { self.voiceOverOn() },
                                         now: { clock },
                                         post: { posted.append($0.message) })

        announcer.announce(.cameraStreaming(false))
        clock = clock.addingTimeInterval(SessionAnnouncer.repeatWindow + 0.1)
        announcer.announce(.cameraStreaming(false))

        XCTAssertEqual(posted, ["Camera stopped", "Camera stopped"])
    }

    /// Suppression is per *line*, not a cooldown on the announcer: a different transition landing
    /// immediately after must still be reported.
    @MainActor
    func testADifferentTransitionIsNotSuppressedByTheRepeatGuard() {
        var posted: [String] = []
        let announcer = SessionAnnouncer(context: { self.voiceOverOn() },
                                         now: { Date(timeIntervalSince1970: 100) },
                                         post: { posted.append($0.message) })

        announcer.announce(.cameraStreaming(true))
        announcer.announce(.micMuted(true))

        XCTAssertEqual(posted, ["Camera started", "Microphone muted"])
    }

    /// A transition the policy withholds must not consume the repeat slot — otherwise a silenced
    /// line would suppress the next real one.
    @MainActor
    func testAWithheldTransitionPostsNothing() {
        var posted: [String] = []
        let announcer = SessionAnnouncer(
            context: { AnnouncementContext(voiceOverRunning: true, assistantIsSpeaking: true) },
            now: { Date(timeIntervalSince1970: 100) },
            post: { posted.append($0.message) })

        XCTAssertNil(announcer.announce(.cameraStreaming(true)))
        XCTAssertTrue(posted.isEmpty)
    }
}
