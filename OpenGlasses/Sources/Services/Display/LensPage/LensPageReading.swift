import Foundation

/// A cited text passage read on the lens as text (Plan KV §1, reading mode). Pure.
///
/// A picture of body text can't be legible on the Display: a text line spans the column, so even
/// fitted to the line it draws about 9 px tall. When the page view opens on a cited **text
/// passage** — not a pictured table, a marked table row or a drawing — and the page has a text
/// layer, it opens on the passage's own words instead, laid out as lens text and paged like the
/// answer card (`HUDAnswerPager`, "1/2" footer) — but with the reading frame's own geometry
/// (`LensPageFrame.readingGeometry`, about nine lines a page on the Display), not the card's.
///
/// The words are the page's: taken from the page's text by each passage's located ranges, never
/// the model's words or the cited chunk's. Several passages on a page follow one another in the
/// answer's order, each starting a line, numbered as the marks are (only when the page carries more
/// than one cited passage).
struct LensPageReading: Equatable {

    struct Passage: Equatable {
        /// The passage's number in the answer, as its mark has it.
        let number: Int
        /// The page's own words for it, whitespace collapsed.
        let words: String
    }

    let passages: [Passage]
    /// Numbers are shown only when the page carries more than one cited passage, as on the marks.
    let showsNumbers: Bool

    init(passages: [Passage], showsNumbers: Bool) {
        self.passages = passages
        self.showsNumbers = showsNumbers
    }

    /// The located passages' words from `pageText`; nil when none was located there.
    init?(_ marks: PassageMarks, pageText: String?) {
        guard let pageText else { return nil }
        let ns = pageText as NSString
        let found = marks.located.compactMap { mark -> Passage? in
            let words = mark.location.ranges
                .filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= ns.length }
                .map { ns.substring(with: $0) }
                .joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return words.isEmpty ? nil : Passage(number: mark.number, words: words)
        }
        guard !found.isEmpty else { return nil }
        passages = found
        showsNumbers = marks.showsNumbers
    }

    /// What a numbered passage starts with: "2 · ". Digits and a dot, so nothing to translate.
    static func prefix(_ number: Int) -> String { "\(number) · " }

    /// The text the pager lays out: one paragraph per passage.
    var text: String {
        passages.map { showsNumbers ? Self.prefix($0.number) + $0.words : $0.words }.joined(separator: "\n")
    }

    /// The reading pages for `geometry`. The citation line sits over the first page only, so that
    /// page is budgeted one line shorter, as the answer card's question line is.
    func pages(geometry: TeleprompterPaginator.Geometry, citationLine: Bool = true) -> [HUDAnswerPage] {
        HUDAnswerPager.pages(for: text, geometry: geometry, firstPageReservedLines: citationLine ? 1 : 0)
    }

    /// The passage `pages[index]` opens in: the last passage whose first line comes at or before
    /// that page's first line. The passage's mark is where **Page** opens the picture.
    func passageNumber(atPage index: Int, of pages: [HUDAnswerPage]) -> Int? {
        guard let first = passages.first else { return nil }
        guard showsNumbers, pages.indices.contains(index) else { return first.number }
        let known = Set(passages.map(\.number))
        var current = first.number
        func starts(_ line: String) -> Int? {
            guard let dot = line.range(of: " · ") else { return nil }
            return Int(line[line.startIndex..<dot.lowerBound]).flatMap { known.contains($0) ? $0 : nil }
        }
        for page in pages[..<index] {
            for line in page.lines { if let number = starts(line) { current = number } }
        }
        if let line = pages[index].lines.first, let number = starts(line) { current = number }
        return current
    }
}
