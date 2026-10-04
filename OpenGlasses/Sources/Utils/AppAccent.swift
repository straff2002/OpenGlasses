import SwiftUI

/// Central accent colour for the app. All UI elements reference this
/// instead of hardcoded color values. Users pick their colour in Settings.
enum AppAccent {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let color: Color
    }

    /// The one fresh-install default, shared by every `@AppStorage` site and
    /// `Config` — three views each carrying their own literal is how the app
    /// once rendered green while Look & Feel highlighted Coral.
    static let defaultPresetID = "violet"   // the Orange preset (legacy id, a stored value)

    /// Brand adaptive colour: #255E88 in light mode, #D9FDFD in dark mode.
    static let brandColor: Color = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xD9/255, green: 0xFD/255, blue: 0xFD/255, alpha: 1)
            : UIColor(red: 0x25/255, green: 0x5E/255, blue: 0x88/255, alpha: 1)
    })

    /// AI accent — the brand orange `#E77F47`. Adaptive so it passes WCAG AA in both modes.
    /// Defined in `AccentColors.aiCoral` so the widget, control and watch targets share
    /// the same source of truth.
    static let aiCoral: Color = AccentColors.aiCoral

    static let presets: [Preset] = [
        Preset(id: "brand",   name: "Brand",   color: brandColor),
        // The id is the stored value from when the default was violet; the preset is the
        // brand orange now, so its display name says so.
        Preset(id: "violet",  name: "Orange",  color: AppAccent.aiCoral),
        Preset(id: "blue",    name: "Blue",    color: Color(red: 0.25, green: 0.5, blue: 1.0)),
        Preset(id: "teal",    name: "Teal",    color: Color(red: 0.2, green: 0.7, blue: 0.7)),
        Preset(id: "green",   name: "Green",   color: Color(red: 0.3, green: 0.75, blue: 0.4)),
        // Labelled Amber, not Orange, now that the default preset is the brand orange: two
        // swatches called Orange side by side is a choice nobody can make. Id unchanged.
        Preset(id: "orange",  name: "Amber",   color: Color(red: 1.0, green: 0.6, blue: 0.2)),
        Preset(id: "pink",    name: "Pink",    color: Color(red: 0.95, green: 0.35, blue: 0.55)),
        Preset(id: "red",     name: "Red",     color: Color(red: 0.9, green: 0.25, blue: 0.3)),
        Preset(id: "white",   name: "White",   color: .white),
    ]

    /// A custom accent as its stored spelling, `#RRGGBB` — the one form an organisation's
    /// profile may supply. Nil for anything else: no shorthand, no alpha, no missing `#`, so the
    /// office, the minting script and the phone can never read one value three ways.
    static func hexValue(_ text: String) -> UInt32? {
        let digits = text.dropFirst()
        guard text.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// Resolve a stored accent — a preset id or a `#RRGGBB` custom colour — to its Color value.
    /// A custom colour is one value in both schemes; `OGTheme.tintedAccentLabel` and
    /// `onAccentLabel` are what keep it legible wherever it is text or ground.
    static func color(for name: String) -> Color {
        if let hex = hexValue(name) {
            return Color(red: Double((hex >> 16) & 0xFF) / 255,
                         green: Double((hex >> 8) & 0xFF) / 255,
                         blue: Double(hex & 0xFF) / 255)
        }
        return presets.first(where: { $0.id == name })?.color
            ?? presets.first(where: { $0.id == defaultPresetID })!.color
    }

    /// The accent in force for a stored choice: the organisation's own colour while its profile
    /// locks one, otherwise the person's choice. Clamped on read — the stored choice is untouched
    /// and comes back when the profile goes.
    static func effectiveName(stored: String) -> String {
        Config.organizationAccentColor ?? stored
    }

    /// The colour the organisation's profile offered as a starting value, if it offered one.
    /// The picker keeps it as a swatch so a technician who tried another colour can go back.
    static var organizationDefaultName: String? {
        guard case .string(let name)? = PolicyEnvelope.current.startingValues[.accentColorName],
              hexValue(name) != nil else { return nil }
        return name
    }

    /// The current accent color (non-reactive, use for one-off reads).
    static var color: Color {
        color(for: effectiveName(stored: Config.accentColorName))
    }
}

// MARK: - Environment Key

/// SwiftUI environment key so child views reactively update when accent changes.
private struct AccentColorKey: EnvironmentKey {
    /// Resolves the stored selection, so a view that renders outside
    /// `MainView`'s environment still matches the chosen accent.
    static let defaultValue: Color = AppAccent.color
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AccentColorKey.self] }
        set { self[AccentColorKey.self] = newValue }
    }
}
