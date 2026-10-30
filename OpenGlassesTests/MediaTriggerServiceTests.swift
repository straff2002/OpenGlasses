import MediaPlayer
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
        /// Whether the (pretend) silent player is still playing. A fresh claim starts it.
        var playerPlaying = false
        var sessionShape = "playAndRecord-mixable"
        var standbyClaimLive: Bool { playerPlaying }
        func claim(mode: NowPlayingClaimMode, onCommand: @escaping (MediaRemoteCommand) -> Void) {
            claimCount += 1
            modes.append(mode)
            self.onCommand = onCommand
            playerPlaying = mode == .standby
        }
        func release() {
            releaseCount += 1
            onCommand = nil
            playerPlaying = false
        }
    }

    /// Stands in for the service's delays: each sleep waits until the test wakes it, so the
    /// settle re-check runs exactly when a test says.
    @MainActor
    private final class ManualSleeper {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var pending: Int { waiting.count }
        func sleep() async {
            await withCheckedContinuation { waiting.append($0) }
        }
        func wakeAll() {
            let woken = waiting
            waiting = []
            woken.forEach { $0.resume() }
        }
    }

    /// Collects the `nowPlaying` support-log lines.
    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func record(_ line: String) {
            guard line.contains("surface=nowPlaying") else { return }
            lock.lock(); stored.append(line); lock.unlock()
        }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Mutable world the injected closures read — one place to flip conditions mid-test.
    private final class World {
        var enabled = true
        var glasses = true
        var otherAudio = false
        var realtime = false
        var owner: AudioSessionOwner?
        var conversation = false
        var sessionControl = true
        var now: TimeInterval = 0
    }

    private var world = World()
    private var claimer = SpyClaimer()
    private var sleeper = ManualSleeper()

    override func setUp() {
        super.setUp()
        world = World()
        claimer = SpyClaimer()
        sleeper = ManualSleeper()
    }

    private func makeService(debounce: TimeInterval = 2.0,
                             table: [MediaRemoteCommand: TempleGesture]? = nil) -> MediaTriggerService {
        let service = MediaTriggerService(
            claimer: claimer,
            isEnabled: { [world] in world.enabled },
            isOtherAudioPlaying: { [world] in world.otherAudio },
            leaseOwner: { [world] in world.owner },
            calibration: { [world] in
                var calibration = TempleCalibration.standard
                calibration.sessionControlAvailable = world.sessionControl
                if let table { calibration.table = table }
                return calibration
            },
            clock: { [world] in world.now },
            debounceInterval: debounce,
            sleep: { [sleeper] _ in await sleeper.sleep() })
        service.realtimeSessionActive = { [world] in world.realtime }
        service.conversationActive = { [world] in world.conversation }
        service.glassesPresent = { [world] in world.glasses }
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
        // Music stops (or pauses): their player keeps Now Playing and its lock-screen widget.
        world.otherAudio = false
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        XCTAssertTrue(service.yieldedToMedia)
        XCTAssertEqual(claimer.claimCount, 1)
        service.stop()
    }

    // MARK: - Glasses present (the lock-screen widget only while they could tap)

    func testNoClaimWithoutGlasses() {
        world.glasses = false
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertFalse(service.isClaimed)
        XCTAssertEqual(claimer.claimCount, 0)
        world.glasses = true
        service.evaluate(cause: .glassesChanged)
        XCTAssertTrue(service.isClaimed)
        service.stop()
    }

    func testGlassesLeavingReleasesTheClaim() {
        let service = makeService()
        service.start()
        XCTAssertTrue(service.isClaimed)
        world.glasses = false
        service.evaluate(cause: .glassesChanged)
        XCTAssertFalse(service.isClaimed)
        XCTAssertEqual(claimer.releaseCount, 1)
        service.stop()
    }

    func testGlassesArrivingAfterMediaTakesTheClaimBack() {
        let service = makeService()
        service.start()
        world.otherAudio = true
        service.evaluate()
        world.otherAudio = false
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        // Taken off (or disconnected) and put back on: a fresh start for the taps.
        world.glasses = false
        service.evaluate(cause: .glassesChanged)
        XCTAssertTrue(service.yieldedToMedia)
        world.glasses = true
        service.evaluate(cause: .glassesChanged)
        XCTAssertFalse(service.yieldedToMedia)
        XCTAssertTrue(service.isClaimed)
        service.stop()
    }

    func testSwitchingTheSettingBackOnForgetsTheYield() {
        let service = makeService()
        service.start()
        service.standDownForUserPlayback()
        XCTAssertTrue(service.yieldedToMedia)
        service.refresh()
        XCTAssertFalse(service.yieldedToMedia)
        XCTAssertTrue(service.isClaimed)
        service.stop()
    }

    func testGlassesArrivingWhileMediaPlaysStillYields() {
        world.glasses = false
        let service = makeService()
        service.start()
        world.glasses = true
        world.otherAudio = true
        service.evaluate(cause: .glassesChanged)
        XCTAssertFalse(service.isClaimed)
        world.otherAudio = false
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
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

    // MARK: - Claim health (Gen 2: dead after the first tap's action)

    /// Let the tasks a wake (or a notification) released run to their end.
    private func settle(until condition: () -> Bool = { false }) async {
        for _ in 0..<50 where !condition() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testStoppedPlayerIsReclaimedOnTheNextEvaluation() {
        let service = makeService()
        service.start()
        XCTAssertEqual(claimer.claimCount, 1)
        // iOS stopped the silent player under us (the wake word reshaped the session).
        claimer.playerPlaying = false
        world.now = 5
        service.evaluate()
        XCTAssertEqual(claimer.claimCount, 2)
        XCTAssertEqual(claimer.releaseCount, 1)   // the dead claim's handlers dropped first
        XCTAssertEqual(service.claimedMode, .standby)
        XCTAssertTrue(claimer.standbyClaimLive)
        service.stop()
    }

    func testLivePlayerIsLeftAlone() {
        let service = makeService()
        service.start()
        world.now = 5
        service.evaluate()
        XCTAssertEqual(claimer.claimCount, 1)
        service.stop()
    }

    func testDeadClaimIsNotRetakenInsideTheCooldown() {
        let service = makeService()
        service.start()                 // claimed at 0
        claimer.playerPlaying = false
        world.now = 1
        service.evaluate()
        XCTAssertEqual(claimer.claimCount, 1)   // a player that will not stay up is not chased
        world.now = 3
        service.evaluate()
        XCTAssertEqual(claimer.claimCount, 2)
        service.stop()
    }

    func testSessionControlWithoutPlayerIsNotADeadClaim() {
        let service = makeService()
        service.start()
        world.owner = .geminiLive
        service.evaluate()
        XCTAssertEqual(service.claimedMode, .sessionControl)
        XCTAssertFalse(claimer.standbyClaimLive)
        world.now = 10
        service.evaluate()
        XCTAssertEqual(claimer.modes, [.standby, .sessionControl])
        service.stop()
    }

    func testDeadClaimWithUserAudioIsReleasedWithItsReason() {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(tap) }
        let service = makeService()
        service.start()
        claimer.playerPlaying = false
        world.otherAudio = true
        world.now = 5
        service.evaluate()
        XCTAssertFalse(service.isClaimed)
        XCTAssertTrue(sink.lines.contains { $0.contains("event=released") && $0.contains("state=userAudio") },
                      "\(sink.lines)")
        service.stop()
    }

    func testTapActionRecheckRetakesADeadClaimAtOnce() {
        let service = makeService()
        service.start()
        claimer.playerPlaying = false
        world.now = 5
        service.recheckClaim(after: .tapAction)
        XCTAssertEqual(claimer.claimCount, 2)
        service.stop()
    }

    func testTapActionRecheckLooksAgainOnceTheSessionSettles() async {
        let service = makeService()
        service.start()
        service.recheckClaim(after: .tapAction)
        XCTAssertEqual(claimer.claimCount, 1)       // still live right after the action
        await settle { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.pending, 1)
        // The wake word reconfigures a moment later and the player stops.
        claimer.playerPlaying = false
        world.now = 5
        sleeper.wakeAll()
        await settle { claimer.claimCount == 2 }
        XCTAssertEqual(claimer.claimCount, 2)
        XCTAssertEqual(service.claimedMode, .standby)
        service.stop()
    }

    func testRecheckDoesNothingWhenStopped() {
        let service = makeService()
        service.recheckClaim(after: .tapAction)
        XCTAssertEqual(claimer.claimCount, 0)
        XCTAssertEqual(sleeper.pending, 0)
    }

    func testDeferredRiderHandBackRechecksTheClaim() async {
        let service = makeService()
        service.start()
        claimer.playerPlaying = false
        world.now = 5
        NotificationCenter.default.post(name: AudioSessionCoordinator.riderHandBackDeferred, object: nil)
        await settle { claimer.claimCount == 2 }
        XCTAssertEqual(claimer.claimCount, 2)
        service.stop()
    }

    func testRecheckOfALiveClaimLogsTheSessionShape() {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(tap) }
        let service = makeService()
        service.start()
        service.recheckClaim(after: .tapAction)
        XCTAssertTrue(sink.lines.contains {
            $0.contains("event=claimChecked") && $0.contains("reason=tapAction")
                && $0.contains("detail=playAndRecord-mixable")
        }, "\(sink.lines)")
        service.stop()
    }

    func testLapseIsLoggedWithItsCause() {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(tap) }
        let service = makeService()
        service.start()
        claimer.playerPlaying = false
        world.now = 5
        service.recheckClaim(after: .handBackDeferred)
        XCTAssertTrue(sink.lines.contains {
            $0.contains("event=claimLapsed") && $0.contains("reason=handBackDeferred")
        }, "\(sink.lines)")
        service.stop()
    }

    // MARK: - The user's audio ending

    func testNothingWatchesForTheUsersAudioToStop() async {
        world.otherAudio = true
        let service = makeService()
        service.start()
        XCTAssertFalse(service.isClaimed)
        await settle()
        XCTAssertEqual(sleeper.pending, 0)          // no poll: their player keeps Now Playing
        service.stop()
    }

    func testStandDownStaysDownUntilTheGlassesArrive() async {
        let service = makeService()
        service.start()
        service.standDownForUserPlayback()
        XCTAssertFalse(service.isClaimed)
        await settle()
        XCTAssertEqual(sleeper.pending, 0)
        service.evaluate()
        XCTAssertFalse(service.isClaimed)           // even if their playback never started
        world.glasses = false
        service.evaluate(cause: .glassesChanged)
        world.glasses = true
        service.evaluate(cause: .glassesChanged)
        XCTAssertTrue(service.isClaimed)
        service.stop()
    }

    // MARK: - Commands that fire nothing are logged with why

    func testDroppedCommandsSayWhy() {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(tap) }
        let service = makeService(debounce: 2.0, table: [.pause: .one, .play: .one, .nextTrack: .two])
        service.start()
        XCTAssertEqual(service.handleRemoteCommand(.pause), .one)
        world.now = 0.05
        XCTAssertNil(service.handleRemoteCommand(.play))            // same tap
        world.now = 1
        XCTAssertNil(service.handleRemoteCommand(.nextTrack))       // inside the debounce
        world.now = 5
        XCTAssertNil(service.handleRemoteCommand(.previousTrack))   // not in this table
        service.stop()
        XCTAssertNil(service.handleRemoteCommand(.nextTrack))       // no claim
        let dropped = sink.lines.filter { $0.contains("event=commandDropped") }
        XCTAssertEqual(dropped.count, 4, "\(dropped)")
        for (reason, command) in [("coalesced", "play"), ("debounced", "nextTrack"),
                                  ("unmapped", "previousTrack"), ("notClaimed", "nextTrack")] {
            XCTAssertTrue(dropped.contains { $0.contains("state=\(reason)") && $0.contains("command=\(command)") },
                          "\(reason): \(dropped)")
        }
    }

    func testStopLogsItsOwnReleaseReason() {
        let sink = LineSink()
        let tap = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(tap) }
        let service = makeService()
        service.start()
        service.standDownForUserPlayback()
        // The glasses come off and back on, which takes the claim back so the stop has one to drop.
        world.glasses = false
        service.evaluate(cause: .glassesChanged)
        world.glasses = true
        service.evaluate(cause: .glassesChanged)
        service.stop()
        let released = sink.lines.filter { $0.contains("event=released") }
        XCTAssertTrue(released.contains { $0.contains("state=userPlaybackRequested") }, "\(released)")
        XCTAssertTrue(released.contains { $0.contains("state=stopped") }, "\(released)")
    }

    // MARK: - Session shape

    func testShapeTokenNamesCategoryAndMixing() {
        XCTAssertEqual(SilentNowPlayingClaimer.shapeToken(category: .playAndRecord,
                                                         options: [.mixWithOthers, .allowBluetoothA2DP]),
                       "playAndRecord-mixable")
        XCTAssertEqual(SilentNowPlayingClaimer.shapeToken(category: .playback, options: []),
                       "playback-exclusive")
        XCTAssertEqual(SilentNowPlayingClaimer.shapeToken(category: .soloAmbient, options: []),
                       "soloAmbient-exclusive")
    }

    // MARK: - Now Playing info

    func testClaimInfoCarriesNoTitleAndReadsAsOurOwn() {
        let info = SilentNowPlayingClaimer.claimInfo
        XCTAssertNil(info[MPMediaItemPropertyTitle])
        XCTAssertTrue(SilentNowPlayingClaimer.isOwnInfo(info))
        XCTAssertFalse(SilentNowPlayingClaimer.isOwnInfo([MPMediaItemPropertyTitle: "Hardcore History"]))
        XCTAssertFalse(SilentNowPlayingClaimer.isOwnInfo([MPMediaItemPropertyArtist: "Dan Carlin"]))
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
