import Foundation

/// Takes citation markup out of text before it is spoken (Plan KZ §6): no web address is ever
/// read aloud.
///
/// - Markdown links keep their words and lose the address: `[the shop list](https://…)` →
///   "the shop list". A link whose words are only a number or an address is dropped.
/// - xAI's inline citations `[[1]](https://…)` and Groq's `【2†L6-L10】` markers are dropped.
/// - Bare addresses (`https://…`, `www.…`, `<https://…>`, `(https://…)`) are dropped.
///
/// Only whitespace is tidied afterwards, never punctuation, so text stripped a piece at a time
/// (`Stream`) and the same text stripped whole agree on every character the speech
/// reconciliation compares. Pure; text with none of this markup comes back unchanged.
enum CitationMarkupStripper {

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals below; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let xaiCitation = regex(#"\[\[\d+\]\]\([^)\s]*\)"#)
    private static let groqMarker = regex(#"【[^】\n]{0,40}】"#)
    private static let markdownLink = regex(#"!?\[([^\]\n]*)\]\(([^)\s]+)\)"#)
    private static let wrappedURL = regex(#"[(<]\s*(?:https?://|www\.)[^\s)>]*\s*[)>]"#)
    private static let bareURL = regex(#"(?:https?://|\bwww\.)[^\s)\]>]+"#)
    /// A URL's trailing sentence punctuation belongs to the sentence.
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    static func strip(_ text: String) -> String {
        guard mayContainMarkup(text) else { return text }
        var result = replace(xaiCitation, in: text) { _ in "" }
        result = replace(groqMarker, in: result) { _ in "" }
        result = replace(markdownLink, in: result) { groups in
            let words = (groups[1] ?? "").trimmingCharacters(in: .whitespaces)
            if words.isEmpty || words.allSatisfy({ $0.isNumber || $0 == "[" || $0 == "]" }) { return "" }
            if words.hasPrefix("http") || words.hasPrefix("www.") { return "" }
            return words
        }
        result = replace(wrappedURL, in: result) { _ in "" }
        result = replace(bareURL, in: result) { groups in
            // Keep a full stop the address swallowed: "see https://x.com." ends a sentence.
            let match = groups[0] ?? ""
            let kept = match.unicodeScalars.reversed().prefix { trailingPunctuation.contains($0) }
            return String(String.UnicodeScalarView(kept.reversed()))
        }
        guard result != text else { return text }
        return tidiedWhitespace(result)
    }

    /// Cheap pre-check: most replies carry no link at all.
    static func mayContainMarkup(_ text: String) -> Bool {
        text.contains("](") || text.contains("【") || text.contains("http://") || text.contains("https://")
            || text.contains("www.")
    }

    private static func replace(_ expression: NSRegularExpression, in text: String,
                                with transform: ([String?]) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups: [String?] = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Runs of spaces become one, and a space left before punctuation goes. The ends are left
    /// alone: a streamed piece's edge spaces separate it from its neighbours.
    private static func tidiedWhitespace(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for char in text {
            if char == " " || char == "\t" {
                if previous == " " { continue }
                out.append(" ")
                previous = " "
                continue
            }
            if previous == " ", ".,;:!?)".contains(char), out.count > 1 { out.removeLast() }
            out.append(char)
            previous = char
        }
        return out
    }

    /// Streamed text, stripped a chunk at a time without ever releasing half a link (§6): the
    /// part that could still become a link or an address is held until it is complete (or until
    /// it plainly is not one), then stripped like whole text.
    struct Stream {
        private var pending = ""
        /// Held text longer than this was never a link; it is let go.
        static let holdLimit = 600

        init() {}

        /// The text safe to pass on now, stripped.
        mutating func ingest(_ chunk: String) -> String {
            pending += chunk
            let cut = Self.safeCut(in: pending)
            guard cut > pending.startIndex else { return "" }
            let ready = String(pending[..<cut])
            pending = String(pending[cut...])
            return CitationMarkupStripper.strip(ready)
        }

        /// Whatever is held, stripped: the stream ended or the iteration did.
        mutating func flush() -> String {
            defer { pending = "" }
            return CitationMarkupStripper.strip(pending)
        }

        /// Where the text stops being certainly complete.
        static func safeCut(in text: String) -> String.Index {
            var hold = text.endIndex
            // An open bracket whose link has not closed yet.
            if var open = text.lastIndex(where: { $0 == "[" }) {
                // xAI's `[[1]](…)` opens with two.
                if open > text.startIndex, text[text.index(before: open)] == "[" {
                    open = text.index(before: open)
                }
                let after = text[open...]
                let closedLink = after.range(of: #"\]\([^)\s]*\)"#, options: .regularExpression) != nil
                let plainBracket = after.contains("]") && !after.hasSuffix("]") && !after.contains("](")
                    && !after.contains("]]")
                if !closedLink && !plainBracket { hold = min(hold, open) }
            }
            if let open = text.lastIndex(of: "【"), !text[open...].contains("】") { hold = min(hold, open) }
            // The last word, if it is or could still become an address.
            if let last = text.last, !last.isWhitespace {
                let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
                let word = text[start...].drop { "([<".contains($0) }.lowercased()
                let prefixes = ["https://", "http://", "www."]
                if prefixes.contains(where: { word.hasPrefix($0) || $0.hasPrefix(word) && !word.isEmpty }) {
                    hold = min(hold, start)
                }
            }
            if text.distance(from: hold, to: text.endIndex) > holdLimit { return text.endIndex }
            return hold
        }
    }
}
