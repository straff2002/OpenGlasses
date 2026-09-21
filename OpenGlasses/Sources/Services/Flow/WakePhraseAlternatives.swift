import Foundation

/// Default alternative spellings for a wake phrase nobody has hand-tuned.
///
/// `Config.defaultAlternativesForPhrase` has a canned list per shipped phrase and returned `[]`
/// for everything else. A custom phrase is exactly the case that needs the list: it is the one
/// the recogniser has never been checked against, and — now that `WakePhraseMatcher` gives short
/// phrases no fuzzy allowance — alternatives are the only cover a custom phrase has.
///
/// # What this will and will not guess
///
/// Only **structural** variants: the ways a recogniser re-shapes a phrase it heard correctly.
/// It writes `"hey"` as `"a"` or `"hi"`, it splits or joins a compound, it drops the greeting.
/// Those are safe because each one is still the wearer's own word.
///
/// It will not guess **phonetic** neighbours. Generating `"zoo"` for `"zulu"` would hand back the
/// false-triggering the matcher was tightened to stop, and it would do it invisibly, in a list the
/// wearer never typed. A phonetic alternative is a judgement about one person's voice and belongs
/// in the field they can see and edit.
enum WakePhraseAlternatives {

    /// Greetings a wake phrase can start with, and what a recogniser writes them as.
    private static let greetings = ["hey", "hi", "ok", "okay"]

    /// Substitutes offered for a leading `"hey"`. `"a"` is not a greeting — it is what the
    /// recogniser produces for an unstressed "hey", which is why two of the canned lists already
    /// carry it ("a computer", "a assistant").
    private static let greetingSubstitutes = ["hi", "a"]

    /// Structural alternatives for `phrase`, lowercased, deduplicated, and never containing the
    /// phrase itself.
    static func generated(for phrase: String) -> [String] {
        let normalized = normalize(phrase)
        guard !normalized.isEmpty else { return [] }
        let words = normalized.split(separator: " ").map(String.init)

        var out: [String] = []
        if let first = words.first, greetings.contains(first), words.count > 1 {
            // The greeting misheard. Not the greeting *dropped*: offering the bare remainder
            // would turn a two-word phrase into a one-word one, which is the shape that wakes on
            // ordinary speech — the thing a wearer chose a greeting to avoid.
            let rest = words.dropFirst().joined(separator: " ")
            out += greetingSubstitutes.map { "\($0) \(rest)" }
        } else {
            out.append("hey \(normalized)")
        }

        // Two words the recogniser runs together. Splitting a single token the other way needs a
        // dictionary to do without inventing words, so it is left alone.
        if words.count > 1 { out.append(words.joined()) }

        var seen = Set([normalized])
        return out.compactMap { candidate in
            let value = normalize(candidate)
            guard value.count >= minimumBareLength, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// Shortest alternative worth offering. Below this an alternative matches more sentences than
    /// it rescues, and the wearer did not ask for it.
    static let minimumBareLength = 4

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
    }
}
