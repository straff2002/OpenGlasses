import CoreGraphics
import Foundation

/// Encode-bitrate policy (pure).
///
/// The recorder and the RTMP broadcaster both used to hardcode 1.5 Mbps no matter what they
/// were actually encoding. The glasses stream runs up to 720×1280 (`StreamingResolution.high`),
/// where 1.5 Mbps is roughly a fifth of a sane H.264 target and the file looks like it; at the
/// `.low` tier (360×640) the same fixed number is simply spent for nothing. Bitrate belongs to
/// the picture, not to the call site — it is derived here from encoded pixel count and frame
/// rate, and every consumer feeds the derived value (including
/// `VideoRecordingService.storageVerdict`, whose minutes-remaining estimate is only honest if
/// it is given the bitrate that will actually be written).
enum VideoBitratePolicy {

    /// A quality target and the bounds it is clamped into.
    struct Profile: Equatable {
        /// Bits spent per pixel per frame, quoted at `referenceFrameRate`.
        let bitsPerPixelPerFrame: Double
        /// Floor — a small frame still needs enough bits to not fall apart.
        let minimum: Int
        /// Ceiling — the point past which more bits buy nothing this pipeline can use.
        let maximum: Int

        /// Disk recording: bounded by storage, which the caller already guards against. 0.29
        /// bits/pixel/frame puts 720×1280@30 at ~8 Mbps — the usual H.264 target for that size
        /// — and 360×640@30 at ~2 Mbps.
        static let disk = Profile(bitsPerPixelPerFrame: 0.29,
                                  minimum: 1_000_000, maximum: 12_000_000)

        /// RTMP: bounded by the phone's *uplink*, not by disk, and a live encoder cannot spend
        /// its way through a hard scene the way a file encoder can — overshoot the link and the
        /// ingest buffers, then drops. Same shape as `disk`, lower target and a much lower
        /// ceiling: 720×1280@15 lands at ~3.1 Mbps, inside the 720p band the common ingests
        /// recommend.
        static let rtmp = Profile(bitsPerPixelPerFrame: 0.16,
                                  minimum: 800_000, maximum: 4_500_000)
    }

    /// Frame rate the `bitsPerPixelPerFrame` targets are quoted at.
    static let referenceFrameRate: Double = 30

    /// Average bitrate (bits/sec) for an encode of `width`×`height` at `frameRate`.
    ///
    /// Linear in pixel count; sub-linear (square root) in frame rate — halving the frame rate
    /// does not halve the bits needed, because each surviving frame carries twice the motion
    /// and predicts worse from its neighbour. The result is rounded to the nearest 100 kbps
    /// and clamped into the profile.
    ///
    /// - Parameter override: an explicit user-set bitrate, which short-circuits the whole
    ///   calculation (and the clamp — an override is a deliberate choice, not a hint).
    ///   Non-positive values are treated as unset.
    static func bitrate(width: Int, height: Int, frameRate: Double,
                        profile: Profile, override: Int? = nil) -> Int {
        if let override, override > 0 { return override }
        let pixels = Double(max(width, 0)) * Double(max(height, 0))
        guard pixels > 0, frameRate.isFinite else { return profile.minimum }
        let motionScale = (max(frameRate, 1) / referenceFrameRate).squareRoot()
        let raw = pixels * profile.bitsPerPixelPerFrame * referenceFrameRate * motionScale
        return clamp(roundedToHundredKilobits(raw), to: profile)
    }

    /// Convenience for callers holding a `CGSize` (the recorder's encoded output size).
    static func bitrate(for size: CGSize, frameRate: Double,
                        profile: Profile, override: Int? = nil) -> Int {
        bitrate(width: Int(size.width), height: Int(size.height),
                frameRate: frameRate, profile: profile, override: override)
    }

    private static func roundedToHundredKilobits(_ bits: Double) -> Int {
        let step = 100_000.0
        // Guard the Int conversion: a nonsense frame size must not trap.
        guard bits.isFinite, bits < Double(Int.max) else { return Int.max }
        return Int((bits / step).rounded()) * Int(step)
    }

    private static func clamp(_ value: Int, to profile: Profile) -> Int {
        min(max(value, profile.minimum), profile.maximum)
    }
}
