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
    static func words(in text: String) -> [String] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// A decimal number bounded by non-word characters, or else a run of word characters. The
    /// decimal alternative is tried first so "0.28" is not taken as "0" then "28".
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\d+(?:[.,]\d+)+(?![\p{L}\p{N}])|[\p{L}\p{N}]+"#)

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

    /// Case-insensitive whole-token containment: "E5" matches "code E5 means" but not "E50".
    static func contains(_ haystack: String, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let lowerHay = haystack.lowercased()
        let lowerToken = token.lowercased()
        var searchStart = lowerHay.startIndex
        while let range = lowerHay.range(of: lowerToken, range: searchStart..<lowerHay.endIndex) {
            let leadingOK = range.lowerBound == lowerHay.startIndex
                || !isWordChar(lowerHay[lowerHay.index(before: range.lowerBound)])
            let trailingOK = range.upperBound == lowerHay.endIndex
                || !isWordChar(lowerHay[range.upperBound])
            if leadingOK && trailingOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
