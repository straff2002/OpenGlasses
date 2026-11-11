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
            if isPresentingMenu {
                // A launcher menu is overlaying the card — leave it up; just drop the now
                // stale task so "Resume task" stops offering a finished card.
                clearTaskState()
            } else {
                stopTask()
                display.flash("✓ \(title) complete")
            }
            return
        }
        // Don't render the card over an open launcher menu, or the page view pushed over it; it
        // re-renders on resume/close.
        guard !isPresentingMenu, !isPresentingPage else { return }
        // Plan KX §6: a step's clip is offered only where the lens can play it.
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

    /// Plan KX §6: play the step's clip over the task card. The card comes back when it ends; a clip
    /// the glasses would not play says so in a short line over the card.
    private func watch(_ video: HUDVideo) {
        display.playVideo(video) { [weak self] ending in
            guard ending == .failed else { return }
            self?.display.flash(String(localized: "Couldn't play that clip",
                                       comment: "Glasses: a Field Assist step's clip did not play."), duration: 3)
        }
    }

    /// Plan KX §6: the words that stop a clip while it plays (the clip has no buttons, and the
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
        // Plan KX §6: while a step's clip plays, "stop" (or "back", "close", "done") stops it and
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

    /// Plan KX §6: redraw the top screen in place (the Now Playing card after a press), without
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

    // MARK: - Card layout

    /// Plan KX §6: the task card's **Watch** item.
    static let watchItemID = "kx.task.watch"

    /// Build the Now/Next card. `static` and pure so it's unit-testable without a device.
    ///
    /// Plan KX §6: `onWatch`, when given and the step has a clip, adds **Watch** before Back.
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
