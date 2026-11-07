import CoreGraphics
import Foundation
import PDFKit

/// Where a range of a page's text sits on the page (Plan KV P0): the seam between `PassageMarks`'
/// text ranges and the lens's rectangles, so the core is tested with a fake and PDFKit stays
/// behind one implementation.
protocol PageTextGeometry {
    /// The page, in PDF points.
    var pageSize: CGSize { get }
    /// One rectangle per line `range` (UTF-16, in the page's own text) covers, in top-down page
    /// points from the media box's top left. Empty when the range is not on the page.
    func lineRects(for range: NSRange) -> [CGRect]
}

/// `PageTextGeometry` from PDFKit's selection bounds. Needs no view, so it runs headless.
struct PDFKitPageTextGeometry: PageTextGeometry {
    let page: PDFPage

    var pageSize: CGSize { page.bounds(for: .mediaBox).size }

    func lineRects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0,
              let length = page.string.map({ ($0 as NSString).length }),
              NSMaxRange(range) <= length,
              let selection = page.selection(for: range) else { return [] }
        let box = page.bounds(for: .mediaBox)
        return selection.selectionsByLine().compactMap { line in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return Self.topDown(bounds, mediaBox: box)
        }
    }

    /// A rectangle in PDF page space (origin at the media box's bottom left, y up) in top-down page
    /// points from its top left — the inverse of `PictureRegion.pdfRect(ofPageRect:mediaBox:)`.
    static func topDown(_ rect: CGRect, mediaBox: CGRect) -> CGRect {
        CGRect(x: rect.minX - mediaBox.minX, y: mediaBox.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A page's located passage marks as rectangles for the lens (Plan KV §1–2), numbered the way the
/// answer numbered them. Marks that could not be located on the page, or whose ranges give no
/// rectangle, are left out: a mark is drawn only where the passage was found.
struct LensPageMarks: Equatable {

    struct Mark: Equatable {
        /// The passage's number in the answer.
        let number: Int
        /// One rectangle per marked line, in top-down page points.
        let lineRects: [CGRect]
        /// The lines united.
        let bounds: CGRect
    }

    let marks: [Mark]
    /// Numbers are drawn only when the page carries more than one cited passage, as on the phone.
    let showsNumbers: Bool

    init(marks: [Mark], showsNumbers: Bool) {
        self.marks = marks
        self.showsNumbers = showsNumbers
    }

    init(_ passageMarks: PassageMarks, geometry: PageTextGeometry) {
        marks = passageMarks.located.compactMap { mark in
            let lines = mark.location.ranges.flatMap(geometry.lineRects(for:))
            guard let first = lines.first else { return nil }
            return Mark(number: mark.number, lineRects: lines,
                        bounds: lines.dropFirst().reduce(first) { $0.union($1) })
        }
        showsNumbers = passageMarks.showsNumbers
    }

    var isEmpty: Bool { marks.isEmpty }

    /// Every marked line, for `LensLegibility`.
    var lineRects: [CGRect] { marks.flatMap(\.lineRects) }

    /// All marks united, or nil when there are none.
    var bounds: CGRect? {
        guard let first = marks.first?.bounds else { return nil }
        return marks.dropFirst().reduce(first) { $0.union($1.bounds) }
    }
}
