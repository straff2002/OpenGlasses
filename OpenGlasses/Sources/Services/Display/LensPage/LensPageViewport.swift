import CoreGraphics
import Foundation

// Plan KV §1 / P0 — the part of a manual page the lens shows.
//
// Pure and SDK-free. Every rectangle in the lens-page core is in **top-down page points**: measured
// from the page's media box top left, y downwards — the space `PictureRegion` and
// `ManualTable.PictureArea` already use, and the space a rendered page image has. PDFKit's own
// page space (origin bottom left, y upwards) is converted once, in `PDFKitPageTextGeometry`.

/// What the lens shows of one page: a crop the shape of the picture box, at a magnification,
/// around a centre.
///
/// **The box.** The picture is drawn into the box the frame leaves it (`LensPageFrame.pictureBox`:
/// 576 px wide, 382–462 px tall by the lines over it), one lens pixel per image pixel, so the crop
/// has the box's shape. The box changes when a line comes or goes (the citation on the first frame,
/// the hint); `setBox(_:)` keeps the magnification, so text stays the size it was and only the
/// crop's height changes.
///
/// **Zoom** is `pixelsPerPoint`, lens pixels per page point; `scale` is that relative to the whole
/// page fitted into the box (scale 1). The view opens at the magnification that fits the padded
/// focus exactly (`init(opening:box:)`). **Zoom in** and **Zoom out** move along a ladder of ×1.5
/// per press anchored at the opening magnification, stopped at scale 1 below and at
/// `maxPixelsPerPoint` above (`LensLegibility.zoomCapPixelsPerPoint`: 8 pt labels at the readable
/// floor, and one more press). **Whole page** is scale 1.
///
/// **Clamping.** On each axis separately: where the crop is shorter than the page, it lies wholly
/// inside the page. Where it is longer — a portrait page's width in a wide box at scale 1 — it is
/// centred on the page, so the page shows whole on that axis with equal black margins either side,
/// and a move along that axis does nothing. The renderer draws the part outside the page as black,
/// which an additive lens shows as clear.
///
/// The requested centre is clamped whenever it is set, so a move against an edge leaves the
/// viewport exactly as it was; the centre shown (`center`) is clamped again for the current box.
struct LensPageViewport: Equatable {

    /// Each press of **Zoom in** magnifies this much; **Zoom out** undoes it.
    static let zoomStep: CGFloat = 1.5

    /// A move by half a crop. Up is towards the page's top.
    enum Step: Equatable, CaseIterable {
        case up, down, left, right
    }

    /// A corner of the page.
    enum Corner: Equatable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The page, in PDF points.
    let pageSize: CGSize
    /// The picture box the crop is drawn into, in lens pixels.
    private(set) var box: CGSize
    /// Lens pixels per page point; nil while the whole page is fitted (scale 1), whatever the box.
    private(set) var magnification: CGFloat?
    /// The requested centre, in top-down page points, clamped when it was set.
    private var target: CGPoint

    /// Where the view opened, so `reset()` can go back to it.
    let openingMagnification: CGFloat?
    let openingCenter: CGPoint
    /// The deepest magnification (see the type's note).
    let maxPixelsPerPoint: CGFloat

    /// The box of a frame with nothing over the picture: where a viewport made without one draws.
    static var plainBox: CGSize { LensPageFrame.pictureBox(metaLines: 0, bodyLines: 0) }

    /// A viewport at `pixelsPerPoint` (nil: the whole page) around `center`.
    init(pageSize: CGSize, box: CGSize = LensPageViewport.plainBox, center: CGPoint, pixelsPerPoint: CGFloat?,
         maxPixelsPerPoint: CGFloat = LensLegibility.zoomCapPixelsPerPoint()) {
        let size = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        let box = CGSize(width: max(box.width, 1), height: max(box.height, 1))
        self.pageSize = size
        self.box = box
        self.maxPixelsPerPoint = maxPixelsPerPoint
        let fit = Self.fitPixelsPerPoint(pageSize: size, box: box)
        let opening = Self.normalized(pixelsPerPoint, fit: fit, max: maxPixelsPerPoint)
        self.magnification = opening
        let clamped = Self.clamp(center, crop: Self.cropSize(box: box, pixelsPerPoint: opening ?? fit), pageSize: size)
        self.target = clamped
        self.openingMagnification = opening
        self.openingCenter = clamped
    }

    /// The whole page, fitted into `box`.
    init(wholePage pageSize: CGSize, box: CGSize = LensPageViewport.plainBox) {
        self.init(pageSize: pageSize, box: box, center: CGPoint(x: pageSize.width / 2, y: pageSize.height / 2),
                  pixelsPerPoint: nil)
    }

    /// A viewport opening on `focus` in `box`: its padded rectangle fitted exactly (as large as the
    /// box holds it whole), up to the cap; the whole page when the focus is the whole page or as
    /// large as it.
    init(opening focus: LensPageFocus, box: CGSize = LensPageViewport.plainBox) {
        let magnification = focus.padded.map { padded -> CGFloat in
            min(max(box.width, 1) / max(padded.width, 1), max(box.height, 1) / max(padded.height, 1))
        }
        self.init(pageSize: focus.pageSize, box: box, center: focus.center, pixelsPerPoint: magnification)
    }

    // MARK: What it shows

    /// The whole page's magnification in this box.
    var fitPixelsPerPoint: CGFloat { Self.fitPixelsPerPoint(pageSize: pageSize, box: box) }

    /// Lens pixels per page point, as drawn.
    var pixelsPerPoint: CGFloat { magnification.map { max($0, fitPixelsPerPoint) } ?? fitPixelsPerPoint }

    /// The magnification relative to the whole page fitted: 1 for the whole page.
    var scale: CGFloat { pixelsPerPoint / fitPixelsPerPoint }

    /// The crop's size, in page points: the box's shape.
    var cropSize: CGSize { Self.cropSize(box: box, pixelsPerPoint: pixelsPerPoint) }

    /// The crop's centre, clamped for the current box.
    var center: CGPoint { Self.clamp(target, crop: cropSize, pageSize: pageSize) }

    /// What the lens shows, in top-down page points: the box's shape, inside the page on each axis
    /// the page is longer than the crop, centred on it on any other.
    var cropRect: CGRect {
        let size = cropSize
        let middle = center
        return CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// True at scale 1: the whole page is on the lens.
    var isWholePage: Bool { pixelsPerPoint <= fitPixelsPerPoint * (1 + Self.tolerance) }
    /// True at the cap.
    var isDeepest: Bool { pixelsPerPoint >= maxPixelsPerPoint * (1 - Self.tolerance) }
    /// The magnification the view opened at, in the current box.
    var openingPixelsPerPoint: CGFloat { openingMagnification.map { max($0, fitPixelsPerPoint) } ?? fitPixelsPerPoint }
    /// True when the view is where it opened.
    var isAtOpening: Bool {
        abs(pixelsPerPoint - openingPixelsPerPoint) <= openingPixelsPerPoint * Self.tolerance
            && Self.near(center, Self.clamp(openingCenter, crop: cropSize, pageSize: pageSize))
    }
    /// True when the view opened on a part of the page rather than the whole of it.
    var opensOnPart: Bool { openingMagnification != nil }

    var canZoomIn: Bool { !isDeepest }
    var canZoomOut: Bool { !isWholePage }

    /// Whether `step` would change the crop from here.
    func canMove(_ step: Step) -> Bool {
        var probe = self
        probe.move(step)
        return !Self.near(probe.center, center)
    }

    // MARK: Changing it

    /// One rung in on the ladder, keeping the centre; the last press stops at the cap. Nothing at
    /// the cap.
    mutating func zoomIn() {
        guard canZoomIn else { return }
        let next = ladder(from: pixelsPerPoint, upwards: true)
        magnification = Self.normalized(min(next, maxPixelsPerPoint), fit: fitPixelsPerPoint, max: maxPixelsPerPoint)
        reclampTarget()
    }

    /// One rung out, keeping the centre; the last press stops at the whole page. Nothing there.
    mutating func zoomOut() {
        guard canZoomOut else { return }
        let next = ladder(from: pixelsPerPoint, upwards: false)
        magnification = Self.normalized(next, fit: fitPixelsPerPoint, max: maxPixelsPerPoint)
        reclampTarget()
    }

    /// The whole page, fitted.
    mutating func showWholePage() {
        magnification = nil
        reclampTarget()
    }

    /// Half a crop in `step`'s direction, stopped at the page's edge. Against the edge, nothing.
    mutating func move(_ step: Step) {
        let size = cropSize
        let start = center
        var next = start
        switch step {
        case .up: next.y -= size.height / 2
        case .down: next.y += size.height / 2
        case .left: next.x -= size.width / 2
        case .right: next.x += size.width / 2
        }
        let clamped = Self.clamp(next, crop: size, pageSize: pageSize)
        guard !Self.near(clamped, start) else { return }
        target = clamped
    }

    /// The crop pushed into `corner`. At the whole page a corner would not move it, so a corner
    /// first zooms in one rung.
    mutating func jump(to corner: Corner) {
        if isWholePage { zoomIn() }
        let far = CGFloat.greatestFiniteMagnitude
        let point: CGPoint
        switch corner {
        case .topLeft: point = CGPoint(x: -far, y: -far)
        case .topRight: point = CGPoint(x: far, y: -far)
        case .bottomLeft: point = CGPoint(x: -far, y: far)
        case .bottomRight: point = CGPoint(x: far, y: far)
        }
        target = Self.clamp(point, crop: cropSize, pageSize: pageSize)
    }

    /// Back to the opening view.
    mutating func reset() {
        magnification = openingMagnification
        target = openingCenter
    }

    /// Draw into `box` from now on, keeping the magnification (the whole page stays whole).
    mutating func setBox(_ box: CGSize) {
        self.box = CGSize(width: max(box.width, 1), height: max(box.height, 1))
        magnification = Self.normalized(magnification, fit: fitPixelsPerPoint, max: maxPixelsPerPoint)
    }

    /// The viewport drawn into `box`.
    func withBox(_ box: CGSize) -> LensPageViewport {
        var copy = self
        copy.setBox(box)
        return copy
    }

    private mutating func reclampTarget() {
        target = Self.clamp(target, crop: cropSize, pageSize: pageSize)
    }

    /// The ladder's next rung from `value`: the opening magnification × 1.5ⁿ, for the next n up or
    /// down.
    private func ladder(from value: CGFloat, upwards: Bool) -> CGFloat {
        let base = openingPixelsPerPoint
        guard base > 0, value > 0 else { return value }
        let rung = log(Double(value / base)) / log(Double(Self.zoomStep))
        let next = upwards ? (rung + 1e-6).rounded(.down) + 1 : (rung - 1e-6).rounded(.up) - 1
        return base * CGFloat(pow(Double(Self.zoomStep), next))
    }

    // MARK: Geometry

    static let tolerance: CGFloat = 1e-6

    static func fitPixelsPerPoint(pageSize: CGSize, box: CGSize) -> CGFloat {
        min(box.width / max(pageSize.width, 1), box.height / max(pageSize.height, 1))
    }

    static func cropSize(box: CGSize, pixelsPerPoint: CGFloat) -> CGSize {
        guard pixelsPerPoint > 0 else { return box }
        return CGSize(width: box.width / pixelsPerPoint, height: box.height / pixelsPerPoint)
    }

    /// A magnification as stored: nil (the whole page) at or under the fit, else at most `max`
    /// (and never under the fit).
    private static func normalized(_ value: CGFloat?, fit: CGFloat, max cap: CGFloat) -> CGFloat? {
        guard let value, value.isFinite, value > fit * (1 + tolerance) else { return nil }
        let capped = Swift.min(value, Swift.max(cap, fit))
        return capped > fit * (1 + tolerance) ? capped : nil
    }

    static func clamp(_ point: CGPoint, crop: CGSize, pageSize: CGSize) -> CGPoint {
        func axis(_ value: CGFloat, side: CGFloat, extent: CGFloat) -> CGFloat {
            guard side < extent - tolerance else { return extent / 2 }
            let finite = value.isFinite ? value : extent / 2
            return min(max(finite, side / 2), extent - side / 2)
        }
        return CGPoint(x: axis(point.x, side: crop.width, extent: pageSize.width),
                       y: axis(point.y, side: crop.height, extent: pageSize.height))
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
    }
}
