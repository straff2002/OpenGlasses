import Foundation

/// Pure builders that turn live app state + injected action closures into `HUDScreen`s
/// for the launcher (Display Phase 4 / Plan Y). No app or SDK dependencies, so every
/// screen is unit-testable headlessly. Leaf effects (run a quick action, switch persona)
/// are passed in as closures by `HUDLauncher`.
enum HUDMenuBuilder {

    /// Root menu: one button per available branch, plus a Close.
    static func root(branches: [HUDItem], onClose: @escaping () -> Void) -> HUDScreen {
        var items = branches
        items.append(HUDItem(id: "close", label: "Close", style: .outline, action: onClose))
        return HUDScreen(title: "Menu", items: items)
    }

    /// Quick Actions: one button per action; selecting runs it. Back returns to root.
    static func quickActions(_ actions: [QuickAction],
                             onRun: @escaping (QuickAction) -> Void,
                             onBack: @escaping () -> Void) -> HUDScreen {
        var items: [HUDItem] = actions.map { action in
            HUDItem(id: "qa:\(action.id)", label: action.label, icon: icon(for: action.type), style: .primary) {
                onRun(action)
            }
        }
        items.append(backItem(onBack))
        return HUDScreen(title: "Quick Actions", items: items)
    }

    /// Mode / Persona: one button per enabled persona; the active one is checked.
    static func personas(_ personas: [Persona], activeId: String?,
                         onSelect: @escaping (Persona) -> Void,
                         onBack: @escaping () -> Void) -> HUDScreen {
        var items: [HUDItem] = personas.map { persona in
            let active = persona.id == activeId
            return HUDItem(id: "persona:\(persona.id)",
                           label: active ? "✓ \(persona.name)" : persona.name,
                           style: active ? .primary : .secondary) {
                onSelect(persona)
            }
        }
        items.append(backItem(onBack))
        return HUDScreen(title: "Mode / Persona", items: items)
    }

    private static func backItem(_ onBack: @escaping () -> Void) -> HUDItem {
        HUDItem(id: "back", label: "Back", style: .outline, action: onBack)
    }

    /// Best-effort HUD icon for a quick-action type (HUDIcon is a small semantic set).
    private static func icon(for type: QuickAction.ActionType) -> GlassesDisplayService.HUDIcon {
        switch type {
        case .prompt, .photoThenPrompt: return .message
        case .homeAssistant: return .location
        case .photo, .siriShortcut, .openApp: return .none
        }
    }
}
