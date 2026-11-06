import Foundation

/// Cuts a whole answer into HUD pages (Plan KP §1, folded in from Plan IB). Pure: the same
/// text and geometry always give the same pages, so it is testable without a display.
///
/// Layout rules:
/// - **Wrapping is the teleprompter's.** Each source line (paragraph) starts a new display line,
///   blank lines are skipped, and words wrap greedily at `geometry.maxChars` exactly as
///   `TeleprompterPaginator.wrap` / `.window` do (`displayLines(for:maxChars:)` is that layout, and
///   the tests hold it equal to `TeleprompterPaginator.window`). Runs of whitespace collapse.
/// - **A single page is today's text.** An answer that fits `geometry.maxLines` lines and
///   `HUDTextShaper.maxBodyLength` characters is one page, no footer, `body` equal to
///   `HUDTextShaper.condense(answer)`.
/// - **A paged answer reserves one footer line** on every page ("1/3", `HUDAnswerPage.footer`), so
///   each page carries `maxLines - 1` lines of text.
/// - **A page break never falls inside a word.** The one exception is a single word longer than
///   a whole page (a long link): the teleprompter already hard-splits a word longer than a line,
///   and such a word is split across pages only when it alone fills the page.
/// - **A page prefers to end at a sentence.** When a page's last line holds a sentence end
///   before its last word, the page ends there and the rest of that line moves to the next page.
/// - **Past `maxPages`** the last page keeps one line for `moreOnPhoneLine` ("… more on phone").
///
/// Streaming: pages are stable on prefixes. When an answer grows by whole words or sentences
/// (separated from what came before by whitespace, as sentence-streamed speech delivers them),
/// the first `settledPageCount(_:)` pages of the shorter text keep their `lines` and `body` in
/// every longer text; only their `count` (and so the footer's total) grows. A single page is
/// never settled, because more text can turn it into a paged answer with a footer.
enum HUDAnswerPager {
    /// Plan KP decision 2: eight pages, then "… more on phone".
    static let defaultMaxPages = 8

    /// The line that ends a capped answer's last page.
    static var moreOnPhoneLine: String { String(localized: "… more on phone") }

    static func pages(for text: String,
                      geometry: TeleprompterPaginator.Geometry,
                      maxPages: Int = defaultMaxPages) -> [HUDAnswerPage] {
        var tokens = tokenize(text)
        guard !tokens.isEmpty else { return [] }
        let maxChars = max(1, geometry.maxChars)
        let maxLines = max(1, geometry.maxLines)

        // One page, exactly as a non-answer caller would show it: an answer short enough that
        // `condense` doesn't cut it, so the body is the whole answer.
        let collapsedLength = tokens.reduce(-1) { $0 + 1 + $1.text.count }
        let whole = layout(tokens, from: 0, maxChars: maxChars, limit: maxLines)
        if whole.count <= maxLines && collapsedLength <= HUDTextShaper.maxBodyLength {
            return [HUDAnswerPage(body: HUDTextShaper.condense(text), lines: whole.map(\.text),
                                  index: 0, count: 1, isCapped: false)]
        }

        // Paged: one line on every page is the footer.
        let contentLines = max(1, maxLines - 1)
        let cap = max(1, maxPages)
        var bodies: [[String]] = []
        var capped = false
        var start = 0
        while start < tokens.count {
            let laid = layout(tokens, from: start, maxChars: maxChars, limit: contentLines)
            if laid.count <= contentLines {          // the rest fits: this is the last page
                bodies.append(laid.map(\.text))
                break
            }
            if bodies.count == cap - 1 {             // the cap page: keep a line for "more on phone"
                let room = contentLines - 1
                var lines: [String] = []
                if room > 0 {
                    let roomLaid = layout(tokens, from: start, maxChars: maxChars, limit: room)
                    lines = cut(roomLaid, pageLines: room, tokens: &tokens, start: start).lines
                }
                bodies.append(lines + [moreOnPhoneLine])
                capped = true
                break
            }
            let page = cut(laid, pageLines: contentLines, tokens: &tokens, start: start)
            bodies.append(page.lines)
            start = page.next
        }

        let count = bodies.count
        return bodies.enumerated().map { index, lines in
            HUDAnswerPage(body: lines.joined(separator: "\n"), lines: lines, index: index,
                          count: count, isCapped: capped && index == count - 1)
        }
    }

    /// How many leading pages of `pages` keep their text however much more the answer grows:
    /// every page but the last of a paged answer, every page of a capped one, none of a single
    /// page. The card shows page 1 once it is settled, or once the turn has ended.
    static func settledPageCount(_ pages: [HUDAnswerPage]) -> Int {
        guard let last = pages.last else { return 0 }
        if last.isCapped { return pages.count }
        return pages.count > 1 ? pages.count - 1 : 0
    }

    /// The answer's wrapped display lines with no page limit: the teleprompter's layout of the
    /// whole text. Exposed for tests and previews.
    static func displayLines(for text: String, maxChars: Int) -> [String] {
        layout(tokenize(text), from: 0, maxChars: max(1, maxChars), limit: Int.max - 1).map(\.text)
    }

    /// Whether a word ends a sentence (closing quotes and brackets after the stop allowed).
    static func endsSentence(_ word: String) -> Bool {
        var trimmed = Substring(word)
        while let last = trimmed.last, sentenceClosers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return sentenceStops.contains(last)
    }

    // MARK: - Layout

    private static let sentenceStops: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let sentenceClosers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    private struct Token {
        var text: String
        let startsParagraph: Bool
    }

    /// Where a token's last character falls on a line (character offset into the line's text).
    private struct Ending {
        let token: Int
        let offset: Int
    }

    private struct LaidLine {
        var text: String
        /// Tokens whose last character is on this line, in order.
        var endings: [Ending]
        /// The line is a hard-split chunk of a word that continues on the next line.
        let endsMidToken: Bool
    }

    private static func tokenize(_ text: String) -> [Token] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var tokens: [Token] = []
        for paragraph in normalized.components(separatedBy: "\n") {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace })
            for (index, word) in words.enumerated() {
                tokens.append(Token(text: String(word), startsParagraph: index == 0))
            }
        }
        return tokens
    }

    /// Greedy wrap from `start`, the same algorithm as `TeleprompterPaginator.wrap` applied per
    /// paragraph, tracking which token ends where. Stops once it has more than `limit` lines, so
    /// `result.count > limit` means "doesn't fit".
    private static func layout(_ tokens: [Token], from start: Int, maxChars: Int, limit: Int) -> [LaidLine] {
        var lines: [LaidLine] = []
        var current = ""
        var endings: [Ending] = []

        func flush(midToken: Bool) {
            lines.append(LaidLine(text: current, endings: endings, endsMidToken: midToken))
            current = ""
            endings = []
        }

        var index = start
        while index < tokens.count && lines.count <= limit {
            let token = tokens[index]
            if token.startsParagraph && !current.isEmpty { flush(midToken: false) }
            if current.isEmpty {
                current = token.text
            } else if current.count + 1 + token.text.count <= maxChars {
                current += " " + token.text
            } else {
                flush(midToken: false)
                current = token.text
            }
            // Only the newest word can overflow a line on its own; hard-split it as `wrap` does.
            while current.count > maxChars {
                let rest = String(current.dropFirst(maxChars))
                current = String(current.prefix(maxChars))
                flush(midToken: true)
                current = rest
            }
            endings.append(Ending(token: index, offset: current.count))
            index += 1
        }
        if !current.isEmpty && lines.count <= limit { flush(midToken: false) }
        return lines
    }

    /// Ends a page that doesn't hold the rest of the answer: the first `pageLines` of `laid`,
    /// pulled back to a word boundary and, where the last line has one, a sentence end.
    /// Returns the page's lines and the token the next page starts at. `tokens` changes only
    /// when a word longer than the whole page has to be split across pages.
    private static func cut(_ laid: [LaidLine], pageLines: Int,
                            tokens: inout [Token], start: Int) -> (lines: [String], next: Int) {
        var page = Array(laid.prefix(pageLines))

        if page.last?.endsMidToken == true {
            // A long word runs over the page break. Its chunks sit on lines of their own; move it
            // whole to the next page unless it is all this page holds.
            while let last = page.last, last.endings.isEmpty { page.removeLast() }
            if let last = page.last, let ending = last.endings.last {
                return (page.map(\.text), ending.token + 1)
            }
            let shown = laid.prefix(pageLines).reduce(0) { $0 + $1.text.count }
            tokens[start].text = String(tokens[start].text.dropFirst(shown))
            return (laid.prefix(pageLines).map(\.text), start)
        }

        guard let last = page.last, let lastEnding = last.endings.last else {
            return (page.map(\.text), start + 1)   // unreachable: a whole line always ends a token
        }
        // Prefer a sentence end inside the last line.
        let candidates = last.endings.dropLast()
        if let stop = candidates.last(where: { endsSentence(tokens[$0.token].text) }) {
            page[page.count - 1].text = String(last.text.prefix(stop.offset))
            return (page.map(\.text), stop.token + 1)
        }
        return (page.map(\.text), lastEnding.token + 1)
    }
}
