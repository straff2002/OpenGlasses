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
        /// The reply says more than the tools' done summaries: a number they did not report, or
        /// more words than a confirmation takes (review follow-up 2026-11-10).
        case replyBeyondSummary
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
        // 7b. The reply says more than the tools reported — an answer the model gave from what it
        //     already knew ("…and it's 3:45"), beside the actions. Every doubt speaks.
        if ReplyBeyondSummaryCue.saysMore(input.reply, than: input.calls) {
            return .speak(reason: .replyBeyondSummary)
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

/// "Was this a question?" (Plan LA §2 rule 6). A language with no list reads every utterance as a
/// question, so it always speaks (decision 8).
///
/// Every sentence and every clause is read, not only the opening words: "turn off the kitchen
/// lights and what time is it" asks a question after the action, and a recogniser often writes no
/// question mark (review follow-up 2026-11-10). A sentence is a question when
/// - it ends in "?" and does not open with a polite request, or
/// - any of its clauses — the opening, or one that starts after a conjunction ("and", "then") or
///   a comma — opens with a question word or "tell me", once a polite opener is taken off.
///
/// A polite request is not a question: "can you turn off the lights?" asks for an action, and a
/// recogniser writes the question mark either way. Only the modal openers count as polite
/// requests; "did you…", "is the…" still ask about the world and are spoken. "Can you tell me…"
/// is a polite question, and speaks.
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

    /// Words that start a new clause inside a sentence, per language.
    static let clauseJoiners: [String: [String]] = [
        "en": ["and", "then", "also", "plus", "but", "so", "or", "and then", "and also"],
    ]

    static func supports(_ languageCode: String) -> Bool { leadingWords[base(languageCode)] != nil }

    static func isQuestion(_ utterance: String, languageCode: String) -> Bool {
        let language = base(languageCode)
        guard let words = leadingWords[language] else { return true }
        let polite = politeRequests[language] ?? []
        let joiners = (clauseJoiners[language] ?? []).sorted { $0.count > $1.count }
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")

        for (sentence, endsInQuestionMark) in sentences(of: text) {
            let opening = Substring(sentence)
            let politelyOpened = polite.contains { opens(opening, with: $0) }
            if endsInQuestionMark && !politelyOpened { return true }
            for clause in clauses(of: sentence, joiners: joiners) {
                var start = clause
                // "can you tell me…", "and could you check…": the request's verb decides.
                if let opener = polite.first(where: { opens(start, with: $0) }) {
                    start = start.dropFirst(opener.count).drop(while: { !$0.isLetter })
                }
                if start.hasPrefix("please ") { start = start.dropFirst("please ".count) }
                if words.contains(where: { opens(start, with: $0) }) { return true }
            }
        }
        return false
    }

    static func base(_ languageCode: String) -> String {
        String(languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// `text` opens with `phrase` as whole words.
    private static func opens(_ text: Substring, with phrase: String) -> Bool {
        text.hasPrefix(phrase + " ") || text.hasPrefix(phrase + ",") || text == Substring(phrase)
    }

    /// The sentences, split at ".", "!", "?" and ";", each with whether it ended in "?". A leading
    /// quote or dash does not change what the sentence is.
    private static func sentences(of text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        func flush(question: Bool) {
            let trimmed = String(current.drop(while: { !$0.isLetter })).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append((trimmed, question)) }
            current = ""
        }
        for character in text {
            switch character {
            case "?": flush(question: true)
            case ".", "!", ";": flush(question: false)
            default: current.append(character)
            }
        }
        flush(question: false)
        return result
    }

    /// A sentence's clauses: its opening, and each part after a comma, a dash or a joining word.
    private static func clauses(of sentence: String, joiners: [String]) -> [Substring] {
        // Commas and dashes break a clause; then each joining word does.
        let separated = sentence.map { $0 == "," || $0 == "\u{2014}" || $0 == "\u{2013}" ? "|" : $0 }
        var parts: [Substring] = []
        for piece in String(separated).split(separator: "|") {
            let tokens = piece.split(separator: " ", omittingEmptySubsequences: true)
            var clause: [Substring] = []
            var index = 0
            while index < tokens.count {
                // The longest joiner that starts here ("and then" before "and").
                if let joiner = joiners.first(where: { joiner in
                    let joinerTokens = joiner.split(separator: " ")
                    return index + joinerTokens.count <= tokens.count
                        && Array(tokens[index..<index + joinerTokens.count]) == joinerTokens
                }) {
                    if !clause.isEmpty { parts.append(Substring(clause.joined(separator: " "))) }
                    clause = []
                    index += joiner.split(separator: " ").count
                    continue
                }
                clause.append(tokens[index])
                index += 1
            }
            if !clause.isEmpty { parts.append(Substring(clause.joined(separator: " "))) }
        }
        return parts.map { $0.drop(while: { !$0.isLetter }) }
    }
}

/// "Does the reply say more than the tools reported?" (review follow-up 2026-11-10, after Plan LA
/// §2 rule 7). A quiet ending stands in for a confirmation, so the reply it replaces must be one:
/// - **No number the summaries don't carry.** "Timer set for 10 minutes." beside "Timer 10
///   minutes" is a confirmation; "Lights off. It's 3:45." answered something no tool reported.
///   Number words count as their digits ("ten" is 10), so "Ten-minute timer set." still confirms.
/// - **Short.** A confirmation is a phrase per action — "Okay, I've turned off the kitchen
///   lights." is seven words — so a reply longer than `wordAllowance(forCalls:)` is saying
///   something else, and speaks.
/// Pure, and English-shaped; a language without word lists never reaches it (rule 6 speaks).
enum ReplyBeyondSummaryCue {
    /// Six words per action plus six for the "okay, I've … and …" around them.
    static func wordAllowance(forCalls count: Int) -> Int { 6 + 6 * max(count, 1) }

    static func saysMore(_ reply: String, than calls: [QuietTurnCall]) -> Bool {
        let words = reply.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        if words.count > wordAllowance(forCalls: calls.count) { return true }
        let reported = calls.compactMap { $0.completion?.doneSummary }.joined(separator: " ")
        return !numbers(in: reply).isSubset(of: numbers(in: reported))
    }

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
    ]

    /// Every run of digits, and every number word, as a value ("07" and "seven" are both 7).
    static func numbers(in text: String) -> Set<Int> {
        var found = Set<Int>()
        let tokens = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        for token in tokens {
            if let word = numberWords[String(token)] { found.insert(word); continue }
            // "10am", "3pm": each run of digits inside a token.
            var digits = ""
            for character in token {
                if character.isASCII, character.isNumber { digits.append(character); continue }
                if let value = Int(digits) { found.insert(value) }
                digits = ""
            }
            if let value = Int(digits) { found.insert(value) }
        }
        return found
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
