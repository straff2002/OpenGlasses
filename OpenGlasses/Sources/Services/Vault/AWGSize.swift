import Foundation

/// The AWG "aught" sizes — 1/0 to 4/0 — in the one form a table row and a technician's words are
/// compared in (Plan KD P0).
///
/// The partner asked for 4/0 and was answered from row 4: the lookup split "4/0" into "4" and
/// "0", matched 4 as a number and dropped the 0. The same size is printed "4/0" in one book and
/// "0000" in another, typed "4/0 AWG", and said "four aught", "four ought" or "four oh" — and a
/// recogniser hears that last as "four out". Every one of those is `4/0` here, and nothing else
/// is: No. 4 is never 4/0, and "0000" is never the number 0.
///
/// Pure. `canonical` reads a whole heading or answer; `find` picks a size out of a sentence;
/// `rewritingSpokenSizes` is the electrical dictation pass (`DictationVocabulary.postProcess`).
enum AWGSize {

    /// The canonical form of a size that is the whole of `text`, give or take the words printed
    /// beside a size ("4/0 AWG", "No. 4/0", "#0000", "4/0 copper"), or nil. A bare "0" is 1/0 here;
    /// whether a table's "0" is a size is the caller's call (`TableLookup`).
    static func canonical(_ text: String) -> String? {
        let words = tokens(text).filter { !sizeNoise.contains($0) }
        guard !words.isEmpty, let (size, used) = size(at: 0, in: words, wholeText: true),
              used == words.count else { return nil }
        return size
    }

    /// The first aught size `text` carries, or nil. A lone "0" counts only beside a conductor word
    /// ("0 copper", "size 0") — in a sentence a 0 is far more often just a zero.
    static func find(in text: String) -> String? {
        if let whole = canonical(text) { return whole }
        let words = tokens(text)
        for index in words.indices {
            if let (size, _) = size(at: index, in: words, wholeText: false) { return size }
        }
        return nil
    }

    /// `text` with every spoken aught size written as printed: "four aught" → "4/0", "double
    /// ought" → "2/0", "four out copper" → "4/0 copper". Digits, and "0000", are left as they are.
    /// The electrical dictation pass, so the model and the lookup see the size the technician said.
    static func rewritingSpokenSizes(in text: String) -> String {
        var out = text
        for pattern in spokenPatterns {
            let ns = out as NSString
            let matches = pattern.regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let count = multiplier(ns.substring(with: match.range(at: 1))),
                      let range = Range(match.range, in: out) else { continue }
                if pattern.needsConductor, !hasConductorWord(near: match.range, in: ns) { continue }
                out.replaceSubrange(range, with: "\(count)/0")
            }
        }
        return out
    }

    /// Whether a word, as `TableLookup.significantWords` gives it, can be part of how a size is
    /// written or said ("4", "0", "0000", "aught", "awg"): what is left once those are out is the
    /// rest of the request ("aluminum").
    static func isSizeWord(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if !lowered.isEmpty, lowered.allSatisfy({ $0 == "0" }) { return true }
        return multiplier(lowered) != nil || aughtWords.contains(lowered) || ohWords.contains(lowered)
            || ["out", "awg", "/"].contains(lowered)
    }

    // MARK: - Reading

    /// The size beginning at `words[index]`, with how many words it used.
    private static func size(at index: Int, in words: [String], wholeText: Bool) -> (String, Int)? {
        let word = words[index]
        let next = index + 1 < words.count ? words[index + 1] : nil
        // "4/0", "4 / 0" (tokenised as "4", "/", "0").
        if let count = digitCount(word), next == "/", index + 2 < words.count, words[index + 2] == "0" {
            return ("\(count)/0", 3)
        }
        if word.count >= 3, word.hasSuffix("/0"), let count = digitCount(String(word.dropLast(2))) {
            return ("\(count)/0", 1)
        }
        // "00", "000", "0000": the size whichever way it sits. A lone "0" only as the whole text or
        // beside a conductor word.
        if !word.isEmpty, word.allSatisfy({ $0 == "0" }), word.count <= 4 {
            if word.count >= 2 { return ("\(word.count)/0", 1) }
            if wholeText || conductorWordNear(index, in: words) { return ("1/0", 1) }
            return nil
        }
        // "four aught", "4 ought", "double aught", "four oh" (not "two oh eight").
        if let count = multiplier(word), let next {
            if aughtWords.contains(next) { return ("\(count)/0", 2) }
            if ohWords.contains(next) {
                let after = index + 2 < words.count ? words[index + 2] : nil
                // …and not "four o'clock".
                if after.map(isNumberWord) != true, after != "clock" { return ("\(count)/0", 2) }
            }
            // "four out" is what the recogniser hears — a size only beside a conductor word.
            if next == "out", conductorWordNear(index, in: words) { return ("\(count)/0", 2) }
        }
        return nil
    }

    /// 1–4 from "1"…"4", "one"…"four", "single"…"quadruple".
    private static func multiplier(_ word: String) -> Int? {
        switch word.lowercased() {
        case "1", "one", "single": return 1
        case "2", "two", "double": return 2
        case "3", "three", "triple": return 3
        case "4", "four", "quadruple", "quad": return 4
        default: return nil
        }
    }

    /// 1–4 written as a digit.
    private static func digitCount(_ word: String) -> Int? {
        guard word.count == 1, let value = Int(word), (1...4).contains(value) else { return nil }
        return value
    }

    private static func isNumberWord(_ word: String) -> Bool {
        word.first?.isNumber == true || numberWords.contains(word)
    }

    private static func conductorWordNear(_ index: Int, in words: [String]) -> Bool {
        let low = max(0, index - reach), high = min(words.count - 1, index + 1 + reach)
        guard low <= high else { return false }
        return words[low...high].contains(where: conductorWords.contains)
    }

    /// Whether a conductor word sits within `reach` words either side of `range` in `text`.
    private static func hasConductorWord(near range: NSRange, in text: NSString) -> Bool {
        let before = tokens(text.substring(to: range.location)).suffix(reach)
        let after = tokens(text.substring(from: range.location + range.length)).prefix(reach)
        return (before + after).contains(where: conductorWords.contains)
    }

    /// Lowercased words, with "/" kept as a word of its own and "4/0" kept whole.
    private static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var out: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { out.append(current); current = "" } }
        for character in lowered {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "/" {
                // "4/0" whole when written tight; "4 / 0" as three words.
                if let last = current.last, last.isNumber { current.append(character) } else { flush(); out.append("/") }
            } else {
                flush()
            }
        }
        flush()
        // A "4/" left by "4/ 0" or a trailing slash: split back out.
        return out.flatMap { word -> [String] in
            guard word.hasSuffix("/"), word.count > 1 else { return [word] }
            return [String(word.dropLast()), "/"]
        }
    }

    // MARK: - Vocabulary

    /// How many words either side a conductor word may sit from a "four out" or a lone "0".
    private static let reach = 2

    private static let conductorWords: Set<String> = [
        "awg", "aluminum", "aluminium", "copper", "conductor", "conductors", "wire", "wires",
        "cable", "cables", "size", "gauge", "al", "cu",
    ]

    /// Printed beside a size and dropped before reading a whole heading as one.
    private static let sizeNoise: Set<String> = [
        "awg", "no", "number", "size", "gauge", "copper", "aluminum", "aluminium", "cu", "al",
        "conductor", "conductors", "wire", "cable",
    ]

    private static let aughtWords: Set<String> = ["aught", "ought", "naught", "nought"]
    private static let ohWords: Set<String> = ["oh", "o"]
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "oh", "o", "hundred", "thousand",
    ]

    private struct SpokenPattern {
        let regex: NSRegularExpression
        let needsConductor: Bool
    }

    /// The spoken forms the dictation pass rewrites. Group 1 is the count.
    private static let spokenPatterns: [SpokenPattern] = {
        let count = #"\b(one|two|three|four|single|double|triple|quadruple|quad|[1-4])"#
        func make(_ pattern: String, conductor: Bool = false) -> SpokenPattern {
            SpokenPattern(regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                          needsConductor: conductor)
        }
        return [
            make(count + #"[\s-]+(?:aught|ought|naught|nought)\b"#),
            // "four oh", not "two oh eight" or "one oh one".
            make(count + #"[\s-]+(?:oh|o)\b(?![\s-]*(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|oh|o|\d)\b|['\x{2019}])"#),
            make(count + #"\s+out\b"#, conductor: true),
        ]
    }()
}
