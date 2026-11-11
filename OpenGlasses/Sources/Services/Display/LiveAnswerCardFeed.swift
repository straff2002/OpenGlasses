import Foundation

/// What a live session (Gemini Live, OpenAI Realtime, Qwen, Doubao) tells the lens about a turn
/// (Plan LC §5). `RealtimeSessionManager`, the one coordinator every live provider shares, sends
/// these from the places it already hears them; nothing provider-specific reaches the lens.
enum LiveAnswerEvent: Equatable {
    /// The server's voice activity heard the wearer start talking.
    case wearerSpeechStarted
    /// The wearer's words so far this turn (the whole accumulated transcript, not a delta).
    case wearerWords(String)
    /// A piece of the model's spoken transcript (a delta, as the provider sends it).
    case assistantText(String)
    /// The wearer spoke over the model and the response was cut.
    case interrupted
    /// The model's turn ended. `publishes` is false for a turn that is not an answer — the spoken
    /// interpreter, the idle warning.
    case turnComplete(publishes: Bool)
    /// The session stopped.
    case sessionEnded
}

/// One live-mode answer for the card (Plan LC §5).
struct LiveAnswer: Equatable {
    let text: String
    /// What the wearer said that turn, for the card's "You: …" line; nil when they said nothing.
    let question: String?
    /// The wearer spoke or pressed that turn: the card may reopen a lens they dismissed.
    let wearerLed: Bool
}

/// Collects one live turn's transcript into one answer (Plan LC §5). Pure.
///
/// - **The answer is the turn's transcript, whole.** Deltas join with `ScriptAwareJoiner` (the
///   session's own rule, so CJK isn't spaced apart). Nothing is published until the turn ends.
/// - **A turn the wearer spoke over is dropped** while it is still open: its response was
///   cancelled, the text is a fragment, and the wearer is already asking the next thing, whose
///   answer replaces it moments later. A turn already *complete* that the wearer talks over (the
///   server finishes generating before the audio finishes playing) is whole, and is published.
/// - **The question and who led carry over a turn with no text.** A tool call ends a turn with
///   nothing said (OpenAI's `response.done` for a function call); the answer after it is still the
///   reply to what the wearer asked, so it keeps their words and their lead.
/// - **Late words.** A JSON provider's input transcript can land after the model's turn ended. Words
///   that arrive while a completed turn waits to publish, with no new speech started since, are that
///   turn's question. New speech (`wearerSpeechStarted`) closes the wait.
struct LiveAnswerTurnTracker: Equatable {
    private(set) var assistantText = ""
    private(set) var wearerWords = ""
    private(set) var wearerLed = false
    /// The model's turn ended; its answer waits (the settle) for trailing transcript.
    private(set) var isComplete = false
    private var publishes = true

    /// The wearer started talking. True when a completed turn is waiting and must be published
    /// first (this speech belongs to the next turn).
    mutating func wearerSpeechStarted() -> Bool {
        let flush = isComplete
        if !flush { wearerLed = true }
        return flush
    }

    /// The wearer's words so far, whole.
    mutating func wearerSaid(_ words: String) {
        wearerWords = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wearerWords.isEmpty { wearerLed = true }
    }

    /// The wearer pressed More, Send, Repeat or a follow-up on the card: the next answer is theirs.
    mutating func wearerAsked() { wearerLed = true }

    mutating func assistantSaid(_ delta: String) {
        assistantText = ScriptAwareJoiner.join(assistantText, delta)
    }

    /// True when a completed turn is waiting and should be published now (the wearer cut its
    /// playback short, and the text is whole).
    mutating func interrupted() -> Bool {
        if isComplete { return true }
        assistantText = ""
        return false
    }

    mutating func turnComplete(publishes: Bool) {
        isComplete = true
        self.publishes = self.publishes && publishes
    }

    /// The completed turn's answer, if it is one, and the tracker ready for the next turn. A turn
    /// with no text keeps the wearer's words and lead for the turn after it.
    mutating func take() -> LiveAnswer? {
        guard isComplete else { return nil }
        let text = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let publish = publishes
        isComplete = false
        publishes = true
        guard !text.isEmpty else {
            assistantText = ""
            return nil
        }
        let answer = LiveAnswer(text: text, question: wearerWords.isEmpty ? nil : wearerWords,
                                wearerLed: wearerLed)
        self = LiveAnswerTurnTracker()
        return publish ? answer : nil
    }
}

/// The adapter from a live session to the answer card (Plan LC §5): `RealtimeSessionManager`'s
/// `onAnswerEvent` goes to `handle(_:)`, and each model turn's transcript becomes one KP card through
/// `HUDAnswerCard.presentLiveAnswer` at the turn's end.
///
/// **Turn end only, no partials.** A live provider's transcript arrives in sub-word deltas, ahead of
/// the audio, and its turn ends while the audio is often still playing; and the card only shows
/// page 1 once it is settled (KP's growth rule), so a short answer would draw nothing until its end
/// anyway. Throttled partials would spend sends while the model talks for a card that barely moves,
/// so the card goes up once, whole.
///
/// **The settle.** The answer waits `settle` (0.5 s) after the turn ends for transcript that trails
/// the turn-complete event (Gemini can send the last transcription after it), and is published at
/// once when the wearer starts talking or cuts the audio short.
///
/// Everything else is the card's: the HUD switch, the Display-in-use rule, never over a task card, a
/// menu, a page view or an approval card (`acceptsAnswerCard`), and a dismissed lens reopened only by
/// an answer the wearer led.
@MainActor
final class LiveAnswerCardFeed {
    /// How long a completed turn waits for trailing transcript.
    static let defaultSettle: TimeInterval = 0.5

    private let card: HUDAnswerCard
    private(set) var tracker = LiveAnswerTurnTracker()
    private var settleGeneration = 0

    var settle: TimeInterval = LiveAnswerCardFeed.defaultSettle
    /// Test seam: run `fire` after `delay`.
    var schedule: (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    init(card: HUDAnswerCard) {
        self.card = card
    }

    func handle(_ event: LiveAnswerEvent) {
        switch event {
        case .wearerSpeechStarted:
            if tracker.wearerSpeechStarted() {
                publish()
                _ = tracker.wearerSpeechStarted()
            }
        case .wearerWords(let words):
            tracker.wearerSaid(words)
        case .assistantText(let delta):
            tracker.assistantSaid(delta)
        case .interrupted:
            if tracker.interrupted() { publish() }
        case .turnComplete(let publishes):
            tracker.turnComplete(publishes: publishes)
            settleGeneration += 1
            let generation = settleGeneration
            schedule(settle) { [weak self] in
                guard let self, generation == self.settleGeneration else { return }
                self.publish()
            }
        case .sessionEnded:
            settleGeneration += 1
            tracker = LiveAnswerTurnTracker()
        }
    }

    /// The wearer pressed something on the card that asks the live model again.
    func wearerAsked() { tracker.wearerAsked() }

    private func publish() {
        settleGeneration += 1
        guard let answer = tracker.take() else { return }
        card.presentLiveAnswer(answer.text, question: answer.question, wearerLed: answer.wearerLed)
    }
}

/// Where a press on a live-mode answer card goes (Plan LC §5). Pure.
///
/// The card's More, Send and follow-ups submit a next turn, and Repeat says the answer again. In
/// Direct mode that is the typed-turn path and the app's voice, as KP built them. In a live mode the
/// live model is the one answering, so a next turn goes into the session as a text turn — where the
/// provider takes them — and Repeat uses the provider's exact-speech lane when it has one, else asks
/// the model for it as a text turn. A session that can take neither (not ready, a protocol with no
/// text lane) cannot do it, and the card says so rather than sending it to a model the wearer did
/// not choose.
enum LiveAnswerCardRouting {
    enum Route: Equatable {
        /// The Direct path, as KP built it.
        case direct
        /// A text turn into the live session.
        case liveTurn
        /// The live session's exact-speech lane.
        case liveSpeech
        /// Nothing can do it now.
        case unavailable
    }

    static func submit(realtimeMode: Bool, canInject: Bool, textTurns: Bool) -> Route {
        guard realtimeMode else { return .direct }
        return canInject && textTurns ? .liveTurn : .unavailable
    }

    static func repeatAnswer(realtimeMode: Bool, canInject: Bool, textTurns: Bool, suppliedSpeech: Bool) -> Route {
        guard realtimeMode else { return .direct }
        guard canInject else { return .unavailable }
        if suppliedSpeech { return .liveSpeech }
        return textTurns ? .liveTurn : .unavailable
    }

    /// What Repeat asks a live model that has no exact-speech lane.
    static var repeatRequest: String {
        String(localized: "Say your last answer again, word for word.",
               comment: "Sent to a live voice model when the wearer presses Repeat on the glasses' answer card.")
    }

    /// The line the lens flashes when a press can't be done in this live mode.
    static var unavailableLine: String {
        String(localized: "Not available in this live mode",
               comment: "Glasses: flashed when an answer card button can't be used with the current live voice model.")
    }
}
