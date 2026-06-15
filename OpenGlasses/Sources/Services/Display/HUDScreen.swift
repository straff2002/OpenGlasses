import Foundation

/// SDK-free description of one interactive HUD screen (Display Phase 3 / Plan X).
///
/// A screen is a heading + some non-interactive content lines + a list of
/// band-selectable items. `GlassesDisplayService` renders it to a `MWDATDisplay`
/// `FlexBox`/`Button` tree; nothing here imports the SDK, so screens are pure data
/// and unit-testable headlessly. `HUDIcon` is reused from `GlassesDisplayService`.

/// Text emphasis for a content line, mapped to the SDK's `TextStyle`/`TextColor`
/// inside `GlassesDisplayService`.
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
    let icon: GlassesDisplayService.HUDIcon
    let emphasis: HUDEmphasis

    init(_ text: String, icon: GlassesDisplayService.HUDIcon = .none, emphasis: HUDEmphasis = .primary) {
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
    let icon: GlassesDisplayService.HUDIcon
    let style: HUDButtonStyle
    let action: () -> Void

    init(id: String,
         label: String,
         icon: GlassesDisplayService.HUDIcon = .none,
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
