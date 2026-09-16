import Foundation
import Combine

/// The one repeating timer behind the speech-reactive visuals (Plan FE P5) — a seam, so the
/// cadence can be driven a tick at a time in a test instead of waited on.
///
/// "One cadence, not a task per word" is the requirement, and this protocol is how it is kept: the
/// monitor owns exactly one of these, starts it when playback starts and stops it when the level
/// reaches zero. A word boundary moves a number; it never schedules anything.
@MainActor
protocol PlaybackActivityCadence: AnyObject {
    var isRunning: Bool { get }
    /// Begin calling `tick` every `interval`. Starting an already-running cadence replaces it —
    /// there is never more than one.
    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void)
    func stop()
}

/// The shipping cadence: a single `Task` that sleeps and ticks. No `Timer`, so it does not depend
/// on a run-loop mode, and cancelling the task is the whole teardown.
@MainActor
final class TaskPlaybackActivityCadence: PlaybackActivityCadence {
    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        stop()
        let nanoseconds = UInt64(max(0.001, interval) * 1_000_000_000)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return }
                guard self != nil else { return }
                tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Publishes the bounded playback-activity level the voice visuals scale themselves by
/// (Plan FE P5). Thin on purpose: every rule lives in `PlaybackActivityCore`, every gate in
/// `PlaybackActivityGate`, and this class is the main-actor shell that owns the cadence, holds the
/// meter and republishes the number.
///
/// **It is decorative.** `activity` feeds an amplitude scale and a glow, and nothing else reads it.
/// It is never spoken, never announced to VoiceOver (the waveline and the ambience are both
/// `accessibilityHidden`), never logged and never recorded — a level derived from the wearer's own
/// assistant audio is not something to keep.
///
/// **Nothing runs unless something is watching.** `isVisible` defaults to `false`: a monitor that
/// no view has claimed meters nothing, which is the correct behaviour for a signal whose only
/// purpose is an animation. The view that draws the animation turns it on when it appears and off
/// when it goes away.
@MainActor
final class PlaybackActivityMonitor: ObservableObject {

    /// The level the visuals consume: `nil` when nothing is playing (or the gates say no), and
    /// `0…1` while it is. `nil` is load-bearing — it is what makes the visuals fall back to their
    /// approved state-only behaviour rather than to "speaking, but silent".
    @Published private(set) var activity: Double?

    /// Whether the live signal is inferred (word pulses) rather than measured (an audio meter).
    /// Exposed so a developer surface can say which it is; the visuals treat both the same.
    @Published private(set) var isApproximate: Bool = false

    // MARK: Gates
    //
    // Set by the view and the app, read only through `PlaybackActivityGate`.

    /// The animation is on screen. `false` until a view says otherwise — see the class note.
    private(set) var isVisible = false
    /// The scene is foreground-active.
    private(set) var isSceneActive = true
    /// The wearer asked for reduced motion: no reactive scaling at all, so nothing to meter.
    private(set) var reduceMotion = false
    /// The app's power posture. A closure so the default reads the live service without this type
    /// depending on it at construction (and so tests can pin it).
    var posture: () -> PowerPosture = { PowerPolicyService.shared.posture }

    // MARK: Internals

    private var core: PlaybackActivityCore
    private let cadence: PlaybackActivityCadence
    private let now: () -> TimeInterval
    private var meter: PlaybackMeterSource?

    /// How many cadences have been started. Tests assert on this to prove the gated cases start
    /// *none* — "we ignored the ticks" and "there were no ticks" are different claims, and only
    /// the second one saves any power.
    private(set) var cadenceStartCount = 0
    /// Whether a cadence is running right now.
    var isCadenceRunning: Bool { cadence.isRunning }

    /// Republish threshold. A wave that moves by a hundredth of an amplitude is not a frame worth
    /// invalidating a view for, and steady speech would otherwise publish 20 near-identical values
    /// a second.
    private static let publishEpsilon = 0.01

    init(tuning: PlaybackActivityCore.Tuning = .default,
         cadence: PlaybackActivityCadence? = nil,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.core = PlaybackActivityCore(tuning: tuning)
        self.cadence = cadence ?? TaskPlaybackActivityCadence()
        self.now = now
    }

    // MARK: - Gate updates

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        enforceGates()
    }

    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        enforceGates()
    }

    func setReduceMotion(_ reduced: Bool) {
        guard reduced != reduceMotion else { return }
        reduceMotion = reduced
        enforceGates()
    }

    /// Whether a cadence is permitted at this instant.
    var allowsMetering: Bool {
        PlaybackActivityGate.allowsMetering(visible: isVisible,
                                            sceneActive: isSceneActive,
                                            reduceMotion: reduceMotion,
                                            posture: posture())
    }

    /// A gate closing mid-utterance stops the cadence outright rather than letting it run down:
    /// the screen went away, so there is nothing for the tail to be seen on.
    private func enforceGates() {
        guard !allowsMetering, core.needsCadence else { return }
        stopImmediately()
    }

    // MARK: - Playback lifecycle

    /// Playback has actually begun for `generation`.
    ///
    /// - Parameter meter: the audio meter to sample, or `nil` for the system synthesizer, whose
    ///   level is the approximate word pulse. `enable()` is called **only** if this call is going
    ///   to start a cadence, so a gated-off animation never switches metering on at the source.
    /// - Returns: `true` when a cadence was started.
    @discardableResult
    func playbackDidStart(generation: Int, meter source: PlaybackMeterSource?) -> Bool {
        guard allowsMetering else { return false }
        guard core.begin(generation: generation,
                         source: source == nil ? .wordPulse : .meter,
                         at: now()) else { return false }
        meter = source
        source?.enable()
        isApproximate = core.isApproximate
        publish(core.level)
        cadenceStartCount += 1
        cadence.start(interval: core.tuning.cadence) { [weak self] in self?.tick() }
        return true
    }

    /// The system synthesizer is about to speak a word. Moves the pulse origin; schedules nothing.
    func wordBoundary(generation: Int) {
        core.observeWordBoundary(generation: generation, at: now())
    }

    /// Playback for `generation` finished, failed or was cancelled: run down to zero within the
    /// core's bound, then stop. A call naming a generation that is no longer live is dropped.
    func playbackDidEnd(generation: Int) {
        core.end(generation: generation, at: now())
    }

    /// Teardown: zero now, no cadence, no tail.
    func stopImmediately() {
        core.stopImmediately()
        meter = nil
        cadence.stop()
        isApproximate = false
        publish(nil)
    }

    // MARK: - The tick

    private func tick() {
        if let meter {
            core.observe(meterDB: meter.sample(), generation: core.generation ?? -1)
        }
        let keepGoing = core.tick(at: now())
        if keepGoing {
            publish(core.level)
        } else {
            meter = nil
            cadence.stop()
            isApproximate = false
            publish(nil)
        }
    }

    private func publish(_ value: Double?) {
        switch (activity, value) {
        case (nil, nil):
            return
        case let (current?, next?) where abs(current - next) < Self.publishEpsilon:
            return
        default:
            activity = value
        }
    }
}
