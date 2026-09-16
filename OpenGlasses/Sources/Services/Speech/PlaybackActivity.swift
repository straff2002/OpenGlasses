import Foundation

/// Where one activity sample came from — and, crucially, how much it is worth (Plan FE P5).
///
/// The distinction is the whole reason this type exists. One of these is a measurement; the other
/// is a guess shaped like one, and the code must never let the second be described as the first.
enum PlaybackActivitySource: Equatable {
    /// A real audio meter: `AVAudioPlayer.averagePower(forChannel:)` on the path that is actually
    /// playing the audio. This is measured signal level.
    case meter
    /// An **approximate** envelope driven by the system synthesizer's word-boundary callbacks
    /// (`willSpeakRangeOfSpeechString`). `AVSpeechSynthesizer` exposes no audio to meter, so the
    /// only thing available is *when a word starts*. A short attack/decay per word looks like
    /// speech because speech has words in it — it is not loudness, not amplitude, and not an audio
    /// measurement of any kind, and nothing in the UI may present it as one.
    case wordPulse

    /// `true` when the level is inferred rather than measured. Carried so callers cannot
    /// accidentally treat the two the same.
    var isApproximate: Bool { self == .wordPulse }
}

/// A live meter on whatever is currently playing (Plan FE P5).
///
/// Two closures rather than a value, because **turning metering on is itself the cost being
/// gated**. `AVAudioPlayer.isMeteringEnabled` makes the player compute per-channel power for every
/// buffer it renders; the monitor calls `enable()` only once it has decided it is actually going to
/// sample, so a hidden screen, a backgrounded scene, Reduce Motion or a conserving power posture
/// means the player is never asked to meter in the first place.
struct PlaybackMeterSource {
    /// Switch metering on at the source. Called at most once, and only when sampling will happen.
    let enable: () -> Void
    /// Current average power in decibels (`AVAudioPlayer`'s scale: ≤ 0 dBFS, −160 for silence),
    /// or `nil` when the source has gone away.
    let sample: () -> Double?

    init(enable: @escaping () -> Void, sample: @escaping () -> Double?) {
        self.enable = enable
        self.sample = sample
    }
}

/// Whether a decorative playback animation may run its meter cadence at all (Plan FE P5).
///
/// Pure and deliberately tiny: "do not run 20 Hz metering solely for a hidden/disabled animation"
/// is a single boolean, and it should be readable in one place rather than spread across the view
/// layer as four separate early returns.
enum PlaybackActivityGate {

    /// - Parameters:
    ///   - visible: the animation that consumes the level is on screen.
    ///   - sceneActive: the scene is foreground-active (not inactive, not background).
    ///   - reduceMotion: the wearer asked for less motion — the reactive scaling is off entirely,
    ///     so there is nothing to feed and no reason to meter.
    ///   - posture: the app's power posture (docs/plans/BV-power-policy.md). Anything past
    ///     `.normal` is the app economising, and a decorative animation is the first thing to go.
    static func allowsMetering(visible: Bool,
                               sceneActive: Bool,
                               reduceMotion: Bool,
                               posture: PowerPosture) -> Bool {
        visible && sceneActive && !reduceMotion && posture.allowsDecorativeMetering
    }
}

extension PowerPosture {
    /// Whether a purely decorative signal may run a sampling cadence. Only `.normal`: the point of
    /// `conserve` is that the app stops spending on things the wearer did not ask for.
    var allowsDecorativeMetering: Bool { self == .normal }
}

/// The bounded, normalized playback-activity signal behind the speech-reactive visuals
/// (Plan FE P5) — pure, clock-injected, and the only place the rules live.
///
/// **What it is.** A value in `0…1` describing how lively playback is *right now*, sampled on one
/// cadence, from whichever source the engine that is speaking can actually offer. It drives a
/// decoration and nothing else: no announcement, no tool, no record.
///
/// **What it guards.** Three things, each of which was a real way to get this wrong:
///
///   1. **Generation.** Every input names the playback generation it belongs to, and a mismatch is
///      dropped. The engine callbacks this rides on are late by construction — an `AVAudioPlayer`
///      delegate hop or an `AVSpeechSynthesizer` `didFinish` can land after a newer utterance has
///      already taken the floor — and an older utterance animating a newer one is exactly the
///      stale-callback class of defect P4 spent its evidence on.
///   2. **Start.** The level is zero until playback actually begins. A queued, downloading or
///      about-to-be-refused utterance animates nothing.
///   3. **Bounded decay.** Finish, error, cancel and stop all end at zero, and the first three
///      within `Tuning.endDecay` rather than "eventually": a cadence that never learns it is over
///      is a cadence that runs forever.
///
/// It holds no audio, no text and no timer — only numbers and a generation. The cadence that calls
/// `tick` and the publisher that broadcasts the result live in `PlaybackActivityMonitor`.
struct PlaybackActivityCore {

    /// Every constant in one place, overridable in tests.
    struct Tuning: Equatable {
        /// Sampling period. 20 Hz is the ceiling: it is smooth enough for a wave whose own motion
        /// is ~1–5 Hz, and it is a twentieth of the work a display-link would do.
        var cadence: TimeInterval = 1.0 / 20.0
        /// dBFS treated as silence. Below this the level is 0; `0 dBFS` is 1.
        var meterFloorDB: Double = -50
        /// Smoothing time constants. Rising is quicker than falling so onsets read as onsets and
        /// gaps between words do not strobe.
        var attack: TimeInterval = 0.05
        var decay: TimeInterval = 0.15
        /// The bound this promises for silence: after this long with the meter at the floor the
        /// level is at or below `silenceResidual`.
        var silenceDecayBound: TimeInterval = 0.6
        var silenceResidual: Double = 0.02
        /// The word pulse's shape. Peak below 1 because it is an approximation and should not
        /// claim the top of the range that a real meter can reach.
        var wordPulsePeak: Double = 0.85
        var wordPulseAttack: TimeInterval = 0.05
        var wordPulseDecay: TimeInterval = 0.26
        /// How long the run-down to zero takes after playback ends. A hard ramp, not a tail: at
        /// `endDecay` the level is 0 and the cadence stops, whatever it was doing before.
        var endDecay: TimeInterval = 0.25

        static let `default` = Tuning()
    }

    let tuning: Tuning

    /// The playback generation currently being animated, or `nil` when idle. `nil` is also the
    /// answer to "is a cadence needed" — no generation, no work.
    private(set) var generation: Int?
    /// The published value: always `0…1`.
    private(set) var level: Double = 0
    /// What the current generation's level is derived from, or `nil` when idle.
    private(set) var source: PlaybackActivitySource?
    /// Whether the current level is inferred rather than measured. `false` when idle.
    var isApproximate: Bool { source?.isApproximate ?? false }
    /// Whether a cadence should be running. Exactly "there is a generation to animate".
    var needsCadence: Bool { generation != nil }

    /// Where the smoothing is heading.
    private var target: Double = 0
    private var lastTick: TimeInterval?
    /// Origin of the current word pulse, for the envelope.
    private var pulseStart: TimeInterval?
    /// Set when playback ended: the level it ended at, and when. While set, the level is a linear
    /// ramp from the first to zero over `endDecay` — bounded by construction.
    private var endedAt: TimeInterval?
    private var endLevel: Double = 0

    init(tuning: Tuning = .default) {
        self.tuning = tuning
    }

    // MARK: - Inputs

    /// Playback for `generation` has begun.
    ///
    /// - Returns: `true` when this call started a new cadence. A repeat call for a generation that
    ///   is already running returns `false` and changes nothing — **one cadence per generation** is
    ///   enforced here rather than trusted to the caller, because the caller is a delegate.
    @discardableResult
    mutating func begin(generation newGeneration: Int,
                        source newSource: PlaybackActivitySource,
                        at now: TimeInterval) -> Bool {
        if generation == newGeneration, endedAt == nil { return false }
        generation = newGeneration
        source = newSource
        level = 0
        target = 0
        lastTick = now
        pulseStart = nil
        endedAt = nil
        endLevel = 0
        return true
    }

    /// A meter reading in decibels. Ignored unless it names the live generation and playback has
    /// not ended; `nil` (the source went away) is read as silence rather than as "hold the last
    /// value", because a level that can no longer be refuted should fall, not freeze.
    mutating func observe(meterDB: Double?, generation observedGeneration: Int) {
        guard observedGeneration == generation, endedAt == nil, source == .meter else { return }
        target = meterDB.map { Self.normalized(meterDB: $0, floor: tuning.meterFloorDB) } ?? 0
    }

    /// A word boundary from the system synthesizer — the start of the approximate pulse. Ignored
    /// for any other source, any other generation, and after playback ends.
    mutating func observeWordBoundary(generation observedGeneration: Int, at now: TimeInterval) {
        guard observedGeneration == generation, endedAt == nil, source == .wordPulse else { return }
        pulseStart = now
    }

    /// Playback for `generation` finished, failed or was cancelled: run down to zero within
    /// `Tuning.endDecay` and then stop. A late call naming an older generation is dropped.
    mutating func end(generation endedGeneration: Int, at now: TimeInterval) {
        guard endedGeneration == generation, endedAt == nil else { return }
        endedAt = now
        endLevel = level
        target = 0
        pulseStart = nil
    }

    /// Stop now: zero level, no cadence, no run-down. This is the teardown path (`stopSpeaking`),
    /// where the audio is already gone and a graceful tail would be animating something that is
    /// no longer being heard.
    mutating func stopImmediately() {
        generation = nil
        source = nil
        level = 0
        target = 0
        lastTick = nil
        pulseStart = nil
        endedAt = nil
        endLevel = 0
    }

    // MARK: - The cadence

    /// Advance one cadence step.
    ///
    /// - Returns: `true` while the cadence should keep running, `false` once it has nothing left to
    ///   do (the level is zero and playback has ended, or nothing is playing at all).
    @discardableResult
    mutating func tick(at now: TimeInterval) -> Bool {
        guard generation != nil else { return false }
        let dt = max(0, now - (lastTick ?? now))
        lastTick = now

        if let endedAt {
            // Bounded run-down: a straight ramp to zero, so "within endDecay" is arithmetic
            // rather than a property of a time constant.
            let progress = tuning.endDecay > 0 ? (now - endedAt) / tuning.endDecay : 1
            level = max(0, endLevel * (1 - min(1, progress)))
            if level <= 0 {
                stopImmediately()
                return false
            }
            return true
        }

        if source == .wordPulse {
            target = pulseStart.map { Self.pulseEnvelope(elapsed: now - $0, tuning: tuning) } ?? 0
        }
        let tau = target > level ? tuning.attack : tuning.decay
        level = Self.approach(level, target: target, dt: dt, tau: tau)
        return true
    }

    // MARK: - Pure math

    /// dBFS → `0…1`, linear between the floor and 0 dB. No curve: a curve would be a claim about
    /// perceived loudness, and this is a decoration, not a meter readout.
    static func normalized(meterDB: Double, floor: Double) -> Double {
        guard floor < 0 else { return 0 }
        return min(1, max(0, (meterDB - floor) / -floor))
    }

    /// The per-word envelope: a short linear attack to the peak, then an exponential fall. Shaped
    /// like a spoken syllable, derived from nothing but the callback's timing — see
    /// `PlaybackActivitySource.wordPulse` for what that does and does not mean.
    static func pulseEnvelope(elapsed: TimeInterval, tuning: Tuning) -> Double {
        guard elapsed >= 0 else { return 0 }
        if elapsed < tuning.wordPulseAttack {
            guard tuning.wordPulseAttack > 0 else { return tuning.wordPulsePeak }
            return tuning.wordPulsePeak * (elapsed / tuning.wordPulseAttack)
        }
        guard tuning.wordPulseDecay > 0 else { return 0 }
        return tuning.wordPulsePeak * exp(-(elapsed - tuning.wordPulseAttack) / tuning.wordPulseDecay)
    }

    /// One exponential smoothing step — frame-rate independent, so a dropped tick changes the
    /// timing of the motion and not its shape.
    static func approach(_ value: Double, target: Double, dt: TimeInterval, tau: TimeInterval) -> Double {
        guard tau > 0 else { return target }
        let blended = value + (target - value) * (1 - exp(-dt / tau))
        return min(1, max(0, blended))
    }
}
