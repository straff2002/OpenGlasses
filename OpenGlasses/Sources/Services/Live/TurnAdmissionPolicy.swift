import Foundation

/// Plan CO Item 3 — what happens to speech that arrives while a turn is already in flight.
///
/// The old guard was one line:
///
/// ```swift
/// guard !self.isProcessing else {
///     // …logged "Transcription ignored - already processing" and returned
///     return
/// }
/// ```
///
/// It does prevent the worse bug — an answer landing on the wrong question — but it *discards* the
/// user's words behind a debug `print`. No tone, no HUD, nothing the wearer can perceive. Someone
/// who adds a second thought while the first is still being answered is silently ignored, and has
/// no way to tell "it didn't hear me" from "it heard me and threw it away", so the natural next
/// move is to repeat themselves into the same guard.
///
/// Two changes follow. Recognition is suspended for the duration of the turn, so in the common
/// case nothing half-heard is collected at all. And where something still arrives, it is either
/// held for the next turn or refused *audibly*.
///
/// One held utterance, never a queue: a backlog of stale phrases replayed at someone is worse than
/// dropping them, and the user's most recent intent is the one worth keeping.
enum TurnAdmissionPolicy {

    enum Decision: Equatable {
        /// Nothing in flight — handle it now.
        case accept
        /// A turn is running; hold this utterance and replay it when the turn finishes.
        case deferToQueue
        /// Refuse, and tell the user so — audibly, not in a log.
        case rejectWithCue(Reason)
    }

    enum Reason: Equatable {
        /// The turn has run long enough that the holding slot would deliver something stale.
        case turnTooLong
        /// Nothing usable was recognised.
        case emptyUtterance
    }

    /// Past this, a held utterance is more likely to confuse than to help: the user has been
    /// waiting long enough that whatever they said has probably been overtaken.
    static let maxHoldAge: TimeInterval = 20

    /// - Parameters:
    ///   - isProcessing: whether a turn is currently in flight.
    ///   - turnElapsed: seconds since the in-flight turn was dispatched (nil when idle).
    ///   - utterance: the recognised text.
    static func decide(isProcessing: Bool,
                       turnElapsed: TimeInterval?,
                       utterance: String) -> Decision {
        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejectWithCue(.emptyUtterance)
        }
        guard isProcessing else { return .accept }
        guard let elapsed = turnElapsed, elapsed < maxHoldAge else {
            return .rejectWithCue(.turnTooLong)
        }
        return .deferToQueue
    }

    /// Whether a held utterance is still worth replaying when the turn completes. The slot expires
    /// on the same clock that governs admission, so a phrase can never surface minutes later
    /// attached to nothing.
    static func heldUtteranceIsStillFresh(heldAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(heldAt) < maxHoldAge
    }
}

/// Plan CO Item 4 — how long to wait for a reply before ending the conversation.
///
/// `TranscriptionService` used a flat 2.0 s silence window, after which the conversation ends and
/// the app returns to the wake word. Two seconds is a statement's pause. When the assistant's own
/// answer is a *question* — a disambiguation, a save confirmation, or Item 1's new "that might be
/// Sam or Alex" — the user has to think, and thinking reliably takes longer than that. The window
/// closes underneath them and their answer arrives as a fresh wake-word utterance with nothing to
/// attach it to.
///
/// Item 1 makes question-shaped answers more common by design, which is why this ships alongside it.
enum SpeechContinuationPolicy {

    /// The shipped default, and the floor the *question* rule works from: that rule may lengthen
    /// the wait, never shorten it. Plan FE P3 lets the wearer choose a different window; this stays
    /// the value they get until they do, and the value every fixture without a setting assumes.
    static let baseWindow: TimeInterval = 2.0

    /// Plan FE P3 — the range a stored preference is allowed to take.
    ///
    /// The floor is not a matter of taste: below about a second the recognizer's own burst gaps
    /// read as silence and the turn is cut mid-sentence on nearly every utterance. The ceiling is
    /// there so a malformed or hostile stored value cannot leave the wearer with a mic that is hot
    /// for a minute with nothing to end it.
    static let minimumWindow: TimeInterval = 1.0
    static let maximumWindow: TimeInterval = 10.0

    /// The windows offered in Settings. Not a bound — `clampWindow` is — just the rungs of the
    /// ladder, from a clipped reply to dictating a paragraph a sentence at a time.
    static let presetWindows: [TimeInterval] = [1.5, 2.0, 3.0, 4.0, 6.0]

    /// Coerce a stored preference into something the timing code can use.
    ///
    /// Everything that is not a usable number becomes `baseWindow` rather than the nearest bound:
    /// NaN, an infinity, a negative, a missing value and a value of the wrong type all mean "we do
    /// not know what the wearer wanted", and the answer to that is the default they would have had
    /// anyway — not a 1-second window that cuts them off, nor a 10-second one that hangs.
    static func clampWindow(_ raw: Double?) -> TimeInterval {
        guard let raw, raw.isFinite, raw > 0 else { return baseWindow }
        return min(max(raw, minimumWindow), maximumWindow)
    }

    /// The preset to show as selected for an arbitrary stored window, so a value that arrived from
    /// somewhere else (an older build, a synced default) still renders as one of the rungs.
    static func nearestPreset(to window: TimeInterval) -> TimeInterval {
        let clamped = clampWindow(window)
        return presetWindows.min(by: { abs($0 - clamped) < abs($1 - clamped) }) ?? baseWindow
    }

    /// Window after the assistant has asked something. Long enough to think, short enough that a
    /// wearer who has walked away is not left with a hot mic.
    static let questionWindow: TimeInterval = 6.0

    /// Whether `text` reads as a question the user is expected to answer.
    ///
    /// Deliberately dumb. TTS sanitisation strips some punctuation, so a terminal `?` cannot be the
    /// only signal, and the cost asymmetry is stark: waiting too long is mildly awkward, cutting
    /// someone off mid-thought loses the turn entirely. When unsure, wait.
    static func isQuestionShaped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }

        // Punctuation-stripped forms: fall back to the interrogative opener of the final clause.
        let finalClause = trimmed
            .split(whereSeparator: { ".!?;\n".contains($0) })
            .last?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        let openers = ["which", "who", "what", "where", "when", "how", "why",
                       "do you", "did you", "would you", "should i", "shall i",
                       "can you", "could you", "is that", "are you", "want me to"]
        return openers.contains { finalClause.hasPrefix($0) }
    }

    /// The silence window to use after speaking `text`, given the wearer's chosen window.
    ///
    /// The question rule only ever *widens*. Someone who has asked for a 6- or 10-second pause
    /// because they dictate in sentences must not find that pause quietly cut to 6 the moment the
    /// assistant's reply happens to end in a question — that would be the CO Item 4 bug inverted,
    /// and it would only show up for the wearers who went looking for the setting in the first
    /// place. Hence `max`, not "replace with `questionWindow`".
    static func silenceWindow(afterSpeaking text: String?,
                              userWindow: TimeInterval = baseWindow) -> TimeInterval {
        let chosen = clampWindow(userWindow)
        guard let text, isQuestionShaped(text) else { return chosen }
        return max(chosen, questionWindow)
    }
}

/// Plan FE P3 — which window a turn is running under, and when a settings change takes effect.
///
/// The rule this type exists to make true: **a change applies from the next turn.** A turn already
/// in flight keeps the window it started with. Anything else means the wearer moves the slider,
/// the timer that is already armed re-arms underneath the sentence they are halfway through, and
/// the very act of asking for a longer pause cuts them off once. The settings footer says so in
/// as many words, so the rule is a promise, not an implementation detail.
///
/// It is a value type with no clock and no services precisely so the promise is testable without
/// a microphone: begin a turn, change the setting, assert the running window did not move, begin
/// the next one, assert it did.
struct SpeechTurnWindowLedger: Equatable {

    /// The assistant's last utterance, kept until it is replaced — the same lifetime the old
    /// `silenceThreshold` had, so a question asked two turns ago does not keep widening windows
    /// but a question asked just now still does.
    private var lastAssistantUtterance: String?

    /// The window the turn that is running right now started with.
    private(set) var currentWindow: TimeInterval

    init(currentWindow: TimeInterval = SpeechContinuationPolicy.baseWindow) {
        self.currentWindow = SpeechContinuationPolicy.clampWindow(currentWindow)
    }

    /// Whether the window in force right now was widened by the question rule.
    var isQuestionWidened: Bool {
        guard let lastAssistantUtterance else { return false }
        return SpeechContinuationPolicy.isQuestionShaped(lastAssistantUtterance)
    }

    /// Record what the assistant just said. Does **not** change the running window: the turn that
    /// is in flight is the one that was listening while the assistant spoke, and it keeps its own.
    mutating func noteAssistantSpoke(_ text: String?) {
        lastAssistantUtterance = text
    }

    /// Start a turn, adopting the wearer's setting exactly as it stands at this moment.
    @discardableResult
    mutating func beginTurn(userWindow: TimeInterval) -> TimeInterval {
        currentWindow = SpeechContinuationPolicy.silenceWindow(afterSpeaking: lastAssistantUtterance,
                                                               userWindow: userWindow)
        return currentWindow
    }
}
