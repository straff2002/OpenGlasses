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

/// Cuts an answer into the reading view's rows (Plan MG §2, Plan MU §1). Pure.
///
/// - **A paragraph is a row** when it fits in `rowMaxLines` (8) lines, each source line of the
///   answer a paragraph (blank lines skipped).
/// - **A longer paragraph is cut** at the last sentence end at or before its 8th line, and where
///   those lines hold none, at the last word that fits. A row never breaks inside a word (except a
///   word longer than a whole line, which the wrap hard-splits as the teleprompter does).
/// - **No orphan tile.** The paragraph's last piece, when it is one line or under
///   `orphanCharacters` characters, joins the row before it if that row then stays within
///   `rowCeilingLines` (9, the lens-safe ceiling). Otherwise the cut moves back a sentence (or, with
///   no earlier sentence end, a word at a time) until the last piece is not that short. There is no
///   other cut: MG's stride cut, which made a tile of "20.", is gone.
/// - **Lens height.** 8 lines is about 320 px with the card's padding, 9 about 360: inside the
///   600 px lens with the question line and the start of the next tile (a row taller than the lens
///   loses its top: measured on the simulated Display).
/// - **Streaming.** Rows are stable on prefixes: every paragraph before the last is settled once a
///   later one has begun, and within the last, every row but its own last — and none from a row
///   whose end the no-orphan rule moved back on, since more text can undo that move. Once the
///   answer is final every row is settled.
enum HUDReadingRows {
    /// Plan MU decision 1: eight lines, joined up to nine.
    static let rowMaxLines = 8
    /// The tallest a row may grow by taking in a short last piece.
    static let rowCeilingLines = 9
    /// A last piece shorter than this (or of one line) is an orphan.
    static let orphanCharacters = 20

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
            split(paragraph, maxChars: maxChars, rowMaxLines: rowMaxLines).rows.enumerated().map { offset, lines in
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
        return before + split(last, maxChars: maxChars, rowMaxLines: rowMaxLines).settledRows
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

    /// A paragraph's rows, and the first row whose end the no-orphan rule moved back: more text
    /// can make the last piece long enough to need no move, so that row and every one after it may
    /// still change.
    struct Split: Equatable {
        var rows: [[String]]
        var firstMovedRow: Int?

        /// The rows that keep their text however much more of the paragraph comes: all but the
        /// last, and none from a moved one on.
        var settledRows: Int { min(max(0, rows.count - 1), firstMovedRow ?? Int.max) }
    }

    /// One word of a paragraph, or a `maxChars` chunk of a word longer than a line.
    private struct Token {
        let text: String
        /// A chunk of a hard-split word with more of the word after it: no sentence ends here.
        let continues: Bool
    }

    private static func tokens(_ paragraph: String, maxChars: Int) -> [Token] {
        paragraph.split(whereSeparator: { $0.isWhitespace }).flatMap { word -> [Token] in
            var rest = Substring(word)
            var chunks: [Token] = []
            while rest.count > maxChars {
                chunks.append(Token(text: String(rest.prefix(maxChars)), continues: true))
                rest = rest.dropFirst(maxChars)
            }
            chunks.append(Token(text: String(rest), continues: false))
            return chunks
        }
    }

    /// The greedy wrap of `tokens[range]`, the teleprompter's: a word goes on the line when it
    /// fits after a space, otherwise starts the next.
    private static func wrap(_ tokens: [Token], _ range: Range<Int>, maxChars: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for token in tokens[range] {
            if current.isEmpty {
                current = token.text
            } else if current.count + 1 + token.text.count <= maxChars {
                current += " " + token.text
            } else {
                lines.append(current)
                current = token.text
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func lineCount(_ tokens: [Token], _ range: Range<Int>, maxChars: Int) -> Int {
        wrap(tokens, range, maxChars: maxChars).count
    }

    /// The tokens from `start` that fill at most `lines` lines: the end of the longest such run.
    private static func end(of tokens: [Token], from start: Int, lines limit: Int, maxChars: Int) -> Int {
        var line = 0
        var used = 0
        var index = start
        while index < tokens.count {
            let length = tokens[index].text.count
            if used == 0 {
                used = length
            } else if used + 1 + length <= maxChars {
                used += 1 + length
            } else {
                line += 1
                used = length
            }
            if line >= limit { return index }
            index += 1
        }
        return tokens.count
    }

    private static func isOrphan(_ tokens: [Token], _ range: Range<Int>, maxChars: Int) -> Bool {
        guard !range.isEmpty else { return false }
        let characters = tokens[range].reduce(-1) { $0 + 1 + $1.text.count }
        return lineCount(tokens, range, maxChars: maxChars) <= 1 || characters < orphanCharacters
    }

    private static func endsSentence(_ token: Token) -> Bool {
        !token.continues && HUDAnswerPager.endsSentence(token.text)
    }

    /// `ceilingLines` is how tall a row may grow by taking in the last piece: one line over
    /// `rowMaxLines` by default, which always holds a one-line piece, so with the defaults the cut
    /// never has to move back. A lower ceiling (a test's) does move it.
    static func split(_ paragraph: String, maxChars: Int, rowMaxLines: Int, ceilingLines: Int? = nil) -> Split {
        let chars = max(1, maxChars)
        let limit = max(1, rowMaxLines)
        let ceiling = max(limit, ceilingLines ?? limit + (rowCeilingLines - Self.rowMaxLines))
        let tokens = tokens(paragraph, maxChars: chars)
        var rows: [[String]] = []
        var firstMoved: Int?
        var start = 0
        while start < tokens.count {
            let fullEnd = end(of: tokens, from: start, lines: limit, maxChars: chars)
            if fullEnd >= tokens.count {
                rows.append(wrap(tokens, start..<tokens.count, maxChars: chars))
                break
            }
            // The cut: the last sentence end inside the first `limit` lines, else the last word.
            let sentenceCuts = (start..<fullEnd).filter { endsSentence(tokens[$0]) }.map { $0 + 1 }
            var cut = sentenceCuts.last ?? fullEnd
            // The no-orphan rule, for the paragraph's last piece only.
            let rest = cut..<tokens.count
            if lineCount(tokens, rest, maxChars: chars) <= limit, isOrphan(tokens, rest, maxChars: chars) {
                if lineCount(tokens, start..<tokens.count, maxChars: chars) <= ceiling {
                    rows.append(wrap(tokens, start..<tokens.count, maxChars: chars))
                    break
                }
                if let earlier = sentenceCuts.dropLast().last {
                    cut = earlier
                } else {
                    while cut - 1 > start, isOrphan(tokens, cut..<tokens.count, maxChars: chars) { cut -= 1 }
                }
                if firstMoved == nil { firstMoved = rows.count }
            }
            rows.append(wrap(tokens, start..<cut, maxChars: chars))
            start = cut
        }
        return Split(rows: rows, firstMovedRow: firstMoved)
    }
}
