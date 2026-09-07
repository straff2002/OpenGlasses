import Foundation

/// Content-word overlap between a question and a passage — the deterministic evidence signal that
/// works when embedding similarity does not.
///
/// The word-average embedding backend scores every passage of a real OEM manual within a couple of
/// hundredths of every other (0.87–0.91 measured across the Lennox SLP99 pair), so no similarity
/// floor and no relative margin can tell an in-scope question from an out-of-scope one. Shared
/// content terms can: a question about a torque spec the manual never gives shares almost nothing
/// with the prose the embedder returned, while a question about manifold pressure shares the words
/// the table is printed with.
///
/// Sibling of [[CodeTokenizer]], and deliberately as dumb: lowercase, letters only, four or more
/// characters, a short stopword list, one pass of suffix trimming. No stemmer, no language model —
/// the point is that the same query gives the same answer on every device and in every test.
enum LexicalSupport {

    /// Function words long enough to survive the four-letter cut. Everything shorter ("the", "for",
    /// "how", "is") is already excluded by length.
    static let stopwords: Set<String> = [
        "about", "after", "again", "also", "back", "been", "before", "being", "both", "cannot",
        "could", "does", "doing", "done", "down", "each", "else", "even", "ever", "every", "from",
        "give", "goes", "have", "here", "into", "just", "know", "like", "look", "make", "many",
        "more", "most", "much", "must", "need", "next", "only", "onto", "other", "over", "same",
        "should", "some", "such", "take", "tell", "than", "that", "their", "them", "then", "there",
        "these", "they", "this", "those", "through", "used", "using", "very", "want", "what",
        "when", "where", "which", "while", "will", "with", "would", "your",
    ]

    /// Minimum length of a term, before and after suffix trimming.
    private static let minimumLength = 4

    /// The content terms of a piece of text: lowercased alphabetic runs of at least four
    /// characters, stopwords removed, each trimmed of one plural/`-ing`/`-ed` suffix so that
    /// "pressures" and "pressure" are the same term.
    ///
    /// Digits are deliberately dropped: a code-like token is [[CodeTokenizer]]'s job and already
    /// counts as evidence on its own, so counting it twice here would let a bare model number carry
    /// a question the manual does not answer.
    static func contentTerms(_ text: String) -> Set<String> {
        var terms: Set<String> = []
        for run in text.lowercased().components(separatedBy: CharacterSet.letters.inverted) {
            guard run.count >= minimumLength, !stopwords.contains(run) else { continue }
            let stem = trimSuffix(run)
            guard stem.count >= minimumLength else { continue }
            terms.insert(stem)
        }
        return terms
    }

    /// How many of `queryTerms` appear in `text`. The passage side is stemmed the same way, so the
    /// comparison is symmetric.
    static func sharedTermCount(text: String, queryTerms: Set<String>) -> Int {
        guard !queryTerms.isEmpty else { return 0 }
        return queryTerms.intersection(contentTerms(text)).count
    }

    /// One pass of suffix trimming. Approximate by design: "clocking" → "clock" and "pressures" →
    /// "pressure" are what matter; "measuring" → "measur" not matching "measure" is a miss we
    /// accept in exchange for a rule that fits in a paragraph.
    private static func trimSuffix(_ word: String) -> String {
        if word.hasSuffix("ing"), word.count >= minimumLength + 3 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed"), word.count >= minimumLength + 2 { return String(word.dropLast(2)) }
        // "gases" → "gas", "matches" → "match": an -es plural after a sibilant loses both letters.
        for sibilant in ["ses", "xes", "zes", "ches", "shes"] where word.hasSuffix(sibilant) {
            if word.count >= minimumLength + 2 { return String(word.dropLast(2)) }
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"),
           word.count >= minimumLength + 1 { return String(word.dropLast()) }
        return word
    }
}
