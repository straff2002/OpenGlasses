import Foundation

/// Does this transcript contain a wake phrase? Pure, so the answer can be tested against a corpus
/// of ordinary sentences instead of only against the phrases it is supposed to match.
///
/// # Why it moved out of `WakeWordService`
///
/// The matcher there did substring containment plus Levenshtein with a two-edit allowance for any
/// phrase of ten characters or fewer. Both halves are fine for `"hey claude"` and fall apart for a
/// short phrase, which is exactly what a field tester asked for — the single word `"zulu"`:
///
/// - Substring containment fires *inside longer words*: `"the zoo"` is not a match but a phrase
///   like `"rule"` matches `"ruler"`, and a compound like `"openglasses"` matches nothing else
///   only by luck of being long.
/// - Two edits on a four-letter word matches a large slice of ordinary English. `"zulu"` is two
///   edits from `"zoo"`, `"blue"`, `"rule"` and `"you'll"`, and a wearer who picks it would find
///   the assistant waking up through half their sentences.
///
/// So: whole-token matching, and a fuzzy allowance that scales with the phrase and switches off
/// entirely for short ones. A short wake phrase has no room for misrecognition slack; the honest
/// way to cover how a recogniser mangles it is the alternatives list, which is exact and which the
/// wearer can see and edit.
enum WakePhraseMatcher {

    /// A phrase to listen for, and the primary phrase to report when it matches. Alternatives
    /// report their primary so callers route to the right persona.
    struct Candidate: Equatable {
        let phrase: String
        let primary: String

        init(phrase: String, primary: String? = nil) {
            self.phrase = phrase
            self.primary = primary ?? phrase
        }
    }

    /// Shortest phrase that may be fuzzy-matched at all, in letters.
    ///
    /// Below this the edit-distance neighbourhood of a phrase is full of ordinary words, and no
    /// threshold above zero is safe. Eight is low enough that every phrase the app ships as a
    /// default (`"hey claude"` is the shortest, at ten) keeps the allowance it has always had, and
    /// high enough to exclude a bare single word, which is the case that goes wrong.
    static let shortestFuzzyPhrase = 8

    /// How many character edits a window may differ from a phrase by, given the phrase's length.
    ///
    /// Zero under `shortestFuzzyPhrase`. Two through the length of the default phrases, which is
    /// what they were matched with before this existed (`"hey claude"` ← `"hey cloud"`, two
    /// edits). Three for the long compounds, where two edits cannot bridge a recogniser that
    /// splits the word.
    static func fuzzyThreshold(forPhraseLength length: Int) -> Int {
        switch length {
        case ..<shortestFuzzyPhrase: return 0
        case shortestFuzzyPhrase...11: return 2
        default: return 3
        }
    }

    /// The primary phrase matched by `transcript`, or nil.
    ///
    /// Exact whole-token matches across every candidate first, so an alternative never loses to a
    /// fuzzy match on a different persona's phrase.
    static func match(transcript: String, candidates: [Candidate]) -> String? {
        let tokens = PhraseMatcher.tokenize(transcript)
        guard !tokens.isEmpty else { return nil }

        for candidate in candidates where !candidate.phrase.isEmpty {
            if PhraseMatcher.contains(candidate.phrase, in: tokens) { return candidate.primary }
        }

        return fuzzyMatch(tokens: tokens, candidates: candidates)?.primary
    }

    /// The fuzzy half, separated so callers that want to log the distance can reach it.
    static func fuzzyMatch(tokens: [String], candidates: [Candidate]) -> (primary: String, distance: Int)? {
        for candidate in candidates {
            let phraseTokens = PhraseMatcher.tokenize(candidate.phrase)
            let windowSize = phraseTokens.count
            let phrase = phraseTokens.joined(separator: " ")
            let threshold = fuzzyThreshold(forPhraseLength: phrase.count)
            guard threshold > 0, windowSize > 0, tokens.count >= windowSize else { continue }

            for start in 0...(tokens.count - windowSize) {
                let window = tokens[start..<(start + windowSize)].joined(separator: " ")
                let distance = levenshteinDistance(window, phrase)
                if distance <= threshold && distance > 0 {
                    return (candidate.primary, distance)
                }
            }
        }
        return nil
    }

    /// Levenshtein edit distance between two strings.
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }
}
