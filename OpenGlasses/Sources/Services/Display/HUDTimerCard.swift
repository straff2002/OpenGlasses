import Foundation

/// What a press on the timer card does (Plan LC §6).
enum HUDTimerAction: Equatable {
    case stop, extend, close
}

/// Plan LC §6: the card a finished timer or alarm raises on the lens. Pure.
///
/// **Timer done** (or **Alarm**) as the heading, the wearer's label under it, then **Stop**
/// (primary, focused: the likeliest press is to silence it) · **+5 min** (only when the timer can be
/// set again) · **Close** (leaves it ringing on the phone). Three buttons, well inside focus reach.
enum HUDTimerCardBuilder {
    enum ItemID {
        static let stop = "lc.timer.stop"
        static let extend = "lc.timer.extend"
        static let close = "lc.timer.close"
    }

    static var timerHeading: String {
        String(localized: "Timer done", comment: "Glasses: heading of the card a finished timer raises.")
    }
    static var alarmHeading: String {
        String(localized: "Alarm", comment: "Glasses: heading of the card a ringing alarm raises.")
    }

    static func screen(_ timer: FinishedTimer, canExtend: Bool,
                       onAction: @escaping (HUDTimerAction) -> Void) -> HUDScreen {
        let heading = timer.kind == .timer ? timerHeading : alarmHeading
        var lines: [HUDLine] = []
        if let label = timer.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
           label.caseInsensitiveCompare("Timer") != .orderedSame,
           label.caseInsensitiveCompare("Alarm") != .orderedSame {
            lines.append(HUDLine(label, icon: .reminder))
        }
        var items = [
            HUDItem(id: ItemID.stop, label: String(localized: "Stop", comment: "Glasses: silences a finished timer or alarm."),
                    icon: .success, style: .primary) { onAction(.stop) },
        ]
        if canExtend && timer.canExtend {
            items.append(HUDItem(id: ItemID.extend,
                                 label: String(localized: "+5 min", comment: "Glasses: sets a finished timer or alarm again for five minutes."),
                                 style: .secondary) { onAction(.extend) })
        }
        items.append(HUDItem(id: ItemID.close, label: String(localized: "Close", comment: "Glasses: closes a card."),
                             style: .outline) { onAction(.close) })
        return HUDScreen(title: heading, lines: lines, items: items, focusItemID: ItemID.stop)
    }
}

/// Plan LC §6: holds the timer card on the lens when a timer or an AlarmKit alarm finishes
/// (`TimerCompletionWatch`).
///
/// **When it goes up.** Over nothing, an answer card or the turn's card
/// (`GlassesDisplayService.acceptsRaisedCard`). It is not a wearer-led frame, so a lens the wearer
/// dismissed stays shut. Over a task card, a menu, a page view, an approval card or a clip, the
/// lens gets a five-second line instead and the work underneath comes back; the phone rings as it
/// always did either way.
///
/// **Presses.** Issued against the card as last drawn: one made under a notification is stale and
/// dropped (`acceptsHeldScreenPress`). **Stop** silences it, **+5 min** sets it again, **Close**
/// only closes the card. The card closes by itself after `lifetime`, inside the panel's wake.
@MainActor
final class HUDTimerCard {
    static let lifetime: TimeInterval = 60
    /// How long the line shown instead of the card stays.
    static let lineDuration: TimeInterval = 5

    private let display: GlassesDisplayService

    /// Set by AppState: silence it, and set it again (nil: **+5 min** is not offered).
    var stop: ((FinishedTimer) -> Void)?
    var extend: ((FinishedTimer) -> Void)?

    /// Test seam: run `fire` after `delay`.
    var scheduleExpiry: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    /// The card last handed to the display, buttons and all. Read by tests.
    private(set) var screenOnLens: HUDScreen?
    private var timer: FinishedTimer?
    private var generation = 0

    init(display: GlassesDisplayService) {
        self.display = display
    }

    /// Whether the card is the screen the lens holds (or holds under a notification).
    var isShowing: Bool {
        guard let screenOnLens else { return false }
        return display.heldScreenRenderKey == screenOnLens.renderKey
    }

    /// A timer or alarm finished.
    func show(_ timer: FinishedTimer) {
        let screen = HUDTimerCardBuilder.screen(timer, canExtend: extend != nil) { [weak self] action in
            self?.handle(action)
        }
        guard display.presentRaisedCard(screen, onSelect: { [weak self] id in
            self?.screenOnLens?.items.first(where: { $0.id == id })?.action()
        }) else {
            let heading = timer.kind == .timer ? HUDTimerCardBuilder.timerHeading : HUDTimerCardBuilder.alarmHeading
            display.showNotification(title: heading, body: timer.label ?? "", icon: .reminder,
                                     duration: Self.lineDuration)
            return
        }
        self.timer = timer
        screenOnLens = screen
        generation += 1
        let armed = generation
        scheduleExpiry(Self.lifetime) { [weak self] in
            guard let self, self.generation == armed else { return }
            self.close()
        }
    }

    /// A press from the band, issued against the card as last drawn.
    func handle(_ action: HUDTimerAction) {
        guard isShowing, let timer,
              display.acceptsHeldScreenPress(issuedAgainst: display.heldScreenRevision) else { return }
        switch action {
        case .stop: stop?(timer)
        case .extend: extend?(timer)
        case .close: break
        }
        close()
        if action == .extend {
            display.flash(String(localized: "Again in 5 minutes", comment: "Glasses: a timer or alarm was set again for five minutes."),
                          duration: 2)
        }
    }

    /// Close the card if it is still the lens's.
    func close() {
        generation += 1
        let showing = isShowing
        screenOnLens = nil
        timer = nil
        if showing { display.endInteractive() }
    }
}
