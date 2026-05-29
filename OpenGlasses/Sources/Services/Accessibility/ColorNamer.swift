import Foundation
import UIKit

/// Maps an RGB color to a human color name (accessibility — colorblind / low-vision support).
/// Pure and deterministic so it's unit-testable; uses HSV for robust hue/saturation/brightness naming.
enum ColorNamer {

    /// Human-readable name for a 0–1 RGB color, e.g. "dark red", "light blue", "gray".
    static func name(r: Double, g: Double, b: Double) -> String {
        let (h, s, v) = rgbToHSV(r: r, g: g, b: b)

        // Achromatic: low saturation → grayscale ramp.
        if s < 0.12 {
            switch v {
            case ..<0.10: return "black"
            case ..<0.30: return "dark gray"
            case ..<0.70: return "gray"
            case ..<0.92: return "light gray"
            default: return "white"
            }
        }

        let hue = hueName(h)
        // Brown is a special low-value/low-sat orange.
        if (h >= 20 && h < 45) && v < 0.6 && s > 0.3 { return v < 0.4 ? "dark brown" : "brown" }

        let lightness: String
        switch v {
        case ..<0.35: lightness = "dark "
        case ..<0.80: lightness = ""
        default: lightness = s < 0.45 ? "light " : ""
        }
        return "\(lightness)\(hue)"
    }

    /// Name for a UIColor (averages to its RGBA components).
    static func name(of color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return name(r: Double(r), g: Double(g), b: Double(b))
    }

    // MARK: - Hue buckets

    private static func hueName(_ h: Double) -> String {
        switch h {
        case ..<15, 345...360: return "red"
        case ..<45: return "orange"
        case ..<70: return "yellow"
        case ..<170: return "green"
        case ..<200: return "cyan"
        case ..<255: return "blue"
        case ..<290: return "purple"
        case ..<345: return "pink"
        default: return "red"
        }
    }

    /// RGB (0–1) → HSV with hue in degrees (0–360), s and v in 0–1.
    static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxC == g { h = 60 * (((b - r) / delta) + 2) }
            else { h = 60 * (((r - g) / delta) + 4) }
        }
        if h < 0 { h += 360 }
        let s = maxC == 0 ? 0 : delta / maxC
        return (h, s, maxC)
    }
}
