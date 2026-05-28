import Foundation

/// 1€ filter: an adaptive low-pass filter that reduces jitter on a noisy signal while staying
/// responsive to fast changes. Cutoff frequency rises with signal velocity, so a stable signal is
/// smoothed heavily and a fast-moving one tracks closely.
///
/// Reference: Casiez, Roussel, Vogel — "1€ Filter" (CHI 2012). Adapted from SkyRadar.
/// Use for sensor streams that are both noisy and occasionally fast (compass/heading smoothing,
/// device orientation for AR overlays).
struct OneEuroFilter {
    /// Minimum cutoff frequency (Hz). Lower = more smoothing of a stable signal.
    var minCutoff: Double
    /// Speed coefficient. Higher = less lag during fast motion (cutoff rises faster with velocity).
    var beta: Double
    /// Cutoff for the derivative low-pass (Hz).
    var dCutoff: Double

    private var xPrev: Double?
    private var dxPrev: Double = 0
    private var tPrev: TimeInterval?

    init(minCutoff: Double = 0.3, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    /// Filter a scalar sample observed at time `t` (seconds). The first sample is returned as-is.
    mutating func filter(_ x: Double, t: TimeInterval) -> Double {
        guard let xPrev, let tPrev else {
            self.xPrev = x
            self.tPrev = t
            self.dxPrev = 0
            return x
        }
        let dt = t - tPrev
        guard dt > 0 else { return xPrev } // out-of-order / duplicate timestamp

        let dx = (x - xPrev) / dt
        let edx = Self.lowPass(dx, prev: dxPrev, alpha: Self.alpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(edx)
        let filtered = Self.lowPass(x, prev: xPrev, alpha: Self.alpha(cutoff: cutoff, dt: dt))

        self.xPrev = filtered
        self.dxPrev = edx
        self.tPrev = t
        return filtered
    }

    /// Filter an angle in degrees (0–360), handling the 359°→1° wrap correctly by filtering the
    /// unwrapped delta relative to the previous output, then re-normalizing to 0–360.
    mutating func filterAngle(_ x: Double, t: TimeInterval) -> Double {
        guard let prev = xPrev else {
            return filter(x, t: t)
        }
        // Shortest signed delta from prev to x, in [-180, 180].
        let delta = ((x - prev).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
        let unwrapped = prev + delta
        let filtered = filter(unwrapped, t: t)
        return ((filtered.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Clear state so the next sample is treated as the first.
    mutating func reset() {
        xPrev = nil
        dxPrev = 0
        tPrev = nil
    }

    // MARK: - Math

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private static func lowPass(_ x: Double, prev: Double, alpha: Double) -> Double {
        alpha * x + (1 - alpha) * prev
    }
}
