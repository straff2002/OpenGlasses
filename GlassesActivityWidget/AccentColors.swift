import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Shared accent colours used across app, widget, control and watch targets.
/// Kept here (in the widget folder) so it can be added to every target's Sources
/// phase without pulling in app-only dependencies like `Config`.
/// Reusable logo view — uses the `AvenkinMark` template image bundled in each
/// target's asset catalog. Tint it with `.foregroundStyle(...)` at the call site.
struct LogoIcon: View {
    var size: CGFloat = 24
    var body: some View {
        Image("AvenkinMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

enum AccentColors {
    /// The AI accent in dark mode: the brand orange `#E77F47` (Plan FY P1 item 11), ≈ 7.5:1 on
    /// black. The one place the value is written — `aiCoral` below and `OGTheme.Token.accent`
    /// both read it. The accent's rule stands: never violet, never cyan.
    static let aiAccentDarkHex: UInt32 = 0xE77F47
    /// Its light-mode derivative, `#B05426` — the same hue, darker, ≈ 5.1:1 on white (AA).
    static let aiAccentLightHex: UInt32 = 0xB05426

    private static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// AI accent — the brand orange. Adaptive so it passes WCAG AA in both modes. (The name is
    /// historical; every target reads it, so it is not renamed with the colour.)
    static let aiCoral: Color = adaptive(light: aiAccentLightHex, dark: aiAccentDarkHex)

    // MARK: - App surfaces

    /// The app's two surface pairs, written here (as the accent is) so the widget targets — which
    /// cannot import OGDesign — paint the same ground the app does. `OGTheme.Token.canvas` and
    /// `OGTheme.Token.card` read these, so the app and the widgets cannot drift apart.
    /// Screen background: off-white in light, near-black in dark.
    static let canvasLightHex: UInt32 = 0xF5F3F0
    static let canvasDarkHex: UInt32 = 0x151413
    /// Card / row fill, one step above the canvas.
    static let cardLightHex: UInt32 = 0xFFFFFF
    static let cardDarkHex: UInt32 = 0x201E1C

    /// The Home Screen widget's ground: the app's card surface, because a widget sits on the
    /// Home Screen the way a card sits on the canvas. Neutral in both modes — never a tinted
    /// gradient (`WidgetSurfaceGuardTests` holds that).
    static let widgetSurface: Color = adaptive(light: cardLightHex, dark: cardDarkHex)

    // MARK: - Label on a filled accent

    /// The label a control filled with `accentHex` paints with: whichever pole — white or black —
    /// has the higher WCAG contrast against it. One of the two always clears AA against any single
    /// solid colour. This is the one definition of the rule: `OGTheme.onAccentLabel` (the app's
    /// filled buttons) and `onAiCoral` (the widgets' filled buttons) both read it.
    static func onAccentLabelHex(onAccent accentHex: UInt32) -> UInt32 {
        let accent = rgb(accentHex)
        return prefersWhiteLabel(red: accent.red, green: accent.green, blue: accent.blue)
            ? 0xFFFFFF : 0x000000
    }

    /// `onAccentLabelHex`'s comparison on 0…1 sRGB channels. WCAG 2.2 relative luminance;
    /// white wins ties, as it does in the app.
    static func prefersWhiteLabel(red: Double, green: Double, blue: Double) -> Bool {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let onWhite = 1.05 / (luminance + 0.05)
        let onBlack = (luminance + 0.05) / 0.05
        return onWhite >= onBlack
    }

    /// The label on a solid `aiCoral` fill, adaptive with it: white on the light-mode orange,
    /// black on the brighter dark-mode one — what the app's primary button paints.
    static let onAiCoral: Color = adaptive(
        light: onAccentLabelHex(onAccent: aiAccentLightHex),
        dark: onAccentLabelHex(onAccent: aiAccentDarkHex)
    )

    // MARK: - Adaptive helper

    /// A light/dark pair as one `Color`.
    private static func adaptive(light lightHex: UInt32, dark darkHex: UInt32) -> Color {
        let dark = rgb(darkHex)
        #if os(watchOS)
        // watchOS UI is always dark; UIColor(dynamicProvider:) and userInterfaceStyle
        // are unavailable here, so use the dark-mode value directly.
        return Color(red: dark.red, green: dark.green, blue: dark.blue)
        #elseif canImport(UIKit)
        let light = rgb(lightHex)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
                : UIColor(red: light.red, green: light.green, blue: light.blue, alpha: 1)
        })
        #else
        return Color(red: dark.red, green: dark.green, blue: dark.blue)
        #endif
    }
}
