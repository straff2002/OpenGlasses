import Combine
import Foundation

/// Plan KT §6.2 (decision 6): which cards may be shown on the lens unasked, and when. Pure.
///
/// Only four kinds are ever pushed — leave by, running late, running late to a job and on my way —
/// and each only once it is `immediate` (leave-by ten minutes away, or late now). Each card pushes
/// once. Everything else is pulled only.
///
/// | The lens | What happens to an immediate card not pushed before |
/// |---|---|
/// | another app has it (`.inUse`) | dropped: nothing is pushed and nothing queues (KP §8 rule 3) |
/// | no display, glasses off or not worn (`.off`) | nothing; it may still push if the glasses go on while it is immediate |
/// | quiet hours | nothing |
/// | ours, but a task card, an answer card, a menu, the turn's card or the cards themselves are up | it waits; once they close it pushes only if it is still immediate |
/// | ours and free | pushed: a 20-second glance, **Open** · **Close** |
///
/// One glance at a time: a second immediate card waits for the first to close.
enum PreparedCardPushPolicy {
    static let pushableKinds: Set<PreparedCardKind> = [.leaveBy, .runningLate, .jobRunningLate, .jobOnMyWay]
    /// A pushed glance stays this long.
    static let glanceLifetime: TimeInterval = 20

    struct Context: Equatable {
        var availability: DisplayAvailability
        /// The glasses can show anything: a display, and the HUD on.
        var hasDisplay: Bool
        /// `GlassesConnectionService.isWorn`: nil is unknown, not "taken off".
        var worn: Bool?
        var quiet: Bool
        /// Nothing the wearer is working with is on the lens, and a raised card may go up now.
        var lensFree: Bool
    }

    struct Decision: Equatable {
        /// The card to push now, if any.
        var push: PreparedCard?
        /// Cards that are spent without a push (the Display was in use when they came due).
        var drop: [PreparedCardID] = []
    }

    static func isPushable(_ card: PreparedCard) -> Bool {
        pushableKinds.contains(card.kind) && card.urgency == .immediate
    }

    static func decide(cards: [PreparedCard], pushed: Set<String>, context: Context) -> Decision {
        let due = cards.filter { isPushable($0) && !pushed.contains($0.id.rawValue) }
        guard !due.isEmpty else { return Decision() }
        if context.availability == .inUse { return Decision(drop: due.map(\.id)) }
        guard context.availability == .ours, context.hasDisplay, context.worn != false,
              !context.quiet, context.lensFree else { return Decision() }
        return Decision(push: due.first)
    }
}

/// Puts the policy's glances on the lens (Plan KT §6.2). Re-checks whenever the feed changes and
/// whenever the lens frees up or changes hands, so a glance waiting behind a task card goes up when
/// the card closes — if its card is still immediate by then.
@MainActor
final class PreparedCardGlances {
    private let display: GlassesDisplayService
    private weak var router: HUDRouter?

    /// Wired by AppState.
    var cards: () -> [PreparedCard] = { [] }
    var worn: () -> Bool? = { nil }
    var quiet: () -> Bool = { false }
    /// **Open**: the stack at this card.
    var open: (PreparedCardID) -> Void = { _ in }
    var notePushed: (PreparedCard) -> Void = { _ in }
    var geometry: () -> TeleprompterPaginator.Geometry = HUDAnswerCard.activeGeometry
    /// Test seam: run `fire` after `delay`.
    var scheduleExpiry: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    /// Ids already pushed or spent, so each card pushes once — across launches too.
    private static let pushedKey = "preparedCardPushedIDs"
    static let rememberedLimit = 100
    private let defaults: UserDefaults

    /// The glance last handed to the display. Read by tests.
    private(set) var screenOnLens: HUDScreen?
    private var glanceCard: PreparedCardID?
    private var generation = 0
    private var cancellables: Set<AnyCancellable> = []

    init(display: GlassesDisplayService, router: HUDRouter, defaults: UserDefaults = .standard) {
        self.display = display
        self.router = router
        self.defaults = defaults
        // The lens frees up (a task card, an answer card, a menu closed) or changes hands.
        display.$isInteractive.removeDuplicates().dropFirst()
            .merge(with: display.$showsAnswerCard.removeDuplicates().dropFirst())
            .sink { [weak self] _ in Task { @MainActor in self?.evaluate() } }
            .store(in: &cancellables)
        display.$displayAvailability.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.evaluate() } }
            .store(in: &cancellables)
    }

    var pushed: Set<String> { Set(defaults.stringArray(forKey: Self.pushedKey) ?? []) }

    /// Whether the glance is the screen the lens holds (or holds under a notification).
    var isShowing: Bool {
        guard let screenOnLens else { return false }
        return display.heldScreenRenderKey == screenOnLens.renderKey
    }

    /// Nothing the wearer is working with is up, and a raised card may go up: never over a task
    /// card, an answer card, the turn's card, a menu, a page view, the cards, or a glance already
    /// up.
    var lensFree: Bool {
        guard display.acceptsRaisedCard, !display.showsAnswerCard, !display.showsTurnState else { return false }
        guard let router else { return false }
        return !router.isPresentingTask && !router.isPresentingMenu && !router.isPresentingPage
            && !router.isPresentingCards && !isShowing
    }

    var context: PreparedCardPushPolicy.Context {
        PreparedCardPushPolicy.Context(availability: display.displayAvailability,
                                       hasDisplay: display.deviceSupportsDisplay() && Config.glassesDisplayEnabled,
                                       worn: worn(), quiet: quiet(), lensFree: lensFree)
    }

    /// Push the next due card if the lens can take it.
    func evaluate() {
        let decision = PreparedCardPushPolicy.decide(cards: cards(), pushed: pushed, context: context)
        remember(decision.drop.map(\.rawValue))
        guard let card = decision.push else { return }
        show(card)
    }

    private func show(_ card: PreparedCard) {
        let screen = PreparedCardHUDBuilder.glance(card, geometry: geometry()) { [weak self] press in
            self?.handle(press)
        }
        guard display.presentRaisedCard(screen, onSelect: { [weak self] id in
            self?.screenOnLens?.items.first(where: { $0.id == id })?.action()
        }) else { return }
        remember([card.id.rawValue])
        notePushed(card)
        screenOnLens = screen
        glanceCard = card.id
        generation += 1
        let armed = generation
        scheduleExpiry(PreparedCardPushPolicy.glanceLifetime) { [weak self] in
            guard let self, self.generation == armed else { return }
            self.close()
        }
    }

    /// A press on the glance, issued against it as last drawn: one made under a notification is
    /// stale and dropped (`PageTurnGate`, through `acceptsHeldScreenPress`).
    func handle(_ press: PreparedCardLensPress) {
        guard isShowing, glanceCard == press.cardID,
              display.acceptsHeldScreenPress(issuedAgainst: display.heldScreenRevision) else { return }
        switch press.action {
        case .open:
            generation += 1
            screenOnLens = nil
            glanceCard = nil
            open(press.cardID)
        default:
            close()
        }
    }

    /// Close the glance if it is still the lens's.
    func close() {
        generation += 1
        let showing = isShowing
        screenOnLens = nil
        glanceCard = nil
        if showing { display.endInteractive() }
    }

    private func remember(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var list = defaults.stringArray(forKey: Self.pushedKey) ?? []
        list += ids.filter { !list.contains($0) }
        defaults.set(Array(list.suffix(Self.rememberedLimit)), forKey: Self.pushedKey)
    }
}
