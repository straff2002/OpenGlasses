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

    init(display: GlassesDisplayService) {
        self.display = display
    }

    // MARK: - Task presentation

    /// Begin driving `source` as a Now/Next card. Re-renders on every source change.
    func startTask(_ source: HUDTaskSource) {
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
        cancellable = nil
        taskSource = nil
        currentScreen = nil
        isPresentingTask = false
        display.endInteractive()
    }

    private func refresh() {
        guard let source = taskSource else { return }
        guard let current = source.current else {
            // Workflow finished → confirmation flash, then back to ambient.
            let title = source.title
            stopTask()
            display.flash("✓ \(title) complete")
            return
        }
        let screen = Self.taskCard(source: source, current: current, next: source.next)
        currentScreen = screen
        display.present(screen: screen) { [weak self] id in
            self?.handleSelection(id)
        }
    }

    private func handleSelection(_ id: String) {
        guard let item = currentScreen?.items.first(where: { $0.id == id }) else { return }
        item.action()
    }

    /// Voice leg of the band+voice+phone input model: while a task card is active,
    /// "next/done/skip/back" drive the source. Returns `true` if it consumed the
    /// utterance (so the caller doesn't also send it to the LLM). No-op otherwise.
    @discardableResult
    func handleVoiceCommand(_ text: String) async -> Bool {
        guard isPresentingTask, let source = taskSource,
              let command = HUDVoiceCommand.parse(text) else { return false }
        switch command {
        case .complete: await source.complete()
        case .skip: await source.skip()
        case .back: await source.back()
        }
        return true
    }

    // MARK: - Launcher screen stack (Display Phase 4 / Plan Y)

    private var screenStack: [HUDScreen] = []

    /// Whether a launcher menu is currently on the HUD.
    @Published private(set) var isPresentingMenu = false

    /// Present `root` as the base of a fresh navigation stack.
    func openLauncher(_ root: HUDScreen) {
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

    /// Close the launcher entirely and return the HUD to its ambient producers.
    func dismiss() {
        screenStack = []
        currentScreen = nil
        isPresentingMenu = false
        display.endInteractive()
    }

    /// Depth of the live menu stack (0 when closed). Exposed for tests.
    var menuDepth: Int { screenStack.count }

    private func renderTop() {
        guard let top = screenStack.last else { return }
        currentScreen = top
        display.present(screen: top) { [weak self] id in self?.handleSelection(id) }
    }

    // MARK: - Card layout

    /// Build the Now/Next card. `static` and pure so it's unit-testable without a device.
    static func taskCard(source: HUDTaskSource, current: HUDStep, next: HUDStep?) -> HUDScreen {
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
        items.append(HUDItem(id: "back", label: "Back", style: .outline) {
            Task { await source.back() }
        })

        return HUDScreen(title: current.title, lines: lines, items: items)
    }
}
