import Foundation

/// Plan KK — which timeline entries stop being true when their source changes. Pure.
///
/// An entry is derived text. When the messages it was made from are removed (an edit or a
/// regenerate) it summarises words the wearer took back, and the entry goes so the range is
/// summarised again from what is left. When the person it names is erased it would go on
/// re-sending their name on every turn, so its text goes and its span stays (`redactingMentions`).
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

    /// `entries` with every one that names `token` as a whole word (ignoring case and diacritics,
    /// so "Zoë" finds "zoe" and "Ann" does not find "Annual") emptied in place, and how many were.
    /// An empty token names nobody.
    ///
    /// Emptied rather than removed (P2): an erasure leaves the thread text, so a removed entry
    /// would leave its span uncovered and the summary pass would write the name straight back.
    /// A redacted entry keeps covering its span without saying anything. Nothing remembers the
    /// name itself, which would keep the very thing the erasure removed.
    static func redactingMentions(of token: String,
                                  in entries: [TimelineEntry]) -> (entries: [TimelineEntry], redacted: Int) {
        var redacted = 0
        let result = entries.map { entry -> TimelineEntry in
            guard !entry.isRedacted, mentions(entry.text, token) else { return entry }
            redacted += 1
            return entry.redacting()
        }
        return (result, redacted)
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
