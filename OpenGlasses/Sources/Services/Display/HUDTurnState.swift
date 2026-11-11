import Foundation

/// The lens while the wearer waits (Plan LC §4): Listening (the live partial transcript) →
/// Thinking → the KP answer card, so the lens is never blank between the wake word and the answer.
///
/// **Only for a turn the wearer started.** `beginListening()` is called where the wearer opens a
/// turn — the wake word, a tap, the Action Button, a temple tap (`AppState.handleWakeWordDetected`)
/// — and that is a wearer-led frame, so it reopens a lens the wearer dismissed (§2.2). The
/// follow-up capture a conversation re-arms by itself after an answer does not start it: that would
/// cover the answer card the wearer is still reading. Every later step (a partial, the final
/// transcript, Thinking) acts only on a turn whose Listening card is up.
///
/// **Only while the lens is the wearer's.** The card goes up only when nothing but an answer card is
/// held (`GlassesDisplayService.acceptsTurnState`): never over a task card, a menu, a page view or an
/// approval card. Anything that takes the lens meanwhile (a menu the turn opened, guidance, the
/// wearer's Back) ends it here too; the answer card replaces it when its first page is ready.
///
/// **Paced.** A partial goes to the lens at most once per `HUDPartialThrottle.gap` (0.4 s); one that
/// arrives inside the gap waits it out and the newest goes then. The final transcript is always
/// sent. The render queue is latest-wins, so a final followed at once by Thinking may only ever be
/// drawn as Thinking — which carries the same words as its "You: …" line.
///
/// **Ends** when the answer card replaces it, when the turn is over without one (`end()`: the
/// conversation re-arms or drops back to the wake word, processing stops, nothing was heard), or
/// after a lifetime with no change (`listeningLifetime`, `thinkingLifetime`) as a backstop, so the
/// lens is never left saying "Thinking…".
///
/// **Stop.** On Listening it stops capture and sends what was heard (the phone's Tap to stop); on
/// Thinking it cancels the turn (the phone's cancel). Both are band presses issued against the card
/// as last drawn: a press made under a notification is stale and dropped.
@MainActor
final class HUDTurnState {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
    }

    /// Backstop: a Listening card with no new words for this long clears.
    static let listeningLifetime: TimeInterval = 30
    /// Backstop: a Thinking card no answer replaced clears after this long.
    static let thinkingLifetime: TimeInterval = 90

    private let display: GlassesDisplayService

    /// Test seam: the clock the throttle reads.
    var now: () -> Date = Date.init
    /// Test seam: run `fire` after `delay` (the throttle's trailing send, and the lifetime).
    /// Production sleeps on the main actor; a test captures the timers and fires them.
    var schedule: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }
    /// The page shape, from the active backend: the Thinking card's question line is one of its lines.
    var geometry: () -> TeleprompterPaginator.Geometry = HUDAnswerCard.activeGeometry

    // MARK: Wiring (AppState)

    /// Listening's Stop: stop capture and send what was heard.
    var onStopListening: (() -> Void)?
    /// Thinking's Stop: cancel the turn.
    var onCancelTurn: (() -> Void)?

    // MARK: State

    private(set) var phase: Phase = .idle
    /// The partial last handed to the display.
    private(set) var shownPartial = ""
    /// The newest partial heard, sent or waiting out the throttle.
    private var latestPartial = ""
    private var throttle = HUDPartialThrottle()
    private var trailingSendArmed = false
    /// Bumped when the turn's card ends, so a timer armed for it does nothing.
    private var turnGeneration = 0
    /// Bumped on every change, so only the newest lifetime timer clears the card.
    private var lifetimeGeneration = 0
    /// The screen last handed to the display, buttons and all. Read by tests.
    private(set) var screenOnLens: HUDScreen?

    init(display: GlassesDisplayService) {
        self.display = display
    }

    // MARK: - The turn

    /// The wearer started a turn and the app is listening. Shows an empty Listening card, if the
    /// lens can take it.
    func beginListening() {
        reset()
        let screen = listeningScreen(partial: nil)
        guard display.presentTurnState(screen, wearerStarted: true, onSelect: selectionHandler) else { return }
        phase = .listening
        screenOnLens = screen
        throttle.sent(at: now())
        armLifetime()
    }

    /// The recogniser's current transcript. Ignored unless this turn's Listening card is up.
    func partial(_ text: String) {
        guard phase == .listening, stillOnLens() else { return }
        let words = HUDTextShaper.condense(text, max: Int.max)
        guard !words.isEmpty, words != latestPartial else { return }
        latestPartial = words
        switch throttle.decision(at: now(), isFinal: false) {
        case .sendNow:
            send(words)
        case .wait(let delay):
            armTrailingSend(after: delay)
        }
    }

    /// The final transcript: always sent. An empty one (nothing was heard) ends the card.
    func heard(_ text: String) {
        guard phase == .listening else { return }
        let words = HUDTextShaper.condense(text, max: Int.max)
        guard !words.isEmpty else {
            end()
            return
        }
        guard stillOnLens() else { return }
        latestPartial = words
        send(words)
    }

    /// The turn is going to the assistant: Thinking, with what was heard. Only after this turn's
    /// Listening card; `question` defaults to the last transcript the card showed.
    func thinking(question: String? = nil) {
        guard phase == .listening, stillOnLens() else { return }
        let heard = question ?? (latestPartial.isEmpty ? nil : latestPartial)
        let screen = HUDTurnStateBuilder.thinking(question: heard, lineChars: geometry().maxChars,
                                                  onStop: { [weak self] in self?.press() })
        guard display.presentTurnState(screen, wearerStarted: false, onSelect: selectionHandler) else {
            reset()
            return
        }
        phase = .thinking
        screenOnLens = screen
        armLifetime()
    }

    /// Processing stopped (`AppState.isProcessing` went false). Ends a Thinking card the answer did
    /// not replace — a failed turn, a cancelled one, one answered by a command — and leaves a
    /// Listening card alone: that is the next turn.
    func processingEnded() {
        guard phase == .thinking else { return }
        end()
    }

    /// The turn is over: the card clears if it is still the turn's (the answer card replacing it
    /// already ended it), including one held under an approval card.
    func end() {
        reset()
        display.endTurnState()
    }

    // MARK: - Internals

    /// Whether this turn's card is still the held screen. Something else took the lens (the answer
    /// card, a menu, guidance, the wearer's Back): the turn is over here, and nothing is redrawn.
    /// Under an approval card it is held, not lost — it comes back when the approval is answered.
    private func stillOnLens() -> Bool {
        if display.showsTurnState { return true }
        if display.showsApprovalCard { return false }
        reset()
        return false
    }

    private func send(_ words: String) {
        let screen = listeningScreen(partial: words)
        guard display.presentTurnState(screen, wearerStarted: false, onSelect: selectionHandler) else { return }
        screenOnLens = screen
        shownPartial = words
        throttle.sent(at: now())
        armLifetime()
    }

    /// One trailing send per gap: the newest partial, once the gap is over.
    private func armTrailingSend(after delay: TimeInterval) {
        guard !trailingSendArmed else { return }
        trailingSendArmed = true
        let generation = turnGeneration
        schedule(delay) { [weak self] in
            // A timer from an earlier turn: `reset()` already cleared the flag for this one.
            guard let self, generation == self.turnGeneration else { return }
            self.trailingSendArmed = false
            guard self.phase == .listening, self.stillOnLens(),
                  self.latestPartial != self.shownPartial else { return }
            self.send(self.latestPartial)
        }
    }

    private func armLifetime() {
        lifetimeGeneration += 1
        let generation = lifetimeGeneration
        let lifetime = phase == .thinking ? Self.thinkingLifetime : Self.listeningLifetime
        schedule(lifetime) { [weak self] in
            guard let self, generation == self.lifetimeGeneration, self.phase != .idle else { return }
            self.display.onDebugEvent?("HUD turn state lifetime ended")
            self.end()
        }
    }

    private func reset() {
        phase = .idle
        latestPartial = ""
        shownPartial = ""
        throttle.reset()
        trailingSendArmed = false
        turnGeneration += 1
        lifetimeGeneration += 1
        screenOnLens = nil
    }

    private func listeningScreen(partial: String?) -> HUDScreen {
        HUDTurnStateBuilder.listening(partial: partial, onStop: { [weak self] in self?.press() })
    }

    /// Stop, from the band, against the card as last drawn.
    private func press() {
        guard phase != .idle, display.showsTurnState,
              display.acceptsHeldScreenPress(issuedAgainst: display.heldScreenRevision) else { return }
        switch phase {
        case .listening:
            onStopListening?()
        case .thinking:
            onCancelTurn?()
            end()
        case .idle:
            break
        }
    }

    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let item = self?.screenOnLens?.items.first(where: { $0.id == id }) else { return }
            item.action()
        }
    }
}
