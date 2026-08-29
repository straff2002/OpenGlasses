import Foundation

/// One conversation turn as fed to the recall index. A plain value type (decoupled from
/// `ConversationStore`'s model) so the index + query builder are pure and headless-testable;
/// Phase 2 maps `ConversationMessage` → `IndexedTurn`.
struct IndexedTurn: Equatable, Sendable {
    let id: String          // stable per message (ConversationMessage.id)
    let threadID: String
    let role: String        // "user" / "assistant" / "system"
    let text: String
    let timestamp: Date
}

/// A search hit from the conversation index: the matched turn plus an FTS snippet and rank.
struct RecallHit: Equatable, Sendable {
    let id: String
    let threadID: String
    let role: String
    let text: String
    let timestamp: Date
    /// FTS5 `snippet()` excerpt with the match highlighted (falls back to a text prefix).
    let snippet: String
    /// FTS5 bm25 score — lower is a better match. 0 for non-MATCH (date-only) queries.
    let rank: Double
}

/// A natural-language recall phrase parsed into an FTS5 query + optional date window.
/// `match == nil` means "no text filter" (e.g. "what did we talk about yesterday") — the
/// index then returns the most recent turns in the date window.
struct ParsedQuery: Equatable, Sendable {
    let match: String?
    let since: Date?
    let until: Date?

    var isEmpty: Bool { match == nil && since == nil && until == nil }
}

/// Turns a spoken recall phrase into a safe FTS5 MATCH + a date window. Pure and
/// deterministic given an injected `now`, so date phrases ("yesterday", "last week") are
/// fully unit-tested without a clock.
enum FTSQueryBuilder {
    /// Common words that carry no search signal (question words, articles, pronouns, aux verbs).
    /// `last`/`this` are handled by date detection *before* this set is applied.
    static let stopwords: Set<String> = [
        "what", "when", "where", "who", "whom", "why", "how", "which",
        "did", "do", "does", "was", "were", "is", "are", "am", "be", "been",
        "the", "a", "an", "of", "to", "in", "on", "at", "for", "about", "with",
        "we", "i", "you", "he", "she", "it", "they", "me", "my", "our", "your",
        "that", "this", "these", "those", "and", "or", "but", "so", "then",
        "say", "said", "talk", "talked", "tell", "told", "discuss", "discussed",
    ]

    static func build(_ phrase: String, now: Date, calendar: Calendar = .current) -> ParsedQuery {
        let lower = phrase.lowercased()
        let (since, until, dateWords) = dateWindow(in: lower, now: now, calendar: calendar)

        let tokens = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) && !dateWords.contains($0) }

        let match = tokens.isEmpty
            ? nil
            : tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
        return ParsedQuery(match: match, since: since, until: until)
    }

    /// Detect a relative-date phrase and return its [since, until) window plus the words to
    /// drop from the token stream.
    private static func dateWindow(in phrase: String, now: Date,
                                   calendar: Calendar) -> (Date?, Date?, Set<String>) {
        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: startOfToday)! }

        if phrase.contains("today") {
            return (startOfToday, day(1), ["today"])
        }
        if phrase.contains("yesterday") {
            return (day(-1), startOfToday, ["yesterday"])
        }
        if phrase.contains("last week") {
            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            return (calendar.date(byAdding: .day, value: -7, to: startOfWeek)!, startOfWeek,
                    ["last", "week"])
        }
        if phrase.contains("this week") {
            let week = calendar.dateInterval(of: .weekOfYear, for: now)!
            return (week.start, week.end, ["this", "week"])
        }
        if phrase.contains("last month") {
            let startOfMonth = calendar.dateInterval(of: .month, for: now)!.start
            return (calendar.date(byAdding: .month, value: -1, to: startOfMonth)!, startOfMonth,
                    ["last", "month"])
        }
        if phrase.contains("this month") {
            let month = calendar.dateInterval(of: .month, for: now)!
            return (month.start, month.end, ["this", "month"])
        }
        return (nil, nil, [])
    }
}

/// Shared ISO-8601 timestamp format for the index — fixed-width and lexically sortable, so
/// FTS5 (whose columns are text) can range-filter chronologically with plain string compares.
enum RecallTimestamp {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // yyyy-MM-dd'T'HH:mm:ssZ — sorts chronologically
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}
