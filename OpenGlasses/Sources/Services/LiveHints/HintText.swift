import Foundation
import NaturalLanguage

/// The text handling the live-hints core shares (Plan MO §2, §4, §5): one way to fold a caption into
/// words, so the trigger's repeat check, the keyword matcher and the passage pick agree on what a
/// word is; and the cuts that keep a hint or a card inside its length.
///
/// Pure. Words are folded for case and diacritics and split at anything that is not a letter or a
/// digit, apostrophes included ("what's" is `what`, `s`), so the two sides of every comparison are
/// folded the same way.
enum HintText {

    /// The caption's words, folded and in order.
    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// The folded words joined by single spaces: the form phrase lists are compared in.
    static func normalized(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    /// Words that carry no meaning of their own in a question. Question words stay out of it on
    /// purpose: "when does it open" and "where does it open" are different questions.
    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "you", "your", "yours", "i", "me", "my", "we", "our", "us", "it", "its", "of", "to", "in",
        "on", "for", "at", "by", "with", "about", "and", "or", "so", "that", "this", "these",
        "those", "can", "could", "would", "will", "please", "there", "they", "them", "their",
        "have", "has", "had", "any", "some", "just", "really", "s", "t", "re", "ve", "ll", "d", "m",
        "um", "uh", "like", "okay", "ok", "well",
    ]

    /// The question words, which `stopWords` keeps but a passage search does not need.
    static let questionWords: Set<String> = ["what", "which", "who", "whom", "whose", "when",
                                             "where", "why", "how", "tell", "explain", "describe"]

    /// The caption's words without the stop words.
    static func contentWords(_ text: String) -> Set<String> {
        Set(words(text).filter { !stopWords.contains($0) })
    }

    /// Word-set overlap: shared words over all words. Two empty sets are the same.
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    /// The number of words, counted by the system's word tokenizer so a language written without
    /// spaces is counted in words, not as one long one.
    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// The text's sentences, trimmed, in order: a sentence ends at ".", "!" or "?" (and their
    /// full-width forms) followed by a space or the end.
    static func sentences(_ text: String) -> [String] {
        let enders: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard enders.contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next!.isWhitespace || "\u{3002}\u{FF01}\u{FF1F}".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Runs of whitespace (newlines included) as single spaces, trimmed.
    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Punctuation a cut line must not end on.
    private static let danglingPunctuation: Set<Character> = [",", ";", ":", "-", "\u{2013}",
                                                              "\u{2014}", "\u{2026}", "(", "/"]

    /// `text` without trailing spaces and dangling punctuation (a comma, a dash, an ellipsis);
    /// with `includingStops`, a trailing full stop too, for a line that was cut.
    static func trimmingTrailingPunctuation(_ text: String, includingStops: Bool = false) -> String {
        var result = Substring(text)
        while let last = result.last,
              last.isWhitespace || danglingPunctuation.contains(last) || (includingStops && last == ".") {
            result = result.dropLast()
        }
        return String(result)
    }

    /// At most `maxWords` words and `maxCharacters` characters, cut at a word boundary. A single
    /// word longer than the limit is cut inside itself, the one case with no boundary to cut at.
    /// Returns the cut text and whether anything was cut.
    static func cut(_ text: String, maxWords: Int = .max, maxCharacters: Int) -> (text: String, wasCut: Bool) {
        let tokens = collapsingWhitespace(text).split(separator: " ").map(String.init)
        var kept = Array(tokens.prefix(maxWords))
        var wasCut = kept.count < tokens.count
        while kept.count > 1 && kept.joined(separator: " ").count > maxCharacters {
            kept.removeLast()
            wasCut = true
        }
        var line = kept.joined(separator: " ")
        if line.count > maxCharacters {
            line = String(line.prefix(maxCharacters))
            wasCut = true
        }
        return (line, wasCut)
    }
}
