import CoreGraphics
import Foundation

/// How tall a page's text draws on the lens, and whether that is readable (Plan KV §1). Pure.
///
/// The estimate is the text's height in page points times the lens pixels per page point at the
/// viewport (`LensPageViewport.pixelsPerPoint`: the picture box's width over the crop's, as drawn
/// in the box `LensPageFrame` leaves the picture). The text height comes from the cited lines'
/// selection bounds when there are any, else `defaultTextHeightPoints` (a drawing's labels).
/// The floor is KP's smallest text token on the Meta Display, `HUDCanvas.metaDisplay.textSize(.meta)`
/// (22 px), which is itself an estimate until P5 measures a real lens — so `isEstimate` carries it.
///
/// **The zoom cap** (`zoomCapPixelsPerPoint`): the magnification at which 8 pt labels reach the
/// floor (22 ÷ 8 = 2.75 lens pixels per page point), and one more ×1.5 press: 4.125, where 8 pt
/// labels draw about 33 px. Deeper than that only shows less of the page.
struct LensLegibility: Equatable {

    /// A drawing's terminal labels, when no cited line says otherwise.
    static let defaultTextHeightPoints: CGFloat = 8

    /// The page's text height, in page points.
    let textHeightPoints: CGFloat
    /// The smallest text height the lens reads, in lens pixels.
    let floorPixels: CGFloat
    /// True while the floor is a guess rather than a measurement.
    let isEstimate: Bool

    init(textHeightPoints: CGFloat? = nil, canvas: HUDCanvas = .metaDisplay) {
        let floor = canvas.textSize(.meta)
        if let textHeightPoints, textHeightPoints.isFinite, textHeightPoints > 0 {
            self.textHeightPoints = textHeightPoints
        } else {
            self.textHeightPoints = Self.defaultTextHeightPoints
        }
        self.floorPixels = floor.pixels
        self.isEstimate = floor.isEstimate
    }

    /// The legibility of a page whose cited lines are `lineRects` (top-down page points): their
    /// median height, or the default when there are none.
    init(lineRects: [CGRect], canvas: HUDCanvas = .metaDisplay) {
        self.init(textHeightPoints: Self.medianHeight(lineRects), canvas: canvas)
    }

    /// The text's estimated height on the lens, in lens pixels, at `pixelsPerPoint`.
    func estimatedPixels(pixelsPerPoint: CGFloat) -> CGFloat {
        guard pixelsPerPoint.isFinite, pixelsPerPoint > 0 else { return 0 }
        return textHeightPoints * pixelsPerPoint
    }

    func estimatedPixels(at viewport: LensPageViewport) -> CGFloat {
        estimatedPixels(pixelsPerPoint: viewport.pixelsPerPoint)
    }

    /// True when the text draws under the floor at `viewport`.
    func isUnderFloor(at viewport: LensPageViewport) -> Bool {
        estimatedPixels(at: viewport) < floorPixels
    }

    /// Whether the view says "Zoom in for labels": the text is under the floor and the view can
    /// zoom in further. At the cap the hint would ask for something the view cannot do.
    func needsZoomHint(at viewport: LensPageViewport) -> Bool {
        isUnderFloor(at: viewport) && viewport.canZoomIn
    }

    /// The lens pixels per page point at which this text reaches the floor.
    var readablePixelsPerPoint: CGFloat { floorPixels / textHeightPoints }

    /// The deepest the view zooms (see the type's note): 8 pt labels at the floor, and one more
    /// ×1.5 press. 4.125 lens pixels per page point on the Meta Display.
    static func zoomCapPixelsPerPoint(canvas: HUDCanvas = .metaDisplay) -> CGFloat {
        LensLegibility(canvas: canvas).readablePixelsPerPoint * LensPageViewport.zoomStep
    }

    static func medianHeight(_ rects: [CGRect]) -> CGFloat? {
        let heights = rects.map(\.height).filter { $0.isFinite && $0 > 0 }.sorted()
        guard !heights.isEmpty else { return nil }
        let middle = heights.count / 2
        return heights.count.isMultiple(of: 2) ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
    }
}
