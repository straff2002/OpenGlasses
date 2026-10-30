import Foundation

/// Decides when a sentence of a streamed reply may be handed to speech (Plan HZ P0).
///
/// The splitter knows where sentences end; it does not know whether a sentence is *final*. The
/// turn path still rewrites some replies after generation — memory commands are parsed out of
/// them, a numbered choice list becomes HUD buttons — and a local reasoning model opens with a
/// block nobody should hear. Speaking any of that early would say something `speak(response)`
/// never would, and the plan's one hard rule is that streaming changes *when* words are said,
/// never *which*. So the gate holds:
///
/// - **while think filtering is undecided.** Chunks pass through a `ThinkStreamFilter` first;
///   until an open block closes, nothing after it reaches the splitter at all.
/// - **for the rest of the reply** once `Rules.holdWholeReply` says the text so far has a shape
///   later processing rewrites (a memory command by default), or `Rules.looksLikeChoiceList` says
///   its opening is a choice list. What is held is spoken whole at the end, as it is today, by the
///   caller — `reconcile(reply:spoken:)` says what is left to say.
///
/// One gate covers one *iteration* of the tool loop. `endIteration()` is the stream reset: the
/// iteration's last complete sentence may still be released (a preamble — "Let me check the
/// forecast." — said before the tool runs), and the next iteration starts clean.
///
/// A class rather than a struct only because the think filter it wraps is one; it holds no audio,
/// no clock and no app state, and is driven entirely by its inputs.
final class StreamSpeechGate {

    /// The predicates, injected so the app can pass its live settings and a test its own shapes.
    struct Rules {
        /// True when the text so far may still be rewritten by post-processing. Latches.
        var holdWholeReply: (String) -> Bool = StreamSpeechGate.looksLikeMemoryCommand
        /// True when the reply's opening looks like a choice list. Latches.
        var looksLikeChoiceList: (String) -> Bool = StreamSpeechGate.looksLikeChoiceListOpening

        static let `default` = Rules()
    }

    /// Why the rest of the reply is being held.
    enum HoldReason: String, Equatable {
        case rewrite
        case choiceList
    }

    private let rules: Rules
    private let limits: SentenceStreamSplitter.Limits
    private var thinkFilter = ThinkStreamFilter(startsInThink: false)
    private var splitter: SentenceStreamSplitter

    /// The iteration's speakable text so far (think blocks removed).
    private(set) var text = ""
    /// The sentences released to speech in this iteration, in order.
    private(set) var released: [String] = []
    /// Set once the rest of the iteration is held for the end.
    private(set) var holdReason: HoldReason?

    init(rules: Rules = .default, limits: SentenceStreamSplitter.Limits = .default) {
        self.rules = rules
        self.limits = limits
        self.splitter = SentenceStreamSplitter(limits: limits)
    }

    var isHolding: Bool { holdReason != nil }

    /// Feed one chunk; returns the sentences that may be spoken now.
    func ingest(_ chunk: String) -> [String] {
        let visible = thinkFilter.ingest(chunk)
        guard !visible.isEmpty else { return [] }
        text += visible
        guard holdReason == nil else { return [] }
        if rules.holdWholeReply(text) {
            holdReason = .rewrite
            return []
        }
        if rules.looksLikeChoiceList(text) {
            holdReason = .choiceList
            return []
        }
        let sentences = splitter.ingest(visible)
        released += sentences
        return sentences
    }

    /// The stream reset: the tool loop is starting a new iteration (or the cascade a new model).
    ///
    /// Returns the iteration's last sentence when it is complete and nothing is holding — the
    /// preamble a tool turn opens with. A fragment cut off mid-clause (a model that failed half
    /// way through a sentence) is dropped, not spoken. Everything is then cleared for the next
    /// iteration, including a hold: the held text belonged to an iteration whose words are not the
    /// reply.
    func endIteration() -> [String] {
        var tail: [String] = []
        if holdReason == nil {
            let rest = thinkFilter.flush()
            if !rest.isEmpty {
                text += rest
                if !rules.holdWholeReply(text), !rules.looksLikeChoiceList(text) {
                    tail = splitter.ingest(rest)
                }
            }
            if holdReason == nil, !rules.holdWholeReply(text), !rules.looksLikeChoiceList(text) {
                tail += splitter.flushIfComplete()
            }
        }
        thinkFilter = ThinkStreamFilter(startsInThink: false)
        splitter = SentenceStreamSplitter(limits: limits)
        text = ""
        released = []
        holdReason = nil
        return tail
    }

    // MARK: - Default rules

    /// Memory-command tags `SemanticMemoryStore.parseAndExecuteCommands` strips from a reply.
    static let memoryCommandOpeners = ["[REMEMBER", "[FORGET", "[DIARY"]

    /// The reply carries a memory command, so post-processing will rewrite it.
    static func looksLikeMemoryCommand(_ text: String) -> Bool {
        memoryCommandOpeners.contains { text.contains($0) }
    }

    /// How far into a reply its "opening" runs, for the choice-list rule.
    static let choiceOpeningLength = 300

    /// The reply opens like a choice list `ChoiceDetector` would turn into buttons: a lettered
    /// item ("A) …", "b. …") at the start of a line, or a numbered one with a choice cue (a
    /// question mark, "which", "pick", "choose", "prefer", "option") before it. Numbered steps with
    /// no cue are instructions and stream like any prose.
    static func looksLikeChoiceListOpening(_ text: String) -> Bool {
        let opening = String(text.prefix(choiceOpeningLength))
        var offset = 0
        for line in opening.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { offset += line.count + 1 }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let marker = trimmed.first else { continue }
            let rest = trimmed.dropFirst()
            if marker.isLetter, "ABCDEabcde".contains(marker),
               let punct = rest.first, punct == ")" || punct == ".",
               rest.dropFirst().first == " " {
                return true
            }
            let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 2 else { continue }
            let after = trimmed.dropFirst(digits.count)
            guard let punct = after.first, punct == ")" || punct == "." else { continue }
            let before = opening.prefix(offset).lowercased()
            if before.contains("?") || ["which", "pick", "choose", "prefer", "option"]
                .contains(where: { before.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - The end of the reply

    /// What is left to say once the reply is final.
    struct Reconciliation: Equatable {
        /// The words of the reply not yet spoken, in reply order; empty when nothing is left.
        let remainder: String
        /// Whether what was spoken is part of the reply. False when the reply that came back is
        /// not the text that was streamed — a yield, a wrap-up — in which case what was spoken was
        /// a preamble and the whole reply is still owed.
        let spokenIsPartOfReply: Bool
    }

    /// Reconcile the final reply with the sentences already spoken from this iteration.
    ///
    /// Whitespace is ignored on both sides: the splitter trims, and the reply has been trimmed and
    /// joined by layers that never saw the stream. When the spoken text opens the reply (the
    /// normal case), the remainder is what follows it. When the reply has gained a prefix the
    /// stream never carried — a notice composed after generation — the remainder is that prefix
    /// and what follows. When the spoken text is not in the reply at all, the whole reply remains.
    static func reconcile(reply: String, spoken: [String]) -> Reconciliation {
        let spokenChars = Array(spoken.joined().filter { !$0.isWhitespace })
        let replyChars = Array(reply)
        guard !spokenChars.isEmpty else {
            return Reconciliation(remainder: trimmedText(reply), spokenIsPartOfReply: true)
        }
        // Positions of the reply's non-whitespace characters, so a match maps back to the reply.
        var positions: [Int] = []
        var letters: [Character] = []
        for (index, char) in replyChars.enumerated() where !char.isWhitespace {
            positions.append(index)
            letters.append(char)
        }
        guard let start = firstMatch(of: spokenChars, in: letters) else {
            // Plan KD P3: the reply's repeated end was collapsed (`RepeatedReplyCollapse`) after
            // the stream had already said some of the repeat. What was said is the reply's own
            // sentences with one said twice, not a preamble: the reply carries on after the
            // furthest of them, rather than being said again in full.
            if let end = endOfRepeatedSentences(spoken, in: letters) {
                let after = trimmedText(String(replyChars[(positions[end - 1] + 1)...]))
                return Reconciliation(remainder: after, spokenIsPartOfReply: true)
            }
            return Reconciliation(remainder: trimmedText(reply), spokenIsPartOfReply: false)
        }
        let matchStart = positions[start]
        let matchEnd = positions[start + spokenChars.count - 1] + 1
        let before = trimmedText(String(replyChars[..<matchStart]))
        let after = trimmedText(String(replyChars[matchEnd...]))
        let remainder = [before, after].filter { !$0.isEmpty }.joined(separator: " ")
        return Reconciliation(remainder: remainder, spokenIsPartOfReply: true)
    }

    /// When every spoken sentence is in the reply and at least one was spoken twice, the end (in
    /// the reply's non-whitespace characters) of the furthest of them; else nil.
    private static func endOfRepeatedSentences(_ spoken: [String], in letters: [Character]) -> Int? {
        let sentences = spoken.map { Array($0.filter { !$0.isWhitespace }) }.filter { !$0.isEmpty }
        guard Set(sentences.map { String($0) }).count < sentences.count else { return nil }
        var end = 0
        for sentence in sentences {
            guard let start = firstMatch(of: sentence, in: letters) else { return nil }
            end = max(end, start + sentence.count)
        }
        return end > 0 ? end : nil
    }

    private static func firstMatch(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where haystack[start] == needle[0] && Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }

    private static func trimmedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
