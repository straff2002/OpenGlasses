import UIKit
import CoreGraphics

/// Mean luma over a decoded still, the darkness half of the pair `ImageSharpness` started.
///
/// The two exist for the same reason and are used the same way: to tell a wearer *which* thing to
/// change when a reading capture comes back unusable. A blurry frame and a dark frame both produce
/// no text, and "I couldn't read it" is the same unhelpful sentence for both; "hold still" and
/// "find more light" are different, actionable, and only distinguishable by measuring.
///
/// Deliberately not a gate. Vision reads some very dark labels and fails on some bright ones, so
/// this never decides whether to *try* — only what to say once trying has already failed.
enum ImageBrightness {

    /// Below this mean luma (0–1) a frame reads as too dark to have been worth reading.
    ///
    /// Derived rather than guessed: a correctly exposed indoor still sits around 0.35–0.6, and
    /// Vision's own recognition falls away well before a frame looks black to a person. 0.18 is
    /// roughly "a stop and a half under a dim indoor scene" — low enough that an ordinary
    /// badly-lit-but-readable label is never blamed on the light, which is the failure that
    /// matters here: telling a blind wearer to find a lamp when the real problem was the angle
    /// sends them across a room for nothing.
    static let darkThreshold: Double = 0.18

    /// True only when the image decodes AND scores below the threshold. Undecodable input answers
    /// false — the same rule `ImageSharpness` follows, for the same reason: never claim a cause
    /// we did not measure.
    static func isDark(_ data: Data) -> Bool {
        guard let luma = meanLuma(data) else { return false }
        return luma < darkThreshold
    }

    /// Mean luma (0–1) of a ~64px grayscale copy, or nil when the image can't be decoded.
    ///
    /// 64px rather than the sharpness pass's 256: an average needs far fewer samples than a
    /// Laplacian does, and this runs on the same failure path.
    static func meanLuma(_ data: Data) -> Double? {
        guard let cg = UIImage(data: data)?.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        return meanLuma(cg)
    }

    static func meanLuma(_ cg: CGImage) -> Double? {
        guard cg.width > 0, cg.height > 0 else { return nil }
        let targetW = 64
        let scale = Double(targetW) / Double(cg.width)
        let w = max(Int(Double(cg.width) * scale), 1)
        let h = max(Int(Double(cg.height) * scale), 1)

        var buffer = [UInt8](repeating: 0, count: w * h)
        let rendered: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }
        let total = buffer.reduce(0.0) { $0 + Double($1) }
        return total / Double(buffer.count) / 255.0
    }
}
