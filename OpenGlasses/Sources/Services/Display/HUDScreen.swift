import Foundation

/// SDK-free description of one interactive HUD screen (Display Phase 3 / Plan X).
///
/// A screen is a heading + some non-interactive content lines + a list of
/// band-selectable items. The active `GlassesDisplayBackend` renders it (Meta: a
/// `MWDATDisplay` FlexBox/Button tree; EVEN G2: a monochrome text frame — Plan AH);
/// nothing here imports an SDK, so screens are pure data and unit-testable headlessly.

/// Semantic icon for HUD content. Lives with the DSL (Plan AH) so the DSL's owner isn't
/// an SDK-importing class; each backend maps it to its own representation (Meta:
/// `MWDATDisplay.IconName`; EVEN: a text glyph).
enum HUDIcon: Equatable {
    case none
    case info, success, warning, error
    case navigation, hazard
    case calendar, location, reminder, message
}

/// Shared HUD text shaping (Plan AH — extracted from `GlassesDisplayService` so every
/// backend condenses identically).
enum HUDTextShaper {
    /// Max characters for a body line — kept short for in-lens legibility.
    static let maxBodyLength = 120
    /// Max characters for a heading.
    static let maxTitleLength = 40

    /// Collapse whitespace and truncate to a HUD-legible length.
    static func condense(_ text: String, max: Int = maxBodyLength) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        let cut = collapsed.prefix(max)
        // Prefer to break on the last space so we don't slice a word in half.
        if let lastSpace = cut.lastIndex(of: " "), lastSpace > cut.index(cut.startIndex, offsetBy: max / 2) {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }
}

/// Text emphasis for a content line; each backend maps it to its own representation.
enum HUDEmphasis: Equatable {
    case primary    // body / primary colour
    case secondary  // body / secondary colour
    case meta       // small meta / secondary colour
}

/// Button prominence, mapped to the SDK's `ButtonStyle` inside `GlassesDisplayService`.
enum HUDButtonStyle: Equatable {
    case primary
    case secondary
    case outline
}

/// A non-interactive content line (optional leading icon + text).
struct HUDLine: Equatable {
    let text: String
    let icon: HUDIcon
    let emphasis: HUDEmphasis

    init(_ text: String, icon: HUDIcon = .none, emphasis: HUDEmphasis = .primary) {
        self.text = text
        self.icon = icon
        self.emphasis = emphasis
    }
}

/// A band-selectable action. `id` is stable and Sendable so the SDK `onClick`
/// callback can route back by id; `action` is invoked on the main actor by `HUDRouter`.
struct HUDItem: Identifiable {
    let id: String
    let label: String
    let icon: HUDIcon
    let style: HUDButtonStyle
    let action: () -> Void

    init(id: String,
         label: String,
         icon: HUDIcon = .none,
         style: HUDButtonStyle = .secondary,
         action: @escaping () -> Void) {
        self.id = id
        self.label = label
        self.icon = icon
        self.style = style
        self.action = action
    }
}

/// One renderable interactive screen.
struct HUDScreen {
    let title: String?
    let lines: [HUDLine]
    let items: [HUDItem]

    init(title: String? = nil, lines: [HUDLine] = [], items: [HUDItem] = []) {
        self.title = title
        self.lines = lines
        self.items = items
    }

    /// Stable key over the *visible* content, used to skip redundant re-renders
    /// (the render queue collapses identical screens). Excludes closures.
    var renderKey: String {
        let head = title ?? ""
        let body = lines.map { "\($0.emphasis):\($0.icon):\($0.text)" }.joined(separator: "¦")
        let acts = items.map { "\($0.id):\($0.style):\($0.icon):\($0.label)" }.joined(separator: "¦")
        return "\(head)|\(body)|\(acts)"
    }
}
