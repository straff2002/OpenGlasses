import CoreGraphics
import Foundation

/// What the whole page highlights, why, and its words (Plan MU §6, decision 7). Pure.
///
/// "Show me the page" opens on the whole page with the part the answer came from outlined in the
/// highlight colour and the rest of the page at about half brightness (`LensPageRenderPlan`'s
/// `brightRects`), so on an additive lens the wearer sees at once where the answer is. At that
/// size the page's text is too small to read, so the line under the picture carries the part's own
/// words, one or two lines: the cited table row's values (from the vault's table, `LensPageRows`),
/// or the cited passage's first sentence. The picture shows where; the line says what.
///
/// The part is the page view's focus (`LensPageFocus`): the cited passages' marks (a table row
/// when the cited passage is a row's), the pictured table's area, the chosen drawing, or nothing
/// for a page asked for by number.
struct LensPageHighlight: Equatable {

    /// Why the part is highlighted: what the support report and the page audit say.
    enum Reason: String, Equatable, CaseIterable {
        /// A cited passage's mark.
        case citedMark = "cited_mark"
        /// A cited table row (a row passage's printed line).
        case tableRow = "table_row"
        /// A table read from a picture, outlined where it was recognised.
        case table
        /// A drawing, asked for or chosen.
        case figure
        /// Nothing: a page asked for by number.
        case none
    }

    let reason: Reason
    /// What is outlined and kept bright, in top-down page points.
    let rects: [CGRect]
    /// The part padded (`LensPageFocus.padded`): what the close-up is of. Nil with no highlight.
    let part: CGRect?
    /// How tall the part's text is, for the close-up's zoom.
    let legibility: LensLegibility
    /// The part's own words for the line under the picture (already cut to `maxWordsCharacters`);
    /// nil when there are none to give.
    let words: String?

    static func none(legibility: LensLegibility = LensLegibility()) -> LensPageHighlight {
        LensPageHighlight(reason: .none, rects: [], part: nil, legibility: legibility, words: nil)
    }

    var isNone: Bool { reason == .none }

    /// Two lens lines of words at most.
    static var maxWordsCharacters: Int { 2 * LensPageFrame.readingGeometry.maxChars }

    /// How many body lines `words` take under the picture: one or two.
    var wordsLineCount: Int {
        guard let words, !words.isEmpty else { return 0 }
        return words.count > LensPageFrame.readingGeometry.maxChars ? 2 : 1
    }

    // MARK: - Making one

    /// The highlight of a laid-out page: its focus, and its words from the cited passages and the
    /// page's table rows.
    static func of(_ layout: LensPageLayout, cited: [CitedPassage], page: Int,
                   rows: LensPageRows?) -> LensPageHighlight {
        let focus = layout.focus
        switch focus.source {
        case .wholePage:
            return .none(legibility: layout.legibility)
        case .figure:
            let rects = focus.region.map { [$0] } ?? []
            return LensPageHighlight(reason: .figure, rects: rects, part: focus.padded,
                                     legibility: layout.legibility, words: nil)
        case .pictureArea:
            return LensPageHighlight(reason: .table, rects: layout.pictureAreas, part: focus.padded,
                                     legibility: layout.legibility, words: nil)
        case .citedPassages:
            let onPage = cited.filter { $0.anchor.covers(page) }
            let isRow = onPage.contains { !$0.anchor.printedRuns.isEmpty }
            let words: String?
            if isRow {
                words = rows?.highlightedText ?? onPage.compactMap { rowWords(ofPassage: $0.anchor.text) }.first
            } else {
                let pageWords = layout.reading?.passages.first?.words
                words = (pageWords ?? onPage.first?.anchor.text).flatMap(firstSentence(of:))
            }
            return LensPageHighlight(reason: isRow ? .tableRow : .citedMark,
                                     rects: layout.marks?.marks.map(\.bounds) ?? [], part: focus.padded,
                                     legibility: layout.legibility, words: words.flatMap(cut))
        }
    }

    /// A drawing as the highlight (**Next diagram** by voice): outlined, no words.
    static func figure(_ drawing: PageDrawing, pageSize: CGSize) -> LensPageHighlight {
        let focus = LensPageFocus.pick(pageSize: pageSize, figure: drawing.rect)
        return LensPageHighlight(reason: .figure, rects: [drawing.rect], part: focus.padded,
                                 legibility: LensPageLayout.legibility(of: drawing), words: nil)
    }

    /// A row passage's values ("E7 · 30 · 35") when the vault's table isn't there to read.
    static func rowWords(ofPassage text: String) -> String? {
        let values = TableRowPassage.values(ofSentence: text)
        guard !values.isEmpty else { return nil }
        let name = TableRowPassage.rowName(ofSentence: text)
        return ([name].compactMap { $0 } + values).joined(separator: " · ")
    }

    /// The passage's first sentence, whitespace collapsed.
    static func firstSentence(of text: String) -> String? {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return PassageLocator.sentences(of: collapsed, starts: []).first ?? collapsed
    }

    /// `words` cut to two lens lines.
    static func cut(_ words: String) -> String? {
        let text = HUDTextShaper.condense(words, max: maxWordsCharacters)
        return text.isEmpty ? nil : text
    }
}
