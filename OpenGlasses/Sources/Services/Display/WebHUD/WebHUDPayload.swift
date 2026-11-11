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

    /// Plan KP P1: one page of an answer card, as the page draws it.
    struct Page: Codable, Equatable {
        let lines: [Line]
        let items: [Item]
    }

    let title: String?
    let lines: [Line]
    let items: [Item]
    /// Client re-renders only when this changes (same key the native queue dedups on).
    let renderKey: String
    /// Plan KP P1: an answer card's every readable page, with the one the phone shows at
    /// `pageIndex`. The mirror is read-only, so the page turns them itself (arrow keys) and no
    /// key ever reaches the phone. Absent on every other frame.
    var pages: [Page]?
    var pageIndex: Int?
    /// Which answer card the pages belong to: the same while one answer grows, so the page keeps
    /// the place it turned to; a new one for a new answer.
    var card: Int?

    static let empty = WebHUDPayload(title: nil, lines: [], items: [], renderKey: "")

    static func from(screen: HUDScreen) -> WebHUDPayload {
        // Plan KT §6.6: a screen that says what the mirror may show is shown that way, without
        // its pages.
        switch screen.mirror {
        case .hidden(let placeholder)?:
            return WebHUDPayload(title: nil,
                                 lines: [Line(text: placeholder, icon: iconName(.none), emphasis: emphasisName(.meta))],
                                 items: [], renderKey: "mirror-hidden|\(placeholder)")
        case .lines(let replacement)?:
            var redacted = HUDScreen(title: screen.title, lines: replacement, items: screen.items)
            redacted.focusItemID = screen.focusItemID
            return WebHUDPayload(title: redacted.title, lines: lines(redacted), items: items(redacted),
                                 renderKey: redacted.renderKey)
        case nil:
            break
        }
        var payload = WebHUDPayload(
            title: screen.title,
            lines: lines(screen),
            items: items(screen),
            renderKey: screen.renderKey)
        if let set = screen.pageSet, !set.pages.isEmpty {
            let index = min(max(set.index, 0), set.pages.count - 1)
            // The page shown can stay the same while more pages become readable behind it, so the
            // key the client re-renders on carries the card, the page count and the index too.
            payload = WebHUDPayload(
                title: payload.title, lines: payload.lines, items: payload.items,
                renderKey: payload.renderKey + "|pages:\(set.card).\(set.pages.count).\(index)",
                pages: set.pages.map { Page(lines: lines($0), items: items($0)) },
                pageIndex: index,
                card: set.card)
        }
        return payload
    }

    private static func lines(_ screen: HUDScreen) -> [Line] {
        screen.lines.map {
            Line(text: $0.text, icon: Self.iconName($0.icon), emphasis: Self.emphasisName($0.emphasis))
        }
    }

    private static func items(_ screen: HUDScreen) -> [Item] {
        screen.items.map { Item(id: $0.id, label: $0.label, style: Self.styleName($0.style)) }
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
        case .weather: return "weather"
        case .clock: return "clock"
        case .microphone: return "microphone"
        case .music: return "music"
        case .video: return "video"
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
