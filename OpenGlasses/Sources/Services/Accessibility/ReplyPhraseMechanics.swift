import Foundation

/// The string mechanics the offline answer audit (`BlindAssistanceResponseAudit`) and the runtime
/// reply check (`BlindReplyCheck`) share: how text is folded before a phrase table is matched, how
/// every occurrence of a phrase is found, and the window of text either side of a match in which a
/// qualifier is looked for.
///
/// Lifted out of the audit so the two read text the same way while keeping their own tables: the
/// audit's broad ones are right for hand-written fixtures, where a false positive costs nothing,
/// and the runtime check's narrow ones are right for a sentence about to be said to a blind
/// wearer. Pure and stateless.
enum ReplyPhraseMechanics {

    /// How far either side of a match a qualifier is looked for. Wide enough to catch the clause a
    /// hedge normally lives in, narrow enough that a hedge about a *different* detail somewhere
    /// else in the answer does not launder this one.
    static let qualifierWindow = 80

    /// Lowercased, curly quotes and dashes normalised, whitespace collapsed — so a phrase table
    /// matches speech-shaped text however it was punctuated.
    static func normalised(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Every occurrence of `needle` in `text`, left to right, not overlapping.
    static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// Up to `width` characters before `range`, padded with a space at each end so a
    /// space-delimited marker can match at either edge.
    static func window(_ text: String, before range: Range<String.Index>,
                       width: Int = qualifierWindow) -> String {
        let start = text.index(range.lowerBound, offsetBy: -width,
                               limitedBy: text.startIndex) ?? text.startIndex
        return " " + text[start..<range.lowerBound] + " "
    }

    /// Up to `width` characters either side of `range`, the match included.
    static func window(_ text: String, around range: Range<String.Index>,
                       width: Int = qualifierWindow) -> String {
        let start = text.index(range.lowerBound, offsetBy: -width,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: width,
                             limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    /// Every match of `regex` in `text`, as ranges of `text`.
    static func matches(of regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
    }
}
