import CoreGraphics
import Foundation

// Plan KV §1 / P0 — the part of a manual page the lens shows.
//
// Pure and SDK-free. Every rectangle in the lens-page core is in **top-down page points**: measured
// from the page's media box top left, y downwards — the space `PictureRegion` and
// `ManualTable.PictureArea` already use, and the space a rendered page image has. PDFKit's own
// page space (origin bottom left, y upwards) is converted once, in `PDFKitPageTextGeometry`.

/// What the lens shows of one page: a square crop, at a zoom step, around a centre.
///
/// The crop is always square, because the Meta Display's canvas is. At `.fit` its side is the
/// page's longer side, so the whole page is in it; each step in divides that side.
///
/// **Clamping.** On each axis separately: where the crop is shorter than the page, it lies wholly
/// inside the page (the centre is held at least half a crop from either edge). Where it is longer
/// — the short side of a non-square page at `.fit`, or of a very long page at `.x2` — it is
/// centred on the page, so the page shows whole on that axis with equal black margins either
/// side, and a move along that axis does nothing. That is the best a square can cover a page it
/// is larger than. The renderer (P1) draws the part outside the page as black, which an additive
/// lens shows as clear.
///
/// The centre is clamped on every change, so two viewports that show the same crop are equal, and
/// a move against an edge leaves the viewport exactly as it was.
struct LensPageViewport: Equatable {

    /// Zoom steps relative to the whole page fitted into the square lens (decision 3).
    enum Zoom: Int, CaseIterable, Comparable {
        case fit = 1
        case x2 = 2
        case x3 = 3
        case x4 = 4

        /// How many times the whole-page fit this step magnifies.
        var factor: CGFloat { CGFloat(rawValue) }

        /// The next step in, or nil at the deepest.
        var deeper: Zoom? { Zoom(rawValue: rawValue + 1) }
        /// The next step out, or nil at `.fit`.
        var shallower: Zoom? { Zoom(rawValue: rawValue - 1) }

        static let deepest: Zoom = .x4

        static func < (lhs: Zoom, rhs: Zoom) -> Bool { lhs.rawValue < rhs.rawValue }
    }

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
    /// The crop's centre, in top-down page points. Always clamped (see the type's note).
    private(set) var center: CGPoint
    private(set) var zoom: Zoom

    /// Where the view opened, so `reset()` can go back to it.
    let openingCenter: CGPoint
    let openingZoom: Zoom

    /// A viewport opening at `zoom` around `center` (clamped).
    init(pageSize: CGSize, center: CGPoint, zoom: Zoom) {
        let size = CGSize(width: max(pageSize.width, 1), height: max(pageSize.height, 1))
        self.pageSize = size
        let clamped = Self.clamp(center, zoom: zoom, pageSize: size)
        self.center = clamped
        self.zoom = zoom
        self.openingCenter = clamped
        self.openingZoom = zoom
    }

    /// The whole page, fitted.
    init(wholePage pageSize: CGSize) {
        self.init(pageSize: pageSize, center: CGPoint(x: pageSize.width / 2, y: pageSize.height / 2), zoom: .fit)
    }

    /// A viewport opening on `focus`: its centre, at the step it chose.
    init(opening focus: LensPageFocus) {
        self.init(pageSize: focus.pageSize, center: focus.center, zoom: focus.zoom)
    }

    // MARK: What it shows

    /// The crop's side, in page points.
    var cropSide: CGFloat { Self.cropSide(zoom: zoom, pageSize: pageSize) }

    /// What the lens shows, in top-down page points. Square; inside the page on each axis the
    /// page is longer than the crop, centred on it on any other.
    var cropRect: CGRect {
        let side = cropSide
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// True at `.fit`: the whole page is on the lens.
    var isWholePage: Bool { zoom == .fit }
    /// True at the deepest step.
    var isDeepest: Bool { zoom == .deepest }
    /// True when the view is where it opened.
    var isAtOpening: Bool { zoom == openingZoom && center == openingCenter }
    /// True when the view opened on a part of the page rather than the whole of it.
    var opensOnPart: Bool { openingZoom != .fit }

    var canZoomIn: Bool { zoom.deeper != nil }
    var canZoomOut: Bool { zoom.shallower != nil }

    /// Whether `step` would change the crop from here.
    func canMove(_ step: Step) -> Bool {
        var probe = self
        probe.move(step)
        return probe.center != center
    }

    // MARK: Changing it

    /// One step in, keeping the centre. Nothing at the deepest step.
    mutating func zoomIn() {
        guard let deeper = zoom.deeper else { return }
        setZoom(deeper)
    }

    /// One step out, keeping the centre. Nothing at `.fit`.
    mutating func zoomOut() {
        guard let shallower = zoom.shallower else { return }
        setZoom(shallower)
    }

    /// The whole page, fitted.
    mutating func showWholePage() { setZoom(.fit) }

    /// Half a crop in `step`'s direction, stopped at the page's edge.
    mutating func move(_ step: Step) {
        let half = cropSide / 2
        var next = center
        switch step {
        case .up: next.y -= half
        case .down: next.y += half
        case .left: next.x -= half
        case .right: next.x += half
        }
        center = Self.clamp(next, zoom: zoom, pageSize: pageSize)
    }

    /// The crop pushed into `corner`. At `.fit` the whole page is already in view and a corner
    /// would not move it, so a corner first zooms to `.x2`, the widest step at which the corners
    /// differ.
    mutating func jump(to corner: Corner) {
        if zoom == .fit { zoom = .x2 }
        let far = CGFloat.greatestFiniteMagnitude
        let target: CGPoint
        switch corner {
        case .topLeft: target = CGPoint(x: -far, y: -far)
        case .topRight: target = CGPoint(x: far, y: -far)
        case .bottomLeft: target = CGPoint(x: -far, y: far)
        case .bottomRight: target = CGPoint(x: far, y: far)
        }
        center = Self.clamp(target, zoom: zoom, pageSize: pageSize)
    }

    /// Back to the opening view.
    mutating func reset() {
        zoom = openingZoom
        center = openingCenter
    }

    private mutating func setZoom(_ next: Zoom) {
        zoom = next
        center = Self.clamp(center, zoom: next, pageSize: pageSize)
    }

    // MARK: Geometry

    static func cropSide(zoom: Zoom, pageSize: CGSize) -> CGFloat {
        max(pageSize.width, pageSize.height) / zoom.factor
    }

    static func clamp(_ point: CGPoint, zoom: Zoom, pageSize: CGSize) -> CGPoint {
        let side = cropSide(zoom: zoom, pageSize: pageSize)
        func axis(_ value: CGFloat, extent: CGFloat) -> CGFloat {
            guard side < extent else { return extent / 2 }
            let finite = value.isFinite ? value : extent / 2
            return min(max(finite, side / 2), extent - side / 2)
        }
        return CGPoint(x: axis(point.x, extent: pageSize.width), y: axis(point.y, extent: pageSize.height))
    }
}
