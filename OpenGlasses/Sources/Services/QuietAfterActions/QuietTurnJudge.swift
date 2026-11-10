import Foundation

/// One tool call of the turn, as the quiet-ending judge sees it (Plan LA §2).
struct QuietTurnCall: Equatable, Sendable {
    /// How the call ended, without its text.
    enum Outcome: String, Equatable, Sendable {
        case completed
        case rejected
        case failedBeforeExecution
        case outcomeUnknown
        /// Dispatched and not yet back — never the case for a finished turn, and never quiet.
        case running

        init(_ outcome: ToolExecutionOutcome) {
            switch outcome {
            case .completed: self = .completed
            case .rejected: self = .rejected
            case .failedBeforeExecution: self = .failedBeforeExecution
            case .outcomeUnknown: self = .outcomeUnknown
            }
        }
    }

    let tool: String
    /// The call's effect after `ToolEffectClassifier.isReadAction`.
    let effect: ToolEffect
    let outcome: Outcome
    /// What the tool reported (`ActionCompletionReport`); nil for no report.
    let completion: ActionCompletion?
    /// A tool this app ships, not an MCP server's or the gateway's.
    let isNative: Bool

    /// The call could end a turn quietly on its own account: a reviewed native tool that changed
    /// something, completed, and reported `.done`.
    var isQuietCapable: Bool {
        isNative && QuietActionRoster.isReviewed(tool) && effect != .readOnly
            && outcome == .completed && completion?.isDone == true
    }
}

/// Everything the judge reads about one turn (Plan LA §2). Pure data.
struct QuietTurnInput: Equatable, Sendable {
    enum Origin: String, Equatable, Sendable {
        /// A Direct-mode turn the wearer spoke: the only one that can end quiet.
        case spokenDirect
        case typed
        case siri
        case live
    }

    /// The Quiet After Actions setting.
    var enabled: Bool
    var simpleMode: Bool
    var voiceOverRunning: Bool
    var origin: Origin
    /// The turn's language code ("en", "de"), from the speech locale.
    var languageCode: String
    /// The wearer's words, only to ask "was this a question?".
    var utterance: String
    var calls: [QuietTurnCall]
    /// The final reply, follow-ups tail already taken off.
    var reply: String
    /// The reply came with a follow-ups tail (`FollowUpTail`).
    var hasFollowUps: Bool
}

/// The verdict, and why (Plan LA §2). The reason is logged and tested; it is never spoken.
enum QuietTurnVerdict: Equatable, Sendable {
    case quiet(summary: String)
    case speak(reason: SpeakReason)

    enum SpeakReason: String, Equatable, Sendable {
        /// Setting off, Simple Mode, or not a spoken Direct turn.
        case notApplicable
        /// No tool ran: a plain answer is an answer.
        case noAction
        /// Something was refused, failed, timed out, partly done, or not vouched for.
        case notAllDone
        /// Something was looked up.
        case lookup
        /// The wearer asked a question.
        case askedQuestion
        /// The reply asks something, offers follow-ups or carries a caveat.
        case replyHasMore
    }

    var isQuiet: Bool {
        if case .quiet = self { return true }
        return false
    }

    /// For the trace: "quiet", or "speak: lookup".
    var traceToken: String {
        switch self {
        case .quiet: return "quiet"
        case .speak(let reason): return "speak: \(reason.rawValue)"
        }
    }
}

/// Decides, once per turn, whether a finished turn ends with the done tone or is spoken (Plan LA
/// §2). Pure. The rules run in order and the first that applies decides; every doubt speaks.
enum QuietTurnJudge {

    static func judge(_ input: QuietTurnInput) -> QuietTurnVerdict {
        // 1. Only a spoken Direct turn, with the setting on and Simple Mode off.
        guard input.enabled, !input.simpleMode, input.origin == .spokenDirect else {
            return .speak(reason: .notApplicable)
        }
        // 2. No tool ran.
        guard !input.calls.isEmpty else { return .speak(reason: .noAction) }
        // 3. Anything refused, failed before running, timed out or still running.
        if input.calls.contains(where: { $0.outcome != .completed }) {
            return .speak(reason: .notAllDone)
        }
        // 4. Lookups always speak, alone or beside an action.
        if input.calls.contains(where: { $0.effect == .readOnly }) {
            return .speak(reason: .lookup)
        }
        // 5. Every call must be a reviewed native tool that reported `.done`.
        guard input.calls.allSatisfy(\.isQuietCapable) else { return .speak(reason: .notAllDone) }
        // 6. The wearer asked a question ("did you turn the lights off?").
        if UtteranceQuestionCue.isQuestion(input.utterance, languageCode: input.languageCode) {
            return .speak(reason: .askedQuestion)
        }
        // 7. The reply asks something, offers more, or hedges — the model knows something the
        //    tools did not report.
        if input.hasFollowUps
            || ReplyCaveatCue.hasMore(input.reply, languageCode: input.languageCode) {
            return .speak(reason: .replyHasMore)
        }
        // 8. Quiet.
        return .quiet(summary: summary(of: input.calls))
    }

    /// The calls' `done` summaries, each once, in order: "Kitchen lights off · Timer 10 minutes".
    static func summary(of calls: [QuietTurnCall]) -> String {
        var seen = Set<String>()
        let parts = calls.compactMap { $0.completion?.doneSummary }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
    }

    // MARK: - The stream gate's questions (Plan LA §3, §4)

    /// Hold the preamble said before this round's tools: every call is a reviewed native tool that
    /// changes something. The round's calls are read after they ran, at the stream reset, but
    /// only their names and effects are needed — the preamble is held before anything is known
    /// about how they ended.
    static func holdsPreamble(forRound calls: [QuietTurnCall]) -> Bool {
        !calls.isEmpty && calls.allSatisfy { $0.isNative && QuietActionRoster.isReviewed($0.tool)
            && $0.effect != .readOnly }
    }

    /// Hold the next iteration whole: every call of the round just finished could end the turn
    /// quietly. The judge then sees the whole reply before any of it is spoken.
    static func holdsNextIteration(afterRound calls: [QuietTurnCall]) -> Bool {
        !calls.isEmpty && calls.allSatisfy(\.isQuietCapable)
    }
}

// MARK: - Word cues

/// "Was this a question?" (Plan LA §2 rule 6). A trailing question mark, or a leading question
/// word from the language's list. A language with no list reads every utterance as a question, so
/// it always speaks (decision 8).
///
/// A polite request is not a question: "can you turn off the lights?" asks for an action, and a
/// recogniser writes the question mark either way. Only the modal openers count as polite
/// requests; "did you…", "is the…" still ask about the world and are spoken.
enum UtteranceQuestionCue {
    static let leadingWords: [String: [String]] = [
        "en": ["did", "is", "are", "was", "were", "do", "does", "have", "has", "should",
               "what", "what's", "whats", "which", "who", "when", "where", "why", "how", "how's",
               "tell me", "check"],
    ]

    /// Openers that make a request of an action, per language.
    static let politeRequests: [String: [String]] = [
        "en": ["can you", "could you", "would you", "will you", "can u", "please can you",
               "please could you"],
    ]

    static func supports(_ languageCode: String) -> Bool { leadingWords[base(languageCode)] != nil }

    static func isQuestion(_ utterance: String, languageCode: String) -> Bool {
        let language = base(languageCode)
        guard let words = leadingWords[language] else { return true }
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        // A leading quote or dash does not change what the sentence is.
        let opening = trimmed.drop(while: { !$0.isLetter })
        func opens(with phrase: String) -> Bool {
            opening.hasPrefix(phrase + " ") || opening.hasPrefix(phrase + ",") || opening == Substring(phrase)
        }
        if (politeRequests[language] ?? []).contains(where: opens) { return false }
        if trimmed.hasSuffix("?") { return true }
        return words.contains(where: opens)
    }

    static func base(_ languageCode: String) -> String {
        String(languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }
}

/// "Does the reply ask something or carry a caveat?" (Plan LA §2 rule 7). A question mark, or a
/// word from a short per-language list ("couldn't", "but", "only"…). A language with no list
/// reads every reply as carrying one, so it always speaks (decision 8).
enum ReplyCaveatCue {
    static let caveatWords: [String: [String]] = [
        "en": ["couldn't", "could not", "can't", "cannot", "but", "only", "instead", "didn't",
               "did not", "unable", "not", "however", "although", "though", "except", "failed",
               "won't", "wasn't", "isn't", "no ", "unfortunately", "sorry", "tap", "open the",
               "partly", "partially", "some of"],
    ]

    static func hasMore(_ reply: String, languageCode: String) -> Bool {
        guard let words = caveatWords[UtteranceQuestionCue.base(languageCode)] else { return true }
        let text = " " + reply.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if text.contains("?") { return true }
        // Whole words only: "not" must not match "note", "but" must not match "button".
        let separated = text.map { $0.isLetter || $0 == "'" ? $0 : " " }
        let spaced = " " + String(separated).split(separator: " ").joined(separator: " ") + " "
        return words.contains { word in
            let needle = word.trimmingCharacters(in: .whitespaces)
            return spaced.contains(" " + needle + " ")
        }
    }
}
