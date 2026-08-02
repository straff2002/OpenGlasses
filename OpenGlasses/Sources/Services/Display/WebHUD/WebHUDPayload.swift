import Foundation

/// Plan BP — the wire shape of one mirrored HUD frame (`GET /hud.json`). A read-only,
/// eventually-consistent snapshot: item *labels* render on the web surface, actions don't
/// fire (the mirror is a pull channel — deliberately NOT a third `GlassesDisplayBackend`).
struct WebHUDPayload: Codable, Equatable {
    struct Line: Codable, Equatable {
        let text: String
        let icon: String
        let emphasis: String
    }

    struct Item: Codable, Equatable {
        let id: String
        let label: String
        let style: String
    }

    let title: String?
    let lines: [Line]
    let items: [Item]
    /// Client re-renders only when this changes (same key the native queue dedups on).
    let renderKey: String

    static let empty = WebHUDPayload(title: nil, lines: [], items: [], renderKey: "")

    static func from(screen: HUDScreen) -> WebHUDPayload {
        WebHUDPayload(
            title: screen.title,
            lines: screen.lines.map {
                Line(text: $0.text, icon: Self.iconName($0.icon), emphasis: Self.emphasisName($0.emphasis))
            },
            items: screen.items.map {
                Item(id: $0.id, label: $0.label, style: Self.styleName($0.style))
            },
            renderKey: screen.renderKey)
    }

    /// Stable wire names — the page's JS glyph map keys off these.
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

    static func styleName(_ style: HUDButtonStyle) -> String {
        switch style {
        case .primary: return "primary"
        case .secondary: return "secondary"
        case .outline: return "outline"
        }
    }

    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
