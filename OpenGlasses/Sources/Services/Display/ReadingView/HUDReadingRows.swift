import Foundation

/// One row of the reading view (Plan MG §2): a paragraph of the answer, or up to `rowMaxLines`
/// display lines of a long one. Pure data.
struct HUDReadingRow: Equatable {
    /// The row's wrapped display lines.
    let lines: [String]
    /// Which paragraph of the answer the row belongs to.
    let paragraph: Int
    /// The row is the first of its paragraph.
    let startsParagraph: Bool

    var text: String { lines.joined(separator: " ") }
}

/// Cuts an answer into the reading view's rows (Plan MG §2). Pure.
///
/// - **A paragraph is a row**, each source line of the answer a paragraph (blank lines skipped).
/// - **A paragraph longer than `rowMaxLines` is split** the way the answer card cuts its pages
///   (`HUDAnswerPager`'s wrap and sentence rule): a row prefers to end at a sentence, and never
///   breaks inside a word. So each band move brings in a few lines, never a whole screen, and no
///   row is taller than the lens (a row taller than the lens loses its top: measured on the
///   simulated Display).
/// - **Streaming.** Rows are stable on prefixes: every paragraph before the last is settled once a
///   later one has begun, and within the last, every row but its own last
///   (`HUDAnswerPager.settledPageCount`). Once the answer is final every row is settled.
enum HUDReadingRows {
    /// Four lines at most: about 160 px with the card's padding, well inside the 600 px lens.
    static let rowMaxLines = 4

    /// The characters a row's line holds: the lens column less the card's padding either side,
    /// at the answer card's character advance.
    static func maxChars(for geometry: TeleprompterPaginator.Geometry) -> Int {
        let column = LensPageFrame.contentWidthPixels
        let advance = column / CGFloat(max(1, geometry.maxChars))
        let inside = column - 2 * LensPageFrame.cardPaddingPixels
        return max(1, Int((inside / advance).rounded(.down)))
    }

    /// The answer's paragraphs, trimmed, blank ones dropped.
    static func paragraphs(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func rows(for text: String, maxChars: Int, rowMaxLines: Int = rowMaxLines) -> [HUDReadingRow] {
        paragraphs(of: text).enumerated().flatMap { index, paragraph in
            split(paragraph, maxChars: maxChars, rowMaxLines: rowMaxLines).enumerated().map { offset, lines in
                HUDReadingRow(lines: lines, paragraph: index, startsParagraph: offset == 0)
            }
        }
    }

    /// How many leading rows keep their text however much more the answer grows.
    static func settledRowCount(for text: String, maxChars: Int, rowMaxLines: Int = rowMaxLines,
                                isComplete: Bool) -> Int {
        let rows = rows(for: text, maxChars: maxChars, rowMaxLines: rowMaxLines)
        guard !isComplete else { return rows.count }
        let paragraphs = paragraphs(of: text)
        guard let last = paragraphs.last else { return 0 }
        let before = rows.filter { $0.paragraph < paragraphs.count - 1 }.count
        let pages = pager(last, maxChars: maxChars, rowMaxLines: rowMaxLines)
        return before + HUDAnswerPager.settledPageCount(pages)
    }

    /// How many leading paragraphs are settled: all of a final answer, all but the last of one
    /// still streaming.
    static func settledParagraphCount(for text: String, isComplete: Bool) -> Int {
        let count = paragraphs(of: text).count
        return isComplete ? count : max(0, count - 1)
    }

    /// What a press on row `index` says again (decision 3): the answer from that row to its end,
    /// with its paragraph breaks.
    static func spokenText(from index: Int, in rows: [HUDReadingRow]) -> String {
        guard rows.indices.contains(index) else { return "" }
        var text = ""
        for (offset, row) in rows[index...].enumerated() {
            if offset > 0 { text += row.startsParagraph ? "\n" : " " }
            text += row.text
        }
        return text
    }

    // MARK: - Splitting

    private static func pager(_ paragraph: String, maxChars: Int, rowMaxLines: Int) -> [HUDAnswerPage] {
        // The pager keeps one line of a paged page for its footer, so a page of `rowMaxLines + 1`
        // lines carries `rowMaxLines` of text; past its cap would need more than any view holds.
        HUDAnswerPager.pages(for: paragraph,
                             geometry: TeleprompterPaginator.Geometry(maxLines: rowMaxLines + 1, maxChars: maxChars),
                             maxPages: Int.max)
    }

    private static func split(_ paragraph: String, maxChars: Int, rowMaxLines: Int) -> [[String]] {
        let limit = max(1, rowMaxLines)
        return pager(paragraph, maxChars: maxChars, rowMaxLines: limit).flatMap { page -> [[String]] in
            // A single page can hold one more line than a paged one; cut it on its lines.
            guard page.lines.count > limit else { return [page.lines] }
            return stride(from: 0, to: page.lines.count, by: limit).map {
                Array(page.lines[$0..<min($0 + limit, page.lines.count)])
            }
        }
    }
}
