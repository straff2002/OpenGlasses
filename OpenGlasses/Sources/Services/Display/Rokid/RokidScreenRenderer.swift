import Foundation

/// Pure `HUDScreen`/content → `[RokidCommand]` mapping for the Rokid RV101 (Plan AH).
///
/// Two tiers, deliberately separated:
/// 1. **Visual HUD** — ambient content maps to a `Ntf` notification card and interactive
///    screens to a `Custom_View` command. Both param schemas are *reconstructed* and ship
///    dark until a capture/hardware pass confirms them (the honest mirror of the EVEN
///    backend's "ships dark" transport).
/// 2. **TTS** — `Sys/Tts_SendPlayTts` has a published schema but is NOT emitted here: this
///    app owns its own TTS, and speaking every ambient caption aloud would be wrong. The
///    primitive lives in `RokidCommand.tts(_:)` for the Phase 1 spike, off the display path.
///
/// Everything here is deterministic and unit-tested at the JSON layer; only the
/// device-facing semantics await hardware.
enum RokidScreenRenderer {

    /// Keep in step with the EVEN monochrome budget for cross-device legibility.
    static let charBudget = 44
    static let maxLines = 8

    // MARK: - Content (ambient / notification / navigation)

    static func renderContent(title: String?, body: String, icon: HUDIcon) -> [RokidCommand] {
        [.notification(title: title, text: body, icon: iconName(icon))]
    }

    // MARK: - Interactive screens

    static func renderScreen(_ screen: HUDScreen) -> [RokidCommand] {
        [.customView(param: screenParam(screen))]
    }

    static func clearCommands() -> [RokidCommand] {
        [.clearCustomView()]
    }

    // MARK: - Parameter shapes (reconstructed)

    /// The `Custom_View` parameter object for one interactive screen. Titles, content
    /// lines, and numbered items mirror the EVEN text layout; the device-side keys are
    /// reconstructed pending capture validation.
    static func screenParam(_ screen: HUDScreen) -> [String: Any] {
        [
            "title": screen.title ?? "",
            "lines": screen.lines.map {
                [
                    "text": $0.text,
                    "icon": iconName($0.icon),
                    "emphasis": emphasisName($0.emphasis),
                ]
            },
            "items": screen.items.enumerated().map {
                ["id": $0.element.id, "label": $0.element.label, "index": $0.offset + 1]
            },
        ]
    }

    // MARK: - Semantic mappings

    /// Stable semantic name for a HUD icon (the device's own enum names are unknown, so
    /// these are the reconstruction's identifiers, not a promise of the device vocabulary).
    static func iconName(_ icon: HUDIcon) -> String {
        switch icon {
        case .none: return "none"
        case .info: return "info"
        case .success: return "success"
        case .warning: return "warning"
        case .error: return "error"
        case .navigation: return "navigation"
        case .hazard: return "hazard"
        case .calendar: return "calendar"
        case .location: return "location"
        case .reminder: return "reminder"
        case .message: return "message"
        }
    }

    static func emphasisName(_ emphasis: HUDEmphasis) -> String {
        switch emphasis {
        case .primary: return "primary"
        case .secondary: return "secondary"
        case .meta: return "meta"
        }
    }
}
