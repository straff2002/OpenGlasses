import XCTest
@testable import OpenGlasses

/// Tests for the temple-tap trigger service's state machine (Plan CH P2, Plan GJ P1): policy
/// application through the claimer seam (both claim modes), command → tap decoding and gating, and
/// the stand-down path. Fresh instances
/// with injected inputs throughout (house rule: never `.shared` in tests); the production
/// `SilentNowPlayingClaimer` is device runtime and not exercised here beyond its WAV generator.
@MainActor
final class MediaTriggerServiceTests: XCTestCase {

    private final class SpyClaimer: NowPlayingClaiming {
        var claimCount = 0
        var releaseCount = 0
        var modes: [NowPlayingClaimMode] = []
        var onCommand: ((MediaRemoteCommand) -> Void)?
        func claim(mode: NowPlayingClaimMode, onCommand: @escaping (MediaRemoteCommand) -> Void) {
            claimCount += 1
            modes.append(mode)
            self.onCommand = onCommand
        }
        func release() {
            releaseCount += 1
            onCommand = nil
        }
    }

    /// Mutable world the injected closures read — one place to flip conditions mid-test.
    private final class World {
        var enabled = true
        var otherAudio = false
        var realtime = false
        var owner: AudioSessionOwner?
        var conversation = false
        var sessionControl = true
        var now: TimeInterval = 0
    }

    private var world = World()
    private var claimer = SpyClaimer()

    override func setUp() {
        super.setUp()
        world = World()
        claimer = SpyClaimer()
    }

    private func makeService(debounce: TimeInterval = 2.0) -> MediaTriggerService {
        let service = MediaTriggerService(
            claimer: claimer,
            isEnabled: { [world] in world.enabled },
            isOtherAudioPlaying: { [world] in world.otherAudio },
            leaseOwner: { [world] in world.owner },
            calibration: { [world] in
                var calibration = TempleCalibration.assumedDefault
                calibration.sessionControlAvailable = world.sessionControl
                return calibration
            },
            clock: { [world] in world.now },
            debounceInterval: debounce)
        service.realtimeSessionActive = { [world] in world.realtime }
        service.conversationActive = { [world] in world.conversation }
        return service
    }

    // MARK: - Claim / release transitions

    func testStartClaimsWhenIdle() {
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isClaimed)
        XCTAssertEqual(claimer.claimCount, 1)
        service.stop()
    }

    func testStartIsNoOpWhenDisabled() {
        world.enabled = false
        let service = makeService()
        service.start()
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(claimer.claimCount, 0)
    }

    func testDoesNotClaimOverUserAudio() {
        world.otherAudio = true
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertFalse(service.isClaimed)
        service.stop()
    }

    func testUserAudioStartingReleasesClaim() {
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isClaimed)
        world.otherAudio = true
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        XCTAssertEqual(claimer.releaseCount, 1)
        // Music stops → the next evaluation reclaims.
        world.otherAudio = false
        service.evaluate()
        XCTAssertTrue(service.isClaimed)
        XCTAssertEqual(claimer.claimCount, 2)
        service.stop()
    }

    func testRealtimeSessionSwitchesToSessionControl() {
        let service = makeService()
        service.start()
        world.realtime = true
        service.evaluate()
        // The standby claim (and its silent player) is dropped, and handlers-only control taken.
        XCTAssertEqual(service.claimedMode, .sessionControl)
        XCTAssertEqual(claimer.releaseCount, 1)
        XCTAssertEqual(claimer.modes, [.standby, .sessionControl])
        // Session over → back to the silent-player standby claim.
        world.realtime = false
        service.evaluate()
        XCTAssertEqual(service.claimedMode, .standby)
        XCTAssertEqual(claimer.modes, [.standby, .sessionControl, .standby])
        service.stop()
    }

    func testDirectConversationSwitchesToSessionControl() {
        let service = makeService()
        service.start()
        world.conversation = true
        world.owner = .transcription
        service.evaluate()
        XCTAssertEqual(service.claimedMode, .sessionControl)
        service.stop()
    }

    func testSessionControlUnavailableReleasesInConversation() {
        world.sessionControl = false
        let service = makeService()
        service.start()
        world.owner = .geminiLive
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        service.stop()
    }

    func testOtherPartyLeaseHolderForcesRelease() {
        let service = makeService()
        service.start()
        world.owner = .expertCall
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        service.stop()
    }

    func testWakeWordLeaseDoesNotBlockClaim() {
        world.owner = .wakeWord
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isClaimed)
        service.stop()
    }

    func testStopReleasesClaim() {
        let service = makeService()
        service.start()
        service.stop()
        XCTAssertFalse(service.isClaimed)
        XCTAssertEqual(claimer.releaseCount, 1)
    }

    func testEvaluateWhileClaimedAndClearIsStable() {
        let service = makeService()
        service.start()
        service.evaluate()
        service.evaluate()
        XCTAssertEqual(claimer.claimCount, 1)   // no re-claim churn
        service.stop()
    }

    func testRefreshAfterDisableReleases() {
        let service = makeService()
        service.start()
        world.enabled = false
        service.refresh()
        XCTAssertFalse(service.isClaimed)
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Command → tap

    func testNextTrackCommandFiresTwoTaps() {
        let service = makeService()
        var fired: [TempleGesture] = []
        service.onGesture = { gesture, _ in fired.append(gesture) }
        service.start()
        XCTAssertEqual(service.handleRemoteCommand(.nextTrack), .two)
        XCTAssertEqual(fired, [.two])
        service.stop()
    }

    func testCommandArrivesThroughClaimerCallback() {
        let service = makeService()
        var fired: [(TempleGesture, MediaRemoteCommand)] = []
        service.onGesture = { fired.append(($0, $1)) }
        service.start()
        claimer.onCommand?(.previousTrack)
        XCTAssertEqual(fired.map { $0.0 }, [.three])
        XCTAssertEqual(fired.map { $0.1 }, [.previousTrack])
        service.stop()
    }

    func testEveryCommandDecodesToATap() {
        // Play/pause and previous-track did nothing under the single-gesture grammar; every
        // command now decodes to a tap through the calibration table.
        let service = makeService(debounce: 0)
        var fired: [TempleGesture] = []
        service.onGesture = { gesture, _ in fired.append(gesture) }
        service.start()
        for (index, command) in [MediaRemoteCommand.togglePlayPause, .play, .pause, .nextTrack, .previousTrack].enumerated() {
            world.now = Double(index)
            service.handleRemoteCommand(command)
        }
        XCTAssertEqual(fired, [.one, .one, .one, .two, .three])
        service.stop()
    }

    func testPauseThenPlayInOneTapFiresOnce() {
        let service = makeService(debounce: 0)
        var fired: [TempleGesture] = []
        service.onGesture = { gesture, _ in fired.append(gesture) }
        service.start()
        XCTAssertEqual(service.handleRemoteCommand(.pause), .one)
        world.now = 0.05
        XCTAssertNil(service.handleRemoteCommand(.play))
        XCTAssertEqual(fired, [.one])
        service.stop()
    }

    func testDebounceDropsRapidRepeats() {
        let service = makeService(debounce: 2.0)
        var fired = 0
        service.onGesture = { _, _ in fired += 1 }
        service.start()
        XCTAssertNotNil(service.handleRemoteCommand(.nextTrack))
        world.now = 1.0
        XCTAssertNil(service.handleRemoteCommand(.nextTrack))   // inside the window
        world.now = 3.0
        XCTAssertNotNil(service.handleRemoteCommand(.nextTrack))    // outside it
        XCTAssertEqual(fired, 2)
        service.stop()
    }

    func testTapsFireDuringSessionControl() {
        // The point of session control: a conversation no longer swallows the taps.
        let service = makeService()
        var fired: [TempleGesture] = []
        service.onGesture = { gesture, _ in fired.append(gesture) }
        service.start()
        world.owner = .geminiLive
        service.evaluate()
        XCTAssertEqual(service.handleRemoteCommand(.nextTrack), .two)
        XCTAssertEqual(fired, [.two])
        service.stop()
    }

    func testCommandWithoutClaimDoesNotFire() {
        world.otherAudio = true   // never claimed
        let service = makeService()
        var fired = 0
        service.onGesture = { _, _ in fired += 1 }
        service.start()
        XCTAssertNil(service.handleRemoteCommand(.nextTrack))
        XCTAssertEqual(fired, 0)
        service.stop()
    }

    // MARK: - Stand-down for user playback

    func testStandDownReleasesImmediately() {
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isClaimed)
        service.standDownForUserPlayback()
        // Released even though no other audio is audible yet — the user's playback is on its way.
        XCTAssertFalse(service.isClaimed)
        XCTAssertEqual(claimer.releaseCount, 1)
        service.stop()
    }

    // MARK: - Silent asset

    func testSilentWAVIsAValidRIFFFile() {
        let data = SilentNowPlayingClaimer.silentWAV(sampleRate: 8000)
        XCTAssertEqual(data.count, 44 + 16_000)                       // header + 1 s of 16-bit mono
        XCTAssertEqual(String(bytes: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertTrue(data.suffix(from: 44).allSatisfy { $0 == 0 })   // actually silent
    }
}
