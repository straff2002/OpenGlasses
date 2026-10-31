import Foundation

/// What an equipment code looks like — shared by equipment lookup (OCR tokens → vault search) and
/// manual retrieval (exact-token boost), so both agree on what counts as "E5", "30RB", "T02".
enum CodeTokenizer {

    /// Plausible code/model tokens from free text: alphanumeric, 2–24 chars, containing at least
    /// one digit or being short uppercase-only (e.g. "E5", "30RB", "T02", "DAIKIN"). Order of first
    /// appearance, de-duplicated case-insensitively.
    ///
    /// A decimal stays whole (Plan GB P1): "0.28" is one token, never "0" and "28", so a spoken
    /// reading cannot exact-match a "28" in a table cell, and "0.35" cannot match a "TABLE 35"
    /// caption. A decimal is a measurement, not a code, so `isCodeLike` does not boost on it. The
    /// upper bound was 14, which dropped full model numbers ("SLP99UH090XV48CK" is 16).
    static func candidateTokens(from text: String) -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for t in words(in: text) {
            guard t.count >= 2, t.count <= maximumTokenLength else { continue }
            let hasDigit = t.contains { $0.isNumber }
            let isShortAlpha = t.count <= 8 && t.allSatisfy { $0.isLetter }
            guard hasDigit || isShortAlpha else { continue }
            if seen.insert(t.uppercased()).inserted { tokens.append(t) }
        }
        return tokens
    }

    static let maximumTokenLength = 24

    /// A token strong enough to boost retrieval on its own: it carries a digit, so it is a code or
    /// a model number rather than an ordinary word that happened to be short. A decimal number is
    /// a reading and is not one.
    static func isCodeLike(_ token: String) -> Bool {
        token.count >= 2 && token.contains { $0.isNumber } && !isDecimal(token)
    }

    /// The text's words: runs of letters and digits, with a decimal number ("0.28", "1,5") kept as
    /// one word. Separators are everything else, as before.
    ///
    /// Full-width letters and digits (ＡＢＣ１２３, which CJK text often sets) and Arabic-Indic digits
    /// are read as their ASCII forms first (Plan JY P5a), so a model number printed full-width in a Chinese manual is the
    /// same token as the one a question types. Text without them is read exactly as before.
    static func words(in text: String) -> [String] {
        let text = foldedForms(text)
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// A decimal number bounded by non-word characters, or else a run of word characters. The
    /// decimal alternative is tried first so "0.28" is not taken as "0" then "28".
    ///
    /// A letter of a script that separates codes (`separatingScripts`) is never part of a code's
    /// word (Plan JY P0): "型号ABC123的" and "модельABC123" are written without a space before the
    /// model number, and the whole run was one token that no spoken "ABC123" matched. Such letters
    /// make words of their own. Text without them is read exactly as before.
    private static let wordPattern: NSRegularExpression = {
        let separating = "[\\p{L}&&[\(separatingScripts)]]"
        let word = "[\\p{N}[\\p{L}&&[^\(separatingScripts)]]]"
        return try! NSRegularExpression(
            pattern: "(?<!\(word))\\d+(?:[.,]\\d+)+(?!\(word))|\(word)+|\(separating)+")
    }()

    /// The scripts whose letters separate code tokens: those of the interface languages that are
    /// not Latin, and the katakana prolonged-sound mark, which is a letter of no script. Greek is
    /// not among them, so "10μF" and "10Ω" stay whole as they always have.
    private static let separatingScripts =
        #"\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Cyrillic}\p{Arabic}\x{30FC}\x{FF70}"#

    /// `text` with the full-width ASCII forms (U+FF01–U+FF5E: ＡＢＣ, １２３, ．, －) as their ASCII
    /// characters, the ideographic space as a space, and Arabic-Indic and Extended Arabic-Indic
    /// digits (٣, ۳) as ASCII digits (Plan JY P5a) — the forms a CJK or Arabic-script manual prints
    /// a model or clause number in, which a question rarely types. One character for one, so
    /// offsets in characters are kept; everything else is untouched, and a text without them is
    /// returned as it is.
    static func foldedForms(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isFoldedForm) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000: scalars.append(" ")
            case 0xFF01...0xFF5E: scalars.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x0660...0x0669: scalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30) ?? scalar)
            case 0x06F0...0x06F9: scalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30) ?? scalar)
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isFoldedForm(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000, 0xFF01...0xFF5E, 0x0660...0x0669, 0x06F0...0x06F9: return true
        default: return false
        }
    }

    /// "0.28", "1,5", "12.0" — digits either side of a decimal mark.
    static func isDecimal(_ token: String) -> Bool {
        token.range(of: #"^\d+(?:[.,]\d+)+$"#, options: .regularExpression) != nil
    }

    /// A plain number: an integer or a decimal ("140", "0.28") — what a reading is made of, and
    /// what a table cell is made of.
    static func isNumber(_ token: String) -> Bool {
        token.range(of: #"^\d+(?:[.,]\d+)*$"#, options: .regularExpression) != nil
    }

    /// Code-like tokens only — the set retrieval boosts on.
    static func codeTokens(from text: String) -> [String] {
        candidateTokens(from: text).filter(isCodeLike)
    }

    /// Words written in capitals, three to eight letters — a designation said as letters: a cord
    /// or cable type ("QXRT"; one with a digit, "QMX90", is a code already). Field report: on a
    /// code-book vault, "that type of cord is <type>, the gauge is 14" boosted only the 14, a cell
    /// on page after page of the book, and never searched the one word that names the cord. Only
    /// as written: a turn typed or transcribed all in capitals has
    /// no designations to tell apart, so it yields none. Retrieval counts one only when the
    /// manuals print it.
    static func capitalisedDesignations(from text: String) -> [String] {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty, letters.contains(where: \.isLowercase) else { return [] }
        var seen = Set<String>()
        return words(in: text).filter { word in
            (3...8).contains(word.count) && word.allSatisfy { $0.isLetter && $0.isUppercase }
                && seen.insert(word).inserted
        }
    }

    /// Ranges a table keys its rows by — "7-9", "10–12" — kept whole (Plan JJ P1). `words(in:)`
    /// splits them at the dash into two one- or two-digit numbers, which are never searched, so a
    /// question naming the row "7-9" reached it only by the words around it, shared by every row of
    /// the table. Each range comes back in both printed spellings, hyphen and en dash, since a
    /// table prints either; retrieval counts one only when the manuals print it. A rule number
    /// ("26-700") is a clause and is taken out before this is asked (`ClauseReference`).
    static func rangeKeys(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}.,\-\x{2013}])(\d{1,4}(?:\.\d{1,2})?)\s?[-\x{2013}]\s?(\d{1,4}(?:\.\d{1,2})?)(?![\p{L}\p{N}]|[.,\-\x{2013}]\d)"#)
        else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let low = ns.substring(with: match.range(at: 1)), high = ns.substring(with: match.range(at: 2))
            guard let a = Double(low), let b = Double(high), a < b else { continue }
            for key in ["\(low)-\(high)", "\(low)\u{2013}\(high)"] where seen.insert(key).inserted { out.append(key) }
        }
        return out
    }

    /// Case-insensitive whole-token containment: "E5" matches "code E5 means" but not "E50".
    ///
    /// A code is also found with its hyphens written differently: "QZ4417" in "the QZ-4417 board"
    /// and the reverse, "QZV441760B" in "QZV-4417-60B". Cloud dictation writes a code without its
    /// hyphens whatever the vocabulary says, and manuals print them. Only for a code of four or
    /// more characters with a letter and two digits (`isHyphenFoldable`), and only as the whole
    /// hyphenated code: "QZ4417" is not found in "QZV-4417-60B", "79" is not a range "7-9", and
    /// "E5" stays exact.
    static func contains(_ haystack: String, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        // Both sides read full-width forms as ASCII (Plan JY P5a).
        let lowerHay = foldedForms(haystack).lowercased()
        let lowerToken = foldedForms(token).lowercased()
        if containsWhole(lowerHay, token: lowerToken) { return true }
        guard lowerHay.contains("-") || lowerToken.contains("-") else { return false }
        let key = lowerToken.replacingOccurrences(of: "-", with: "")
        guard isHyphenFoldable(key) else { return false }
        return containsWhole(joiningHyphenatedWords(lowerHay), token: key)
    }

    /// A text read once, for asking about many tokens: `contains(_:token:)` with the text's words in
    /// a set, so a vault's hundreds of model spellings cost one reading of a passage rather than one
    /// each (Plan KG P4). That scan was 18 ms a passage on a Mac. A token of more than one word, a
    /// hyphenated spelling, is asked the long way.
    struct TokenIndex {
        private let haystack: String
        private let words: Set<String>
        private let joined: Set<String>?

        init(_ haystack: String) {
            self.haystack = haystack
            let lower = CodeTokenizer.foldedForms(haystack).lowercased()
            words = CodeTokenizer.wholeWords(of: lower)
            joined = lower.contains("-") ? CodeTokenizer.wholeWords(of: CodeTokenizer.joiningHyphenatedWords(lower)) : nil
        }

        func contains(_ token: String) -> Bool {
            guard !token.isEmpty else { return false }
            let lower = CodeTokenizer.foldedForms(token).lowercased()
            guard CodeTokenizer.wholeWords(of: lower) == [lower] else { return CodeTokenizer.contains(haystack, token: token) }
            if words.contains(lower) { return true }
            return CodeTokenizer.isHyphenFoldable(lower) && joined?.contains(lower) == true
        }
    }

    /// The runs of `text` that `containsWhole` would call a whole token, by the same boundary.
    private static func wholeWords(of text: String) -> Set<String> {
        var words = Set<String>()
        var word = ""
        var previous: Character?
        for character in text {
            if let last = previous, isWordChar(character, beside: last) {
                word.append(character)
            } else {
                if !word.isEmpty { words.insert(word) }
                word = character.isLetter || character.isNumber ? String(character) : ""
            }
            previous = word.isEmpty ? nil : character
        }
        if !word.isEmpty { words.insert(word) }
        return words
    }

    /// A code whose hyphens are a matter of spelling: four or more letters and digits, at least
    /// one letter and two digits — "QZ4417", "R454B". Shorter codes ("E5", "R22") and numbers
    /// (a range, a rule number) are matched only as written.
    static func isHyphenFoldable(_ key: String) -> Bool {
        key.count >= 4 && key.allSatisfy { $0.isLetter || $0.isNumber }
            && key.contains(where: \.isLetter) && key.filter(\.isNumber).count >= 2
    }

    /// `text` with every hyphen that joins two letters or digits taken out, so a hyphenated code
    /// reads as one word ("qzv-4417-60b" → "qzv441760b"). Every other character is kept.
    private static func joiningHyphenatedWords(_ text: String) -> String {
        let characters = Array(text)
        var out = String()
        out.reserveCapacity(characters.count)
        for (i, c) in characters.enumerated() {
            if c == "-", i > 0, i + 1 < characters.count,
               characters[i - 1].isLetter || characters[i - 1].isNumber,
               characters[i + 1].isLetter || characters[i + 1].isNumber {
                continue
            }
            out.append(c)
        }
        return out
    }

    /// Whole-token containment of an already folded, lowercased token.
    private static func containsWhole(_ lowerHay: String, token lowerToken: String) -> Bool {
        var searchStart = lowerHay.startIndex
        while let range = lowerHay.range(of: lowerToken, range: searchStart..<lowerHay.endIndex) {
            let leadingOK = range.lowerBound == lowerHay.startIndex
                || !isWordChar(lowerHay[lowerHay.index(before: range.lowerBound)], beside: lowerHay[range.lowerBound])
            let trailingOK = range.upperBound == lowerHay.endIndex
                || !isWordChar(lowerHay[range.upperBound], beside: lowerHay[lowerHay.index(before: range.upperBound)])
            if leadingOK && trailingOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Whether `c`, standing beside a token whose edge character is `edge`, continues the
    /// token's word — as `words(in:)` reads words. A letter of a separating script (Han, kana,
    /// Hangul, Cyrillic, Arabic) and any other letter or digit belong to different words (Plan JY
    /// P0), so "ABC123" is whole in "型号ABC123的", and "модель" in "ABC123модель"; two letters of
    /// separating scripts, or two of the others, are one word, as before.
    private static func isWordChar(_ c: Character, beside edge: Character) -> Bool {
        guard c.isLetter || c.isNumber else { return false }
        return separates(c) == separates(edge)
    }

    /// A letter of a script that separates code tokens — the Swift side of `separatingScripts`.
    private static func separates(_ c: Character) -> Bool {
        if c == "\u{30FC}" || c == "\u{FF70}" { return true }
        guard let script = TextScript.of(c) else { return false }
        return script == .cyrillic || script == .arabic || script.isCJK
    }
}
