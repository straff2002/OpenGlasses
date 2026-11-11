import Combine
import Foundation

/// The approval card on the glasses (Plan LC §3): the shared consent surface's ask (BN P1), held on
/// the lens until it is answered.
///
/// **What it replaces.** The lens half of an approval was a ten-second ambient "Approve?" line the
/// next frame could replace. Now, while the HUD is on and a display or the web mirror can show it
/// (`GlassesDisplayService.acceptsApprovalCard`), an approve/deny ask is a held card built by
/// `HUDApprovalCardBuilder`: the action as the heading, who asks, one preview line, and **Approve**
/// (primary, focused) · **Deny** · **Details** (when there is more). A text-reply ask (Plan FE P1)
/// is not approve/deny, so it keeps the old line, as does any ask the lens cannot hold (the HUD off,
/// another app has the Display, the wearer dismissed the lens).
///
/// **How it is answered.** By the band (Approve / Deny on the card), by voice (the coordinator's
/// `resolveByVoice`, unchanged), or on the phone's consent card. The card watches the coordinator's
/// `pending`, so whichever answers, the card closes. A band press is issued against the card as
/// last drawn: one made while a notification is over it is stale and dropped
/// (`acceptsHeldScreenPress`). A temple tap never answers it: the temple taps have no approval
/// effect (`TempleActionResolver`), and this card takes no press from them.
///
/// **Timeout (decision 4).** A card on the lens that is not answered within `timeout` (20 s) is
/// denied: the coordinator resolves Deny, which the tool router records as a decline like any
/// other. The timeout belongs to the card: an ask the lens could not hold waits on the phone as
/// before.
///
/// **What was under it.** The service keeps the held screen (a task card, a menu, an answer card,
/// the turn's card, a page view) and restores it when the card ends; with nothing held, the lens
/// clears.
@MainActor
final class HUDApprovalCard {
    /// Plan LC decision 4: an unanswered card denies after this long. Twice the old line's ten
    /// seconds, so the preview can be read and answered by voice after the prompt is spoken, and
    /// inside the 25 s the Display's panel stays awake.
    static let defaultTimeout: TimeInterval = 20

    private let display: GlassesDisplayService
    private let coordinator: ToolConfirmationCoordinator
    private var subscription: AnyCancellable?

    /// Test seam: the timeout.
    var timeout: TimeInterval = HUDApprovalCard.defaultTimeout
    /// Test seam: run `fire` after `delay`. Production sleeps on the main actor; a test captures
    /// the timer and fires it, so the timeout is checked without racing the clock.
    var scheduleTimeout: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    /// The ask on the lens, by the coordinator's id. Nil when no card is up.
    private(set) var askOnLens: UUID?
    private var summary = ""
    private var source: RemoteActionSource = .assistant
    private(set) var isOnDetails = false
    /// The screen last handed to the display, buttons and all: what a band press acts on. Read by
    /// tests.
    private(set) var screenOnLens: HUDScreen?
    private var timeoutGeneration = 0

    init(display: GlassesDisplayService, coordinator: ToolConfirmationCoordinator) {
        self.display = display
        self.coordinator = coordinator
    }

    /// Start watching the coordinator. `$pending` publishes in willSet, so the new value is taken
    /// from the sink, never read back from the coordinator.
    func start() {
        subscription = coordinator.$pending.sink { [weak self] pending in
            self?.pendingChanged(pending)
        }
    }

    /// The card is on the glasses (or held under a notification).
    var isShowing: Bool { askOnLens != nil && display.showsApprovalCard }

    private func pendingChanged(_ pending: PendingToolConfirmation?) {
        guard let pending else {
            close()
            return
        }
        guard pending.id != askOnLens else { return }
        show(pending)
    }

    private func show(_ pending: PendingToolConfirmation) {
        // A text-reply ask is answered in words, never by Approve: it keeps the line.
        guard !pending.reply.isText, display.acceptsApprovalCard else {
            showLine(for: pending)
            return
        }
        summary = pending.summary
        source = pending.source
        isOnDetails = false
        let screen = currentScreen()
        guard display.presentApprovalCard(screen, onSelect: selectionHandler) else {
            showLine(for: pending)
            return
        }
        askOnLens = pending.id
        screenOnLens = screen
        armTimeout(for: pending.id)
    }

    /// Today's lens half for an ask the card does not take: the ten-second line.
    private func showLine(for pending: PendingToolConfirmation) {
        let prompt = RemoteActionConsentRequest(source: pending.source, summary: pending.summary).spokenPrompt
        display.showNotification(title: HUDApprovalCardBuilder.genericHeading, body: prompt, icon: .info, duration: 10)
    }

    // MARK: - Presses

    /// A press from the band, issued against the card as last drawn.
    func handle(_ action: HUDApprovalAction) {
        guard isShowing, let ask = askOnLens, coordinator.pending?.id == ask,
              display.acceptsHeldScreenPress(issuedAgainst: display.heldScreenRevision) else { return }
        switch action {
        case .approve:
            coordinator.resolve(true)       // `pending` goes nil, and the card closes
        case .deny:
            coordinator.resolve(false)
        case .details:
            guard !isOnDetails else { return }
            isOnDetails = true
            redraw()
        case .back:
            guard isOnDetails else { return }
            isOnDetails = false
            redraw()
        }
    }

    private func redraw() {
        let screen = currentScreen()
        if display.presentApprovalCard(screen, onSelect: selectionHandler) { screenOnLens = screen }
    }

    /// The ask was answered (here, by voice, on the phone) or timed out: the card ends and what was
    /// under it comes back.
    private func close() {
        timeoutGeneration += 1
        guard askOnLens != nil else { return }
        askOnLens = nil
        screenOnLens = nil
        isOnDetails = false
        display.endApprovalCard()
    }

    /// Decision 4: the card denies when it has not been answered in `timeout`. A timer armed for an
    /// earlier ask finds a newer generation (or another ask pending) and does nothing.
    private func armTimeout(for ask: UUID) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        scheduleTimeout(timeout) { [weak self] in
            guard let self, generation == self.timeoutGeneration, self.askOnLens == ask,
                  self.coordinator.pending?.id == ask else { return }
            self.display.onDebugEvent?("HUD approval timed out: denied")
            self.coordinator.resolve(false)
        }
    }

    // MARK: - Screens

    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let item = self?.screenOnLens?.items.first(where: { $0.id == id }) else { return }
            item.action()
        }
    }

    private func currentScreen() -> HUDScreen {
        let onAction: (HUDApprovalAction) -> Void = { [weak self] action in self?.handle(action) }
        return isOnDetails
            ? HUDApprovalCardBuilder.details(summary: summary, source: source, onAction: onAction)
            : HUDApprovalCardBuilder.card(summary: summary, source: source, onAction: onAction)
    }
}
