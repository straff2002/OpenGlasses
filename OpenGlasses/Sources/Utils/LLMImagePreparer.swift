import UIKit

/// How hard to shrink an outgoing image before it is sent to a vision model.
///
/// Raw values are the stored `UserDefaults` strings and must not change — `original` is stored as
/// `"off"` because that is what shipped. An enum rather than a bare string so a typo is a compile
/// error and the switches below cannot silently fall through to a default.
enum LLMImagePreset: String, CaseIterable, Identifiable {
    /// Full detail, bounded only by the provider's hard limit. The default.
    case full
    case balanced
    case compact
    case custom
    /// Send what the camera produced, subject only to the provider's hard limit.
    case original = "off"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full:     return "Full Quality"
        case .balanced: return "Balanced"
        case .compact:  return "Compact"
        case .custom:   return "Custom"
        case .original: return "Original"
        }
    }

    var explanation: String {
        switch self {
        case .full:
            return "Best detail for reading labels and instruments. Uses more image tokens."
        case .balanced:
            return "Good detail with smaller payloads — a practical default for most vision questions."
        case .compact:
            return "Smaller images for quick scene descriptions when fine print is less important."
        case .custom:
            return "Tune the resize and compression limits yourself."
        case .original:
            return "Send camera photos as captured. Still capped at the provider's hard limit, which very large iPhone captures would otherwise exceed."
        }
    }
}

/// Bounds an outgoing image so it stays within cloud vision-model limits before it is
/// base64-encoded into a request.
///
/// Anthropic's Messages API rejects an inline image larger than **5 MB** with a 400
/// (`image exceeds 5 MB maximum`) and downsamples anything over the model's long-edge
/// ceiling anyway. Ray-Ban glasses frames arrive small (the DAT stream is already downscaled), so
/// this never bites on the glasses path — but the iPhone-camera fallback
/// (`PhoneCameraSource`) and the photo tools capture at full sensor resolution, where a
/// 12 MP JPEG can clear 5 MB and fail the request on *exactly* the no-glasses path we rely
/// on for hardware-free development. This shrinks such images first; already-small images
/// pass through untouched, so the common glasses path pays nothing.
///
/// A user-selected `LLMImagePreset` can shrink images *further* than this — small-context
/// providers (Groq's free tier and friends) bill and cap by tokens, and image tokens scale with
/// pixels. What a preset cannot do is shrink them *less* than the API allows: `apiCeiling` is a
/// property of the endpoint, not a preference, which is why `.original` is still bounded by it.
enum LLMImagePreparer {
    /// Longest edge (in pixels) we allow before downscaling. Current Claude models
    /// (Sonnet 5 / Opus 4.7+, incl. our default) support high-resolution vision up to
    /// 2576 px on the long edge; older models just downscale server-side, so this is safe
    /// across providers. Costs more image tokens than the old 1568 ceiling, but history
    /// pruning keeps only the latest image so the spend is bounded — and the extra fidelity
    /// is exactly what instrument_reading / text-in-scene captures need.
    static let maxLongEdge: CGFloat = 2576
    /// Byte ceiling for the encoded JPEG, kept comfortably under Anthropic's 5 MB hard limit.
    static let maxBytes = 4_500_000
    /// Frames below this long edge carry no usable content (the 1×1 placeholder failure mode).
    static let minLongEdge = 32

    /// One preset's resolved numbers.
    struct Limits: Equatable {
        let maxLongEdge: CGFloat
        let maxBytes: Int
        let qualitySteps: [CGFloat]

        /// The provider's hard limit and nothing more — what `.original` is held to, and what
        /// every preset shipped before presets existed.
        static let apiCeiling = Limits(
            maxLongEdge: LLMImagePreparer.maxLongEdge,
            maxBytes: LLMImagePreparer.maxBytes,
            qualitySteps: [0.8, 0.65, 0.5, 0.35, 0.25, 0.2]
        )
    }

    /// Limits for the active preset. `.original` reports the API ceiling, because that is what it
    /// is actually held to — a UI showing "unlimited" here would be lying.
    static var limits: Limits { limits(for: Config.llmImagePreset) }

    static func limits(for preset: LLMImagePreset) -> Limits {
        switch preset {
        case .original:
            return .apiCeiling
        case .full:
            return .apiCeiling
        case .balanced:
            return Limits(maxLongEdge: 1568, maxBytes: 1_500_000,
                          qualitySteps: [0.75, 0.6, 0.5, 0.4, 0.3, 0.2])
        case .compact:
            return Limits(maxLongEdge: 1024, maxBytes: 800_000,
                          qualitySteps: [0.65, 0.5, 0.4, 0.3, 0.25, 0.2])
        case .custom:
            return Limits(maxLongEdge: min(CGFloat(Config.llmImageCustomMaxLongEdge), maxLongEdge),
                          maxBytes: min(Config.llmImageCustomMaxBytes, maxBytes),
                          qualitySteps: qualityLadder(from: Config.llmImageCustomJPEGQuality))
        }
    }

    /// True for undecodable or absurdly small images (long edge < `minLongEdge`). Such frames
    /// should be dropped before they are base64'd into a conversation and poison context —
    /// a degenerate placeholder frame reads as "the camera saw nothing" to the model.
    static func isDegenerate(_ data: Data) -> Bool {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return true }
        return max(cg.width, cg.height) < minLongEdge
    }

    /// Returns JPEG `Data` within the active preset's limits where possible. Already-bounded
    /// input is returned unchanged (no re-encode). Undecodable input is returned as-is —
    /// there is nothing we can do, and failing open beats dropping the image.
    static func prepared(_ data: Data) -> Data {
        prepared(data, limits: limits)
    }

    /// Testable core: the same work against explicit limits.
    static func prepared(_ data: Data, limits: Limits) -> Data {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return data }
        let pxLongEdge = CGFloat(max(cg.width, cg.height))

        // Fast path: small enough in both dimensions and bytes — leave it exactly as-is.
        if data.count <= limits.maxBytes && pxLongEdge <= limits.maxLongEdge { return data }

        let resized = pxLongEdge > limits.maxLongEdge
            ? downscale(cg, toLongEdge: limits.maxLongEdge)
            : image

        // Step the JPEG quality down until the payload fits under the byte cap.
        for quality in limits.qualitySteps {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= limits.maxBytes {
                return jpeg
            }
        }
        // Last resort: hardest compression even if still over (better than a guaranteed 400).
        return resized.jpegData(compressionQuality: 0.2) ?? data
    }

    /// Quality ladder for the custom preset: start where the user put the slider and step down in
    /// 0.15 increments, always ending at the floor the fixed presets share.
    static func qualityLadder(from initial: CGFloat, floor: CGFloat = 0.2, step: CGFloat = 0.15) -> [CGFloat] {
        var steps: [CGFloat] = []
        var quality = min(1.0, max(floor, initial))
        while quality > floor {
            steps.append(quality)
            quality -= step
        }
        steps.append(floor)
        return steps
    }

    private static func downscale(_ cg: CGImage, toLongEdge longEdge: CGFloat) -> UIImage {
        let pxLongEdge = CGFloat(max(cg.width, cg.height))
        let scale = longEdge / pxLongEdge
        let target = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // `target` is already in pixels; don't let Retina multiply it back up
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let source = UIImage(cgImage: cg)
        return renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
