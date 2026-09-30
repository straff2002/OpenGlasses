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
    static let aiCoral: Color = {
        let dark = rgb(aiAccentDarkHex)
        #if os(watchOS)
        // watchOS UI is always dark; UIColor(dynamicProvider:) and userInterfaceStyle
        // are unavailable here, so use the dark-mode value directly.
        return Color(red: dark.red, green: dark.green, blue: dark.blue)
        #elseif canImport(UIKit)
        let light = rgb(aiAccentLightHex)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dark.red, green: dark.green, blue: dark.blue, alpha: 1)
                : UIColor(red: light.red, green: light.green, blue: light.blue, alpha: 1)
        })
        #else
        return Color(red: dark.red, green: dark.green, blue: dark.blue)
        #endif
    }()
}
