import Foundation

/// One page of an answer card (Plan KP §1). Pure data, produced by `HUDAnswerPager`.
///
/// `lines` is the authoritative layout: the page's wrapped display lines, without the footer.
/// `body` is the same text as one string, for callers that want a single block:
/// - a single-page answer's `body` is exactly `HUDTextShaper.condense(answer)`, the text every
///   other HUD caller gets today;
/// - a paged answer's `body` is `lines` joined by newlines.
struct HUDAnswerPage: Equatable {
    let body: String
    let lines: [String]
    /// Zero-based page index.
    let index: Int
    /// Pages in the answer as laid out so far. Grows while an answer streams.
    let count: Int
    /// True on the last page of an answer that ran past the page cap: its final line is
    /// `HUDAnswerPager.moreOnPhoneLine`.
    let isCapped: Bool

    var isPaged: Bool { count > 1 }
    var isLast: Bool { index == count - 1 }

    /// The reserved footer line ("1/3") on a paged answer; nil on a single page. Digits and a
    /// slash, so it needs no translation (Plan KP decision 1).
    var footer: String? { isPaged ? "\(index + 1)/\(count)" : nil }
}
