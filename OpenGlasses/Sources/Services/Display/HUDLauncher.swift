import Foundation

/// Orchestrates the band-navigable HUD launcher (Display Phase 4 / Plan Y): opens the
/// root menu, pushes category submenus via `HUDRouter`, and runs leaf actions through
/// closures injected by AppState. Screens come from the pure `HUDMenuBuilder`.
///
/// Branches: Resume task · Quick Actions · Workflows · SOPs (Field Assist) · Mode/Persona.
/// Workflows and SOPs hand off to the Plan X Now/Next task card; the rest run an action and
/// return. All app/SDK effects are injected closures so the launcher stays unit-testable.
@MainActor
final class HUDLauncher {
    private let router: HUDRouter

    /// Injected by AppState — the real app effects.
    var runQuickAction: ((QuickAction) -> Void)?
    var switchPersona: ((Persona) -> Void)?
    var activePersonaId: (() -> String?)?

    /// Workflows branch (Plan Y): live playbook listing + start handler. `startPlaybook`
    /// both starts the session and hands off to the Plan X card (wired in AppState).
    var availablePlaybooks: (() -> [Playbook])?
    var startPlaybook: ((String) -> Void)?

    /// SOPs / Field Assist branch (Plan Y): the entitlement gate, the live procedure listing
    /// (vault-scoped, so only populated during an active session), and the start handler
    /// (ensures a session, starts the procedure, hands off to the Plan X card — wired in AppState).
    var fieldAssistActive: (() -> Bool)?
    var availableProcedures: (() -> [Procedure])?
    var startProcedure: ((String) -> Void)?

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
        ["menu", "show menu", "open menu", "open the menu", "hud menu"].contains(normalize(text))
    }

    /// Voice navigation within an open menu (Plan Y): match a spoken phrase to a visible
    /// item's label or a global verb ("back"/"close") and fire it. Returns `true` when
    /// consumed (so the caller doesn't also route it to the LLM). Only active while a menu
    /// is presented, and deliberately conservative — it never fires on an ambiguous match.
    @discardableResult
    func handleVoiceSelection(_ text: String) -> Bool {
        guard router.isPresentingMenu, let screen = router.currentScreen else { return false }
        let phrase = Self.normalize(text)
        guard !phrase.isEmpty else { return false }

        if ["back", "go back"].contains(phrase) { router.pop(); return true }
        if ["close", "exit", "dismiss", "cancel"].contains(phrase) { router.dismiss(); return true }

        // Exact label match wins (the "✓ " active-persona marker normalises away).
        if let item = screen.items.first(where: { Self.normalize($0.label) == phrase }) {
            item.action()
            return true
        }
        // Otherwise a unique substring match; ambiguity is a no-op (never wrong-fires).
        let matches = screen.items.filter { Self.normalize($0.label).contains(phrase) }
        if matches.count == 1 {
            matches[0].action()
            return true
        }
        return false
    }

    /// Lowercase, strip punctuation/symbols, collapse whitespace — shared by the open-command
    /// and in-menu voice matchers so they normalise identically.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Screens

    private func rootBranches() -> [HUDItem] {
        var branches: [HUDItem] = []

        // Resume the active Plan X task card — only while one is running.
        if router.isPresentingTask {
            branches.append(HUDItem(id: "branch:resume", label: "Resume task", icon: .navigation, style: .primary) { [weak self] in
                self?.router.resumeTask()
            })
        }
        if !Config.quickActions.isEmpty {
            branches.append(HUDItem(id: "branch:quick", label: "Quick Actions", icon: .message, style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.quickActionsScreen())
            })
        }
        if !playbooks().isEmpty {
            branches.append(HUDItem(id: "branch:workflows", label: "Workflows", icon: .reminder, style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.workflowsScreen())
            })
        }
        if isFieldAssistActive(), !procedures().isEmpty {
            branches.append(HUDItem(id: "branch:sops", label: "SOPs", icon: .navigation, style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.proceduresScreen())
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

    private func playbooks() -> [Playbook] { availablePlaybooks?() ?? [] }
    private func procedures() -> [Procedure] { availableProcedures?() ?? [] }
    private func isFieldAssistActive() -> Bool { fieldAssistActive?() ?? false }

    private func quickActionsScreen(page: Int = 0) -> HUDScreen {
        HUDMenuBuilder.quickActions(
            Config.quickActions, page: page,
            onRun: { [weak self] action in
                self?.runQuickAction?(action)
                self?.router.dismiss()   // run it, then close the launcher
            },
            onMore: { [weak self] next in self?.router.push(self?.quickActionsScreen(page: next) ?? HUDScreen()) },
            onBack: { [weak self] in self?.router.pop() }
        )
    }

    private func workflowsScreen(page: Int = 0) -> HUDScreen {
        HUDMenuBuilder.workflows(
            playbooks(), page: page,
            onStart: { [weak self] id in self?.startPlaybook?(id) },   // AppState hands off to the card
            onMore: { [weak self] next in self?.router.push(self?.workflowsScreen(page: next) ?? HUDScreen()) },
            onBack: { [weak self] in self?.router.pop() }
        )
    }

    private func proceduresScreen(page: Int = 0) -> HUDScreen {
        HUDMenuBuilder.procedures(
            procedures(), page: page,
            onStart: { [weak self] id in self?.startProcedure?(id) },  // AppState ensures a session + hands off
            onMore: { [weak self] next in self?.router.push(self?.proceduresScreen(page: next) ?? HUDScreen()) },
            onBack: { [weak self] in self?.router.pop() }
        )
    }

    private func personaScreen(page: Int = 0) -> HUDScreen {
        HUDMenuBuilder.personas(
            Config.enabledPersonas,
            activeId: activePersonaId?(),
            page: page,
            onSelect: { [weak self] persona in
                self?.switchPersona?(persona)
                self?.router.dismiss()
            },
            onMore: { [weak self] next in self?.router.push(self?.personaScreen(page: next) ?? HUDScreen()) },
            onBack: { [weak self] in self?.router.pop() }
        )
    }
}
