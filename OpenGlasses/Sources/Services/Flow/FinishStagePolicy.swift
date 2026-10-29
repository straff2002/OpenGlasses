import Foundation

/// What the end of a turn should do with the microphone and the conversation.
///
/// Issue 427 follow-up. The finish stage used to be an `if listeningEnabled` guard with a bare
/// `return`, which looked like "don't touch the mic" but actually meant "leave the conversation
/// open forever": `inConversation` stayed `true`, and `onWakeWordDetected`'s
/// `guard !inConversation && !isProcessing` then dropped every later wake word as
/// `alreadyProcessing` until the app was force-quit. Field trace (build 371):
/// `tts finished; wakeWord listenerSkippedDisabled` at 16:11:10, then `wakeWord detected;
/// app alreadyProcessing detail=wakeWord` at 16:11:49.
///
/// Turning the master toggle off must still *end* the conversation — it only forbids re-opening
/// the mic, and `returnToWakeWord()` already checks the toggle again before it does that.
enum FinishStagePolicy {

    enum Action: Equatable {
        /// Stay in the conversation and listen for a follow-up utterance.
        case resumeDictation
        /// Reset conversation state and hand back to `returnToWakeWord()`, which re-checks the
        /// master toggle (and silent mode, connection, mute) before touching the microphone.
        case endConversation
    }

    /// - Parameters:
    ///   - listeningEnabled: the user's master listening toggle.
    ///   - inConversation: whether a conversation is still open.
    ///   - singleQuestion: the wearer's "One Question at a Time" setting
    ///     (`Config.singleQuestionPerActivation`).
    ///   - answerOwed: whether the turn just finished asked the wearer something
    ///     (`answerOwed(lastSpoken:appAskedQuestion:handsFreeModeRunning:)`).
    static func action(listeningEnabled: Bool, inConversation: Bool,
                       singleQuestion: Bool = false, answerOwed: Bool = false) -> Action {
        // The toggle being off never means "do nothing" — that is the stranding bug. It means
        // close the conversation and leave the mic shut.
        guard listeningEnabled else { return .endConversation }
        guard inConversation else { return .endConversation }
        // One question per activation: the answer ends the conversation unless it asked one back.
        if singleQuestion && !answerOwed { return .endConversation }
        return .resumeDictation
    }

    // MARK: - One question per activation (Plan KD P1)

    /// Whether the end of this turn owes the wearer a chance to answer, which is the one case
    /// "One Question at a Time" still reopens the microphone.
    ///
    /// Build 581: after every answer the app reopened the mic for a follow-up, and with the phone's
    /// mic under the glasses' speakers that mic heard the end of the answer and the room. The
    /// wearer asked for one activation per question — wake word or Tap & Talk, a cue, the question,
    /// a cue, the answer, then nothing until they ask again. But a turn that ended on a question
    /// is not finished: the app's own job-number question, a rule chain asking for the next value,
    /// "which size did you mean?". Shutting the mic on those makes the wearer say the wake word
    /// just to answer what they were asked.
    ///
    /// The rule is deliberately plain so it can be predicted: the follow-up is owed when the app
    /// itself just asked a question (`GuidedJobFlow.speakPendingQuestionIfDue()`), when the last
    /// thing spoken ends with a question mark (`endsWithQuestionMark`), or while a hands-free mode
    /// that is driven by voice commands (the teleprompter) is running. Each answer earns one more
    /// capture only if it, too, asks — so a chain of questions keeps going and an answer that
    /// does not ask ends the conversation. Punctuation and nothing else: no wording is read, so
    /// the rule is the same in every language. A reply that ends with a courtesy question
    /// ("Anything else?") does reopen the mic; that is the price of not guessing.
    static func answerOwed(lastSpoken: String?, appAskedQuestion: Bool,
                           handsFreeModeRunning: Bool) -> Bool {
        appAskedQuestion || handsFreeModeRunning || endsWithQuestionMark(lastSpoken)
    }

    /// Question marks in the scripts the app speaks: Latin, full-width (Chinese, Japanese) and
    /// Arabic.
    static let questionMarks: Set<Character> = ["?", "\u{FF1F}", "\u{061F}"]

    /// Closing marks that may follow the question mark: quotes and brackets.
    static let trailingClosers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{300D}", "\u{FF09}"]

    /// Whether `text` ends with a question mark, ignoring trailing whitespace and closing marks.
    static func endsWithQuestionMark(_ text: String?) -> Bool {
        guard var rest = text?.trimmingCharacters(in: .whitespacesAndNewlines)[...] else { return false }
        while let last = rest.last, trailingClosers.contains(last) || last.isWhitespace {
            rest = rest.dropLast()
        }
        guard let last = rest.last else { return false }
        return questionMarks.contains(last)
    }
}

/// What "One Question at a Time" is when the wearer has not set it (Plan KD P1).
///
/// On for Field Assist, off elsewhere. A technician on a job asks one thing at a time and answers
/// come back over speakers the phone's mic can hear; an assistant that reopens the mic after every
/// answer is what took the app's own voice back as a question in build 581. Everyone else keeps
/// the conversation they have today. A stored value — the wearer's choice — always wins.
enum SingleQuestionDefault {
    static func resolve(stored: Bool?, fieldAssistActive: Bool) -> Bool {
        stored ?? fieldAssistActive
    }
}
