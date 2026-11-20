import Foundation

/// The on-keyword mode's ear for the wearer's trigger words (Plan MO §2).
///
/// The wearer lists words or names; when one is said, by anyone, it fires. Whole words only, with
/// case and diacritics ignored, so "cart" never fires inside "cartridge" and "Müller" fires on
/// "muller". A trigger of several words ("price list") fires when they are said together, in that
/// order. A word that fired is held for `HintLimits.keywordHold` seconds so a topic that keeps
/// coming up puts one card on the lens, not one per sentence.
///
/// Pure apart from its own hold state; the clock is the `at` passed to `match`.
struct KeywordMatcher: Equatable {

    /// The wearer's keywords as they typed them, without blanks or folded repeats.
    let keywords: [String]
    private let folded: [[String]]
    private var firedAt: [String: Date] = [:]

    init(keywords: [String]) {
        var seen = Set<String>()
        var kept: [String] = []
        var folded: [[String]] = []
        for keyword in keywords {
            let words = HintText.words(keyword)
            let key = words.joined(separator: " ")
            guard !words.isEmpty, seen.insert(key).inserted else { continue }
            kept.append(keyword.trimmingCharacters(in: .whitespacesAndNewlines))
            folded.append(words)
        }
        self.keywords = kept
        self.folded = folded
    }

    var isEmpty: Bool { keywords.isEmpty }

    /// The keywords `text` says that are not being held, in the order the text first says them.
    /// Each one returned is held from `now`.
    mutating func match(_ text: String, at now: Date) -> [String] {
        let words = HintText.words(text)
        guard !words.isEmpty else { return [] }
        var hits: [(position: Int, index: Int)] = []
        for (index, keyword) in folded.enumerated() {
            guard let position = Self.firstPosition(of: keyword, in: words) else { continue }
            let key = keyword.joined(separator: " ")
            if let fired = firedAt[key],
               now.timeIntervalSince(fired) < HintLimits.keywordHold - HintLimits.timeTolerance {
                continue
            }
            hits.append((position, index))
        }
        hits.sort { $0.position == $1.position ? $0.index < $1.index : $0.position < $1.position }
        for hit in hits { firedAt[folded[hit.index].joined(separator: " ")] = now }
        return hits.map { keywords[$0.index] }
    }

    /// Forget every hold (a new session).
    mutating func reset() { firedAt.removeAll() }

    /// Where `phrase` first occurs in `words` as consecutive whole words.
    private static func firstPosition(of phrase: [String], in words: [String]) -> Int? {
        guard phrase.count <= words.count else { return nil }
        for start in 0...(words.count - phrase.count)
        where words[start..<start + phrase.count].elementsEqual(phrase) {
            return start
        }
        return nil
    }
}
