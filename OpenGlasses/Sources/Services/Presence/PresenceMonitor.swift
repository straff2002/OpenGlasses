import Foundation
import Combine

/// Tunable windows for presence detection (Plan W). Defaults are the plan's recommendation; the
/// idle threshold is intended to be user-settable later. Kept as a value type so tests pin exact
/// boundaries without touching globals.
struct PresenceThresholds: Equatable {
    /// A spoken/looked interaction within this window (or live voice) ⇒ `.active`.
    var activeWindow: TimeInterval = 30
    /// Past this with no interaction ⇒ `.idle` (the autonomy-downgrade point).
    var idleThreshold: TimeInterval = 300   // 5 minutes
    /// Debounce dwell: a *drop* in engagement must persist this long before it commits, so a single
    /// missed tick doesn't flap the mode.
    var debounceDwell: TimeInterval = 12

    static let `default` = PresenceThresholds()
}

/// A snapshot of the raw presence signals at one instant. Pure input to `PresenceEvaluator` — no
/// clock or device access inside, so fusion is deterministic and testable.
struct PresenceSignals: Equatable {
    /// When the user last engaged (spoke a command, tapped, etc.).
    var lastInteraction: Date
    /// Live voice activity right now (wake-word / transcription pipeline mid-utterance).
    var voiceActive: Bool
    /// Are the glasses connected (DAT session up)?
    var connected: Bool
    /// Is the app in the foreground? (MLX inference is foreground-only — backgrounded ⇒ paused is a
    /// correctness constraint, not just a battery optimisation. See the Local Model Background note.)
    var foreground: Bool
    /// Active physical motion right now — walking/running/cycling/driving (Plan W v2, CoreMotion).
    /// A moving-but-quiet user is *engaged*, so motion floors the quiet bands at `.present` and
    /// prevents a false `.idle` during a walk or workout. Defaults `false` (no motion signal wired).
    var motionActive: Bool = false
}

/// Pure fusion of `PresenceSignals` → `(engagement, mode)` given the thresholds (Plan W). The single
/// place the signal-combination rules live, so they're unit-tested in isolation from sampling.
enum PresenceEvaluator {

    /// Fuse a snapshot into a raw (pre-debounce) mode. `now` is injected.
    static func mode(for signals: PresenceSignals, now: Date, thresholds: PresenceThresholds) -> EngagementMode {
        // Disconnected or backgrounded trumps everything — nothing should run.
        guard signals.connected, signals.foreground else { return .away }

        // Live voice or a very recent interaction ⇒ fully engaged.
        let age = now.timeIntervalSince(signals.lastInteraction)
        if signals.voiceActive || age < thresholds.activeWindow { return .active }

        // Active motion (walking/workout/driving) means the user is engaged even when silent, so
        // floor the quiet bands at `.present` — never drop a moving user to `.idle` (Plan W v2).
        if signals.motionActive { return .present }

        // Connected & foreground, quiet, stationary: present until the idle threshold, then idle.
        return age < thresholds.idleThreshold ? .present : .idle
    }

    /// The fused mode plus its canonical engagement factor.
    static func evaluate(_ signals: PresenceSignals, now: Date, thresholds: PresenceThresholds) -> (engagement: Double, mode: EngagementMode) {
        let m = mode(for: signals, now: now, thresholds: thresholds)
        return (m.engagement, m)
    }
}

/// Anti-flap filter for mode transitions (Plan W). A *rise* in engagement commits immediately — when
/// the user re-engages, loops should resume full cadence promptly. A *drop* must persist for
/// `dwell` before it commits, so one missed voice tick or a brief disconnection blip doesn't
/// repeatedly downgrade autonomy. Pure and deterministic given the `(raw, now)` sequence.
struct ModeDebouncer {
    let dwell: TimeInterval
    private(set) var committed: EngagementMode
    private var pending: (mode: EngagementMode, since: Date)?

    init(dwell: TimeInterval, initial: EngagementMode = .active) {
        self.dwell = dwell
        self.committed = initial
    }

    /// Feed the latest raw mode; returns the committed (debounced) mode.
    mutating func step(raw: EngagementMode, now: Date) -> EngagementMode {
        // Same as committed, or more engaged ⇒ commit now (instant on re-engagement).
        if raw.rank >= committed.rank {
            committed = raw
            pending = nil
            return committed
        }
        // A drop: start (or continue) the dwell timer; commit only once it elapses.
        if pending?.mode != raw {
            pending = (raw, now)
        }
        if let p = pending, now.timeIntervalSince(p.since) >= dwell {
            committed = raw
            pending = nil
        }
        return committed
    }
}

/// Fuses cheap on-device signals into a presence `mode`/`engagement` and the resulting
/// `ThrottleDecision` (Plan W). The signal *sources* are injected closures (default to a neutral
/// "fully present" so the monitor is constructible without the app), keeping `update(now:)` a
/// deterministic, testable step. Wiring the real sources (transcription pipeline, DAT session,
/// scene phase, CoreMotion) and applying `decision` to the live loops + Plan S autonomy ceiling is
/// the deferred integration — this type is the tested core those consumers read.
@MainActor
final class PresenceMonitor: ObservableObject {
    @Published private(set) var engagement: Double
    @Published private(set) var mode: EngagementMode
    @Published private(set) var decision: ThrottleDecision

    /// Injected signal providers. Defaults describe an idealised present-and-connected device so the
    /// monitor has sane behaviour before the app wires real sources.
    var lastInteraction: () -> Date
    var voiceActive: () -> Bool
    var connected: () -> Bool
    var foreground: () -> Bool
    /// Active physical motion right now (Plan W v2). Defaults `false` so the monitor behaves exactly
    /// as before until AppState wires a CoreMotion provider.
    var motionActive: () -> Bool = { false }

    /// Fired when the user re-engages: the committed mode rises to `.active` from a disengaged mode
    /// (`.idle`/`.away`). AppState uses it to surface any held recommendations (TTS + HUD).
    var onReEngage: (() -> Void)?

    let thresholds: PresenceThresholds
    private var debouncer: ModeDebouncer

    init(thresholds: PresenceThresholds = .default,
         lastInteraction: @escaping () -> Date = { Date() },
         voiceActive: @escaping () -> Bool = { false },
         connected: @escaping () -> Bool = { true },
         foreground: @escaping () -> Bool = { true }) {
        self.thresholds = thresholds
        self.lastInteraction = lastInteraction
        self.voiceActive = voiceActive
        self.connected = connected
        self.foreground = foreground
        self.debouncer = ModeDebouncer(dwell: thresholds.debounceDwell, initial: .active)
        self.mode = .active
        self.engagement = EngagementMode.active.engagement
        self.decision = ThrottlePolicy.decide(mode: .active)
    }

    /// Sample the current signals and recompute mode/engagement/decision. `now` is injected so the
    /// monitor (and its debounce) are fully deterministic under test; the live app passes `Date()`.
    func update(now: Date = Date()) {
        let signals = PresenceSignals(
            lastInteraction: lastInteraction(),
            voiceActive: voiceActive(),
            connected: connected(),
            foreground: foreground(),
            motionActive: motionActive()
        )
        let raw = PresenceEvaluator.mode(for: signals, now: now, thresholds: thresholds)
        let previous = mode
        let committed = debouncer.step(raw: raw, now: now)
        mode = committed
        engagement = committed.engagement
        decision = ThrottlePolicy.decide(mode: committed)

        // Re-engagement: rose to active from a disengaged mode → let AppState surface held recs.
        if committed == .active, previous == .idle || previous == .away {
            onReEngage?()
        }
    }

    /// The throttle decision for a loop with a minimum-mode floor (e.g. hazard navigation passes
    /// `.present` so it never throttles below that even when the user looks idle).
    func decision(minMode: EngagementMode) -> ThrottleDecision {
        ThrottlePolicy.decide(mode: mode, minMode: minMode)
    }
}
