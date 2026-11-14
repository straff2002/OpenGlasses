import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where in an utterance a wake-phrase alternative may match (Plan LT §5). Pure: the lexicon is a
/// closure, so the rule is tested against a fixed word list and the device reads the system one.
///
/// An alternative made only of ordinary words — "summary" for a phrase a recogniser hears that
/// way, "small tree", "even kin" — is also something people say. Matched anywhere, as every
/// candidate was before LT, it wakes the assistant in the middle of a sentence about something
/// else. So an alternative whose every token is an ordinary word in the wake language matches only
/// at the **start of an utterance**, optionally after one opener ("hey", "ok"):
///
/// - the first token of the recogniser's current result, or
/// - the first token after a pause of at least `minimumGap` between segments, where the
///   recogniser gives segment timestamps (it often gives none until a result is final).
///
/// The primary phrase, and alternatives with a word the lexicon does not know (an invented name,
/// a misspelling), keep matching anywhere: "what's on my list, Avenkin" must still wake.
enum WakeAlternativePosition {

    /// One recogniser segment: its text and when it was said, in seconds from the start of audio.
    struct Segment: Equatable {
        let text: String
        let timestamp: TimeInterval
        let duration: TimeInterval
    }

    /// A pause at least this long between two segments starts a new utterance.
    static let minimumGap: TimeInterval = 0.7

    /// Whether `phrase`, an alternative for `primary`, may match only at the start of an
    /// utterance: it is an alternative (differs from its primary) and every token is an ordinary
    /// word by `isOrdinaryWord`.
    static func isStartBound(phrase: String, primary: String,
                             isOrdinaryWord: (String) -> Bool) -> Bool {
        let tokens = PhraseMatcher.tokenize(phrase)
        guard !tokens.isEmpty, tokens != PhraseMatcher.tokenize(primary) else { return false }
        return tokens.allSatisfy(isOrdinaryWord)
    }

    /// `candidates` with `startOnly` set by `isStartBound`. A candidate already start-only stays so.
    static func marked(_ candidates: [WakePhraseMatcher.Candidate],
                       isOrdinaryWord: (String) -> Bool) -> [WakePhraseMatcher.Candidate] {
        candidates.map { candidate in
            guard !candidate.startOnly,
                  isStartBound(phrase: candidate.phrase, primary: candidate.primary,
                               isOrdinaryWord: isOrdinaryWord) else { return candidate }
            return WakePhraseMatcher.Candidate(phrase: candidate.phrase, primary: candidate.primary,
                                               startOnly: true)
        }
    }

    /// Token indices that begin an utterance: 0, and the first token of every segment that follows
    /// a pause of at least `minimumGap`. With no segments, or segments whose tokens do not add up
    /// to `tokenCount` (so they cannot be lined up with the transcript), only 0.
    static func utteranceStarts(tokenCount: Int, segments: [Segment]) -> Set<Int> {
        guard tokenCount > 0 else { return [] }
        var starts: Set<Int> = [0]
        guard !segments.isEmpty else { return starts }
        let counts = segments.map { PhraseMatcher.tokenize($0.text).count }
        guard counts.reduce(0, +) == tokenCount else { return starts }
        var index = 0
        for (i, segment) in segments.enumerated() {
            if i > 0, counts[i] > 0 {
                let previous = segments[i - 1]
                let gap = segment.timestamp - (previous.timestamp + previous.duration)
                if gap >= minimumGap { starts.insert(index) }
            }
            index += counts[i]
        }
        return starts
    }

    /// Where a start-bound alternative may begin: each utterance start, and the token after it
    /// when that token is an opener.
    static func allowedStarts(tokens: [String], utteranceStarts: Set<Int>,
                              openers: Set<String>) -> Set<Int> {
        var allowed = utteranceStarts
        for start in utteranceStarts where start < tokens.count && openers.contains(tokens[start]) {
            allowed.insert(start + 1)
        }
        return allowed
    }

    /// The openers a wake phrase may follow at the start, for a language code ("en", "de-DE").
    /// The English four apply everywhere; a few languages add their own greeting.
    static func openers(forLanguage code: String?) -> Set<String> {
        let common: Set<String> = ["hey", "ok", "okay", "hi"]
        let language = code.map { String($0.prefix { $0 != "-" && $0 != "_" }).lowercased() }
        switch language {
        case "de": return common.union(["hallo"])
        case "fr": return common.union(["salut", "hé"])
        case "es": return common.union(["oye", "hola"])
        case "it": return common.union(["ehi", "ciao"])
        case "pt": return common.union(["oi", "olá", "ei"])
        case "nl": return common.union(["hoi", "hé"])
        default: return common
        }
    }
}

#if canImport(UIKit)
/// The system lexicon behind `WakeAlternativePosition` on the device: a word is ordinary when
/// `UITextChecker` finds it correctly spelled in the wake language. A language the checker has no
/// dictionary for makes no word ordinary, so every alternative keeps matching anywhere, as before.
@MainActor
enum WakeLexicon {
    private static var cache: [String: Bool] = [:]

    /// The checker language for a recogniser locale ("en-US" → "en_US"), or the first available
    /// dictionary for the same language, or nil.
    static func checkerLanguage(forLocaleIdentifier identifier: String) -> String? {
        let available = UITextChecker.availableLanguages
        let underscored = identifier.replacingOccurrences(of: "-", with: "_")
        if available.contains(underscored) { return underscored }
        let language = String(underscored.prefix { $0 != "_" })
        return available.first { $0 == language || $0.hasPrefix(language + "_") }
    }

    static func isOrdinaryWord(_ word: String, localeIdentifier: String) -> Bool {
        let key = localeIdentifier + "|" + word
        if let known = cache[key] { return known }
        let ordinary: Bool
        if let language = checkerLanguage(forLocaleIdentifier: localeIdentifier), !word.isEmpty {
            let misspelled = UITextChecker().rangeOfMisspelledWord(
                in: word, range: NSRange(location: 0, length: (word as NSString).length),
                startingAt: 0, wrap: false, language: language)
            ordinary = misspelled.location == NSNotFound
        } else {
            ordinary = false
        }
        cache[key] = ordinary
        return ordinary
    }
}
#endif
