import XCTest
@testable import OpenGlasses

/// Plan FE P5 — the playback-activity signal behind the speech-reactive visuals.
///
/// Everything here is headless and clock-injected. The simulator has no speech engine and no audio
/// route, so a test that could only reach this through real playback would reach it nowhere; the
/// core takes its time as a parameter and the monitor takes its cadence as a seam, which is what
/// makes "the level was still zero 200 ms in" and "no cadence was ever started" assertable claims
/// rather than descriptions.
final class PlaybackActivityTests: XCTestCase {

    private let tuning = PlaybackActivityCore.Tuning.default

    // MARK: - Normalization

    /// dBFS → `0…1` against a floor, linear and clamped at both ends.
    func testMeterNormalizationMapsDecibelsToUnitRangeWithAFloor() {
        let floor = tuning.meterFloorDB
        XCTAssertEqual(PlaybackActivityCore.normalized(meterDB: 0, floor: floor), 1, accuracy: 1e-9)
        XCTAssertEqual(PlaybackActivityCore.normalized(meterDB: floor, floor: floor), 0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackActivityCore.normalized(meterDB: floor / 2, floor: floor), 0.5, accuracy: 1e-9)
        // Below the floor and above 0 dBFS are both clamped: −160 dB (AVAudioPlayer's silence) is
        // 0, and a hot signal cannot push the wave past its lane.
        XCTAssertEqual(PlaybackActivityCore.normalized(meterDB: -160, floor: floor), 0, accuracy: 1e-9)
        XCTAssertEqual(PlaybackActivityCore.normalized(meterDB: 12, floor: floor), 1, accuracy: 1e-9)
    }

    // MARK: - Start delay

    /// The level is zero until playback actually begins — a queued or downloading utterance
    /// animates nothing, and ticking an idle core does not start anything either.
    func testLevelStaysZeroUntilPlaybackBegins() {
        var core = PlaybackActivityCore()
        XCTAssertNil(core.generation)
        XCTAssertEqual(core.level, 0)
        XCTAssertFalse(core.needsCadence)
        XCTAssertFalse(core.tick(at: 10))
        core.observe(meterDB: -3, generation: 1)
        XCTAssertEqual(core.level, 0, "a meter reading before start must not animate anything")
        XCTAssertFalse(core.tick(at: 10.05))
        XCTAssertEqual(core.level, 0)
    }

    // MARK: - Meter path

    /// A loud meter drives the level up and a silent one brings it back down inside the documented
    /// bound — both inside `0…1` at every step.
    func testMeterDrivesLevelAndSilenceDecaysWithinTheBound() {
        var core = PlaybackActivityCore()
        XCTAssertTrue(core.begin(generation: 1, source: .meter, at: 0))

        var t = 0.0
        core.observe(meterDB: -5, generation: 1)
        while t < 0.5 {
            t += tuning.cadence
            XCTAssertTrue(core.tick(at: t))
            XCTAssertTrue((0...1).contains(core.level), "escaped 0…1 at \(t)")
        }
        XCTAssertGreaterThan(core.level, 0.5, "a loud meter should raise the level")

        // Now silence. AVAudioPlayer reports −160 dB for digital silence.
        let silenceStart = t
        core.observe(meterDB: -160, generation: 1)
        while t < silenceStart + tuning.silenceDecayBound {
            t += tuning.cadence
            core.observe(meterDB: -160, generation: 1)
            XCTAssertTrue(core.tick(at: t))
        }
        XCTAssertLessThanOrEqual(core.level, tuning.silenceResidual,
                                 "silence must decay within silenceDecayBound")
        XCTAssertTrue(core.needsCadence, "silence is not the end of playback — the cadence stays")
    }

    /// A meter source that has gone away reads as silence, not as "hold the last value": a level
    /// nothing can refute any more should fall rather than freeze.
    func testMissingMeterSampleReadsAsSilence() {
        var core = PlaybackActivityCore()
        core.begin(generation: 4, source: .meter, at: 0)
        core.observe(meterDB: -2, generation: 4)
        var t = 0.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        let loud = core.level
        XCTAssertGreaterThan(loud, 0.4)

        core.observe(meterDB: nil, generation: 4)
        for _ in 0..<20 { t += tuning.cadence; core.observe(meterDB: nil, generation: 4); core.tick(at: t) }
        XCTAssertLessThan(core.level, loud / 4)
    }

    // MARK: - Word pulse

    /// The word pulse's shape: zero at the callback, a short rise to its (sub-1) peak, then a fall
    /// back toward zero — all inside `0…1`, and flagged approximate.
    func testWordPulseEnvelopeShapeAndBound() {
        XCTAssertEqual(PlaybackActivityCore.pulseEnvelope(elapsed: 0, tuning: tuning), 0, accuracy: 1e-9)
        let peak = PlaybackActivityCore.pulseEnvelope(elapsed: tuning.wordPulseAttack, tuning: tuning)
        XCTAssertEqual(peak, tuning.wordPulsePeak, accuracy: 1e-9)
        XCTAssertLessThan(peak, 1, "an approximation must not claim the top of a measured range")
        XCTAssertGreaterThan(peak, PlaybackActivityCore.pulseEnvelope(elapsed: tuning.wordPulseAttack / 2,
                                                                     tuning: tuning))
        XCTAssertLessThan(PlaybackActivityCore.pulseEnvelope(elapsed: 1.0, tuning: tuning), 0.05)
        for elapsed in stride(from: -0.1, through: 2.0, by: 0.01) {
            let value = PlaybackActivityCore.pulseEnvelope(elapsed: elapsed, tuning: tuning)
            XCTAssertTrue((0...1).contains(value), "escaped 0…1 at \(elapsed)")
        }
    }

    /// The system engine's path is flagged approximate and its words move the level; between words
    /// it falls. The flag is the contract: this is inferred from callback *timing*, never measured.
    func testWordBoundariesDriveAnApproximateLevel() {
        var core = PlaybackActivityCore()
        core.begin(generation: 2, source: .wordPulse, at: 0)
        XCTAssertTrue(core.isApproximate)
        XCTAssertTrue(PlaybackActivitySource.wordPulse.isApproximate)
        XCTAssertFalse(PlaybackActivitySource.meter.isApproximate)

        core.observeWordBoundary(generation: 2, at: 0)
        var t = 0.0
        for _ in 0..<4 { t += tuning.cadence; core.tick(at: t) }
        let atWord = core.level
        XCTAssertGreaterThan(atWord, 0.1, "a word should be visible")

        for _ in 0..<20 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertLessThan(core.level, atWord / 2, "the pulse falls between words")
        XCTAssertTrue((0...1).contains(core.level))
    }

    /// A word boundary is not a scheduling event: twenty of them in a row move one number and the
    /// level stays bounded — "one cadence, not a task per word" holds in the core too.
    func testManyWordBoundariesStayBounded() {
        var core = PlaybackActivityCore()
        core.begin(generation: 3, source: .wordPulse, at: 0)
        var t = 0.0
        for _ in 0..<20 {
            core.observeWordBoundary(generation: 3, at: t)
            for _ in 0..<3 { t += tuning.cadence; core.tick(at: t) }
            XCTAssertTrue((0...1).contains(core.level))
        }
        XCTAssertLessThanOrEqual(core.level, 1)
    }

    /// A meter reading cannot drive the word-pulse path and a word cannot drive the meter path —
    /// the source a generation started with is the source it keeps.
    func testSourcesDoNotCrossFeed() {
        var core = PlaybackActivityCore()
        core.begin(generation: 1, source: .wordPulse, at: 0)
        core.observe(meterDB: 0, generation: 1)
        var t = 0.0
        for _ in 0..<5 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertEqual(core.level, 0, accuracy: 1e-9, "a meter must not feed the word-pulse path")

        var meterCore = PlaybackActivityCore()
        meterCore.begin(generation: 1, source: .meter, at: 0)
        meterCore.observeWordBoundary(generation: 1, at: 0)
        t = 0
        for _ in 0..<5 { t += tuning.cadence; meterCore.tick(at: t) }
        XCTAssertEqual(meterCore.level, 0, accuracy: 1e-9, "a word must not feed the meter path")
    }

    // MARK: - Finish, error, cancel

    /// Playback ending runs the level down to zero within `endDecay` and then stops the cadence.
    /// The same path serves finish, decode error and engine cancel — the core is told "it ended",
    /// not why, because the animation has nothing different to say about the three.
    func testEndDecaysToZeroWithinTheBoundAndStopsTheCadence() {
        var core = PlaybackActivityCore()
        core.begin(generation: 7, source: .meter, at: 0)
        core.observe(meterDB: -2, generation: 7)
        var t = 0.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertGreaterThan(core.level, 0.4)

        core.end(generation: 7, at: t)
        let deadline = t + tuning.endDecay
        var running = true
        while t < deadline + tuning.cadence, running {
            t += tuning.cadence
            running = core.tick(at: t)
            XCTAssertTrue((0...1).contains(core.level))
        }
        XCTAssertFalse(running, "the cadence must stop once the run-down reaches zero")
        XCTAssertEqual(core.level, 0)
        XCTAssertNil(core.generation)
        XCTAssertFalse(core.needsCadence)
        XCTAssertLessThanOrEqual(t, deadline + 2 * tuning.cadence, "the run-down is bounded")
    }

    /// The run-down is monotonic — it never bumps back up on a late meter reading or a late word.
    func testEndIgnoresLateInputsAndNeverRises() {
        var core = PlaybackActivityCore()
        core.begin(generation: 8, source: .meter, at: 0)
        core.observe(meterDB: -4, generation: 8)
        var t = 0.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        core.end(generation: 8, at: t)

        var previous = core.level
        var running = true
        while running {
            t += tuning.cadence
            core.observe(meterDB: 0, generation: 8)
            core.observeWordBoundary(generation: 8, at: t)
            running = core.tick(at: t)
            XCTAssertLessThanOrEqual(core.level, previous, "the run-down rose again at \(t)")
            previous = core.level
        }
        XCTAssertEqual(core.level, 0)
    }

    // MARK: - Stop

    /// Stop is immediate: zero level, no generation, no tail. The audio is already gone.
    func testStopZeroesImmediately() {
        var core = PlaybackActivityCore()
        core.begin(generation: 9, source: .meter, at: 0)
        core.observe(meterDB: 0, generation: 9)
        var t = 0.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertGreaterThan(core.level, 0.5)

        core.stopImmediately()
        XCTAssertEqual(core.level, 0)
        XCTAssertNil(core.generation)
        XCTAssertFalse(core.isApproximate)
        XCTAssertFalse(core.tick(at: t + tuning.cadence))
    }

    // MARK: - Generation

    /// Rapid utterance replacement: the older generation's samples are ignored, and the newer one
    /// starts from zero rather than inheriting the level it interrupted.
    func testNewGenerationStartsCleanAndIgnoresTheOldOnesSamples() {
        var core = PlaybackActivityCore()
        core.begin(generation: 1, source: .meter, at: 0)
        core.observe(meterDB: 0, generation: 1)
        var t = 0.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertGreaterThan(core.level, 0.5)

        XCTAssertTrue(core.begin(generation: 2, source: .meter, at: t))
        XCTAssertEqual(core.level, 0, "a new utterance does not inherit its predecessor's level")

        // Everything the old utterance has left to say is dropped.
        core.observe(meterDB: 0, generation: 1)
        core.observeWordBoundary(generation: 1, at: t)
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        XCTAssertEqual(core.level, 0, accuracy: 1e-9, "an older utterance animated a newer one")
        XCTAssertEqual(core.generation, 2)
    }

    /// A late `end` from a replaced utterance cannot stop the animation of the one that replaced it.
    func testLateEndFromAnOlderGenerationIsIgnored() {
        var core = PlaybackActivityCore()
        core.begin(generation: 1, source: .meter, at: 0)
        core.begin(generation: 2, source: .meter, at: 1)
        core.observe(meterDB: -3, generation: 2)
        var t = 1.0
        for _ in 0..<10 { t += tuning.cadence; core.tick(at: t) }
        let live = core.level

        core.end(generation: 1, at: t)
        XCTAssertTrue(core.tick(at: t + tuning.cadence))
        XCTAssertGreaterThan(core.level, live / 2, "a stale end tore down a live animation")
        XCTAssertEqual(core.generation, 2)
    }

    /// One cadence per generation: a second `begin` for the generation already running is a no-op,
    /// so a duplicate "playback started" cannot double anything up.
    func testRepeatBeginForTheSameGenerationDoesNotRestart() {
        var core = PlaybackActivityCore()
        XCTAssertTrue(core.begin(generation: 5, source: .meter, at: 0))
        core.observe(meterDB: -3, generation: 5)
        var t = 0.0
        for _ in 0..<8 { t += tuning.cadence; core.tick(at: t) }
        let level = core.level
        XCTAssertFalse(core.begin(generation: 5, source: .meter, at: t),
                       "the same generation must not start a second cadence")
        XCTAssertEqual(core.level, level, accuracy: 1e-9)
    }

    // MARK: - The gate

    /// The four gates, each sufficient on its own to refuse a cadence.
    func testGateRefusesHiddenInactiveReducedMotionAndConservingPower() {
        XCTAssertTrue(PlaybackActivityGate.allowsMetering(visible: true, sceneActive: true,
                                                          reduceMotion: false, posture: .normal))
        XCTAssertFalse(PlaybackActivityGate.allowsMetering(visible: false, sceneActive: true,
                                                           reduceMotion: false, posture: .normal))
        XCTAssertFalse(PlaybackActivityGate.allowsMetering(visible: true, sceneActive: false,
                                                           reduceMotion: false, posture: .normal))
        XCTAssertFalse(PlaybackActivityGate.allowsMetering(visible: true, sceneActive: true,
                                                           reduceMotion: true, posture: .normal))
        for posture in [PowerPosture.conserve, .reserve] {
            XCTAssertFalse(PlaybackActivityGate.allowsMetering(visible: true, sceneActive: true,
                                                               reduceMotion: false, posture: posture),
                           "\(posture) still metered")
        }
        XCTAssertTrue(PowerPosture.normal.allowsDecorativeMetering)
        XCTAssertFalse(PowerPosture.conserve.allowsDecorativeMetering)
        XCTAssertFalse(PowerPosture.reserve.allowsDecorativeMetering)
    }

    // MARK: - The monitor

    @MainActor
    private func makeMonitor(posture: PowerPosture = .normal)
        -> (PlaybackActivityMonitor, FakeCadence, Clock) {
        let cadence = FakeCadence()
        let clock = Clock()
        let monitor = PlaybackActivityMonitor(cadence: cadence, now: { clock.now })
        monitor.posture = { posture }
        monitor.setVisible(true)
        return (monitor, cadence, clock)
    }

    /// The happy path: playback starts, exactly one cadence runs, the meter is enabled once, and
    /// the published level tracks it.
    @MainActor
    func testMonitorRunsOneCadenceAndPublishesTheLevel() {
        let (monitor, cadence, clock) = makeMonitor()
        var enabled = 0
        let meter = PlaybackMeterSource(enable: { enabled += 1 }, sample: { -4 })

        XCTAssertTrue(monitor.playbackDidStart(generation: 1, meter: meter))
        XCTAssertEqual(enabled, 1)
        XCTAssertEqual(cadence.startCount, 1)
        XCTAssertEqual(monitor.cadenceStartCount, 1)
        XCTAssertTrue(monitor.isCadenceRunning)
        XCTAssertFalse(monitor.isApproximate, "the player path is a real meter")

        for _ in 0..<12 { clock.advance(cadence.interval); cadence.tick() }
        XCTAssertNotNil(monitor.activity)
        XCTAssertGreaterThan(monitor.activity ?? 0, 0.5)
        XCTAssertLessThanOrEqual(monitor.activity ?? 0, 1)
        XCTAssertEqual(cadence.startCount, 1, "a second cadence was started")
        XCTAssertEqual(enabled, 1, "metering was enabled more than once")
    }

    /// Finishing publishes `nil` — the signal's way of saying "no live level", which is what puts
    /// the visuals back on their approved state-only behaviour — and stops the cadence.
    @MainActor
    func testMonitorClearsTheLevelAndStopsTheCadenceWhenPlaybackEnds() {
        let (monitor, cadence, clock) = makeMonitor()
        monitor.playbackDidStart(generation: 1,
                                 meter: PlaybackMeterSource(enable: {}, sample: { -4 }))
        for _ in 0..<10 { clock.advance(cadence.interval); cadence.tick() }
        XCTAssertNotNil(monitor.activity)

        monitor.playbackDidEnd(generation: 1)
        var guardRail = 0
        while monitor.isCadenceRunning, guardRail < 200 {
            clock.advance(cadence.interval)
            cadence.tick()
            guardRail += 1
        }
        XCTAssertLessThan(guardRail, 200, "the cadence never stopped")
        XCTAssertNil(monitor.activity)
        XCTAssertFalse(monitor.isCadenceRunning)
        XCTAssertFalse(monitor.isApproximate)
    }

    /// Stop is immediate and takes the cadence with it.
    @MainActor
    func testMonitorStopIsImmediate() {
        let (monitor, cadence, clock) = makeMonitor()
        monitor.playbackDidStart(generation: 1,
                                 meter: PlaybackMeterSource(enable: {}, sample: { -4 }))
        for _ in 0..<10 { clock.advance(cadence.interval); cadence.tick() }
        monitor.stopImmediately()
        XCTAssertNil(monitor.activity)
        XCTAssertFalse(monitor.isCadenceRunning)
        XCTAssertEqual(cadence.stopCount, 1)
    }

    /// Hidden, inactive, Reduce Motion and a conserving posture each mean **no cadence is
    /// started** — not "the ticks are ignored". The meter's `enable` is never called either, so
    /// the player is never asked to compute power in the first place.
    @MainActor
    func testGatedOffPlaybackStartsNoCadenceAtAll() {
        func assertNoCadence(_ configure: (PlaybackActivityMonitor) -> Void,
                             _ label: String,
                             posture: PowerPosture = .normal,
                             file: StaticString = #filePath, line: UInt = #line) {
            let (monitor, cadence, _) = makeMonitor(posture: posture)
            configure(monitor)
            var enabled = 0
            let started = monitor.playbackDidStart(
                generation: 1, meter: PlaybackMeterSource(enable: { enabled += 1 }, sample: { 0 }))
            XCTAssertFalse(started, label, file: file, line: line)
            XCTAssertEqual(cadence.startCount, 0, "\(label): a cadence was started",
                           file: file, line: line)
            XCTAssertEqual(monitor.cadenceStartCount, 0, "\(label): a cadence was counted",
                           file: file, line: line)
            XCTAssertFalse(monitor.isCadenceRunning, label, file: file, line: line)
            XCTAssertEqual(enabled, 0, "\(label): metering was enabled at the source",
                           file: file, line: line)
            XCTAssertNil(monitor.activity, label, file: file, line: line)
        }

        assertNoCadence({ $0.setVisible(false) }, "hidden")
        assertNoCadence({ $0.setSceneActive(false) }, "inactive scene")
        assertNoCadence({ $0.setReduceMotion(true) }, "reduce motion")
        assertNoCadence({ _ in }, "conserving", posture: .conserve)
        assertNoCadence({ _ in }, "reserve", posture: .reserve)
    }

    /// A gate closing mid-utterance stops the cadence outright: the screen went away, so there is
    /// nothing for a graceful tail to be seen on.
    @MainActor
    func testClosingAGateMidPlaybackStopsTheCadence() {
        for close in [{ (m: PlaybackActivityMonitor) in m.setVisible(false) },
                      { (m: PlaybackActivityMonitor) in m.setSceneActive(false) },
                      { (m: PlaybackActivityMonitor) in m.setReduceMotion(true) }] {
            let (monitor, cadence, clock) = makeMonitor()
            monitor.playbackDidStart(generation: 1,
                                     meter: PlaybackMeterSource(enable: {}, sample: { -4 }))
            for _ in 0..<10 { clock.advance(cadence.interval); cadence.tick() }
            XCTAssertTrue(monitor.isCadenceRunning)

            close(monitor)
            XCTAssertFalse(monitor.isCadenceRunning)
            XCTAssertNil(monitor.activity)
        }
    }

    /// The system-engine path: no meter, an approximate flag, and words that move the level.
    @MainActor
    func testMonitorWordPulsePathIsFlaggedApproximate() {
        let (monitor, cadence, clock) = makeMonitor()
        XCTAssertTrue(monitor.playbackDidStart(generation: 1, meter: nil))
        XCTAssertTrue(monitor.isApproximate)

        monitor.wordBoundary(generation: 1)
        for _ in 0..<4 { clock.advance(cadence.interval); cadence.tick() }
        XCTAssertGreaterThan(monitor.activity ?? 0, 0.1)
        XCTAssertEqual(cadence.startCount, 1)

        // A hundred words schedule nothing — the cadence count is still one.
        for _ in 0..<100 {
            monitor.wordBoundary(generation: 1)
            clock.advance(cadence.interval)
            cadence.tick()
        }
        XCTAssertEqual(cadence.startCount, 1, "a word started a second cadence")
        XCTAssertLessThanOrEqual(monitor.activity ?? 0, 1)
    }

    /// Late callbacks from a replaced utterance change nothing: the older generation cannot feed
    /// the newer one's animation, and cannot end it either.
    @MainActor
    func testMonitorIgnoresLateCallbacksFromAReplacedUtterance() {
        let (monitor, cadence, clock) = makeMonitor()
        monitor.playbackDidStart(generation: 1, meter: nil)
        monitor.wordBoundary(generation: 1)
        for _ in 0..<4 { clock.advance(cadence.interval); cadence.tick() }

        // A new utterance takes the floor.
        XCTAssertTrue(monitor.playbackDidStart(generation: 2, meter: nil))
        XCTAssertEqual(monitor.cadenceStartCount, 2)
        // Zero, not `nil`: the replacement *is* playing, it has simply not made a sound yet.
        // `nil` is reserved for "no live signal at all", which is what returns the visuals to
        // their approved state-only behaviour.
        XCTAssertEqual(monitor.activity ?? -1, 0, accuracy: 1e-9,
                       "the replacement starts from nothing")

        // Everything generation 1 has left to say.
        monitor.wordBoundary(generation: 1)
        monitor.playbackDidEnd(generation: 1)
        for _ in 0..<4 { clock.advance(cadence.interval); cadence.tick() }
        XCTAssertTrue(monitor.isCadenceRunning, "a stale end stopped the live animation")
        XCTAssertEqual(monitor.activity ?? 0, 0, accuracy: 1e-9,
                       "a stale word animated the live utterance")
    }

    // MARK: - Doubles

    /// A cadence that runs when the test says so, and counts what it was asked to do.
    @MainActor
    private final class FakeCadence: PlaybackActivityCadence {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var interval: TimeInterval = 1.0 / 20.0
        private var body: (@MainActor () -> Void)?
        var isRunning: Bool { body != nil }

        func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
            startCount += 1
            self.interval = interval
            body = tick
        }

        func stop() {
            if body != nil { stopCount += 1 }
            body = nil
        }

        /// One cadence step, if one is running.
        func tick() { body?() }
    }

    private final class Clock {
        var now: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }
}
