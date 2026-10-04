import Foundation

/// How the recorded-session rules read words (Contracts/recorded-session.md §7.3): what a word is,
/// which words carry no content, how a word is reduced to its stem, and when a word is under a
/// negation.
///
/// Every rule is written to be computed the same way anywhere, which is why it is this plain. Only
/// the unaccented Latin letters and the digits make words, and the word lists are English: text in
/// another language yields no content words, so nothing said in it confirms anything. The lists
/// here are also in `Contracts/fixtures/agreement-v1.json`, and a test holds the two together.
enum RecordingText {

    /// Words that say nothing about what was done. Contractions are spelt as `words(_:)` leaves
    /// them, without the apostrophe.
    static let stopWords: Set<String> = [
        "a", "about", "after", "again", "all", "alright", "also", "am", "an", "and", "any", "are", "as",
        "at", "back", "be", "been", "before", "being", "bit", "both", "but", "by", "can", "could", "did",
        "do", "does", "doing", "done", "down", "each", "er", "first", "for", "from", "get", "go", "going",
        "gonna", "got", "had", "has", "have", "having", "he", "her", "here", "heres", "him", "his", "how",
        "i", "id", "if", "ill", "im", "in", "into", "is", "it", "its", "ive", "just", "let", "lets", "like",
        "little", "may", "me", "might", "more", "most", "must", "my", "next", "now", "of", "off", "ok",
        "okay", "on", "once", "one", "ones", "only", "onto", "or", "other", "our", "out", "over", "own",
        "right", "same", "shall", "she", "should", "so", "some", "still", "such", "than", "that", "thats",
        "the", "their", "them", "then", "there", "theres", "these", "they", "theyre", "thing", "things",
        "this", "those", "through", "to", "too", "uh", "um", "up", "us", "very", "was", "we", "well",
        "were", "weve", "what", "whats", "when", "where", "which", "who", "why", "will", "with", "would",
        "yeah", "yes", "you", "youll", "your", "youre", "youve",
    ]

    /// Words that turn what follows them, to the end of the clause, into something not done.
    static let negators: Set<String> = [
        "aint", "arent", "cannot", "cant", "couldnt", "didnt", "doesnt", "dont", "hadnt", "hasnt",
        "havent", "isnt", "mustnt", "neednt", "neither", "never", "no", "nor", "not", "shouldnt",
        "wasnt", "werent", "without", "wont", "wouldnt",
    ]

    /// Characters that end a clause wherever they stand, and with it the reach of a negation.
    static let clauseBreakCharacters: Set<Character> = [".", ",", ";", ":", "!", "?"]
    /// Words that end a clause: "don't remove the cover, but loosen the screws".
    static let clauseBreakWords: Set<String> = ["but"]

    /// A content word is at least this long.
    static let minimumWordLength = 2

    /// The clauses of a text, each as its words in order. A word is a run of the letters a–z (A–Z
    /// read as lower case) and the digits; an apostrophe inside one is dropped, so "don't" is
    /// `dont`; every other character ends the word.
    static func clauses(_ text: String) -> [[String]] {
        var clauses: [[String]] = []
        var clause: [String] = []
        var word = String.UnicodeScalarView()
        func endWord() {
            guard !word.isEmpty else { return }
            let finished = String(word)
            word = String.UnicodeScalarView()
            if clauseBreakWords.contains(finished) {
                clauses.append(clause)
                clause = [finished]
            } else {
                clause.append(finished)
            }
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A:
                word.append(Unicode.Scalar(scalar.value + 0x20) ?? scalar)
            case 0x61...0x7A, 0x30...0x39:
                word.append(scalar)
            case 0x27, 0x2019:
                continue
            default:
                endWord()
                if clauseBreakCharacters.contains(Character(scalar)) {
                    clauses.append(clause)
                    clause = []
                }
            }
        }
        endWord()
        clauses.append(clause)
        return clauses.filter { !$0.isEmpty }
    }

    /// Every word of a text, in order.
    static func words(_ text: String) -> [String] {
        clauses(text).flatMap { $0 }
    }

    /// A word with its ending taken off, so that "remove", "removed", "removing" and "removes" are
    /// one word. Rough on purpose: a rule that fits in a paragraph can be written twice and agree.
    /// A word under four letters, or with a digit in it, is left alone.
    static func stem(_ word: String) -> String {
        var w = Array(word.utf8)
        guard w.count >= 4, !w.contains(where: { (0x30...0x39).contains($0) }) else { return word }
        func ends(_ suffix: String) -> Bool { w.count >= suffix.utf8.count && w.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) }
        func hasVowel(_ letters: ArraySlice<UInt8>) -> Bool { letters.contains { "aeiouy".utf8.contains($0) } }
        func undouble() {
            guard w.count >= 2, w[w.count - 1] == w[w.count - 2], !"lsz".utf8.contains(w[w.count - 1]) else { return }
            w.removeLast()
        }

        // Plurals.
        if ends("ies"), w.count >= 5 {
            w.removeLast(3)
            w.append(UInt8(ascii: "y"))
        } else if ends("sses") || ends("ches") || ends("shes") || ends("xes") || ends("zes") {
            w.removeLast(2)
        } else if ends("s"), !ends("ss"), !ends("us"), !ends("is") {
            w.removeLast()
        }
        // -ing and -ed, when what is left still has a vowel in it.
        if ends("ing"), w.count >= 6, hasVowel(w.dropLast(3)) {
            w.removeLast(3)
            undouble()
        } else if ends("ed"), !ends("eed"), w.count >= 5, hasVowel(w.dropLast(2)) {
            w.removeLast(2)
            undouble()
        }
        // A final e.
        if ends("e"), w.count >= 4 { w.removeLast() }
        return String(decoding: w, as: UTF8.self)
    }

    /// The stems of the content words of a text: every word that is long enough and is neither a
    /// stop-word nor a negator.
    static func contentStems(_ text: String) -> Set<String> {
        Set(words(text).filter(isContent).map(stem))
    }

    /// The stems of the content words that are said without a negation: "don't remove the cover"
    /// has none, "don't worry, remove the cover" has `remov` and `cover`. A negator reaches from
    /// where it stands to the end of its clause. A word said both ways in one text counts as said.
    static func affirmedStems(_ text: String) -> Set<String> {
        var stems: Set<String> = []
        for clause in clauses(text) {
            var negated = false
            for word in clause {
                if negators.contains(word) {
                    negated = true
                } else if !negated, isContent(word) {
                    stems.insert(stem(word))
                }
            }
        }
        return stems
    }

    private static func isContent(_ word: String) -> Bool {
        word.utf8.count >= minimumWordLength && !stopWords.contains(word) && !negators.contains(word)
    }
}
