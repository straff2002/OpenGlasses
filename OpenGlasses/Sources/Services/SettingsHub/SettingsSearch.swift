import Foundation

// Plan NE P0 — finding a screen or a setting by typing. Pure: what is searched is
// `SettingsIndex.visible(in:)`, so a result can never be something this person could not reach
// from the hub. Never logs the query.

enum SettingsSearch {

    /// How well an entry matched, best first.
    enum Rank: Int, Comparable, Sendable {
        /// The title starts with the query.
        case titlePrefix
        /// A word of the title starts with a word of the query.
        case titleWordPrefix
        /// The title contains the query.
        case titleContains
        /// A keyword matches.
        case keyword
        /// Only where it lives matches.
        case breadcrumb

        static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Result: Identifiable, Equatable, Sendable {
        let entry: SettingsIndexEntry
        /// Where it lives: "Assistant › Voice & Triggers".
        let breadcrumb: String
        let rank: Rank

        var id: String { entry.id }
    }

    /// Whether a query asks for results at all. A blank one shows the hub.
    static func isSearching(_ query: String) -> Bool {
        !words(of: query).isEmpty
    }

    /// The visible entries that match every word of `query`, best first. On a tie, screens come
    /// before settings, then index order. A blank query has no results.
    static func results(for query: String, in conditions: SettingsSearchConditions) -> [Result] {
        let queryWords = words(of: query)
        guard !queryWords.isEmpty else { return [] }
        let whole = queryWords.joined(separator: " ")

        let ranked: [(result: Result, order: Int)] = SettingsIndex.visible(in: conditions).enumerated()
            .compactMap { order, entry in
                let breadcrumb = SettingsIndex.breadcrumb(for: entry, on: conditions.phone)
                guard let rank = rank(of: entry, breadcrumb: breadcrumb, words: queryWords, whole: whole) else {
                    return nil
                }
                return (result: Result(entry: entry, breadcrumb: breadcrumb, rank: rank), order: order)
            }
        return ranked.sorted { lhs, rhs in
            if lhs.result.rank != rhs.result.rank { return lhs.result.rank < rhs.result.rank }
            let lhsScreen = lhs.result.entry.kind == .screen
            let rhsScreen = rhs.result.entry.kind == .screen
            if lhsScreen != rhsScreen { return lhsScreen }
            return lhs.order < rhs.order
        }.map(\.result)
    }

    /// How `entry` matches the (folded) query words, or nil when a word matches nothing.
    static func rank(of entry: SettingsIndexEntry, breadcrumb: String, words: [String], whole: String) -> Rank? {
        let title = fold(entry.title)
        let keywords = entry.keywords.map(fold)
        let place = fold(breadcrumb)
        let everyWordMatches = words.allSatisfy { word in
            title.contains(word) || keywords.contains { $0.contains(word) } || place.contains(word)
        }
        guard everyWordMatches else { return nil }

        if title.hasPrefix(whole) { return .titlePrefix }
        let titleWords = self.words(of: title, separators: .alphanumerics.inverted)
        if titleWords.contains(where: { titleWord in words.contains { titleWord.hasPrefix($0) } }) {
            return .titleWordPrefix
        }
        if title.contains(whole) { return .titleContains }
        if keywords.contains(where: { keyword in words.contains { keyword.contains($0) } }) { return .keyword }
        return .breadcrumb
    }

    /// Case-, diacritic- and width-insensitive, in the current locale: "resume" finds "Résumé".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    /// The folded words of a query, split on white space.
    static func words(of query: String) -> [String] {
        words(of: fold(query), separators: .whitespacesAndNewlines)
    }

    private static func words(of text: String, separators: CharacterSet) -> [String] {
        text.components(separatedBy: separators).filter { !$0.isEmpty }
    }
}
