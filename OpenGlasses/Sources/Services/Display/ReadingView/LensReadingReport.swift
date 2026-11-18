import Foundation

/// What the reading view did since the app started (Plan MG §3), for the support report. Counts
/// and sizes only — never a question, an answer or a row's text. In memory only.
struct LensReadingStats: Equatable {
    var viewsDrawn = 0
    var rowPresses = 0
    var earlierOpened = 0
    /// Tappable blocks and characters per view drawn, newest last.
    private(set) var rows: [Int] = []
    private(set) var characters: [Int] = []

    static let keep = 50

    mutating func noteView(rows count: Int, characters size: Int) {
        viewsDrawn += 1
        rows = Array((rows + [count]).suffix(Self.keep))
        characters = Array((characters + [size]).suffix(Self.keep))
    }
}

/// The support report's **Answers on the lens** lines.
enum LensReadingReport {
    static func lines(stats: LensReadingStats, heldTurns: Int, style: String) -> [String] {
        var lines = ["Answers on the lens: \(style); earlier answers held now \(heldTurns)"]
        guard stats.viewsDrawn > 0 || stats.earlierOpened > 0 else {
            lines.append("  Reading views: none since the app started")
            return lines
        }
        lines.append("  Reading views drawn \(stats.viewsDrawn), row presses \(stats.rowPresses),"
                     + " earlier answers opened \(stats.earlierOpened)")
        lines.append("  Rows per view: " + LensPageReport.summary(stats.rows, unit: "rows")
                     + "; characters per view: " + LensPageReport.summary(stats.characters, unit: "chars"))
        return lines
    }
}
