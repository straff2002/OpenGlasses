import Foundation
import Combine

/// Owns the interactive HUD (Display Phase 3 / Plan X): given a `HUDTaskSource`, it
/// renders the Now/Next card, routes Neural-Band selections back to the source, and
/// re-renders whenever the source changes. The full launcher ([Plan Y](../../../docs/plans/Y-interactive-hud-launcher.md))
/// will reuse this router with a screen *stack*; Phase 3 is a single task card.
@MainActor
final class HUDRouter: ObservableObject {
    private let display: GlassesDisplayService

    private var taskSource: HUDTaskSource?
    /// The interactive screen the router is currently driving (task card or menu), or
    /// nil when none. Published so the on-phone live mirror (`HUDMirrorView`) tracks it.
    @Published private(set) var currentScreen: HUDScreen?
    private var cancellable: AnyCancellable?

    /// Whether a task card is currently being driven on the HUD.
    @Published private(set) var isPresentingTask = false

    /// The answer card (Plan KP P1), whose paging words this router takes while it is the
    /// frame on the glasses. Set by AppState.
    weak var answerCard: HUDAnswerCard?

    /// The page view (Plan KV), whose words (`HUDPageCommand`) this router takes while it is on the
    /// glasses. Set by AppState.
    weak var pageView: LensPageSession?

    /// Whether the page view, or its **Show here** cue, is pushed over the HUD (Plan KV §4).
    @Published private(set) var isPresentingPage = false

    init(display: GlassesDisplayService) {
        self.display = display
    }

    // MARK: - Task presentation

    /// Begin driving `source` as a Now/Next card. Re-renders on every source change.
    /// Starting a task supersedes any open launcher menu (Plan Y) — the card takes the HUD.
    func startTask(_ source: HUDTaskSource) {
        screenStack = []
        isPresentingMenu = false
        isPresentingPage = false
        resetCards()
        taskSource = source
        cancellable = source.changes.sink { [weak self] _ in
            // Defer to the next main-actor tick so the source reflects the new step.
            Task { @MainActor in self?.refresh() }
        }
        isPresentingTask = true
        refresh()
    }

    /// Stop driving the current task and return the HUD to its ambient producers.
    func stopTask() {
        clearTaskState()
        // Plan KT: the day's cards opened over the task stay up; Close then clears the lens.
        guard !isPresentingCards else { return }
        currentScreen = nil
        display.endInteractive()
    }

    /// Drop the active task's source/subscription without touching the HUD. Used both by
    /// `stopTask` and by `refresh` when a workflow finishes underneath an open menu.
    private func clearTaskState() {
        cancellable = nil
        taskSource = nil
        isPresentingTask = false
    }

    private func refresh() {
        guard let source = taskSource else { return }
        guard let current = source.current else {
            // Workflow finished.
            let title = source.title
            if isPresentingMenu || isPresentingCards {
                // A launcher menu (or the day's cards) is overlaying the card — leave it up; just drop the now
                // stale task so "Resume task" stops offering a finished card.
                clearTaskState()
            } else {
                stopTask()
                display.flash("✓ \(title) complete")
            }
            return
        }
        // Don't render the card over an open launcher menu, the page view pushed over it, or the
        // day's cards (Plan KT); it re-renders on resume/close.
        guard !isPresentingMenu, !isPresentingPage, !isPresentingCards else { return }
        // Plan LC §6: a step's clip is offered only where the lens can play it.
        let onWatch: ((HUDVideo) -> Void)? = display.playsVideo ? { [weak self] video in self?.watch(video) } : nil
        let screen = Self.taskCard(source: source, current: current, next: source.next, onWatch: onWatch)
        currentScreen = screen
        display.present(screen: screen) { [weak self] id in
            self?.handleSelection(id)
        }
    }

    private func handleSelection(_ id: String) {
        guard let item = currentScreen?.items.first(where: { $0.id == id }) else { return }
        item.action()
    }

    /// Plan LC §6: play the step's clip over the task card. The card comes back when it ends; a clip
    /// the glasses would not play says so in a short line over the card.
    private func watch(_ video: HUDVideo) {
        display.playVideo(video) { [weak self] ending in
            guard ending == .failed else { return }
            self?.display.flash(String(localized: "Couldn't play that clip",
                                       comment: "Glasses: a Field Assist step's clip did not play."), duration: 3)
        }
    }

    /// Plan LC §6: the words that stop a clip while it plays (the clip has no buttons, and the
    /// band's Back would end the whole display session).
    static func isStopClipCommand(_ text: String) -> Bool {
        ["stop", "stop video", "stop the video", "stop clip", "stop the clip", "close", "back", "done"]
            .contains(HUDLauncher.normalize(text))
    }

    /// Voice leg of the band+voice+phone input model: while a task card is active,
    /// "next/done/skip/back" drive the source, and on a decision step a spoken branch
    /// label selects that branch (Plan AH — on EVEN there is no band, so without this
    /// decision workflows dead-end; same conservative matching discipline as the
    /// launcher: exact label, else unique substring, ambiguity is a no-op). Returns
    /// `true` if it consumed the utterance (so the caller doesn't also send it to the
    /// LLM). No-op otherwise.
    @discardableResult
    func handleVoiceCommand(_ text: String) async -> Bool {
        // Plan LC §6: while a step's clip plays, "stop" (or "back", "close", "done") stops it and
        // brings the card back, rather than moving the step under it.
        if display.showsVideo, Self.isStopClipCommand(text) {
            display.stopVideo()
            return true
        }
        // Plan KV §3: the page view's words, consulted only while the view is on the glasses. A
        // word with nothing to do ("next page" on the last one) goes on: to the task card under the
        // view, or to the model.
        if isPresentingPage, let pageView, pageView.isViewOnLens,
           let command = HUDPageCommand.parse(text), pageView.handle(command) {
            return true
        }
        // Plan KT §6.2: the cards' words, only while the stack is on the glasses. A word with
        // nothing to do ("next card" on the last one) goes on to the model.
        if isPresentingCards, !isPresentingPage, let command = PreparedCardVoiceCommand.parse(text) {
            return handleCardCommand(command)
        }
        // Plan KP: an answer card's paging words, consulted only while the card is the frame on
        // the glasses — never over a task card, where "next" means the step is done.
        // A word with nothing to do ("next" on the last page) is left to the model.
        if !isPresentingTask, !isPresentingMenu, let card = answerCard, card.isShowing,
           let command = HUDAnswerVoiceCommand.parse(text) {
            let action: HUDAnswerAction
            switch command {
            case .next: action = .next
            case .back: action = .back
            case .close: action = .close
            }
            if card.canTurn(action) {
                card.press(action)
                return true
            }
        }
        guard isPresentingTask, let source = taskSource else { return false }
        if let command = HUDVoiceCommand.parse(text) {
            switch command {
            case .complete: await source.complete()
            case .skip: await source.skip()
            case .back: await source.back()
            case .briefing: return false   // global (digest) command — the app-level handler owns it
            }
            return true
        }

        let choices = source.choices
        guard !choices.isEmpty else { return false }
        let phrase = HUDLauncher.normalize(text)
        guard !phrase.isEmpty else { return false }
        if let exact = choices.first(where: { HUDLauncher.normalize($0.label) == phrase }) {
            await source.choose(exact.id)
            return true
        }
        let matches = choices.filter { HUDLauncher.normalize($0.label).contains(phrase) }
        if matches.count == 1 {
            await source.choose(matches[0].id)
            return true
        }
        return false
    }

    // MARK: - Launcher screen stack (Display Phase 4 / Plan Y)

    private var screenStack: [HUDScreen] = []

    /// Whether a launcher menu is currently on the HUD.
    @Published private(set) var isPresentingMenu = false

    /// Present `root` as the base of a fresh navigation stack.
    func openLauncher(_ root: HUDScreen) {
        isPresentingPage = false
        resetCards()
        screenStack = [root]
        isPresentingMenu = true
        renderTop()
    }

    /// Push a child screen onto the stack (a category submenu).
    func push(_ screen: HUDScreen) {
        screenStack.append(screen)
        renderTop()
    }

    /// Pop the top screen; dismiss the launcher when the stack empties.
    func pop() {
        guard !screenStack.isEmpty else { return }
        screenStack.removeLast()
        if screenStack.isEmpty { dismiss() } else { renderTop() }
    }

    /// Close the launcher menu. If a task card was running underneath (the menu was opened
    /// over it), return to that card; otherwise return the HUD to its ambient producers.
    func dismiss() {
        screenStack = []
        isPresentingMenu = false
        if isPresentingTask {
            refresh()   // re-present the task card the menu was overlaying
        } else {
            currentScreen = nil
            display.endInteractive()
        }
    }

    /// Re-present the active task card, closing any open launcher menu. Backs the "Resume
    /// task" root item (Plan Y). No-op when no task is running.
    func resumeTask() {
        guard isPresentingTask else { return }
        screenStack = []
        isPresentingMenu = false
        refresh()
    }

    /// Plan LC §6: redraw the top screen in place (the Now Playing card after a press), without
    /// growing the stack. Nothing when no menu is open.
    func replaceTop(_ screen: HUDScreen) {
        guard isPresentingMenu, !screenStack.isEmpty else { return }
        screenStack[screenStack.count - 1] = screen
        renderTop()
    }

    /// Depth of the live menu stack (0 when closed). Exposed for tests.
    var menuDepth: Int { screenStack.count }

    private func renderTop() {
        guard let top = screenStack.last else { return }
        isPresentingPage = false
        currentScreen = top
        display.present(screen: top) { [weak self] id in self?.handleSelection(id) }
    }

    // MARK: - The page view (Plan KV §4)

    /// Push the page view, or its cue, over whatever the HUD holds: an answer card, a task card, a
    /// menu, or nothing. False when the lens can't take it (the HUD off, no display, or another app
    /// has the Display).
    @discardableResult
    func presentPage(_ screen: HUDScreen, kind: GlassesDisplayService.HeldPage,
                     onSelect: @escaping (String) -> Void) -> Bool {
        guard display.presentPageView(screen, kind: kind, onSelect: onSelect) else { return false }
        isPresentingPage = true
        currentScreen = screen
        return true
    }

    /// The page view's next frame, after a press issued against `revision`; dropped when another
    /// frame was enqueued since.
    @discardableResult
    func updatePage(_ screen: HUDScreen, issuedAgainst revision: UInt64,
                    onSelect: @escaping (String) -> Void) -> Bool {
        guard isPresentingPage,
              display.updatePageView(screen, issuedAgainst: revision, onSelect: onSelect) else { return false }
        currentScreen = screen
        return true
    }

    /// Close the page view and return to what was under it: the open menu, the task card, the
    /// answer card, or nothing.
    func closePage() {
        guard isPresentingPage else { return }
        isPresentingPage = false
        if isPresentingMenu {
            display.releasePageView()
            renderTop()
        } else if isPresentingCards {
            display.releasePageView()
            redrawCards()
        } else if isPresentingTask {
            display.releasePageView()
            refresh()
        } else {
            currentScreen = nil
            display.endPageView()
        }
    }

    /// Something else took the lens from the page view; nothing is redrawn.
    func pageLost() {
        isPresentingPage = false
    }

    // MARK: - The day's cards (Plan KT §6)

    /// The day's prepared cards on the lens, one at a time (Plan KT §6.3): **Next ›** through
    /// them, a card's draft a page at a time, **Send on phone** to stage it. Pulled only — the
    /// launcher's **Ready**, "what's ready", a temple tap — so it is the wearer's, and like a menu it
    /// goes over a running task card and gives the lens back to it on **Close**.
    ///
    /// Every press is issued against the frame it was made on (`heldScreenRevision`) and checked
    /// through `PageTurnGate`; a press under a notification, or on a card that has since expired
    /// or changed on the lens, is dropped and the stack is drawn again as it now is.
    @Published private(set) var isPresentingCards = false
    /// What the stack reads and does. Wired by AppState; nil offers nothing.
    var cardHooks: PreparedCardLensHooks?
    /// The page shape, from the active backend.
    var cardGeometry: () -> TeleprompterPaginator.Geometry = HUDAnswerCard.activeGeometry

    private var cardIndex = 0
    private var cardShownID: PreparedCardID?
    /// The draft's page on the lens, or nil on the card itself.
    private(set) var cardDraftPage: Int?
    /// The `renderKey` of the stack's frame as last drawn: a press on a card whose screen would
    /// now differ was made on an older version of it.
    private var cardScreenKey: String?

    /// The card the stack shows, if it is up.
    var shownCardID: PreparedCardID? { isPresentingCards ? cardShownID : nil }

    /// Whether there are cards to open.
    var hasCards: Bool { !(cardHooks?.cards().isEmpty ?? true) }

    /// Open the stack at `id` (or the first card). False — and nothing changes — with no cards.
    @discardableResult
    func openCards(at id: PreparedCardID? = nil) -> Bool {
        guard let cards = cardHooks?.cards(), !cards.isEmpty else { return false }
        screenStack = []
        isPresentingMenu = false
        isPresentingPage = false
        isPresentingCards = true
        cardIndex = id.flatMap { target in cards.firstIndex { $0.id == target } } ?? 0
        cardShownID = cards[cardIndex].id
        cardDraftPage = nil
        renderCards(cards)
        return true
    }

    /// Close the stack and give the lens back: to the task card it went over, or to nothing.
    func closeCards() {
        guard isPresentingCards else { return }
        resetCards()
        if isPresentingTask {
            refresh()
        } else {
            currentScreen = nil
            display.endInteractive()
        }
    }

    /// The feed changed (a refresh, an action on the phone, a model's draft): the stack is drawn
    /// again only if what it shows has changed, and closes when no card is left.
    func cardsChanged() {
        guard isPresentingCards, !isPresentingPage else { return }
        guard let cards = cardHooks?.cards(), !cards.isEmpty else {
            closeCards()
            return
        }
        settleCardIndex(cards)
        guard cardScreen(cards)?.renderKey != cardScreenKey else { return }
        renderCards(cards)
    }

    /// A band press, issued against the frame as last drawn.
    func pressCard(_ press: PreparedCardLensPress) {
        pressCard(press, issuedAgainst: display.heldScreenRevision)
    }

    /// A press issued against `revision`. Stale (a frame was enqueued since), or made on a card
    /// that has expired or changed: dropped, and the stack drawn again.
    func pressCard(_ press: PreparedCardLensPress, issuedAgainst revision: UInt64) {
        guard isPresentingCards, let hooks = cardHooks else { return }
        guard display.acceptsHeldScreenPress(issuedAgainst: revision) else {
            redrawCards()
            return
        }
        let cards = hooks.cards()
        guard let position = cards.firstIndex(where: { $0.id == press.cardID }), press.cardID == cardShownID,
              cardScreen(cards)?.renderKey == cardScreenKey else {
            redrawCards()
            return
        }
        let card = cards[position]
        hooks.notePress(press.action)
        switch press.action {
        case .run(let action):
            hooks.run(action, card)
            cardsChanged()
        case .draft:
            guard card.draft != nil else { return }
            cardDraftPage = 0
            renderCards(cards)
        case .nextCard:
            guard position + 1 < cards.count else { return }
            show(cards, at: position + 1)
        case .previousCard:
            guard position > 0 else { return }
            show(cards, at: position - 1)
        case .close:
            closeCards()
        case .nextPage:
            guard let page = cardDraftPage,
                  page + 1 < PreparedCardHUDBuilder.draftPages(card, geometry: cardGeometry()).count else { return }
            cardDraftPage = page + 1
            renderCards(cards)
        case .back:
            guard let page = cardDraftPage else { return }
            cardDraftPage = page > 0 ? page - 1 : nil
            renderCards(cards)
        case .sendOnPhone:
            stage(card, cards: cards, position: position)
        case .readIt:
            if let text = card.draft?.text { hooks.readAloud(text) }
        case .later:
            hooks.later(card)
            cardsChanged()
        case .dismiss:
            hooks.dismiss(card)
            cardsChanged()
        case .notUseful:
            hooks.notUseful(card)
            cardsChanged()
        case .open:
            break
        }
    }

    /// §6.4: the draft goes to the phone, a three-second line says where, and the stack moves on
    /// to the next card (or closes after the last).
    private func stage(_ card: PreparedCard, cards: [PreparedCard], position: Int) {
        guard card.draft != nil, let hooks = cardHooks else { return }
        if position + 1 < cards.count {
            show(cards, at: position + 1)
        } else {
            closeCards()
        }
        Task { @MainActor [weak self] in
            let outcome = await hooks.stage(card)
            guard outcome != .nothingToStage else { return }
            self?.display.flash(outcome == .openedComposer ? PreparedCardHUDBuilder.stagedOpenLine
                                                           : PreparedCardHUDBuilder.stagedLine, duration: 3)
        }
    }

    /// A spoken word, while the stack is up. False when it has nothing to do.
    private func handleCardCommand(_ command: PreparedCardVoiceCommand) -> Bool {
        guard let cards = cardHooks?.cards(), !cards.isEmpty else { return false }
        settleCardIndex(cards)
        let card = cards[cardIndex]
        let onDraft = cardDraftPage != nil
        let action: PreparedCardLensAction
        switch command {
        case .next:
            if let page = cardDraftPage {
                guard page + 1 < PreparedCardHUDBuilder.draftPages(card, geometry: cardGeometry()).count else { return false }
                action = .nextPage
            } else {
                guard cardIndex + 1 < cards.count else { return false }
                action = .nextCard
            }
        case .nextCard:
            guard cardIndex + 1 < cards.count else { return false }
            action = .nextCard
        case .back:
            if onDraft {
                action = .back
            } else {
                guard cardIndex > 0 else { return false }
                action = .previousCard
            }
        case .later: action = .later
        case .notUseful: action = .notUseful
        case .dismiss: action = .dismiss
        case .close: action = .close
        case .readIt:
            guard card.draft != nil else { return false }
            action = .readIt
        case .sendOnPhone:
            guard card.draft != nil else { return false }
            action = .sendOnPhone
        }
        pressCard(PreparedCardLensPress(action: action, cardID: card.id))
        return true
    }

    private func show(_ cards: [PreparedCard], at index: Int) {
        cardIndex = index
        cardShownID = cards[index].id
        cardDraftPage = nil
        renderCards(cards)
    }

    /// Draw the stack again from the feed as it is now.
    private func redrawCards() {
        guard isPresentingCards else { return }
        guard let cards = cardHooks?.cards(), !cards.isEmpty else {
            closeCards()
            return
        }
        settleCardIndex(cards)
        renderCards(cards)
    }

    /// Keep the card that was shown when it is still there; otherwise the one that took its
    /// place, and back to the card itself from its draft.
    private func settleCardIndex(_ cards: [PreparedCard]) {
        if let id = cardShownID, let index = cards.firstIndex(where: { $0.id == id }) {
            cardIndex = index
        } else {
            cardIndex = min(max(cardIndex, 0), cards.count - 1)
            cardShownID = cards[cardIndex].id
            cardDraftPage = nil
        }
    }

    private func cardScreen(_ cards: [PreparedCard]) -> HUDScreen? {
        guard cards.indices.contains(cardIndex) else { return nil }
        let geometry = cardGeometry()
        let onPress: (PreparedCardLensPress) -> Void = { [weak self] press in self?.pressCard(press) }
        if let page = cardDraftPage,
           let draft = PreparedCardHUDBuilder.draft(cards[cardIndex], page: page, geometry: geometry, onPress: onPress) {
            return draft
        }
        return PreparedCardHUDBuilder.stack(cards, index: cardIndex, geometry: geometry, onPress: onPress)
    }

    private func renderCards(_ cards: [PreparedCard]) {
        guard let screen = cardScreen(cards) else {
            closeCards()
            return
        }
        cardScreenKey = screen.renderKey
        currentScreen = screen
        display.present(screen: screen) { [weak self] id in self?.handleSelection(id) }
    }

    private func resetCards() {
        isPresentingCards = false
        cardIndex = 0
        cardShownID = nil
        cardDraftPage = nil
        cardScreenKey = nil
    }

    // MARK: - Card layout

    /// Plan LC §6: the task card's **Watch** item.
    static let watchItemID = "lc.task.watch"

    /// Build the Now/Next card. `static` and pure so it's unit-testable without a device.
    ///
    /// Plan LC §6: `onWatch`, when given and the step has a clip, adds **Watch** before Back.
    static func taskCard(source: HUDTaskSource, current: HUDStep, next: HUDStep?,
                         onWatch: ((HUDVideo) -> Void)? = nil) -> HUDScreen {
        var lines: [HUDLine] = []

        if let total = current.total {
            lines.append(HUDLine("Step \(current.index + 1) of \(total)", emphasis: .meta))
        }
        if let instruction = current.instruction, !instruction.isEmpty {
            lines.append(HUDLine(instruction, emphasis: .secondary))
        }
        if let safety = current.safetyNote, !safety.isEmpty {
            lines.append(HUDLine(safety, icon: .hazard, emphasis: .secondary))
        }
        if let next {
            lines.append(HUDLine("Next: \(next.title)", emphasis: .meta))
        }

        // A decision step renders one button per branch (+ Back); a linear step
        // renders Done / Skip / Back.
        let choices = source.choices
        var items: [HUDItem]
        if choices.isEmpty {
            items = [
                HUDItem(id: "done", label: "Done", icon: .success, style: .primary) {
                    Task { await source.complete() }
                },
                HUDItem(id: "skip", label: "Skip", style: .secondary) {
                    Task { await source.skip() }
                },
            ]
        } else {
            items = choices.map { choice in
                HUDItem(id: "choice:\(choice.id)", label: choice.label, style: .primary) {
                    Task { await source.choose(choice.id) }
                }
            }
        }
        if let video = current.video, let onWatch {
            items.append(HUDItem(id: watchItemID,
                                 label: String(localized: "Watch", comment: "Glasses: plays a Field Assist step's clip."),
                                 icon: .video, style: .secondary) { onWatch(video) })
        }
        items.append(HUDItem(id: "back", label: "Back", style: .outline) {
            Task { await source.back() }
        })

        return HUDScreen(title: current.title, lines: lines, items: items)
    }
}

/// What the day's cards on the lens read and do (Plan KT P3). Wired by AppState onto
/// `MyDayService`, `PreparedCardStager` and the speech service.
struct PreparedCardLensHooks {
    /// The feed's cards now, ranked (`MyDayService.todayFeed.cards`).
    var cards: () -> [PreparedCard]
    /// One of a card's own actions, run as the phone runs it (directions, an open, done).
    var run: (PreparedAction, PreparedCard) -> Void
    /// §6.4: stage the card's draft on the phone.
    var stage: (PreparedCard) async -> PreparedCardStager.Outcome
    /// **Read it**: say the draft. Plan KT P4's phraser takes this over for the card itself.
    var readAloud: (String) -> Void
    var later: (PreparedCard) -> Void
    var dismiss: (PreparedCard) -> Void
    var notUseful: (PreparedCard) -> Void
    /// §10: counts a press by button.
    var notePress: (PreparedCardLensAction) -> Void = { _ in }
}

/// The words that drive the day's cards while they are on the lens (Plan KT §6.2). Strict and
/// whole-phrase, with the same filler tolerance as the other HUD words, and consulted only while
/// the stack is up — so "later" in a sentence, or with nothing on the lens, still reaches the model.
enum PreparedCardVoiceCommand: Equatable {
    /// "next": the draft's next page, or the next card.
    case next
    case nextCard
    case back
    case later
    case notUseful
    case dismiss
    case close
    case readIt
    case sendOnPhone

    static func parse(_ text: String) -> PreparedCardVoiceCommand? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ").map(String.init)
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        while let last = core.last, last == "please" { core.removeLast() }
        switch core.joined(separator: " ") {
        case "next", "next page": return .next
        case "next card", "skip", "skip it", "skip this", "next one": return .nextCard
        case "back", "go back", "previous", "previous card", "last card": return .back
        case "later", "later please", "not now", "remind me later": return .later
        case "not useful", "thats not useful", "that is not useful", "not helpful": return .notUseful
        case "dismiss", "dismiss it", "dismiss that": return .dismiss
        case "close", "close it", "close that", "clear", "done": return .close
        case "read it", "read it out", "read it to me", "read the message", "read me the message": return .readIt
        case "send it on my phone", "send it on the phone", "send on my phone", "send on phone",
             "send it on phone", "put it on my phone", "send it from my phone":
            return .sendOnPhone
        default: return nil
        }
    }
}
