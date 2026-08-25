import SwiftUI

// OGDesign tokens — the palette, the fill/opacity roles, and the derived
// accent colours the components tint from.
//
// Split out of `OGDesign.swift` so the palette can be reasoned about (and
// measured) on its own. Every token that carries *text* declares explicit
// light/dark values, so `OGTheme.contrastAudit` can walk the whole palette
// headlessly and fail the suite if a pair drops below WCAG AA.

// MARK: - Token type

/// Which side of the adaptive pair to read. Mirrors `UIUserInterfaceStyle`
/// without dragging UIKit into the measurement path.
enum OGColorScheme: CaseIterable {
    case light, dark
}

/// One palette entry, as explicit values rather than a system semantic colour.
struct OGColorToken {
    let light: SRGBColor
    let dark: SRGBColor

    init(light: UInt32, dark: UInt32) {
        self.light = SRGBColor(hex: light)
        self.dark = SRGBColor(hex: dark)
    }

    /// Same value in both schemes — for surfaces that don't adapt (the ink hero).
    init(fixed: UInt32) {
        self.init(light: fixed, dark: fixed)
    }

    func value(for scheme: OGColorScheme) -> SRGBColor {
        scheme == .dark ? dark : light
    }

    /// The SwiftUI colour this token renders as.
    var color: Color {
        Color(UIColor { traits in
            UIColor(self.value(for: traits.userInterfaceStyle == .dark ? .dark : .light))
        })
    }
}

private extension UIColor {
    convenience init(_ rgb: SRGBColor) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

// MARK: - Palette

enum OGTheme {
    /// The palette, as measurable values. `OGTheme`'s `Color` properties below
    /// are what views use; these are what the contrast tests read.
    enum Token {
        /// Screen background — warm off-white in light, warm near-black in dark.
        static let canvas = OGColorToken(light: 0xF5F3F0, dark: 0x151413)
        /// Card / row fill, one step above the canvas.
        static let card = OGColorToken(light: 0xFFFFFF, dark: 0x201E1C)
        /// Hero-card chrome, always dark — the accent glow carries the warmth.
        static let ink = OGColorToken(fixed: 0x1C1B1A)
        /// Text on ink.
        static let onInk = OGColorToken(fixed: 0xF5F2EE)
        /// Hairline colour before its opacity role is applied.
        static let hairlineBase = OGColorToken(light: 0x3C3C43, dark: 0xF5F2EE)
        /// Stand-in for the system label, so text-on-surface pairs are measurable.
        static let label = OGColorToken(light: 0x000000, dark: 0xFFFFFF)
        /// The shipped default accent (the Coral preset). Other presets are the
        /// user's choice; `tintedAccentLabel` is what keeps *those* legible.
        static let accent = OGColorToken(light: 0xB05426, dark: 0xF08A4B)
        /// Success hue, as painted by a status dot or a small glyph.
        static let ok = OGColorToken(fixed: 0x34C759)
        /// Attention hue — the system orange `OGTheme.warn` renders as.
        static let warn = OGColorToken(light: 0xFF9500, dark: 0xFF9F0A)
        /// Failure hue, likewise.
        static let error = OGColorToken(fixed: 0xE03026)
    }

    /// Opacity roles. Named because the contrast audit asserts against them —
    /// a bare `0.4` in a component is a number nothing can check.
    enum Opacity {
        /// Secondary text (SwiftUI's `.secondary` renders at roughly this).
        static let secondaryLabel = 0.6
        /// Hairline between rows.
        static let hairline = 0.12
        /// Supporting text on the ink hero (battery).
        static let onInkSecondary = 0.75
        /// Quiet text on the ink hero (status line, unavailable chips).
        static let onInkTertiary = 0.6
        /// Accent wash behind accent-coloured text (chips, badges, icon tiles).
        static let accentFill = 0.14
        /// The same wash, lighter, behind a status pill.
        static let accentPillFill = 0.12
        /// The same wash, lighter still, behind a full-width notice.
        static let accentNoticeFill = 0.1
        /// Accent wash on the ink hero, which needs more body against the glow.
        static let accentInkFill = 0.22
        /// Neutral wash on the ink hero (an unavailable chip's ground).
        static let onInkFill = 0.1
    }

    /// Adaptive pair helper: most tokens carry explicit light/dark values
    /// rather than relying on system semantic colours (which are cool-grey).
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        OGColorToken(light: light, dark: dark).color
    }

    static let canvas = Token.canvas.color
    static let card = Token.card.color
    static let ink = Token.ink.color
    static let onInk = Token.onInk.color
    static let hairline = Token.hairlineBase.color.opacity(Opacity.hairline)

    // Status dots only — never row-icon tints. As *text* they are far too light
    // (the green measures ~2.2:1 on a white card); use `okLabel` / `errorLabel`.
    static let ok = Token.ok.color
    static let warn = Color.orange
    static let error = Token.error.color
}

// MARK: - Derived accent colours

extension OGTheme {
    /// The accent as *small text on its own faint tint* — chips, badges, pills,
    /// notices, icon glyphs.
    ///
    /// The raw accent is chosen to read on a plain surface; laying a wash of
    /// itself behind it eats the contrast margin, and a pale preset (White)
    /// disappears outright. This nudges the accent toward black or white by the
    /// least amount that clears AA on both surface tokens, so the hue family is
    /// untouched — with the shipped coral the correction is imperceptible in
    /// light mode and nil in dark.
    static func tintedAccentLabel(_ accent: Color) -> Color {
        derived(from: accent) { tintedAccentLabelValue($0, in: $1) }
    }

    /// `tintedAccentLabel`'s arithmetic, on plain values — the tests measure
    /// this for every accent preset rather than a `Color` they can't inspect.
    static func tintedAccentLabelValue(_ accent: SRGBColor, in scheme: OGColorScheme) -> SRGBColor {
        let grounds = [Token.canvas, Token.card].map {
            accent.composited(alpha: Opacity.accentFill, over: $0.value(for: scheme))
        }
        return ContrastRatio.readable(accent, on: grounds)
    }

    /// The accent on the always-dark hero chrome.
    ///
    /// Resolved against *dark* traits whatever the screen is doing: an adaptive
    /// accent hands out its light-mode value in light mode, and that value is
    /// picked to sit on white — on ink it measures well under AA.
    static func inkAccentLabel(_ accent: Color) -> Color {
        Color(UIColor(inkAccentLabelValue(resolved(accent, for: .dark))))
    }

    /// The accent's dark-scheme value, for washes and glows on the ink hero.
    /// Not a text colour — but it has to come from the same side of the pair as
    /// `inkAccentLabel`, or the hero's tint and its label drift apart in light mode.
    static func inkAccent(_ accent: Color) -> Color {
        Color(UIColor(resolved(accent, for: .dark)))
    }

    /// `inkAccentLabel`'s arithmetic, on plain values.
    static func inkAccentLabelValue(_ darkAccent: SRGBColor) -> SRGBColor {
        let grounds = [
            darkAccent.composited(alpha: Opacity.accentInkFill, over: Token.ink.dark),
            Token.ink.dark,
        ]
        return ContrastRatio.readable(darkAccent, on: grounds)
    }

    /// A filled-accent control's label — the accent is the *ground* here rather
    /// than the text, so the label is whichever pole reads better on it: white
    /// on the light coral, near-black on the brighter dark one. One of the two
    /// always clears AA against any single colour (the worst case a solid ground
    /// can produce is 4.58:1), so this needs no blending.
    static func onAccentLabel(_ accent: Color) -> Color {
        derived(from: accent) { value, _ in onAccentLabelValue(value) }
    }

    /// `onAccentLabel`'s choice, on plain values — the tests measure this for
    /// every accent preset.
    static func onAccentLabelValue(_ accent: SRGBColor) -> SRGBColor {
        ContrastRatio.ratio(.white, accent) >= ContrastRatio.ratio(.black, accent)
            ? .white
            : .black
    }

    /// A status hue as *text* — "Key valid", a validation error, "Granted".
    ///
    /// The dot colours are picked to read as a 7pt dot on any surface; as a
    /// label the green in particular measures barely 2:1. Corrected the same way
    /// the accent is (toward the reachable pole, by the least amount that clears
    /// AA on both surfaces), so the hue still says success or failure.
    static func statusLabelValue(_ status: SRGBColor, in scheme: OGColorScheme) -> SRGBColor {
        ContrastRatio.readable(
            status,
            on: [Token.card.value(for: scheme), Token.canvas.value(for: scheme)]
        )
    }

    static let okLabelToken = OGColorToken(
        light: statusLabelValue(Token.ok.light, in: .light).hex,
        dark: statusLabelValue(Token.ok.dark, in: .dark).hex
    )

    static let warnLabelToken = OGColorToken(
        light: statusLabelValue(Token.warn.light, in: .light).hex,
        dark: statusLabelValue(Token.warn.dark, in: .dark).hex
    )

    static let errorLabelToken = OGColorToken(
        light: statusLabelValue(Token.error.light, in: .light).hex,
        dark: statusLabelValue(Token.error.dark, in: .dark).hex
    )

    /// Success / attention / failure text and the glyphs that sit beside it.
    static let okLabel = okLabelToken.color
    static let warnLabel = warnLabelToken.color
    static let errorLabel = errorLabelToken.color

    /// Build an adaptive `Color` whose value in each scheme is computed from the
    /// accent resolved for that scheme.
    private static func derived(
        from accent: Color,
        _ transform: @escaping (SRGBColor, OGColorScheme) -> SRGBColor
    ) -> Color {
        Color(UIColor { traits in
            let scheme: OGColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            return UIColor(transform(resolved(accent, for: scheme), scheme))
        })
    }

    /// The value an adaptive `Color` hands out under one scheme's traits.
    static func resolved(_ color: Color, for scheme: OGColorScheme) -> SRGBColor {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SRGBColor(red: Double(r), green: Double(g), blue: Double(b))
    }
}

// MARK: - Contrast audit

/// One text-on-surface pair the components actually render, with the threshold
/// it has to clear. `OGDesignContrastTests` walks the table, so the palette
/// can't regress silently.
struct OGContrastPair {
    let name: String
    let foreground: OGColorToken
    let foregroundOpacity: Double
    let background: OGColorToken
    /// A wash of `washColor` at this opacity sits between foreground and
    /// background (a chip's tint, a notice's fill).
    let backgroundWash: (color: OGColorToken, opacity: Double)?
    let textSize: ContrastRatio.TextSize

    init(
        _ name: String,
        foreground: OGColorToken,
        opacity: Double = 1,
        on background: OGColorToken,
        wash: (color: OGColorToken, opacity: Double)? = nil,
        textSize: ContrastRatio.TextSize = .normal
    ) {
        self.name = name
        self.foreground = foreground
        self.foregroundOpacity = opacity
        self.background = background
        self.backgroundWash = wash
        self.textSize = textSize
    }

    /// The measured ratio in one scheme, with the wash composited in.
    func ratio(in scheme: OGColorScheme) -> Double {
        var ground = background.value(for: scheme)
        if let wash = backgroundWash {
            ground = wash.color.value(for: scheme)
                .composited(alpha: wash.opacity, over: ground)
        }
        let text = foreground.value(for: scheme)
            .composited(alpha: foregroundOpacity, over: ground)
        return ContrastRatio.ratio(text, ground)
    }
}

extension OGTheme {
    /// The shipped accent after `tintedAccentLabel`'s correction — what a chip
    /// or notice actually paints with the default preset.
    static let accentLabelToken = OGColorToken(
        light: tintedAccentLabelValue(Token.accent.light, in: .light).hex,
        dark: tintedAccentLabelValue(Token.accent.dark, in: .dark).hex
    )

    /// The same, for the always-dark hero chrome.
    static let inkAccentLabelToken = OGColorToken(
        fixed: inkAccentLabelValue(Token.accent.dark).hex
    )

    /// The wash behind it — the accent's dark value in both schemes.
    static let inkAccentWashToken = OGColorToken(fixed: Token.accent.dark.hex)

    /// Every pair OGDesign puts text into. Accent pairs use the shipped Coral
    /// preset; user-chosen presets are held to the same bar at render time by
    /// `tintedAccentLabel` / `inkAccentLabel`, which the same tests exercise.
    static let contrastAudit: [OGContrastPair] = [
        .init("row title on card", foreground: Token.label, on: Token.card),
        .init("row subtitle on card", foreground: Token.label,
              opacity: Opacity.secondaryLabel, on: Token.card),
        .init("section header on canvas", foreground: Token.label,
              opacity: Opacity.secondaryLabel, on: Token.canvas),
        .init("page text on canvas", foreground: Token.label, on: Token.canvas),
        .init("hero title on ink", foreground: Token.onInk, on: Token.ink),
        .init("hero battery on ink", foreground: Token.onInk,
              opacity: Opacity.onInkSecondary, on: Token.ink),
        .init("hero status on ink", foreground: Token.onInk,
              opacity: Opacity.onInkTertiary, on: Token.ink),
        .init("hero unavailable chip", foreground: Token.onInk,
              opacity: Opacity.onInkTertiary, on: Token.ink,
              wash: (Token.onInk, Opacity.onInkFill)),
        .init("hero accent chip on ink", foreground: inkAccentLabelToken, on: Token.ink,
              wash: (inkAccentWashToken, Opacity.accentInkFill)),
        .init("chip label on card", foreground: accentLabelToken, on: Token.card,
              wash: (Token.accent, Opacity.accentFill)),
        .init("chip label on canvas", foreground: accentLabelToken, on: Token.canvas,
              wash: (Token.accent, Opacity.accentFill)),
        .init("status pill on card", foreground: accentLabelToken, on: Token.card,
              wash: (Token.accent, Opacity.accentPillFill)),
        .init("notice on canvas", foreground: accentLabelToken, on: Token.canvas,
              wash: (Token.accent, Opacity.accentNoticeFill)),
        .init("filled button label on accent", foreground: onAccentLabelToken, on: Token.accent),
        .init("success label on card", foreground: okLabelToken, on: Token.card),
        .init("success label on canvas", foreground: okLabelToken, on: Token.canvas),
        .init("attention label on card", foreground: warnLabelToken, on: Token.card),
        .init("attention label on canvas", foreground: warnLabelToken, on: Token.canvas),
        .init("error label on card", foreground: errorLabelToken, on: Token.card),
        .init("error label on canvas", foreground: errorLabelToken, on: Token.canvas),
    ]

    /// The label a filled accent button paints with the shipped Coral preset.
    /// Every other preset is held to the same bar at render time by
    /// `onAccentLabel`, which the suite exercises across the whole set.
    static let onAccentLabelToken = OGColorToken(
        light: onAccentLabelValue(Token.accent.light).hex,
        dark: onAccentLabelValue(Token.accent.dark).hex
    )
}
