import CoreGraphics
import Foundation

/// Where the page view opens (Plan KV §1, decision 2): the part of the page the answer is about,
/// padded, made square, at the deepest zoom step at which it still fits whole. Pure.
///
/// The sources, in order — the first with any usable rectangle on the page wins:
/// 1. the cited passages' rectangles, united (IN's marks, through `LensPageMarks`);
/// 2. the pictured table's outlined areas, united (JN's `pictureAreas`);
/// 3. the drawing on the page (Plan KV P1b: found by `PageFigureLocator`, chosen by
///    `PageFigureChoice`);
/// 4. none: the whole page, fitted.
///
/// When the request asked for a drawing (`PageFigureAsk.asksForDrawing`, passed as `figureFirst`)
/// the drawing moves to the top, ahead of any cited passage: "show me the wiring diagram" opens on
/// the diagram even when the answer cited a line beside it.
///
/// All rectangles are in top-down page points (see `LensPageViewport`). A rectangle is clipped to
/// the page first; one empty after clipping is not counted, so a source whose rectangles all lie
/// off the page falls through to the next.
struct LensPageFocus: Equatable {

    enum Source: Equatable {
        case citedPassages
        case pictureArea
        case figure
        case wholePage
    }

    /// Padding round the focus on every side: this share of the focus's longer side, but never
    /// less than `minimumMarginPoints`, so a one-line passage keeps some of the lines round it.
    static let marginFraction: CGFloat = 0.08
    static let minimumMarginPoints: CGFloat = 10

    let pageSize: CGSize
    let source: Source
    /// The united focus, before padding; nil for the whole page.
    let region: CGRect?
    /// The padded square the opening crop has to hold; nil for the whole page.
    let square: CGRect?
    /// The step the view opens at.
    let zoom: LensPageViewport.Zoom
    /// The opening crop's centre (the viewport clamps it).
    let center: CGPoint

    var hasFocus: Bool { region != nil }

    /// The focus for one page, from what is known about it.
    static func pick(pageSize: CGSize,
                     passageRects: [CGRect] = [],
                     pictureAreas: [CGRect] = [],
                     figure: CGRect? = nil,
                     figureFirst: Bool = false) -> LensPageFocus {
        let page = CGRect(origin: .zero, size: pageSize)
        var candidates: [(Source, [CGRect])] = [
            (.citedPassages, passageRects),
            (.pictureArea, pictureAreas),
            (.figure, figure.map { [$0] } ?? []),
        ]
        if figureFirst { candidates.insert(candidates.removeLast(), at: 0) }
        for (source, rects) in candidates {
            if let region = united(rects, inside: page) {
                return focus(on: region, source: source, pageSize: pageSize)
            }
        }
        return LensPageFocus(pageSize: pageSize, source: .wholePage, region: nil, square: nil, zoom: .fit,
                             center: CGPoint(x: pageSize.width / 2, y: pageSize.height / 2))
    }

    /// The focus from the page's lens marks and the staged table's picture areas for `physical`
    /// (1-based) page. `ManualTable.PictureArea` is already in top-down page points from the media
    /// box's top left, the same space as the viewport, so its `rect` is used as it is.
    static func pick(pageSize: CGSize,
                     marks: LensPageMarks?,
                     pictureAreas: [ManualTable.PictureArea],
                     physical: Int,
                     figure: CGRect? = nil,
                     figureFirst: Bool = false) -> LensPageFocus {
        pick(pageSize: pageSize,
             passageRects: marks?.marks.map(\.bounds) ?? [],
             pictureAreas: pictureAreas.filter { $0.physical == physical }.map(\.rect),
             figure: figure, figureFirst: figureFirst)
    }

    // MARK: Geometry

    private static func united(_ rects: [CGRect], inside page: CGRect) -> CGRect? {
        rects.lazy
            .map { $0.standardized.intersection(page) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .reduce(nil as CGRect?) { united, next in united.map { $0.union(next) } ?? next }
    }

    private static func focus(on region: CGRect, source: Source, pageSize: CGSize) -> LensPageFocus {
        let margin = max(minimumMarginPoints, max(region.width, region.height) * marginFraction)
        let padded = region.insetBy(dx: -margin, dy: -margin)
        let side = max(padded.width, padded.height)
        let square = CGRect(x: padded.midX - side / 2, y: padded.midY - side / 2, width: side, height: side)
        let zoom = LensPageViewport.Zoom.allCases.reversed().first {
            LensPageViewport.cropSide(zoom: $0, pageSize: pageSize) >= side
        } ?? .fit
        return LensPageFocus(pageSize: pageSize, source: source, region: region, square: square, zoom: zoom,
                             center: CGPoint(x: square.midX, y: square.midY))
    }
}
