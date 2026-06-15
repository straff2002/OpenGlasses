import Foundation

/// Orchestrates the band-navigable HUD launcher (Display Phase 4 / Plan Y): opens the
/// root menu, pushes category submenus via `HUDRouter`, and runs leaf actions through
/// closures injected by AppState. Screens come from the pure `HUDMenuBuilder`.
///
/// Phase 4 (this cut): Quick Actions + Mode/Persona. Workflows and SOPs (which hand off
/// to the Plan X task card) and the voice/phone-mirror navigation are tracked follow-ups.
@MainActor
final class HUDLauncher {
    private let router: HUDRouter

    /// Injected by AppState — the real app effects.
    var runQuickAction: ((QuickAction) -> Void)?
    var switchPersona: ((Persona) -> Void)?
    var activePersonaId: (() -> String?)?

    init(router: HUDRouter) {
        self.router = router
    }

    /// Open the launcher at its root menu. No-op when no branch has content.
    func open() {
        let branches = rootBranches()
        guard !branches.isEmpty else { return }
        router.openLauncher(HUDMenuBuilder.root(branches: branches, onClose: { [weak self] in
            self?.router.dismiss()
        }))
    }

    /// Whether the launcher would have anything to show (used to gate the open trigger).
    var hasContent: Bool { !rootBranches().isEmpty }

    /// Recognise the spoken phrase that opens the launcher.
    static func isOpenCommand(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return ["menu", "show menu", "open menu", "open the menu", "hud menu"].contains(cleaned)
    }

    // MARK: - Screens

    private func rootBranches() -> [HUDItem] {
        var branches: [HUDItem] = []

        if !Config.quickActions.isEmpty {
            branches.append(HUDItem(id: "branch:quick", label: "Quick Actions", icon: .message, style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.quickActionsScreen())
            })
        }
        if Config.enabledPersonas.count > 1 {
            branches.append(HUDItem(id: "branch:modes", label: "Mode / Persona", style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.personaScreen())
            })
        }

        return branches
    }

    private func quickActionsScreen() -> HUDScreen {
        HUDMenuBuilder.quickActions(
            Config.quickActions,
            onRun: { [weak self] action in
                self?.runQuickAction?(action)
                self?.router.dismiss()   // run it, then close the launcher
            },
            onBack: { [weak self] in self?.router.pop() }
        )
    }

    private func personaScreen() -> HUDScreen {
        HUDMenuBuilder.personas(
            Config.enabledPersonas,
            activeId: activePersonaId?(),
            onSelect: { [weak self] persona in
                self?.switchPersona?(persona)
                self?.router.dismiss()
            },
            onBack: { [weak self] in self?.router.pop() }
        )
    }
}
