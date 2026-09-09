import UIKit
import CoreGraphics

/// Measures the two frame properties the uncertainty policy can actually check for itself —
/// sharpness and brightness — from the JPEG that was sent for assessment (W08.2).
///
/// One grayscale render produces both, on the same ~256px downscale the low-vision reading gate
/// already uses, so an assessment costs one extra cheap pass and the word "blurry" means the same
/// thing in both places. Undecodable input yields `nil` for both: the policy treats an unmeasured
/// frame as neither good nor bad, rather than inventing a verdict from a failed decode.
enum ImageQualityProbe {

    /// Sharpness (Laplacian variance) and mean luminance (0–255), or nils when the image cannot be
    /// decoded or rendered.
    static func indicators(for data: Data) -> InputQualityIndicators {
        guard let measured = measure(data) else { return InputQualityIndicators() }
        return InputQualityIndicators(sharpness: measured.sharpness, meanLuminance: measured.luminance)
    }

    static func measure(_ data: Data) -> (sharpness: Double, luminance: Double)? {
        guard let cg = UIImage(data: data)?.cgImage, cg.width > 2, cg.height > 2 else { return nil }
        let targetW = 256
        let scale = Double(targetW) / Double(cg.width)
        let w = max(Int(Double(cg.width) * scale), 3)
        let h = max(Int(Double(cg.height) * scale), 3)

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

        var lapSum = 0.0, lapSumSq = 0.0, lapN = 0.0
        var lumSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let c = Double(buffer[y * w + x])
                lumSum += c
                guard y > 0, y < h - 1, x > 0, x < w - 1 else { continue }
                let lap = 4 * c
                    - Double(buffer[(y - 1) * w + x]) - Double(buffer[(y + 1) * w + x])
                    - Double(buffer[y * w + x - 1]) - Double(buffer[y * w + x + 1])
                lapSum += lap
                lapSumSq += lap * lap
                lapN += 1
            }
        }
        guard lapN > 0 else { return nil }
        let mean = lapSum / lapN
        return (sharpness: lapSumSq / lapN - mean * mean, luminance: lumSum / Double(w * h))
    }
}
