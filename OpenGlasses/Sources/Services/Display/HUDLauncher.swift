import Foundation

/// Orchestrates the band-navigable HUD launcher (Display Phase 4 / Plan Y): opens the
/// root menu, pushes category submenus via `HUDRouter`, and runs leaf actions through
/// closures injected by AppState. Screens come from the pure `HUDMenuBuilder`.
///
/// Plan KX §4: the root (L0) is the Today glance (`HUDTodayBuilder`) — time and glasses battery,
/// the next event, the weather, the route, the digest's top item — with What's new · Resume ·
/// Navigate · Menu · Close. **Menu** pushes the branch list below. Today is summoned only (the
/// "menu" and "show my day" voice commands), never shown by itself. A launcher with no `today`
/// source wired opens at the branch list, as before.
///
/// Branches: Resume task · Quick Actions · Workflows · SOPs (Field Assist) · Mode/Persona ·
/// Practise the band (Plan KP §5).
/// Workflows and SOPs hand off to the Plan X Now/Next task card; the rest run an action and
/// return. All app/SDK effects are injected closures so the launcher stays unit-testable.
@MainActor
final class HUDLauncher {
    private let router: HUDRouter

    /// Injected by AppState — the real app effects.
    var runQuickAction: ((QuickAction) -> Void)?
    /// "What's new" branch (Plan BZ): gate + open action for the notification digest.
    var digestHasContent: (() -> Bool)?
    var openDigest: (() -> Void)?

    /// Navigate branch (Plan CA): recent destinations + start handler.
    var recentDestinations: (() -> [String])?
    var startNavigation: ((String) -> Void)?
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

    /// Practise the band (Plan KP §5): whether to offer it (a display, no task card up) and the
    /// start, which closes this menu and puts the band check's card up.
    var bandPracticeAvailable: (() -> Bool)?
    var startBandPractice: (() -> Void)?

    /// Plan KX §4: the Today glance as it stands now, built from what the app already holds (My
    /// Day's last gathering, the glasses' battery, the route, the digest). Nil — or not wired —
    /// opens the launcher at its branch list.
    var today: (() -> HUDTodayGlance?)?

    /// Plan KX §6: the Now Playing card — what the Music app has loaded (nil: nothing, and the Menu
    /// does not offer it) and its transport. Both wired by AppState.
    var nowPlaying: (() -> HUDNowPlaying?)?
    var mediaTransport: ((HUDMediaAction) -> Void)?
    /// How long after a transport press the card is drawn again, so it shows the new state.
    var mediaRefreshDelay: TimeInterval = 0.4
    /// Test seam: run `body` after `delay` (production sleeps on the main actor).
    var after: (_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Void = { delay, body in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            body()
        }
    }

    /// Plan KX §6: the wearer's Home Assistant quick actions (empty: the Menu does not offer Home)
    /// and how one runs. Both wired by AppState.
    var homeFavourites: (() -> [QuickAction])?
    var runHomeFavourite: ((QuickAction) async -> HomeFavouriteOutcome)?
    /// Where a run's line goes (the lens's `flash`). Wired by AppState.
    var flashLine: ((String) -> Void)?

    init(router: HUDRouter) {
        self.router = router
    }

    /// Open the launcher at its root: the Today glance, or (with no `today` source) the branch
    /// list. No-op when neither has anything to show.
    func open() {
        if let glance = today?() {
            router.openLauncher(todayScreen(glance))
            return
        }
        let branches = rootBranches()
        guard !branches.isEmpty else { return }
        router.openLauncher(menuScreen(branches))
    }

    /// Whether the launcher would have anything to show (used to gate the open trigger).
    var hasContent: Bool { today?() != nil || !rootBranches().isEmpty }

    /// Recognise the spoken phrase that opens the launcher.
    static func isOpenCommand(_ text: String) -> Bool {
        ["menu", "show menu", "open menu", "open the menu", "hud menu"].contains(normalize(text))
    }

    /// Plan KX §4: the spoken phrase that asks for the Today glance on the lens. Whole-phrase only,
    /// so "what's on my day tomorrow" still reaches the assistant.
    static func isTodayCommand(_ text: String) -> Bool {
        ["show my day", "show me my day", "show today", "show me today"].contains(normalize(text))
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

    /// L0 (Plan KX §4): the Today glance and its items. Each item is offered only when it has
    /// something to do, read now: a digest to show, a task card to go back to, a recent destination,
    /// a branch in the Menu.
    private func todayScreen(_ glance: HUDTodayGlance) -> HUDScreen {
        var actions = HUDTodayBuilder.Actions(close: { [weak self] in self?.router.dismiss() })
        if digestHasContent?() == true {
            actions.whatsNew = { [weak self] in self?.openDigest?() }
        }
        if router.isPresentingTask {
            actions.resume = { [weak self] in self?.router.resumeTask() }
        }
        if !(recentDestinations?() ?? []).isEmpty {
            actions.navigate = { [weak self] in
                guard let self else { return }
                self.router.push(self.navigateScreen())
            }
        }
        if !rootBranches().isEmpty {
            actions.menu = { [weak self] in
                guard let self else { return }
                // Built when pressed, so it lists what is available then.
                self.router.push(self.menuScreen(self.rootBranches()))
            }
        }
        return HUDTodayBuilder.screen(glance, actions: actions)
    }

    /// The branch list: L0 without a Today source, else what Today's **Menu** opens. Its Close
    /// closes the launcher; "back" by voice returns to Today.
    private func menuScreen(_ branches: [HUDItem]) -> HUDScreen {
        HUDMenuBuilder.root(branches: branches, onClose: { [weak self] in
            self?.router.dismiss()
        })
    }

    private func rootBranches() -> [HUDItem] {
        var branches: [HUDItem] = []

        // Resume the active Plan X task card — only while one is running.
        if router.isPresentingTask {
            branches.append(HUDItem(id: "branch:resume", label: "Resume task", icon: .navigation, style: .primary) { [weak self] in
                self?.router.resumeTask()
            })
        }
        // Plan BZ: the digest glance — only when it would show something.
        if digestHasContent?() == true {
            branches.append(HUDItem(id: "branch:digest", label: "What's new", icon: .info, style: .primary) { [weak self] in
                self?.openDigest?()
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
        // Plan CA: walk-again to a recent destination.
        if !(recentDestinations?() ?? []).isEmpty {
            branches.append(HUDItem(id: "branch:navigate", label: "Navigate", icon: .navigation, style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.navigateScreen())
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

        // Plan KX §6: the Now Playing card, while the Music app has something loaded.
        if nowPlaying?() != nil {
            branches.append(HUDItem(id: "branch:media", label: HUDNowPlayingBuilder.title, icon: .music,
                                    style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.nowPlayingScreen())
            })
        }
        // Plan KX §6: the Home Assistant favourites, while there are any.
        if !(homeFavourites?() ?? []).isEmpty {
            branches.append(HUDItem(id: "branch:home", label: HUDHomeFavouritesBuilder.title, icon: .location,
                                    style: .secondary) { [weak self] in
                guard let self else { return }
                self.router.push(self.homeScreen(page: 0))
            })
        }

        // Plan KP §5: the band check, last before Close.
        if bandPracticeAvailable?() == true {
            branches.append(HUDItem(id: "branch:band", label: BandPracticeCardBuilder.title,
                                    icon: .info, style: .secondary) { [weak self] in
                self?.startBandPractice?()
            })
        }

        return branches
    }

    // MARK: - Now Playing and Home (Plan KX §6)

    /// The Now Playing card as it stands now.
    func nowPlayingScreen() -> HUDScreen {
        HUDNowPlayingBuilder.screen(nowPlaying?()) { [weak self] action in
            self?.media(action)
        }
    }

    private func media(_ action: HUDMediaAction) {
        guard action != .close else {
            router.dismiss()
            return
        }
        mediaTransport?(action)
        // Drawn again once the player has moved, and only while the card is still the top screen.
        after(mediaRefreshDelay) { [weak self] in
            guard let self, HUDNowPlayingBuilder.isNowPlaying(self.router.currentScreen) else { return }
            self.router.replaceTop(self.nowPlayingScreen())
        }
    }

    /// The Home list's page `page`.
    func homeScreen(page: Int) -> HUDScreen {
        HUDHomeFavouritesBuilder.screen(
            homeFavourites?() ?? [], page: page,
            onRun: { [weak self] action in self?.runHome(action) },
            onMore: { [weak self] next in
                guard let self else { return }
                self.router.push(self.homeScreen(page: next))
            },
            onBack: { [weak self] in self?.router.pop() },
            onClose: { [weak self] in self?.router.dismiss() })
    }

    private func runHome(_ action: QuickAction) {
        guard let runHomeFavourite else { return }
        let label = action.label
        Task { @MainActor [weak self] in
            let outcome = await runHomeFavourite(action)
            self?.flashLine?(HUDHomeFavouritesBuilder.line(for: outcome, label: label))
        }
    }

    private func playbooks() -> [Playbook] { availablePlaybooks?() ?? [] }
    private func procedures() -> [Procedure] { availableProcedures?() ?? [] }
    private func isFieldAssistActive() -> Bool { fieldAssistActive?() ?? false }

    /// Recent destinations as a band-selectable list (Plan CA). Five recents fit one screen.
    private func navigateScreen() -> HUDScreen {
        var items = (recentDestinations?() ?? []).prefix(4).enumerated().map { index, name in
            HUDItem(id: "nav:\(index)", label: name, icon: .navigation, style: .primary) { [weak self] in
                self?.startNavigation?(name)
                self?.router.dismiss()
            }
        }
        items.append(HUDItem(id: "back", label: "Back", style: .outline) { [weak self] in
            self?.router.pop()
        })
        return HUDScreen(title: "Navigate", lines: [], items: items)
    }

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
