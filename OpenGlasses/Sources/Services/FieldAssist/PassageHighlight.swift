import Foundation
import PDFKit
import UIKit

// The highlight in the viewer (Plan IN P1).
//
// The partner's electrician wants the exact supporting passage marked on the page "so he reads the
// requirement instead of the whole page". `PassageLocator` says where a passage is; this says what
// the sheet draws for it, what it says when it cannot draw it, and what VoiceOver reads first.
// The drawing is PDFKit's own highlight annotation on the in-memory page — never written to the
// file, which is the vault's read-only copy and the thing "unmodified since import" is checked on.

/// One passage an answer cited, with the number it has in that answer ("the second one").
struct CitedPassage: Equatable, Hashable {
    /// 1-based, in the order the answer cited its sources.
    let number: Int
    let anchor: PassageAnchor
}

/// Where a citation that names a range opens, and what its passages mark there (Plan KE P2). Pure.
enum CitedPagePlacement {

    /// The page of `pages` holding most of the passages, or the first page when they are on none.
    /// A passage found on a page it does not say it covers is put on that page, and one on no page
    /// of the range is put on the page that opens if it covers none, so the sheet says it could not
    /// be marked instead of saying nothing.
    static func place(_ passages: [CitedPassage], among pages: ClosedRange<Int>,
                      pageText: (Int) -> String?) -> (page: Int, passages: [CitedPassage]) {
        var texts: [Int: String] = [:]
        for page in pages.prefix(PassageLocator.maximumRangePages) {
            if let text = pageText(page) { texts[page] = text }
        }
        let opening = PassageLocator.page(holding: passages.map(\.anchor), among: pages, pageText: { texts[$0] })
            ?? pages.lowerBound
        let placed = passages.map { passage -> CitedPassage in
            let anchor = passage.anchor
            if pages.contains(where: { anchor.covers($0) && !PassageLocator.locate(anchor, onPage: $0, pageText: texts[$0]).ranges.isEmpty }) {
                return passage
            }
            let found = pages.prefix(PassageLocator.maximumRangePages).first {
                !PassageLocator.locate(anchor, onPageText: texts[$0]).ranges.isEmpty
            }
            if let found { return CitedPassage(number: passage.number, anchor: anchor.placed(on: found)) }
            return pages.contains(where: anchor.covers) ? passage
                : CitedPassage(number: passage.number, anchor: anchor.placed(on: opening))
        }
        return (opening, placed)
    }
}

/// What marking one page came to, decided without a screen.
struct PassageMarks: Equatable {

    struct Mark: Equatable {
        let number: Int
        let location: PassageLocation
    }

    let marks: [Mark]

    /// Locate every cited passage on `page` (physical) in that page's text.
    init(passages: [CitedPassage], page: Int, pageText: String?) {
        marks = passages.filter { $0.anchor.covers(page) }.map {
            Mark(number: $0.number, location: PassageLocator.locate($0.anchor, onPage: page, pageText: pageText))
        }
    }

    init(marks: [Mark]) { self.marks = marks }

    /// Whether there was anything to mark on this page at all. A page reached by paging away, or
    /// opened without a passage, has none — and says nothing about it.
    var hasPassages: Bool { !marks.isEmpty }

    var located: [Mark] { marks.filter { !$0.location.ranges.isEmpty } }

    /// Numbers drawn beside each mark only when the page carries more than one cited passage, so
    /// the marks match the answer's "first" and "second".
    var showsNumbers: Bool { marks.count > 1 }

    /// The plain line the sheet shows when a passage could not be marked (decision 3). The page
    /// still opens; it just carries no mark that would be read as the requirement.
    var unmarkedLine: String? {
        guard hasPassages else { return nil }
        let missing = marks.count - located.count
        guard missing > 0 else { return nil }
        if located.isEmpty {
            return marks.count == 1 ? "The passage couldn't be marked on this page."
                : "The passages couldn't be marked on this page."
        }
        return missing == 1 ? "One of the passages couldn't be marked on this page."
            : "\(missing) of the passages couldn't be marked on this page."
    }

    /// What VoiceOver reads before the page: the marked words themselves, in order.
    func spokenPassages(in pageText: String?) -> String? {
        guard let pageText, !located.isEmpty else { return nil }
        let ns = pageText as NSString
        let parts = located.map { mark -> String in
            let words = mark.location.ranges
                .filter { NSMaxRange($0) <= ns.length }
                .map { ns.substring(with: $0).replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " ")
            return showsNumbers ? "Passage \(mark.number): \(words)" : words
        }
        return "Highlighted: " + parts.joined(separator: " ")
    }
}

/// Draws the marks on a PDF page as highlight annotations.
enum PassageHighlighter {

    /// Tags every annotation this app adds, so a re-render removes exactly its own marks and never
    /// one the publisher put in the file.
    static let annotationTag = "openglasses.passage-highlight"

    /// The highlight on a PDF page. A PDF page is paper in both appearances — PDFKit draws it white
    /// in dark mode too — so the page highlight is the design kit's light value either way; the
    /// extracted-text fallback, which sits on the canvas, uses the adaptive token.
    static var pageColor: UIColor {
        UIColor(red: OGTheme.Token.passageHighlight.light.red, green: OGTheme.Token.passageHighlight.light.green,
                blue: OGTheme.Token.passageHighlight.light.blue, alpha: OGTheme.Opacity.passageHighlightOnPaper)
    }

    /// Replace this app's marks on `page` with those for `marks`. Returns the bounds of the first
    /// mark, in page space, for the viewer to scroll to.
    @discardableResult
    static func apply(_ marks: PassageMarks, to page: PDFPage) -> CGRect? {
        clear(page)
        var first: CGRect?
        for mark in marks.located {
            var numbered = false
            for range in mark.location.ranges {
                guard let selection = page.selection(for: range) else { continue }
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let highlight = PDFAnnotation(bounds: bounds.insetBy(dx: -1, dy: -1),
                                                  forType: .highlight, withProperties: nil)
                    highlight.color = pageColor
                    highlight.userName = annotationTag
                    page.addAnnotation(highlight)
                    if first == nil { first = bounds }
                    if marks.showsNumbers, !numbered {
                        page.addAnnotation(numberLabel(mark.number, beside: bounds))
                        numbered = true
                    }
                }
            }
        }
        return first
    }

    /// Outline each region (top-down page points, as [[PictureRegion]] keeps them) on `page`, where
    /// a table was read from a picture (Plan JN P2). Tagged like the highlights, so `clear` removes
    /// them. Returns the first region's bounds in page space, for the viewer to scroll to.
    @discardableResult
    static func outline(_ regions: [CGRect], on page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .mediaBox)
        var first: CGRect?
        for region in regions {
            let bounds = PictureRegion.pdfRect(ofPageRect: region, mediaBox: box)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let outline = PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
            outline.color = pageColor.withAlphaComponent(1)
            let border = PDFBorder()
            border.lineWidth = 2
            outline.border = border
            outline.userName = annotationTag
            page.addAnnotation(outline)
            if first == nil { first = bounds }
        }
        return first
    }

    /// Remove every mark this app drew on `page`.
    static func clear(_ page: PDFPage) {
        for annotation in page.annotations where annotation.userName == annotationTag {
            page.removeAnnotation(annotation)
        }
    }

    /// A small number in the margin beside a mark's first line, the way the answer numbered it.
    private static func numberLabel(_ number: Int, beside line: CGRect) -> PDFAnnotation {
        let size: CGFloat = 14
        let bounds = CGRect(x: max(line.minX - size - 3, 0), y: line.midY - size / 2, width: size, height: size)
        let label = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        label.contents = "\(number)"
        label.font = UIFont.boldSystemFont(ofSize: 10)
        label.fontColor = .black
        label.color = pageColor
        label.alignment = .center
        label.userName = annotationTag
        return label
    }
}
