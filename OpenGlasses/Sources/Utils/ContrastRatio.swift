import Foundation

/// An 8-bit sRGB triple as plain numbers — no UIKit, no SwiftUI.
///
/// The design palette needs to be *measurable* off-device: system semantic
/// colours can't be inspected headlessly, so every OGDesign token carries its
/// own light/dark values and the test suite reads them through this type.
struct SRGBColor: Equatable {
    /// Channels, 0…1.
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    var hex: UInt32 {
        func channel(_ value: Double) -> UInt32 {
            UInt32((value.clamped01 * 255).rounded())
        }
        return (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }

    /// This colour laid over `background` at `alpha` (source-over), which is what
    /// `Color.opacity(_:)` actually renders as on an opaque surface.
    func composited(alpha: Double, over background: SRGBColor) -> SRGBColor {
        let a = alpha.clamped01
        return SRGBColor(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    /// Straight-line blend toward `other`; `amount` 0 is self, 1 is `other`.
    func mixed(with other: SRGBColor, amount: Double) -> SRGBColor {
        let t = amount.clamped01
        return SRGBColor(
            red: red * (1 - t) + other.red * t,
            green: green * (1 - t) + other.green * t,
            blue: blue * (1 - t) + other.blue * t
        )
    }

    static let black = SRGBColor(red: 0, green: 0, blue: 0)
    static let white = SRGBColor(red: 1, green: 1, blue: 1)
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

/// WCAG 2.2 contrast maths.
///
/// Kept pure so the palette's contrast is a property the suite asserts: a token
/// edit that dips below AA fails the build instead of shipping.
enum ContrastRatio {

    /// WCAG AA minimums, by the size of the text the pair is used for.
    enum TextSize {
        /// Anything below 18pt regular / 14pt bold.
        case normal
        /// 18pt regular / 14pt bold and above.
        case large

        var minimumRatio: Double {
            switch self {
            case .normal: return 4.5
            case .large: return 3.0
            }
        }
    }

    /// sRGB channel → linear light.
    static func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(of color: SRGBColor) -> Double {
        0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }

    /// `(lighter + 0.05) / (darker + 0.05)` — 1…21.
    static func ratio(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        let la = relativeLuminance(of: a)
        let lb = relativeLuminance(of: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func meetsAA(_ ratio: Double, size: TextSize) -> Bool {
        // Ratios are reported to 2dp elsewhere; allow the same slack here so a
        // pair that measures exactly at threshold isn't failed by float dust.
        ratio + 1e-9 >= size.minimumRatio
    }

    /// The nearest version of `color` that clears `minimum` against *every*
    /// background it has to sit on, found by blending straight toward black or
    /// white — so the hue family survives the correction. Returns `color`
    /// untouched when it already clears.
    ///
    /// This is what lets a user-chosen accent be used as small text on its own
    /// faint tint: the raw accent is picked to read on the plain surface, and a
    /// wash of it behind itself eats the margin (the White preset vanishes
    /// outright). Deterministic, so the palette test can assert the outcome.
    static func readable(
        _ color: SRGBColor,
        on backgrounds: [SRGBColor],
        minimum: Double = TextSize.normal.minimumRatio,
        steps: Int = 50
    ) -> SRGBColor {
        guard !backgrounds.isEmpty, steps > 0 else { return color }

        func worstRatio(_ candidate: SRGBColor) -> Double {
            backgrounds.map { ratio(candidate, $0) }.min() ?? 0
        }

        if worstRatio(color) >= minimum { return color }

        // Whichever pole the backgrounds are furthest from is the direction that
        // buys contrast; blending the other way would only make it worse.
        let target = worstRatio(.black) >= worstRatio(.white) ? SRGBColor.black : .white

        for step in 1...steps {
            let candidate = color.mixed(with: target, amount: Double(step) / Double(steps))
            if worstRatio(candidate) >= minimum { return candidate }
        }
        // Unreachable for real palettes (black or white always clears against a
        // single surface), but a pure function shouldn't trap.
        return target
    }
}
