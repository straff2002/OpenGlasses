import CoreGraphics
import Foundation

/// How tall a page's text draws on the lens, and whether that is readable (Plan KV §1). Pure.
///
/// The estimate is the text's height in page points times the lens pixels per page point at the
/// crop: `textHeightPoints × (pictureSidePixels ÷ cropSide)`. The text height comes from the cited
/// lines' selection bounds when there are any, else `defaultTextHeightPoints` (a drawing's labels).
/// The floor is KP's smallest text token on the Meta Display, `HUDCanvas.metaDisplay.textSize(.meta)`
/// (22 px), which is itself an estimate until P4 measures a real lens — so `isEstimate` carries it.
struct LensLegibility: Equatable {

    /// A drawing's terminal labels, when no cited line says otherwise.
    static let defaultTextHeightPoints: CGFloat = 8

    /// The page's text height, in page points.
    let textHeightPoints: CGFloat
    /// How many lens pixels the picture is across. The picture fills the canvas width (§1); the
    /// button row below it is not counted against it.
    let pictureSidePixels: CGFloat
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
        self.pictureSidePixels = CGFloat(min(canvas.widthPixels, canvas.heightPixels))
        self.floorPixels = floor.pixels
        self.isEstimate = floor.isEstimate
    }

    /// The legibility of a page whose cited lines are `lineRects` (top-down page points): their
    /// median height, or the default when there are none.
    init(lineRects: [CGRect], canvas: HUDCanvas = .metaDisplay) {
        self.init(textHeightPoints: Self.medianHeight(lineRects), canvas: canvas)
    }

    /// The text's estimated height on the lens, in lens pixels, for a crop `cropSide` points across.
    func estimatedPixels(cropSide: CGFloat) -> CGFloat {
        guard cropSide > 0 else { return 0 }
        return textHeightPoints * pictureSidePixels / cropSide
    }

    func estimatedPixels(at viewport: LensPageViewport) -> CGFloat {
        estimatedPixels(cropSide: viewport.cropSide)
    }

    /// True when the text draws under the floor at `viewport`.
    func isUnderFloor(at viewport: LensPageViewport) -> Bool {
        estimatedPixels(at: viewport) < floorPixels
    }

    /// Whether the view says "Zoom in for labels": the text is under the floor and a deeper step
    /// exists. At the deepest step the hint would ask for something the view cannot do.
    func needsZoomHint(at viewport: LensPageViewport) -> Bool {
        isUnderFloor(at: viewport) && viewport.canZoomIn
    }

    /// The widest step at which the text reaches the floor on a page of `pageSize`, or nil when even
    /// the deepest step leaves it under.
    func readableZoom(pageSize: CGSize) -> LensPageViewport.Zoom? {
        LensPageViewport.Zoom.allCases.first {
            estimatedPixels(cropSide: LensPageViewport.cropSide(zoom: $0, pageSize: pageSize)) >= floorPixels
        }
    }

    static func medianHeight(_ rects: [CGRect]) -> CGFloat? {
        let heights = rects.map(\.height).filter { $0.isFinite && $0 > 0 }.sorted()
        guard !heights.isEmpty else { return nil }
        let middle = heights.count / 2
        return heights.count.isMultiple(of: 2) ? (heights[middle - 1] + heights[middle]) / 2 : heights[middle]
    }
}
