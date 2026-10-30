import XCTest
@testable import OpenGlasses

/// Tests for the pure temple-tap claim policy (Plan CH P1, extended by Plan GJ P0): the full
/// decision matrix as data, the lease-owner classification, and the session-control mode that keeps
/// taps working during the app's own conversations.
final class MediaTriggerPolicyTests: XCTestCase {

    private func conditions(
        enabled: Bool = true,
        glasses: Bool = true,
        userAudio: Bool = false,
        yielded: Bool = false,
        realtime: Bool = false,
        owner: AudioSessionOwner? = nil,
        claimed: NowPlayingClaimMode? = nil,
        conversation: Bool = false,
        sessionControl: Bool = true,
        live: Bool = true
    ) -> MediaTriggerConditions {
        MediaTriggerConditions(
            triggerEnabled: enabled,
            glassesPresent: glasses,
            userAudioPlaying: userAudio,
            yieldedToMedia: yielded,
            realtimeSessionActive: realtime,
            leaseOwner: owner,
            claimedMode: claimed,
            conversationActive: conversation,
            sessionControlEnabled: sessionControl,
            standbyClaimLive: live)
    }

    // MARK: - Claim health (a standby claim whose player stopped)

    func testDeadStandbyClaimIsTakenAfresh() {
        // The Gen 2 report: the claim stayed `.standby` while its player had stopped, so the
        // policy deferred and no tap arrived again.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(claimed: .standby, live: false)),
                       .claim(.standby))
    }

    func testDeadStandbyClaimIsReleasedWhenNoClaimIsWanted() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, claimed: .standby,
                                                            live: false)), .release)
    }

    func testDeadStandbyClaimSwitchesToSessionControlInAConversation() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: .geminiLive, claimed: .standby,
                                                            live: false)), .claim(.sessionControl))
    }

    func testHealthIsIgnoredForSessionControl() {
        // Session control has no player, so "not playing" is its normal state.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: .geminiLive,
                                                            claimed: .sessionControl, live: false)),
                       .defer)
    }

    func testUnclaimedAndUnwantedStillDefers() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, live: false)), .defer)
    }

    // MARK: - Release reasons (what the support log says)

    func testReleaseReasonNamesTheConditionThatWon() {
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(enabled: false)), .disabled)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(glasses: false)), .glassesAbsent)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(userAudio: true)), .userAudio)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(yielded: true)), .yieldedToMedia)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(owner: .expertCall)), .otherParty)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(owner: .liveTranslation)), .otherParty)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(realtime: true, sessionControl: false)),
                       .sessionControlUnavailable)
        XCTAssertNil(MediaTriggerPolicy.releaseReason(conditions()))
        XCTAssertNil(MediaTriggerPolicy.releaseReason(conditions(owner: .geminiLive)))
    }

    func testDisabledOutranksUserAudioInTheReason() {
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(enabled: false, userAudio: true)),
                       .disabled)
    }

    func testAReasonExactlyWhenNoModeIsWanted() {
        // The reason and the desired mode are one decision; they must never disagree.
        for enabled in [true, false] {
            for glasses in [true, false] {
                for userAudio in [true, false] {
                    for yielded in [true, false] {
                        for owner in [nil] + AudioSessionOwner.allCases.map(Optional.some) {
                            for conversation in [true, false] {
                                for sessionControl in [true, false] {
                                    let c = conditions(enabled: enabled, glasses: glasses,
                                                       userAudio: userAudio, yielded: yielded,
                                                       owner: owner, conversation: conversation,
                                                       sessionControl: sessionControl)
                                    XCTAssertEqual(MediaTriggerPolicy.releaseReason(c) == nil,
                                                   MediaTriggerPolicy.desiredMode(c) != nil, "\(c)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lock-screen widget: glasses present, other media first

    func testNoClaimWithoutGlasses() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(glasses: false)), .defer)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(glasses: false, claimed: .standby)), .release)
        // Not even session control: no taps can come from glasses that are not there.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(glasses: false, owner: .geminiLive,
                                                            claimed: .sessionControl)), .release)
    }

    func testYieldedMediaKeepsTheClaimOffEvenWhenSilent() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(yielded: true)), .defer)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(yielded: true, claimed: .standby)), .release)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(yielded: true, conversation: true)), .defer)
    }

    func testGlassesAbsentOutranksMediaInTheReason() {
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(glasses: false, userAudio: true,
                                                                   yielded: true)), .glassesAbsent)
        XCTAssertEqual(MediaTriggerPolicy.releaseReason(conditions(userAudio: true, yielded: true)),
                       .userAudio)
    }

    // MARK: - Standby matrix (Plan CH, unchanged)

    func testClaimsWhenIdleAndEnabled() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim(.standby))
    }

    func testAlreadyClaimedAndClearDefers() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(claimed: .standby)), .defer)
    }

    func testDisabledNeverClaims() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(enabled: false)), .defer)
    }

    func testDisableWhileClaimedReleases() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(enabled: false, claimed: .standby)), .release)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(enabled: false, claimed: .sessionControl)), .release)
    }

    func testUserAudioBlocksClaim() {
        // The user's own music always wins — never claim over it.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true)), .defer)
    }

    func testUserAudioStartingWhileClaimedReleases() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, claimed: .standby)), .release)
    }

    func testUserAudioWinsEvenDuringOwnConversation() {
        // With music playing, taps control the music — session control does not override that.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, owner: .geminiLive,
                                                            claimed: .sessionControl)), .release)
    }

    func testAmbientOwnersDoNotBlockClaim() {
        // The wake-word listener holds the lease whenever it runs — the trigger must be able to
        // coexist with it, or it could never claim at all. Same for TTS, ourselves and capture.
        for owner: AudioSessionOwner? in [nil, .wakeWord, .textToSpeech, .mediaTrigger, .captureAudio] {
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner)), .claim(.standby),
                           "\(String(describing: owner)) should not block claiming")
        }
    }

    func testEveryOwnerIsClassified() {
        // The table must stay total as owners are added, and only ambient owners allow standby.
        for owner in AudioSessionOwner.allCases {
            XCTAssertEqual(MediaTriggerPolicy.ownerBlocksClaim(owner),
                           MediaTriggerPolicy.classify(owner) != .ambient)
        }
    }

    func testMusicInterruptionTransitionRoundTrip() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim(.standby))
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(userAudio: true, claimed: .standby)), .release)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions()), .claim(.standby))
    }

    // MARK: - Session control (Plan GJ)

    func testOwnConversationOwnersSwitchToSessionControl() {
        for owner: AudioSessionOwner in [.transcription, .geminiLive, .openAIRealtime] {
            XCTAssertEqual(MediaTriggerPolicy.classify(owner), .ownConversation)
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner, claimed: .standby)),
                           .claim(.sessionControl), "\(owner) should keep the handlers")
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner)), .claim(.sessionControl))
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner, claimed: .sessionControl)),
                           .defer)
        }
    }

    func testRealtimeFlagOrConversationFlagAloneMeansSessionControl() {
        // The lease can lag the app's own state; either signal is enough to keep the silent
        // player away from a conversation.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(realtime: true, claimed: .standby)),
                       .claim(.sessionControl))
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: .wakeWord, claimed: .standby,
                                                            conversation: true)),
                       .claim(.sessionControl))
    }

    func testOtherPartyOwnersStillBlockEverything() {
        // Another person is on the line: no taps at all, in either mode.
        for owner: AudioSessionOwner in [.liveTranslation, .expertCall] {
            XCTAssertEqual(MediaTriggerPolicy.classify(owner), .otherParty)
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner)), .defer)
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner, claimed: .standby)), .release)
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: owner, claimed: .sessionControl)), .release)
            XCTAssertEqual(MediaTriggerPolicy.decide(conditions(realtime: true, owner: owner,
                                                                claimed: .sessionControl)), .release)
        }
    }

    func testSessionControlDisabledReleasesDuringConversation() {
        // If the glasses run shows taps don't arrive mid-conversation, the handlers go (Plan CH's
        // original behaviour) rather than sitting there looking available.
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: .transcription, claimed: .standby,
                                                            sessionControl: false)), .release)
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(realtime: true, sessionControl: false)), .defer)
    }

    func testConversationEndingReturnsToStandby() {
        XCTAssertEqual(MediaTriggerPolicy.decide(conditions(owner: .wakeWord, claimed: .sessionControl)),
                       .claim(.standby))
    }
}
