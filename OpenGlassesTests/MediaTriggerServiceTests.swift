import XCTest
@testable import OpenGlasses

/// Tests for the temple-tap trigger service's state machine (Plan CH P2): policy application
/// through the claimer seam, command → trigger gating, and the stand-down path. Fresh instances
/// with injected inputs throughout (house rule: never `.shared` in tests); the production
/// `SilentNowPlayingClaimer` is device runtime and not exercised here beyond its WAV generator.
@MainActor
final class MediaTriggerServiceTests: XCTestCase {

    private final class SpyClaimer: NowPlayingClaiming {
        var claimCount = 0
        var releaseCount = 0
        var onCommand: ((MediaRemoteCommand) -> Void)?
        func claim(onCommand: @escaping (MediaRemoteCommand) -> Void) {
            claimCount += 1
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
        var suppressed = false
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
            clock: { [world] in world.now },
            debounceInterval: debounce)
        service.isSuppressed = { [world] in world.suppressed }
        service.realtimeSessionActive = { [world] in world.realtime }
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

    func testRealtimeSessionForcesRelease() {
        let service = makeService()
        service.start()
        world.realtime = true
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        service.stop()
    }

    func testExclusiveLeaseHolderForcesRelease() {
        let service = makeService()
        service.start()
        world.owner = .geminiLive
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

    // MARK: - Command → trigger

    func testNextTrackCommandFiresTrigger() {
        let service = makeService()
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        XCTAssertTrue(service.handleRemoteCommand(.nextTrack))
        XCTAssertEqual(fired, 1)
        service.stop()
    }

    func testCommandArrivesThroughClaimerCallback() {
        let service = makeService()
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        claimer.onCommand?(.nextTrack)
        XCTAssertEqual(fired, 1)
        service.stop()
    }

    func testPlayPauseAndPreviousDoNotFire() {
        let service = makeService()
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        XCTAssertFalse(service.handleRemoteCommand(.togglePlayPause))
        XCTAssertFalse(service.handleRemoteCommand(.previousTrack))
        XCTAssertEqual(fired, 0)
        service.stop()
    }

    func testDebounceDropsRapidRepeats() {
        let service = makeService(debounce: 2.0)
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        XCTAssertTrue(service.handleRemoteCommand(.nextTrack))
        world.now = 1.0
        XCTAssertFalse(service.handleRemoteCommand(.nextTrack))   // inside the window
        world.now = 3.0
        XCTAssertTrue(service.handleRemoteCommand(.nextTrack))    // outside it
        XCTAssertEqual(fired, 2)
        service.stop()
    }

    func testSuppressedCommandDoesNotFire() {
        let service = makeService()
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        world.suppressed = true
        XCTAssertFalse(service.handleRemoteCommand(.nextTrack))
        XCTAssertEqual(fired, 0)
        service.stop()
    }

    func testCommandWithoutClaimDoesNotFire() {
        world.otherAudio = true   // never claimed
        let service = makeService()
        var fired = 0
        service.onTrigger = { fired += 1 }
        service.start()
        XCTAssertFalse(service.handleRemoteCommand(.nextTrack))
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
