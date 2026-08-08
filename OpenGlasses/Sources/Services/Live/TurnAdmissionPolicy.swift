import Foundation

/// Plan CO Item 3 — what happens to speech that arrives while a turn is already in flight.
///
/// The old guard was one line:
///
/// ```swift
/// guard !self.isProcessing else {
///     print("⚠️ Transcription ignored - already processing")
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

    /// Today's window, and the floor: this policy may lengthen the wait, never shorten it.
    static let baseWindow: TimeInterval = 2.0

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

    /// The silence window to use after speaking `text`.
    static func silenceWindow(afterSpeaking text: String?) -> TimeInterval {
        guard let text, isQuestionShaped(text) else { return baseWindow }
        return questionWindow
    }
}
