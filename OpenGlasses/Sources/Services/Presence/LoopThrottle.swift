import Foundation

/// Per-loop tick gate that stretches a continuous loop's *work* by the presence multiplier without
/// rescheduling the loop's timer (Plan W). The loop keeps waking at its base cadence — a cheap
/// wakeup — but only performs its expensive work (frame capture + LLM call, calendar query, …) once
/// `base × multiplier` has elapsed, and never while paused.
///
/// Pure given `(now, base, decision)`, so a loop's throttle behaviour is unit-testable without
/// timers or a running app. A small `tolerance` absorbs timer jitter so full-cadence (`multiplier
/// == 1.0`) work isn't skipped when a tick fires a hair early.
struct LoopThrottle {
    /// Slack subtracted from the target interval to absorb `Timer` jitter (ticks fire slightly late
    /// or early). Keeps `active` cadence (multiplier 1.0) running every base tick.
    var tolerance: TimeInterval = 0.25

    private var lastRun: Date?

    /// Whether this tick should run the loop's work, recording the run time when it returns `true`.
    /// The first tick after a `reset()` (or construction) always runs; a `paused` decision never
    /// runs.
    mutating func shouldRun(now: Date, base: TimeInterval, decision: ThrottleDecision) -> Bool {
        if decision.isPaused { return false }
        guard let last = lastRun else {
            lastRun = now
            return true
        }
        let target = decision.interval(base: base)
        guard now.timeIntervalSince(last) >= target - tolerance else { return false }
        lastRun = now
        return true
    }

    /// Forget the last-run time so the next `shouldRun` fires immediately — call on loop (re)start.
    mutating func reset() { lastRun = nil }
}
