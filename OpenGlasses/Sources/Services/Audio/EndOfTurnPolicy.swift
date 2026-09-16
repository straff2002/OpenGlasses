import Foundation

/// Plan CU P2 — who gets to say the wearer has finished talking.
///
/// Today one thing decides: a silence timer armed on every recognizer partial and fired
/// `SpeechContinuationPolicy.baseWindow` (2.0 s, or 6.0 s after a question-shaped reply) later.
/// That timer asks *"has the recognizer been quiet for N seconds"* as a proxy for *"has the wearer
/// finished"*, and it is wrong in both directions at once: `SFSpeechRecognizer` emits partials in
/// bursts with ~1 s gaps **while the user is still talking**, so any window responsive enough to
/// feel quick fires mid-sentence — and every completed turn pays the whole window regardless.
///
/// This policy does not shorten CO's window; it changes which signal is allowed to end the turn, so
/// the trade-off stops being forced. Four rules, and the third is the one that is easy to get wrong:
///
/// 1. **Detector unavailable ⇒ byte-for-byte today's behaviour.** The timer decides alone. Voice
///    input degrading to "as it was before" is acceptable; breaking it is not.
/// 2. **Speech observed, then ended ⇒ commit on a short grace.** This is the case that removes the
///    floor: the wearer stopped talking, we know it acoustically, and there is nothing to wait for.
/// 3. **Speech never started ⇒ the timer still owns it, at CO's window.** `questionWindow` exists
///    for a wearer who is *thinking about their answer* — who has not started speaking, and about
///    whom acoustic endpointing has precisely nothing to say. Letting the detector's silence commit
///    that turn would quietly re-break the exact case CO shipped to fix, and it would look like a
///    latency win while doing it.
/// 4. **The detector can get stuck, so it never gets an unbounded hold.** A noisy 8 kHz HFP link
///    scoring as speech forever would otherwise hang the turn with a hot mic and no way out. Past
///    the backstop the timer takes the decision back, and the reason says so — a rising
///    `detectorBackstop` count in the P1 panel is the signal that a threshold is wrong.
enum EndOfTurnPolicy {

    /// How long after acoustic speech-end to commit. Long enough to ride out a hop of jitter and a
    /// breath mid-sentence, short enough that it is not a floor by another name — the whole gain
    /// here is the difference between this and `baseWindow`. Provisional until CU P5 measures a
    /// false-cut rate on device; the P1 timeline is what will price a change to it.
    static let acousticGrace: TimeInterval = 0.4

    /// Longest hold granted to a detector that claims speech is still going. Deliberately past
    /// `SpeechContinuationPolicy.questionWindow` so it can never pre-empt rule 3, and far past any
    /// plausible sentence.
    ///
    /// Plan FE P3 made the timer window a preference, so this constant is a *floor* rather than
    /// the whole answer — see `backstop(forWindow:)`.
    static let stuckDetectorBackstop: TimeInterval = 8.0

    /// How far the backstop must sit above the window in force. Plan FE P3.
    ///
    /// A fixed 8 s was safely past every window the app could produce when the only two were 2 s
    /// and 6 s. Once the wearer can choose up to 10 s it stops being safe: a backstop below the
    /// window would commit the turn *before* the window it is supposed to outlast, which is rule 4
    /// quietly pre-empting rule 3 — the exact failure this constant was introduced to prevent, and
    /// one that would only appear for wearers who chose a long pause.
    static let backstopMargin: TimeInterval = 2.0

    /// The hold for a turn running under `window`: never below the historical floor, and always
    /// clear of the window itself.
    static func backstop(forWindow window: TimeInterval) -> TimeInterval {
        max(stuckDetectorBackstop, window + backstopMargin)
    }

    /// Everything the decision depends on, passed in — no clocks, no services, no `Date()` inside.
    struct Input: Equatable {
        var now: Date

        /// Whether a detector is installed *and* loaded. False takes rule 1 unconditionally.
        var detectorAvailable: Bool

        /// Whether **either** the recognizer or the detector has heard speech in this utterance.
        /// The OR is deliberate: rule 3's "thinking" wearer is the one about whom *neither* has
        /// anything to report, and a detector that hears a voice the recognizer cannot parse has
        /// still observed speech.
        var speechObserved: Bool

        /// When the silence window now running was armed — i.e. the last recognizer partial.
        /// `nil` before the first partial, where the no-speech timeout owns the turn instead.
        var lastRecognizerActivityAt: Date?

        /// When the detector says the wearer stopped — the moment the silence *began*, not the
        /// moment it was confirmed (see `SpeechActivityGate`). `nil` means "still speaking, or
        /// never spoke", which rules 3 and 4 separate by `speechObserved`.
        var acousticSpeechEndedAt: Date?

        /// CO Item 4's window for this turn: `baseWindow`, or `questionWindow` after a question.
        var timerWindow: TimeInterval

        var grace: TimeInterval = acousticGrace

        /// A floor for the hold, not the final value: `decide` raises it to clear `timerWindow`
        /// (see `backstop(forWindow:)`), so an explicit value here can lengthen the hold but can
        /// never shorten it below the window the turn is running under.
        var backstop: TimeInterval = stuckDetectorBackstop
    }

    /// Why the turn ended. Recorded, not just logged: which signal committed a turn is a cohort in
    /// the P1 panel, and it is how "did P2 work" gets answered with a number instead of a feeling.
    enum Reason: String, Equatable {
        case acoustic
        case silenceTimer
        case detectorBackstop
    }

    enum Decision: Equatable {
        case commit(Reason)
        /// Nothing to do yet; ask again no later than this. The caller schedules one timer for it,
        /// which is why the policy — not `TranscriptionService` — owns every deadline.
        case wait(until: Date)
    }

    static func decide(_ input: Input) -> Decision {
        let timerDeadline = input.lastRecognizerActivityAt?.addingTimeInterval(input.timerWindow)

        // Rules 1 and 3 are the same code path on purpose: in both, the timer decides alone.
        guard input.detectorAvailable, input.speechObserved else {
            guard let timerDeadline else {
                // No partial yet — the no-speech timeout owns this turn. Re-ask after a window so
                // this never becomes a busy wait.
                return .wait(until: input.now.addingTimeInterval(input.timerWindow))
            }
            return input.now >= timerDeadline ? .commit(.silenceTimer) : .wait(until: timerDeadline)
        }

        if let endedAt = input.acousticSpeechEndedAt {
            // Rule 2. The timer is still allowed to win a race it would win anyway: once the
            // detector agrees speech is over, an earlier timer deadline is strictly faster and is
            // exactly today's behaviour, so there is nothing to protect the wearer from.
            let acousticDeadline = endedAt.addingTimeInterval(input.grace)
            let deadline = min(acousticDeadline, timerDeadline ?? acousticDeadline)
            guard input.now >= deadline else { return .wait(until: deadline) }
            return .commit(deadline == acousticDeadline ? .acoustic : .silenceTimer)
        }

        // Rule 4. The detector says the wearer is still talking, so the timer does *not* cut —
        // that firing is the mid-sentence bug this plan exists to remove — but the hold is bounded.
        let hold = max(input.backstop, backstop(forWindow: input.timerWindow))
        let backstopDeadline = (input.lastRecognizerActivityAt ?? input.now)
            .addingTimeInterval(hold)
        return input.now >= backstopDeadline ? .commit(.detectorBackstop) : .wait(until: backstopDeadline)
    }
}
