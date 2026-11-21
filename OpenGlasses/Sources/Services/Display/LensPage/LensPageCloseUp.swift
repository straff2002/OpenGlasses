import CoreGraphics
import Foundation

/// What one pinch on the whole page opens (Plan MU §6, decision 7): a **close-up** of the
/// highlighted part at a readable zoom, or for a page with nothing highlighted, the page at **fit
/// width**. Pure geometry; `LensPageSession` draws each column as a strip of slices the lens
/// scrolls (`LensPageStrip.slices`), under the button row.
///
/// **The close-up's zoom.** The magnification at which the part's text reaches the lens's
/// readable floor (`LensLegibility.readablePixelsPerPoint`), at least twice the whole page's and
/// never under fit width, and at most the zoom cap. It is of the highlighted part, wherever the
/// lens had been scrolled: the part is known, the lens's own scroll is not.
///
/// **Halves.** A part wider than the lens at that zoom is cut into a left half and a right half,
/// stacked in one strip: the left half's column, a "Right half" marker, then the right half's
/// column, both reached by scrolling, with no **Move** and no arrows. The zoom drops (towards fit
/// width) until the two halves together hold the part's width.
///
/// **Past the part.** Each column starts at the part's top and runs on down the page at the same
/// zoom, so the band scrolls on past the part: up to `LensPageStrip.maxHeightPixels` in all (the
/// send budget), split evenly between two halves. A part taller than its column's share is drawn
/// at a lower zoom, so the whole part is always there.
///
/// **Fit width**: the page as wide as the lens, from the top (or, for "go to the bottom", ending at
/// the page's foot), as far down as the budget holds.
struct LensPageCloseUp: Equatable {

    enum Kind: String, Equatable {
        /// The highlighted part.
        case part
        /// The page as wide as the lens.
        case fitWidth = "fit_width"
    }

    enum Half: Equatable {
        case left, right
    }

    let kind: Kind
    let pageSize: CGSize
    /// Lens pixels per page point.
    let pixelsPerPoint: CGFloat
    /// The output width of every column, in lens pixels (the lens column).
    let width: CGFloat
    /// Each column on the page, top-down page points: one, or the left and the right half.
    let columns: [CGRect]
    /// The part the close-up is of; nil at fit width.
    let part: CGRect?
    /// "Left half" / "right half" by voice: only that column is drawn.
    var only: Half?

    /// The part is cut into halves.
    var hasHalves: Bool { columns.count == 2 }

    /// The columns drawn, in order, and whether each is the right half (which the marker leads).
    var shownColumns: [(rect: CGRect, isRightHalf: Bool)] {
        guard hasHalves else { return columns.map { ($0, false) } }
        switch only {
        case .left?: return [(columns[0], false)]
        case .right?: return [(columns[1], true)]
        case nil: return [(columns[0], false), (columns[1], true)]
        }
    }

    /// A column's picture size, in lens pixels: the lens column's width, and its height at this zoom.
    func outputSize(of column: CGRect) -> CGSize {
        CGSize(width: width.rounded(), height: max(1, (column.height * pixelsPerPoint).rounded()))
    }

    /// The same zoom as a viewport round the part's centre (or the top of the page at fit width),
    /// so a spoken zoom word carries on from what the lens shows.
    func viewport(box: CGSize) -> LensPageViewport {
        let first = columns.first ?? CGRect(origin: .zero, size: pageSize)
        let centre = part.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: first.midX, y: first.minY + box.height / pixelsPerPoint / 2)
        return LensPageViewport(pageSize: pageSize, box: box, center: centre, pixelsPerPoint: pixelsPerPoint)
    }

    // MARK: - Making one

    /// The close-up of `part` (the highlighted part, padded; top-down page points).
    static func of(part: CGRect, pageSize: CGSize, legibility: LensLegibility,
                   width: CGFloat = LensPageFrame.contentWidthPixels,
                   wholePagePixelsPerPoint: CGFloat,
                   maxPixelsPerPoint: CGFloat = LensLegibility.zoomCapPixelsPerPoint(),
                   budget: CGFloat = LensPageStrip.maxHeightPixels) -> LensPageCloseUp {
        let page = CGRect(origin: .zero, size: CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1)))
        let clipped = part.standardized.intersection(page)
        let region = clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? page : clipped
        let fitWidth = width / page.width
        let floor = max(2 * wholePagePixelsPerPoint, fitWidth)
        let readable = min(max(legibility.readablePixelsPerPoint, floor), max(maxPixelsPerPoint, floor))
        func fits(_ ppp: CGFloat) -> Bool { region.width * ppp <= width + 0.5 }
        // One column, the whole part in the whole budget.
        var ppp = min(readable, budget / region.height)
        var halves = !fits(ppp)
        if halves {
            // Two halves that hold the part's width, the whole part in half the budget each.
            ppp = min(readable, 2 * width / region.width, budget / 2 / region.height)
            if fits(ppp) {
                // Half the budget made it narrow enough for one column, which is better at the
                // width that fills the lens (and still within the whole budget).
                halves = false
                ppp = width / region.width
            }
        }
        ppp = max(ppp, wholePagePixelsPerPoint)

        let columnWidth = width / ppp
        let columnHeight = min((halves ? budget / 2 : budget) / ppp, page.height - region.minY)
        let top = region.minY
        func column(x: CGFloat) -> CGRect {
            CGRect(x: clampX(x, width: columnWidth, pageWidth: page.width), y: top,
                   width: columnWidth, height: max(columnHeight, 1 / ppp))
        }
        let columns = halves
            ? [column(x: region.minX), column(x: region.maxX - columnWidth)]
            : [column(x: region.midX - columnWidth / 2)]
        return LensPageCloseUp(kind: .part, pageSize: page.size, pixelsPerPoint: ppp, width: width,
                               columns: columns, part: region)
    }

    /// The page as wide as the lens, from its top, or ending at its foot (`fromBottom`).
    static func fitWidth(pageSize: CGSize, width: CGFloat = LensPageFrame.contentWidthPixels,
                         fromBottom: Bool = false,
                         budget: CGFloat = LensPageStrip.maxHeightPixels) -> LensPageCloseUp {
        let page = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        let ppp = width / page.width
        let height = min(page.height, budget / ppp)
        let top = fromBottom ? page.height - height : 0
        return LensPageCloseUp(kind: .fitWidth, pageSize: page, pixelsPerPoint: ppp, width: width,
                               columns: [CGRect(x: 0, y: top, width: page.width, height: height)], part: nil)
    }

    /// A column's left edge: inside the page when the column is narrower, centred on it otherwise.
    static func clampX(_ x: CGFloat, width: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard width < pageWidth - LensPageViewport.tolerance else { return (pageWidth - width) / 2 }
        return min(max(x, 0), pageWidth - width)
    }
}
