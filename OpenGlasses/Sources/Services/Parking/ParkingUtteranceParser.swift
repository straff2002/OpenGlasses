import Foundation

/// Plan GH — turns what the wearer said about where they parked into level / space / zone, with
/// anything left over kept as a note.
///
/// Pure and deterministic: no locale lookups, no model. It handles the shapes people actually say
/// in car parks — "level 2, space 41", "P3 bay B12", "floor minus one", "B2", "row G", "green zone",
/// "second floor", spelled numbers ("level two, space forty-one") — and leaves everything else to
/// the note rather than guessing. A wrong level is worse than no level.
enum ParkingUtteranceParser {

    static func parse(_ utterance: String) -> ParkingFields {
        let tokens = tokenize(utterance)
        guard !tokens.isEmpty else { return ParkingFields() }
        let words = tokens.map(\.lower)
        var consumed = Array(repeating: false, count: words.count)
        var fields = ParkingFields()

        func mark(_ range: Range<Int>) { for k in range where k < consumed.count { consumed[k] = true } }

        var i = 0
        while i < words.count {
            if consumed[i] { i += 1; continue }
            let word = words[i]

            // "level 2", "floor minus one", "deck P3", "basement 2"
            if fields.level == nil, levelKeywords.contains(word),
               let (value, length) = levelValue(words, at: i + 1) {
                fields.level = value
                mark(i..<(i + 1 + length))
                i += 1 + length
                continue
            }
            if fields.level == nil, word == "basement" {
                if let (n, length) = number(words, at: i + 1) {
                    fields.level = "B\(n)"
                    mark(i..<(i + 1 + length))
                    i += 1 + length
                } else {
                    fields.level = "B"
                    let skip = (i + 1 < words.count && levelKeywords.contains(words[i + 1])) ? 2 : 1
                    mark(i..<(i + skip))
                    i += skip
                }
                continue
            }
            // "second floor", "2nd level", "ground floor", "top deck", "blue level"
            if fields.level == nil, i + 1 < words.count, levelKeywords.contains(words[i + 1]),
               let value = precedingLevelValue(word) {
                fields.level = value
                mark(i..<(i + 2))
                i += 2
                continue
            }
            // "space 41", "bay B12", "spot number forty one", "# 41"
            if fields.space == nil, spaceKeywords.contains(word),
               let (value, length) = spaceValue(words, at: i + 1) {
                fields.space = value
                mark(i..<(i + 1 + length))
                i += 1 + length
                continue
            }
            // "row G", "zone C", "section 4"
            if fields.zone == nil, zoneKeywords.contains(word),
               let (value, length) = zoneValue(words, at: i + 1) {
                fields.zone = word == "row" ? "Row \(value)" : "Zone \(value)"
                mark(i..<(i + 1 + length))
                i += 1 + length
                continue
            }
            // "green zone", "blue section"
            if fields.zone == nil, colours.contains(word), i + 1 < words.count,
               zoneKeywords.contains(words[i + 1]), words[i + 1] != "row" {
                fields.zone = word.capitalized
                mark(i..<(i + 2))
                i += 2
                continue
            }
            // Compact standalone level tokens: "P3", "L2", "B2".
            if fields.level == nil, let value = compactLevel(word) {
                fields.level = value
                mark(i..<(i + 1))
                i += 1
                continue
            }
            i += 1
        }

        fields.note = note(from: tokens, consumed: consumed)
        return fields
    }

    // MARK: - Vocabulary

    static let levelKeywords: Set<String> = ["level", "floor", "deck", "storey", "story", "lvl", "tier"]
    static let spaceKeywords: Set<String> = ["space", "spot", "bay", "stall", "slot", "number", "no", "#",
                                             "position"]
    static let zoneKeywords: Set<String> = ["row", "zone", "section", "area", "sector", "aisle"]
    static let colours: Set<String> = ["red", "orange", "yellow", "green", "blue", "purple", "pink",
                                       "white", "black", "grey", "gray", "brown", "gold", "silver",
                                       "violet", "teal"]

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
    ]

    /// Words that carry no location on their own; trimmed from the ends of a leftover run.
    static let filler: Set<String> = [
        "i", "i'm", "im", "i've", "ive", "we", "we're", "we've", "parked", "park", "parking", "have",
        "has", "my", "our", "the", "car", "is", "it", "it's", "its", "on", "in", "at", "a", "an",
        "and", "remember", "that", "this", "just", "so", "um", "uh", "er", "okay", "ok", "please",
        "save", "note", "there", "here", "was", "were", "am", "are", "me", "to", "of", "with", "up",
        "i'd", "we'd", "been", "got", "left", "where", "spot", "space", "bay", "level", "floor",
        "number", "hey", "right", "now", "then", "also", "oh",
    ]

    // MARK: - Tokens

    struct Token { let original: String; let lower: String }

    static func tokenize(_ text: String) -> [Token] {
        var cleaned = text
        // Sentence punctuation to spaces; keep decimal points and apostrophes.
        cleaned = cleaned.replacingOccurrences(of: #"[,;:!?()\"“”]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\.(?=\s|$)"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "#", with: " # ")
        // "forty-one" → "forty one"; "A-4" → "A4".
        cleaned = cleaned.replacingOccurrences(of: #"(?<=[A-Za-z])-(?=[A-Za-z])"#, with: " ",
                                               options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(?<=[A-Za-z0-9])-(?=[0-9])"#, with: "",
                                               options: .regularExpression)
        return cleaned.split(whereSeparator: \.isWhitespace).map {
            Token(original: String($0), lower: String($0).lowercased()
                .replacingOccurrences(of: "’", with: "'"))
        }
    }

    // MARK: - Numbers

    /// A number at `index`: digits ("41", "2nd"), a spelled ordinal ("second") or a spelled
    /// cardinal ("forty one", "a hundred and five"). Returns the value and how many words it used.
    static func number(_ words: [String], at index: Int) -> (Int, Int)? {
        guard index < words.count else { return nil }
        let word = words[index]
        if let value = Int(word), value >= 0 { return (value, 1) }
        if let digits = firstCapture(#"^(\d+)(?:st|nd|rd|th)$"#, in: word), let value = Int(digits) {
            return (value, 1)
        }
        if let value = ordinals[word] { return (value, 1) }
        return spelledNumber(words, at: index)
    }

    static func spelledNumber(_ words: [String], at index: Int) -> (Int, Int)? {
        var j = index
        var value = 0
        var any = false
        if j + 1 < words.count, words[j + 1] == "hundred", words[j] == "a" || (units[words[j]] ?? 0) > 0 {
            value = (units[words[j]] ?? 1) * 100
            j += 2
            any = true
            if j + 1 < words.count, words[j] == "and",
               tens[words[j + 1]] != nil || units[words[j + 1]] != nil {
                j += 1
            }
        }
        if j < words.count, let t = tens[words[j]] {
            value += t
            j += 1
            any = true
            if j < words.count, let u = units[words[j]], (1...9).contains(u) {
                value += u
                j += 1
            }
        } else if j < words.count, let u = units[words[j]], !(any && u == 0) {
            value += u
            j += 1
            any = true
        }
        return any ? (value, j - index) : nil
    }

    // MARK: - Values

    /// A level after its keyword.
    static func levelValue(_ words: [String], at index: Int) -> (String, Int)? {
        guard index < words.count else { return nil }
        let word = words[index]
        if ["minus", "negative"].contains(word), let (n, length) = number(words, at: index + 1) {
            return ("-\(n)", 1 + length)
        }
        if word.hasPrefix("-"), let n = Int(word.dropFirst()) { return ("-\(n)", 1) }
        if let (n, length) = number(words, at: index) { return ("\(n)", length) }
        if ["ground", "g"].contains(word) { return ("G", 1) }
        if ["roof", "rooftop", "top"].contains(word) { return ("Roof", 1) }
        if colours.contains(word) { return (word.capitalized, 1) }
        if let compact = compactLevel(word) { return (compact, 1) }
        // A single letter, or a letter-digit code the car park uses as its level name ("3A").
        if word.range(of: #"^([a-z]|[a-z]?\d{1,2}[a-z]?)$"#, options: .regularExpression) != nil,
           !["a", "i"].contains(word) {
            return (word.uppercased(), 1)
        }
        return nil
    }

    /// The word before a level keyword: "second floor", "2nd level", "ground floor", "blue level".
    static func precedingLevelValue(_ word: String) -> String? {
        if let value = ordinals[word] { return "\(value)" }
        if let digits = firstCapture(#"^(\d+)(?:st|nd|rd|th)$"#, in: word) { return digits }
        if word == "ground" { return "G" }
        if ["top", "roof", "rooftop"].contains(word) { return "Roof" }
        if colours.contains(word) { return word.capitalized }
        if let compact = compactLevel(word) { return compact }
        return nil
    }

    /// "P3" → "3", "L2" → "2", "LVL4" → "4", "B2" → "B2". Two-digit B codes are left alone: on a
    /// sign or in speech "B12" is far more often a bay than a twelfth basement.
    static func compactLevel(_ word: String) -> String? {
        if let digits = firstCapture(#"^(?:p|l|lvl)(-?\d{1,2})$"#, in: word) { return digits }
        if let digit = firstCapture(#"^b(\d)$"#, in: word) { return "B\(digit)" }
        return nil
    }

    /// A space after its keyword: "41", "forty one", "B12", "b 12", "number 41".
    static func spaceValue(_ words: [String], at index: Int) -> (String, Int)? {
        guard index < words.count else { return nil }
        var start = index
        if ["number", "no", "#"].contains(words[start]) { start += 1 }
        guard start < words.count else { return nil }
        let word = words[start]
        let prefix = start - index
        if let (n, length) = number(words, at: start), ordinals[word] == nil {
            return ("\(n)", prefix + length)
        }
        // "b 12" / "bay B twelve"
        if word.count == 1, word.first?.isLetter == true, !["a", "i"].contains(word),
           let (n, length) = number(words, at: start + 1) {
            return ("\(word.uppercased())\(n)", prefix + 1 + length)
        }
        // "B12", "12B", "A4"
        if word.range(of: #"^[a-z]{0,2}\d{1,4}[a-z]?$"#, options: .regularExpression) != nil {
            return (word.uppercased(), prefix + 1)
        }
        return nil
    }

    /// A zone/row after its keyword: "G", "4", "C", "blue".
    static func zoneValue(_ words: [String], at index: Int) -> (String, Int)? {
        guard index < words.count else { return nil }
        let word = words[index]
        if let (n, length) = number(words, at: index), ordinals[word] == nil { return ("\(n)", length) }
        if colours.contains(word) { return (word.capitalized, 1) }
        if word.range(of: #"^[a-z]\d{0,2}$"#, options: .regularExpression) != nil, !["a", "i"].contains(word) {
            return (word.uppercased(), 1)
        }
        return nil
    }

    /// The first capture group of `pattern` matched against the whole of `text`.
    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Note

    /// Unconsumed runs of words, with filler trimmed from each end; runs with nothing left drop.
    static func note(from tokens: [Token], consumed: [Bool]) -> String? {
        var runs: [[Token]] = []
        var current: [Token] = []
        for (index, token) in tokens.enumerated() {
            if consumed[index] {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { runs.append(current) }

        let kept = runs.compactMap { run -> String? in
            var slice = run[...]
            while let first = slice.first, filler.contains(first.lower) { slice = slice.dropFirst() }
            while let last = slice.last, filler.contains(last.lower) { slice = slice.dropLast() }
            guard !slice.isEmpty else { return nil }
            return slice.map(\.original).joined(separator: " ")
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: ", ")
    }
}
