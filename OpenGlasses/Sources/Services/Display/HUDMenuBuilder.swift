import Foundation

/// Pure builders that turn live app state + injected action closures into `HUDScreen`s
/// for the launcher (Display Phase 4 / Plan Y). No app or SDK dependencies, so every
/// screen is unit-testable headlessly. Leaf effects (run a quick action, start a
/// playbook, switch persona) are passed in as closures by `HUDLauncher`.
enum HUDMenuBuilder {

    /// Max selectable leaf items shown before paginating with a "More…" item. Keeps each
    /// screen band-legible (plan: ≤ 6 items per screen, long lists paginate not scroll).
    static let pageSize = 6

    /// Root menu: one button per available branch, plus a Close.
    static func root(branches: [HUDItem], onClose: @escaping () -> Void) -> HUDScreen {
        var items = branches
        items.append(HUDItem(id: "close", label: "Close", style: .outline, action: onClose))
        return HUDScreen(title: "Menu", items: items)
    }

    /// Quick Actions: one button per action; selecting runs it. Back returns to root.
    static func quickActions(_ actions: [QuickAction],
                             page: Int = 0,
                             onRun: @escaping (QuickAction) -> Void,
                             onMore: ((Int) -> Void)? = nil,
                             onBack: @escaping () -> Void) -> HUDScreen {
        let leaves = actions.map { action in
            HUDItem(id: "qa:\(action.id)", label: action.label, icon: icon(for: action.type), style: .primary) {
                onRun(action)
            }
        }
        return listScreen(title: "Quick Actions", leaves: leaves, page: page,
                          onMore: onMore, trailing: backItem(onBack))
    }

    /// Workflows: one button per playbook; selecting starts it (handing off to the Plan X
    /// Now/Next card). Back returns to root.
    static func workflows(_ playbooks: [Playbook],
                          page: Int = 0,
                          onStart: @escaping (String) -> Void,
                          onMore: ((Int) -> Void)? = nil,
                          onBack: @escaping () -> Void) -> HUDScreen {
        let leaves = playbooks.map { playbook in
            HUDItem(id: "pb:\(playbook.id)", label: playbook.name, icon: .reminder, style: .primary) {
                onStart(playbook.id)
            }
        }
        return listScreen(title: "Workflows", leaves: leaves, page: page,
                          onMore: onMore, trailing: backItem(onBack))
    }

    /// SOPs (Field Assist): one button per procedure; selecting starts it (handing off to
    /// the Plan X card, branching). Back returns to root.
    static func procedures(_ procedures: [Procedure],
                           page: Int = 0,
                           onStart: @escaping (String) -> Void,
                           onMore: ((Int) -> Void)? = nil,
                           onBack: @escaping () -> Void) -> HUDScreen {
        let leaves = procedures.map { procedure in
            HUDItem(id: "sop:\(procedure.id)", label: procedure.title, icon: .navigation, style: .primary) {
                onStart(procedure.id)
            }
        }
        return listScreen(title: "SOPs", leaves: leaves, page: page,
                          onMore: onMore, trailing: backItem(onBack))
    }

    /// Mode / Persona: one button per enabled persona; the active one is checked.
    static func personas(_ personas: [Persona], activeId: String?,
                         page: Int = 0,
                         onSelect: @escaping (Persona) -> Void,
                         onMore: ((Int) -> Void)? = nil,
                         onBack: @escaping () -> Void) -> HUDScreen {
        let leaves = personas.map { persona -> HUDItem in
            let active = persona.id == activeId
            return HUDItem(id: "persona:\(persona.id)",
                           label: active ? "✓ \(persona.name)" : persona.name,
                           style: active ? .primary : .secondary) {
                onSelect(persona)
            }
        }
        return listScreen(title: "Mode / Persona", leaves: leaves, page: page,
                          onMore: onMore, trailing: backItem(onBack))
    }

    // MARK: - Helpers

    /// Assemble a list screen: a page of ≤ `pageSize` leaf items, a "More…" pager when more
    /// remain (carrying the next page index via `onMore`), then the trailing nav item.
    /// Centralising paging keeps every list branch within the band-legible budget.
    private static func listScreen(title: String,
                                   leaves: [HUDItem],
                                   page: Int,
                                   onMore: ((Int) -> Void)?,
                                   trailing: HUDItem) -> HUDScreen {
        var items: [HUDItem] = []
        let start = max(0, page) * pageSize
        if start < leaves.count {
            let end = min(start + pageSize, leaves.count)
            items.append(contentsOf: leaves[start..<end])
            if end < leaves.count, let onMore {
                let next = page + 1
                items.append(HUDItem(id: "more:\(next)", label: "More…", style: .secondary) {
                    onMore(next)
                })
            }
        }
        items.append(trailing)
        return HUDScreen(title: title, items: items)
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
