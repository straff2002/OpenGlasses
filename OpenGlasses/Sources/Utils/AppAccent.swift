import SwiftUI

/// Central accent colour for the app. All UI elements reference this
/// instead of hardcoded color values. Users pick their colour in Settings.
enum AppAccent {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    /// Brand adaptive colour: #255E88 in light mode, #D9FDFD in dark mode.
    static let brandColor: Color = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xD9/255, green: 0xFD/255, blue: 0xFD/255, alpha: 1)
            : UIColor(red: 0x25/255, green: 0x5E/255, blue: 0x88/255, alpha: 1)
    })

    /// AI accent — Claude-adjacent coral. Adaptive so it passes WCAG AA in both modes.
    /// Defined in `AccentColors.aiCoral` so the widget, control and watch targets share
    /// the same source of truth.
    static let aiCoral: Color = AccentColors.aiCoral

    static let presets: [Preset] = [
        Preset(id: "brand",   name: "Brand",   color: brandColor),
        Preset(id: "violet",  name: "Coral",   color: AppAccent.aiCoral),
        Preset(id: "blue",    name: "Blue",    color: Color(red: 0.25, green: 0.5, blue: 1.0)),
        Preset(id: "teal",    name: "Teal",    color: Color(red: 0.2, green: 0.7, blue: 0.7)),
        Preset(id: "green",   name: "Green",   color: Color(red: 0.3, green: 0.75, blue: 0.4)),
        Preset(id: "orange",  name: "Orange",  color: Color(red: 1.0, green: 0.6, blue: 0.2)),
        Preset(id: "pink",    name: "Pink",    color: Color(red: 0.95, green: 0.35, blue: 0.55)),
        Preset(id: "red",     name: "Red",     color: Color(red: 0.9, green: 0.25, blue: 0.3)),
        Preset(id: "white",   name: "White",   color: .white),
    ]

    /// Resolve a color name to its Color value.
    static func color(for name: String) -> Color {
        presets.first(where: { $0.id == name })?.color ?? presets[0].color
    }

    /// The current accent color (non-reactive, use for one-off reads).
    static var color: Color {
        color(for: Config.accentColorName)
    }
}

// MARK: - Environment Key

/// SwiftUI environment key so child views reactively update when accent changes.
private struct AccentColorKey: EnvironmentKey {
    static let defaultValue: Color = AppAccent.brandColor
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AccentColorKey.self] }
        set { self[AccentColorKey.self] = newValue }
    }
}
