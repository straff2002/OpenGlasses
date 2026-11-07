import Foundation

/// A page a technician names out loud — "page 34", "pages 34 and 35", "p. 12", and in words after
/// "page" or "pages": "page four twenty-seven", "page four oh eight", "page twelve" (Plan KR P1) —
/// recognised in a turn so the number is read as a place in the manual rather than as a code.
///
/// Field report, build 497: "check page 34 of the service manual, item number two" handed `34` to
/// the exact-token search, which ranks a verbatim hit ahead of everything else. The vent-length
/// tables on pages 17 and 18 of the installation instructions print a 34 in a cell, so they filled
/// all four passage slots and the next turn put Table 8 on the phone — a page nobody named, in a
/// manual nobody asked for. A page number says where to look; it is not something to look for.
///
/// Pure and deterministic, the sibling of [[ClauseReference]] and of the job references
/// `ManualTurnScope` takes out of a turn.
enum PageReference {

    /// The pages the text names, in ascending order. A short range ("pages 34 to 36") names every
    /// page in it; a long one names its two ends, because a technician reading out a range that
    /// wide is not pointing at one place.
    static func pages(in text: String) -> Set<Int> {
        var pages = Set<Int>()
        for match in matches(in: text) {
            pages.insert(match.first)
            guard let last = match.last else { continue }
            if match.isRange, last > match.first, last - match.first <= maximumFilledRange {
                pages.formUnion(match.first...last)
            } else {
                pages.insert(last)
            }
        }
        return pages
    }

    /// The text with every named page number blanked out. The page word stays — it is ordinary
    /// language — and only the number that would otherwise be searched as a code goes.
    static func removingReferences(from text: String) -> String {
        let ns = NSMutableString(string: text)
        // Digit and spoken matches are found separately, so blank from the end of the text back.
        let ranges = matches(in: text).flatMap(\.numberRanges).sorted { $0.location > $1.location }
        for range in ranges {
            ns.replaceCharacters(in: range, with: " ")
        }
        return ns as String
    }

    // MARK: - Recognition

    private struct Match {
        let first: Int
        let last: Int?
        let isRange: Bool
        let numberRanges: [NSRange]
    }

    private static let maximumFilledRange = 5

    /// "page 34", "page number 34", "pages 34 and 35", "pages 34-36", "pg 12", "p. 12". A bare
    /// "p" needs its full stop: "p 12" is as likely the end of a part number as a page.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:pages?|pgs?\.?|pp?\.)\s*(?:(?:number|no\.?|num|#)\s*)?(\d{1,4})(?:\s*(-|–|to|through|and|&|,)\s*(\d{1,4}))?(?![\p{L}\p{N}])"#)

    /// "page", "pages", "page number", "page no." before a number said in words. Only the full
    /// word: "p three" is not how a page is said.
    private static let spokenKeyword = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])pages?\s+(?:(?:number|no\.?|num)\s+)?(?=\p{L})"#)
    /// What joins two pages said in words: "to", "through", "and", a dash. Not a comma: "page
    /// twelve, two wires loose" names one page.
    private static let spokenJoiner = try! NSRegularExpression(pattern: #"(?i)^\s*(-|–|to|through|and)\s*"#)

    private static func matches(in text: String) -> [Match] {
        digitMatches(in: text) + spokenMatches(in: text)
    }

    /// A page said in words (Plan KR P1): a page number read aloud is the commonest way a
    /// technician names a page, and digits-only recognition left the turn naming nothing — so the
    /// automatic path opened the search's page over the one asked for.
    private static func spokenMatches(in text: String) -> [Match] {
        let ns = text as NSString
        return spokenKeyword.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { result in
            let start = NSMaxRange(result.range)
            guard let first = SpokenNumber.read(in: ns, from: start, digitGroups: true), first.value > 0 else { return nil }
            var ranges = [NSRange(location: start, length: first.end - start)]
            var last: Int?
            var isRange = false
            let rest = NSRange(location: first.end, length: ns.length - first.end)
            if let joiner = spokenJoiner.firstMatch(in: text, options: [.anchored], range: rest) {
                let after = NSMaxRange(joiner.range)
                if let second = SpokenNumber.read(in: ns, from: after, digitGroups: true), second.value > 0 {
                    last = second.value
                    ranges.append(NSRange(location: after, length: second.end - after))
                    isRange = ["-", "–", "to", "through"].contains(ns.substring(with: joiner.range(at: 1)).lowercased())
                }
            }
            return Match(first: first.value, last: last, isRange: isRange, numberRanges: ranges)
        }
    }

    private static func digitMatches(in text: String) -> [Match] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { result in
            guard let first = Int(ns.substring(with: result.range(at: 1))) else { return nil }
            var ranges = [result.range(at: 1)]
            var last: Int?
            var isRange = false
            if result.range(at: 3).location != NSNotFound, let second = Int(ns.substring(with: result.range(at: 3))) {
                last = second
                ranges.append(result.range(at: 3))
                let joiner = ns.substring(with: result.range(at: 2)).lowercased()
                isRange = ["-", "–", "to", "through"].contains(joiner)
            }
            return Match(first: first, last: last, isRange: isRange, numberRanges: ranges)
        }
    }
}
