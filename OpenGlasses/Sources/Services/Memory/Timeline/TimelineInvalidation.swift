import Foundation

/// Plan KK — which timeline entries stop being true when their source changes. Pure.
///
/// An entry is derived text. When the messages it was made from are removed (an edit or a
/// regenerate) it summarises words the wearer took back, and when the person it names is erased
/// it would go on re-sending their name on every turn. Either way the entry goes and the range is
/// summarised again from what is left; nothing here rewrites an entry's text.
enum TimelineInvalidation {

    /// The entries that survive removing `removedIDs` from a thread.
    ///
    /// - Parameter messageIDs: the thread's message ids **before** the removal, in order — spans
    ///   are resolved against it, so a removed message inside a span is caught as well as one at
    ///   either end. An entry whose span cannot be resolved goes too: if it is not known what it
    ///   covers, it cannot be shown not to cover what went.
    static func afterRemoving(_ removedIDs: Set<String>, from messageIDs: [String],
                              entries: [TimelineEntry]) -> [TimelineEntry] {
        guard !removedIDs.isEmpty else { return entries }
        let positions = TimelineEntry.positions(of: messageIDs)
        return entries.filter { entry in
            guard let span = entry.span(in: positions) else { return false }
            return !messageIDs[span].contains { removedIDs.contains($0) }
        }
    }

    /// The entries that do not name `token` as a whole word, ignoring case and diacritics, so
    /// "Zoë" finds "zoe" and "Ann" does not find "Annual". An empty token names nobody.
    static func withoutMentions(of token: String, in entries: [TimelineEntry]) -> [TimelineEntry] {
        entries.filter { !mentions($0.text, token) }
    }

    /// Whether `text` holds `token` as a whole word or phrase, ignoring case and diacritics.
    static func mentions(_ text: String, _ token: String) -> Bool {
        let wanted = fold(token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return false }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: wanted)
            + #"(?![\p{L}\p{N}])"#
        return fold(text).range(of: pattern, options: .regularExpression) != nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
