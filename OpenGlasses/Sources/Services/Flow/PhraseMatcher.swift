import Foundation

/// Token-level phrase matching for voice commands — the shared primitive behind
/// `VoiceCommandParser` and `WakeWordService`'s barge-in path.
///
/// # Why this exists
///
/// Command recognition was doing `transcript.contains(phrase)`. That is `String.contains` doing
/// exactly what `String.contains` does, and it fires on words that merely *contain* the phrase:
/// `"it stopped working yesterday"`, `"nonstop"`, `"stops"` and `"unstoppable"` all read as a stop
/// command. There were also two matchers — one careful, one naive — and the naive one was the
/// barge-in path, i.e. the one that matters most.
///
/// Matching happens over **tokens**, not characters, so a phrase must occupy whole words. ASR
/// punctuation (`"stop."`, `"stop,"`) is handled by tokenising on non-alphanumerics rather than by
/// splitting on spaces.
enum PhraseMatcher {

    /// Split into lowercase alphanumeric tokens, discarding punctuation.
    ///
    /// Apostrophes are kept inside words so `"that's"` stays one token and matches the phrase
    /// `"that's all"` as written.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Where `phrase` occurs in `tokens` as a whole-token subsequence — every occurrence, in order.
    ///
    /// Returns token index ranges so callers can reason about *position*, which is what the
    /// demotion rules in `VoiceCommandParser` need (is the match inside a question frame? does it
    /// end the utterance?).
    static func ranges(of phrase: String, in tokens: [String]) -> [Range<Int>] {
        let needle = tokenize(phrase)
        guard !needle.isEmpty, tokens.count >= needle.count else { return [] }
        var found: [Range<Int>] = []
        for start in 0...(tokens.count - needle.count) {
            if Array(tokens[start..<(start + needle.count)]) == needle {
                found.append(start..<(start + needle.count))
            }
        }
        return found
    }

    /// Whether `phrase` occurs as a whole-token subsequence.
    static func contains(_ phrase: String, in tokens: [String]) -> Bool {
        !ranges(of: phrase, in: tokens).isEmpty
    }

    // MARK: - Stop-phrase recall

    /// Words ASR has been seen to run onto the end of "stop" with no space.
    ///
    /// This exists because tightening the stop predicate moves risk from false-positive to
    /// **false-negative**, and that is the dangerous direction: a missed "stop" means the user
    /// cannot interrupt the assistant. A bare word-boundary test would lose `"stopit"`.
    ///
    /// It is a closed list of words people actually say after "stop", and it must **never** admit
    /// an inflection — `"stopped"`, `"stopping"` and `"stops"` are the original bug. Pinned by
    /// `testStopJoinSuffixesAdmitNoInflections`.
    static let stopJoinSuffixes: Set<String> = [
        "it", "now", "please", "talking", "speaking", "there", "stop",
    ]

    /// How much of the utterance a stop phrase has to occupy.
    ///
    /// The two callers want genuinely different answers, so this is explicit rather than two
    /// predicates drifting apart:
    ///
    /// - ``anywhere`` — the barge-in path, where the phrase list is just "stop" and its persona
    ///   variants. `"okay stop that's wrong"` is a real mid-utterance stop, and the cost of a false
    ///   positive is only that speech halts (the voice-activity barge-in beside it already
    ///   interrupts on any two-word utterance).
    /// - ``utteranceEdge`` — classifying a completed turn, where a match *consumes* the utterance
    ///   instead of answering it. That list includes ordinary words like "quiet" and "cancel", so a
    ///   match anywhere would swallow `"I need peace and quiet to concentrate"` rather than
    ///   replying to it.
    enum StopPosition {
        case anywhere
        case utteranceEdge
    }

    /// Whether any of `phrases` is present as a stop command.
    ///
    /// Whole-token matching, plus the join allowance above for single-word phrases.
    static func containsStopPhrase(
        _ text: String,
        phrases: [String],
        position: StopPosition = .anywhere
    ) -> Bool {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return false }
        for phrase in phrases {
            for range in ranges(of: phrase, in: tokens) {
                switch position {
                case .anywhere:
                    return true
                case .utteranceEdge:
                    if range.lowerBound == 0 || range.upperBound == tokens.count { return true }
                }
            }
            // Join allowance: single-word phrase run together with a following word. Always at the
            // edge by construction for a one-word utterance, and the recall this protects ("stopit")
            // matters in both modes.
            let needle = tokenize(phrase)
            guard needle.count == 1, let word = needle.first else { continue }
            for (index, token) in tokens.enumerated() where token.hasPrefix(word) && token != word {
                let suffix = String(token.dropFirst(word.count))
                guard stopJoinSuffixes.contains(suffix) else { continue }
                switch position {
                case .anywhere: return true
                case .utteranceEdge:
                    if index == 0 || index == tokens.count - 1 { return true }
                }
            }
        }
        return false
    }
}
