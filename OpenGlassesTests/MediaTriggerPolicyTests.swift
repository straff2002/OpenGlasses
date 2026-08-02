import XCTest
@testable import OpenGlasses

/// Tests for the pure temple-tap claim/release/defer policy (Plan CH P1): the full decision
/// matrix as data, the lease-owner classification, and the v1 gesture grammar.
final class MediaTriggerPolicyTests: XCTestCase {

    private func conditions(
        enabled: Bool = true,
        userAudio: Bool = false,
        realtime: Bool = false,
        owner: AudioSessionOwner? = nil,
        claimed: Bool = false
    ) -> MediaTriggerConditions {
        MediaTriggerConditions(
            triggerEnabled: enabled,
            userAudioPlaying: userAudio,
            realtimeSessionActive: realtime,
            leaseOwner: owner,
            isClaimed: claimed)
    }

    // MARK: - Decision matrix

    func testClaimsWhenIdleAndEnabled() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim)
    }

    func testAlreadyClaimedAndClearDefers() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(claimed: true)), .defer)
    }

    func testDisabledNeverClaims() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(enabled: false)), .defer)
    }

    func testDisableWhileClaimedReleases() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(enabled: false, claimed: true)), .release)
    }

    func testUserAudioBlocksClaim() {
        // The user's own music always wins — never claim over it.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true)), .defer)
    }

    func testUserAudioStartingWhileClaimedReleases() {
        // "Release the moment external audio starts."
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, claimed: true)), .release)
    }

    func testRealtimeSessionBlocksClaim() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(realtime: true)), .defer)
    }

    func testRealtimeSessionStartingWhileClaimedReleases() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(realtime: true, claimed: true)), .release)
    }

    func testExclusiveLeaseHolderBlocksClaim() {
        for owner: AudioSessionOwner in [.transcription, .liveTranslation, .geminiLive, .openAIRealtime, .expertCall] {
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner)), .defer,
                           "\(owner) should block claiming")
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner, claimed: true)), .release,
                           "\(owner) taking the lease should force a release")
        }
    }

    func testAmbientOwnersDoNotBlockClaim() {
        // The wake-word listener holds the lease whenever it runs — the trigger must be able to
        // coexist with it, or it could never claim at all. Same for TTS and ourselves.
        for owner: AudioSessionOwner? in [nil, .wakeWord, .textToSpeech, .mediaTrigger] {
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner)), .claim,
                           "\(String(describing: owner)) should not block claiming")
        }
    }

    func testEveryOwnerIsClassified() {
        // The blocking table must stay total as owners are added.
        for owner in AudioSessionOwner.allCases {
            _ = MediaTriggerPolicy.ownerBlocksClaim(owner)
        }
    }

    func testMusicInterruptionTransitionRoundTrip() {
        // Idle → claim; music starts → release; music stops → claim again.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, claimed: true)), .release)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim)
    }

    // MARK: - Gesture grammar (v1: one gesture)

    func testOnlyNextTrackFiresTrigger() {
        XCTAssertTrue(MediaTriggerPolicy.firesTrigger(.nextTrack))
        XCTAssertFalse(MediaTriggerPolicy.firesTrigger(.togglePlayPause))
        XCTAssertFalse(MediaTriggerPolicy.firesTrigger(.previousTrack))
    }
}
