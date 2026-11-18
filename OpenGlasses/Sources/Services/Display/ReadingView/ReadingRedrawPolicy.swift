import Foundation

/// When the reading view is sent while its answer streams (Plan MG §2). Pure.
///
/// Every `send()` replaces the whole view, so a redraw resets focus and where the lens is scrolled
/// to, and the app never hears where the wearer has scrolled. So the view is not redrawn on every
/// streamed sentence:
///
/// - **the first draw** once a row has settled (as the paged card waits for a settled page), or the
///   answer is complete, whichever comes first;
/// - **while it streams,** again each time a paragraph settles (a later paragraph has begun);
/// - **the final draw** when the text is complete;
/// - **after that, never for the text.** Only a press, a new answer (a new policy) or the lens
///   coming back redraws it, and the card does those itself. Answer text usually finishes long
///   before the speech does, so the wearer is still at the top when the last draw lands.
struct ReadingRedrawPolicy: Equatable {
    /// How far the answer had got.
    struct Progress: Equatable {
        var settledRows: Int
        var settledParagraphs: Int
        var isComplete: Bool
    }

    /// The progress at the last draw this policy asked for; nil before the first.
    private(set) var drawn: Progress?

    var hasDrawn: Bool { drawn != nil }
    /// The final draw has been made: the text never redraws the view again.
    var drewComplete: Bool { drawn?.isComplete ?? false }

    /// The answer's text changed (more streamed, or it became final): whether to send the view now.
    mutating func textChanged(_ progress: Progress) -> Bool {
        guard let drawn else {
            guard progress.settledRows > 0 || progress.isComplete else { return false }
            self.drawn = progress
            return true
        }
        guard !drawn.isComplete else { return false }
        guard progress.isComplete || progress.settledParagraphs > drawn.settledParagraphs else { return false }
        self.drawn = progress
        return true
    }

    /// A new answer: the next text change starts over.
    mutating func reset() {
        drawn = nil
    }
}
