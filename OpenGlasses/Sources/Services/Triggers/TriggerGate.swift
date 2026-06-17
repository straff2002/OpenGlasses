import Foundation

/// Decides whether a raw alternative-trigger event should actually fire the assistant (Additional
/// Capabilities #5). Detectors misfire — a low cough, an incidental bump — so every event passes
/// through this gate, which applies:
///
/// - a **confidence threshold** (the acoustic classifier reports a probability; below it, ignore),
/// - a **debounce window** (ignore repeats within N seconds of the last fire — one shake shouldn't
///   fire twice), and
/// - a **suppression** flag (don't fire while a conversation / critical card is held, mirroring the
///   wake-word guard).
///
/// Pure and deterministic — the clock is passed in — so the whole gating policy is unit-testable with
/// no timers, audio, or motion hardware.
struct TriggerGate: Equatable {

    /// Minimum seconds between fires. A second event inside this window is dropped.
    var debounceInterval: TimeInterval

    /// Minimum confidence [0, 1] for an event to count (1.0 for deterministic triggers like shake).
    var minimumConfidence: Double

    /// Timestamp of the last accepted fire, in the same clock as `shouldFire(at:)`.
    private(set) var lastFiredAt: TimeInterval?

    init(debounceInterval: TimeInterval = 2.0, minimumConfidence: Double = 0.6) {
        self.debounceInterval = debounceInterval
        self.minimumConfidence = minimumConfidence
    }

    /// Whether an event at time `now` should fire. Records the fire time on success so the next event
    /// is debounced against it.
    mutating func shouldFire(at now: TimeInterval, confidence: Double = 1.0, suppressed: Bool) -> Bool {
        guard !suppressed else { return false }
        guard confidence >= minimumConfidence else { return false }
        if let last = lastFiredAt, now - last < debounceInterval { return false }
        lastFiredAt = now
        return true
    }

    /// Clear the debounce history (e.g. when re-enabling the feature).
    mutating func reset() {
        lastFiredAt = nil
    }
}
