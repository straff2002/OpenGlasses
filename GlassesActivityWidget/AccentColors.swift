import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Shared accent colours used across app, widget, control and watch targets.
/// Kept here (in the widget folder) so it can be added to every target's Sources
/// phase without pulling in app-only dependencies like `Config`.
/// Reusable logo view — uses the `OpenGlassesLogo` template image bundled in each
/// target's asset catalog. Tint it with `.foregroundStyle(...)` at the call site.
struct LogoIcon: View {
    var size: CGFloat = 24
    var body: some View {
        Image("OpenGlassesLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

enum AccentColors {
    /// AI accent — Claude-adjacent coral. Adaptive so it passes WCAG AA in both modes:
    /// - Dark:  `#F08A4B` (≈ 8.4:1 on black, AAA)
    /// - Light: `#B05426` (≈ 5.4:1 on white, AA — burnt-orange variant of the same hue)
    static let aiCoral: Color = {
        #if os(watchOS)
        // watchOS UI is always dark; UIColor(dynamicProvider:) and userInterfaceStyle
        // are unavailable here, so use the dark-mode value directly.
        return Color(red: 0.941, green: 0.541, blue: 0.294)
        #elseif canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.941, green: 0.541, blue: 0.294, alpha: 1)
                : UIColor(red: 0.690, green: 0.329, blue: 0.149, alpha: 1)
        })
        #else
        return Color(red: 0.941, green: 0.541, blue: 0.294)
        #endif
    }()
}
