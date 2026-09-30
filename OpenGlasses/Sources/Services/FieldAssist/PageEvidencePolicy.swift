import Foundation

/// How a manual page came to be in front of the technician (Plan GB P1).
enum PageOrigin: String, Codable, Equatable {
    /// The app put it there by itself, off a turn's evidence.
    case automatic
    /// The technician asked for it — a citation chip, "show me the wiring diagram", a page they
    /// named.
    case requested
}

/// How the technician said the page checked out.
enum PageConfirmation: Equatable {
    case none
    /// "Checked against manual" on the sheet.
    case tap
    /// "Checked", "that matches the manual" — classified by `SpokenPageConfirmation`.
    case spoken
}

/// What the record may say about a page (Plan GB P1, Decision 2).
enum PageEvidenceState: String, Equatable {
    /// Put on screen by the app. Never listed as verified; kept in the JSON, left out of the PDF.
    case shown
    /// The technician asked for it.
    case opened
    /// The technician confirmed it against what they were doing.
    case verified
}

/// The rule for what a page on screen is evidence of.
///
/// Job 1011's report listed six pages "verified against the manufacturer's document" while its
/// record showed none opened: the sheet appearing was logged as a verification, and the sheet
/// appeared by itself. A page appearing is not a technician checking anything. Verified now means
/// what it says — an explicit confirmation, never a dwell time and never the sheet's appearance.
///
/// - A tap on **Checked against manual** verifies the page on screen, whichever way it got there:
///   it is the technician's own act, on that page, on that page's own control.
/// - A spoken confirmation verifies only a page the technician opened. A sentence cannot say which
///   page it is about, so it is taken to be about the one they asked for, and about nothing when
///   the page on screen is one the app put there.
enum PageEvidencePolicy {

    static func classify(origin: PageOrigin, confirmation: PageConfirmation) -> PageEvidenceState {
        switch (origin, confirmation) {
        case (_, .tap): return .verified
        case (.requested, .spoken): return .verified
        case (.requested, .none): return .opened
        case (.automatic, _): return .shown
        }
    }

    /// One label for a page, however it was reached: "SLP99UHVK Service Manual, page 30" or
    /// "…, page 65, Figure 65". Opened, shown and verified pages are keyed alike, so the same page
    /// is the same entry in every list (the field test had "page 65, Figure 65" and "page 65").
    static func label(title: String, page: Int, figure: String? = nil) -> String {
        var parts = [title, "page \(page)"]
        if let figure, !figure.isEmpty { parts.append(figure) }
        return parts.joined(separator: ", ")
    }

    /// A citation's label in the same form. A core-file citation has no page and keeps its own.
    static func label(for citation: Citation) -> String {
        guard citation.kind == .manual, let page = citation.page else { return citation.label }
        return label(title: citation.title, page: page, figure: citation.figure)
    }
}

/// "Checked", "that matches the manual" — a technician saying the page on screen checks out.
///
/// Deterministic and strict. The words have to be a confirmation and nothing much else: a short
/// utterance, or one that names the manual, with no negation in it. "I checked the filter" is work
/// done, not a page confirmed, and "that doesn't match the manual" is the opposite of one.
enum SpokenPageConfirmation {

    static func isConfirmation(_ text: String) -> Bool {
        let words = ManualTurnClassifier.words(text)
        guard !words.isEmpty, words.count <= maximumWords else { return false }
        guard !words.contains(where: negations.contains) else { return false }
        guard words.contains(where: confirmingWords.contains) else { return false }
        return words.count <= bareConfirmationWords || words.contains(where: manualWords.contains)
    }

    private static let maximumWords = 10
    /// "Checked", "that matches", "yep, confirmed".
    private static let bareConfirmationWords = 3

    private static let confirmingWords: Set<String> = [
        "checked", "matches", "match", "matched", "confirmed", "verified", "agrees",
    ]
    private static let manualWords: Set<String> = [
        "manual", "page", "book", "diagram", "drawing", "table", "figure", "chart",
    ]
    private static let negations: Set<String> = [
        "not", "no", "dont", "doesnt", "didnt", "isnt", "wont", "cant", "never", "wrong",
        "different", "unchecked",
    ]
}
