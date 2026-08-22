import Foundation

/// Plan CU P2 rider — makes one threshold pair mean the same thing on every mic.
///
/// Every number in `SpeechActivityGate` is calibrated against a signal level, and that level is not
/// comparable across routes: a phone mic at arm's length and a glasses mic at the temple are two
/// populations, which is the acoustic half of why `micRoute` is a cohort tag in the P1 timeline
/// rather than a footnote. This lands **with** the thresholds and not after them on purpose —
/// tuning a threshold against an un-normalised level and then normalising the level invalidates the
/// tuning, so the two would have to be done twice.
///
/// It normalises toward a target RMS instead of applying a table of per-route constants. A table
/// would have to be *measured*, we have no device measurements yet, and constants that look
/// measured but are not are worse than none — this way the only per-route state is an estimate the
/// signal itself supplies, kept separate per route so a route flip never inherits the other's idea
/// of loud.
struct MicInputGain {

    /// Target RMS the normaliser aims for. Well inside headroom: hops that arrive near full scale
    /// are attenuated rather than clipped, and `range` bounds how far either way it can go.
    static let targetRMS: Float = 0.05

    /// Clamp. A gain of 8 on a silent room is how a noise floor becomes "speech", so the ceiling is
    /// as much a correctness bound as a sanity one.
    static let range: ClosedRange<Float> = 0.25...8.0

    /// How fast the per-route level estimate follows the signal. Slow: it should track the wearer
    /// and the room, not each syllable — a fast estimate would flatten the very envelope the
    /// detector scores.
    static let smoothing: Float = 0.05

    private var levels: [MicRoute: Float] = [:]

    init() {}

    /// Gain to apply to a hop with the given RMS, updating the route's running level.
    ///
    /// Hops below the noise floor do **not** update the estimate and do not move the gain. Without
    /// that guard a quiet room walks the estimate toward zero, the gain walks to the ceiling, and
    /// the first thing amplified into the detector is the noise it was raised to ignore.
    mutating func gain(forHopRMS rms: Float, route: MicRoute) -> Float {
        let current = levels[route]
        guard rms >= TranscriptGuard.defaultRMSThreshold else {
            return current.map { clamped(Self.targetRMS / $0) } ?? 1.0
        }
        let updated = current.map { $0 + Self.smoothing * (rms - $0) } ?? rms
        levels[route] = updated
        return clamped(Self.targetRMS / max(updated, TranscriptGuard.defaultRMSThreshold))
    }

    /// Drop what we know about a route. Called on a format change: a level learned at 48 kHz from
    /// the phone mic describes nothing about the 8 kHz link that replaced it.
    mutating func forget(route: MicRoute) { levels[route] = nil }

    mutating func forgetAll() { levels.removeAll() }

    /// The route's learned level, for the diagnostics panel — and for tests, which should be able
    /// to assert the estimate rather than infer it from a gain.
    func level(for route: MicRoute) -> Float? { levels[route] }

    private func clamped(_ gain: Float) -> Float {
        min(max(gain, Self.range.lowerBound), Self.range.upperBound)
    }
}
