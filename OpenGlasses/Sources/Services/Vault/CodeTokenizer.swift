import Foundation

/// What an equipment code looks like — shared by equipment lookup (OCR tokens → vault search) and
/// manual retrieval (exact-token boost), so both agree on what counts as "E5", "30RB", "T02".
enum CodeTokenizer {

    /// Plausible code/model tokens from free text: alphanumeric, 2–14 chars, containing at least
    /// one digit or being short uppercase-only (e.g. "E5", "30RB", "T02", "DAIKIN"). Order of first
    /// appearance, de-duplicated case-insensitively.
    static func candidateTokens(from text: String) -> [String] {
        let raw = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var seen = Set<String>()
        var tokens: [String] = []
        for token in raw {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, t.count <= 14 else { continue }
            let hasDigit = t.contains { $0.isNumber }
            let isShortAlpha = t.count <= 8 && t.allSatisfy { $0.isLetter }
            guard hasDigit || isShortAlpha else { continue }
            if seen.insert(t.uppercased()).inserted { tokens.append(t) }
        }
        return tokens
    }

    /// A token strong enough to boost retrieval on its own: it carries a digit, so it is a code or
    /// a model number rather than an ordinary word that happened to be short.
    static func isCodeLike(_ token: String) -> Bool {
        token.count >= 2 && token.contains { $0.isNumber }
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
