import Foundation

/// The spellings a non-Latin recogniser can give a Latin wake phrase.
///
/// The wake-word listener runs in the wearer's language so that "stop", the wake phrase and a
/// sentence spoken over a reply are all heard in the one recogniser. A Korean phone therefore
/// listens with a Korean recogniser, and a Korean recogniser never writes "avenkin": it writes the
/// sound it heard in Hangul, "아벤킨". The matcher compares whole tokens, so until a tester typed
/// that spelling into the alternatives list by hand, the shipped wake phrase could not wake the app
/// on a Korean phone at all — the first thing a tester in Seoul reported (2026-10-09).
///
/// This generates those spellings with the system's own transliteration tables, per word, in every
/// mix of Latin and transliterated words: a recogniser writes an acronym it knows in Latin inside
/// an otherwise-Hangul sentence ("헤이 GPT"). The results are added as alternatives of the phrase
/// they came from, and as contextual strings so the recogniser is nudged towards writing them.
///
/// Scope: scripts that put spaces between words. A Japanese or Chinese recogniser writes a sentence
/// as one token, which whole-token matching cannot see into; the transliteration is still offered
/// as a contextual string, but matching an unspaced transcript is a separate piece of work.
enum WakePhraseScript {

    /// How many words of a phrase take part in the Latin/transliterated mix. Beyond this the
    /// combinations grow past what a wake phrase needs.
    static let mixedWordLimit = 3

    /// The transliteration for a script code (`SpeechLocaleResolver.scriptCode(of:)`), or `nil`
    /// for Latin and for scripts the system has no Latin-to-script table for (Han).
    static func transform(forScriptCode code: String?) -> StringTransform? {
        switch code {
        case "Hang", "Kore": return .latinToHangul
        case "Jpan", "Kana", "Hira": return .latinToKatakana
        case "Cyrl": return .latinToCyrillic
        case "Grek": return .latinToGreek
        case "Arab": return .latinToArabic
        case "Hebr": return .latinToHebrew
        case "Thai": return .latinToThai
        default: return nil
        }
    }

    /// Every spelling of `phrase` a recogniser writing `scriptCode` might produce, other than the
    /// phrase itself. Empty for Latin, for an unknown script, and for a phrase with no Latin
    /// letters (the wearer already typed it in the recogniser's script).
    static func transliterations(of phrase: String, scriptCode: String?) -> [String] {
        guard let transform = transform(forScriptCode: scriptCode) else { return [] }
        let words = PhraseMatcher.tokenize(phrase)
        guard !words.isEmpty, words.contains(where: hasLatinLetters) else { return [] }

        // Each word's spellings: the Latin one, and the transliterated one when it differs.
        let spellings: [[String]] = words.enumerated().map { index, word in
            guard index < mixedWordLimit, hasLatinLetters(word),
                  let other = word.applyingTransform(transform, reverse: false)?.lowercased(),
                  !other.isEmpty, other != word else { return [word] }
            return [word, other]
        }

        var out: [String] = []
        var seen: Set<String> = [words.joined(separator: " ")]
        for combination in cartesian(spellings) {
            let candidate = combination.joined(separator: " ")
            if seen.insert(candidate).inserted { out.append(candidate) }
        }
        return out
    }

    /// `transliterations(of:scriptCode:)` over a list, in order, without duplicates.
    static func transliterations(of phrases: [String], scriptCode: String?) -> [String] {
        var seen = Set<String>()
        return phrases.flatMap { transliterations(of: $0, scriptCode: scriptCode) }
            .filter { seen.insert($0).inserted }
    }

    static func hasLatinLetters(_ word: String) -> Bool {
        word.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic && (scalar.value < 0x250 || (0x1E00...0x1EFF).contains(scalar.value))
        }
    }

    /// The transliterated forms first, so the fully transliterated phrase leads the list.
    private static func cartesian(_ lists: [[String]]) -> [[String]] {
        lists.reduce([[]]) { acc, options in
            options.reversed().flatMap { option in acc.map { $0 + [option] } }
        }
    }
}
