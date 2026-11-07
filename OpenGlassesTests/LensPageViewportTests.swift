import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — the lens page viewport: zoom steps, half-crop moves, corners, clamping, reset.
final class LensPageViewportTests: XCTestCase {

    /// An invented portrait page, 612 × 792 points.
    private let portrait = CGSize(width: 612, height: 792)
    /// An invented very wide page, 1224 × 396 points.
    private let wide = CGSize(width: 1224, height: 396)

    private func centred(_ size: CGSize, _ zoom: LensPageViewport.Zoom) -> LensPageViewport {
        LensPageViewport(pageSize: size, center: CGPoint(x: size.width / 2, y: size.height / 2), zoom: zoom)
    }

    /// On each axis the page is longer than the crop, the crop lies inside it.
    private func assertInside(_ viewport: LensPageViewport, file: StaticString = #filePath, line: UInt = #line) {
        let crop = viewport.cropRect
        let size = viewport.pageSize
        if crop.width < size.width {
            XCTAssertGreaterThanOrEqual(crop.minX, -0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(crop.maxX, size.width + 0.001, file: file, line: line)
        } else {
            XCTAssertEqual(crop.midX, size.width / 2, accuracy: 0.001, file: file, line: line)
        }
        if crop.height < size.height {
            XCTAssertGreaterThanOrEqual(crop.minY, -0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(crop.maxY, size.height + 0.001, file: file, line: line)
        } else {
            XCTAssertEqual(crop.midY, size.height / 2, accuracy: 0.001, file: file, line: line)
        }
    }

    func testFitShowsTheWholePageCentredInASquare() {
        let viewport = LensPageViewport(wholePage: portrait)
        XCTAssertEqual(viewport.zoom, .fit)
        XCTAssertTrue(viewport.isWholePage)
        XCTAssertEqual(viewport.cropRect, CGRect(x: -90, y: 0, width: 792, height: 792))
        XCTAssertTrue(viewport.cropRect.contains(CGRect(origin: .zero, size: portrait)))
    }

    func testEachStepDividesThePagesLongerSide() {
        for zoom in LensPageViewport.Zoom.allCases {
            XCTAssertEqual(centred(portrait, zoom).cropSide, 792 / CGFloat(zoom.rawValue), accuracy: 0.001)
        }
    }

    func testNoMoveChangesTheWholePage() {
        for step in LensPageViewport.Step.allCases {
            var viewport = LensPageViewport(wholePage: portrait)
            XCTAssertFalse(viewport.canMove(step))
            viewport.move(step)
            XCTAssertEqual(viewport, LensPageViewport(wholePage: portrait))
        }
    }

    /// Every move clamps at every edge and at every zoom step.
    func testEveryMoveClampsAtEveryEdgeAndZoom() {
        for size in [portrait, wide] {
            for zoom in LensPageViewport.Zoom.allCases {
                for step in LensPageViewport.Step.allCases {
                    var viewport = centred(size, zoom)
                    for _ in 0..<20 {
                        viewport.move(step)
                        assertInside(viewport)
                    }
                    XCTAssertFalse(viewport.canMove(step), "\(size) \(zoom) \(step)")
                    let atEdge = viewport
                    viewport.move(step)
                    XCTAssertEqual(viewport, atEdge, "a move past the edge changes nothing")
                }
            }
        }
    }

    func testAMoveIsHalfACrop() {
        var viewport = centred(portrait, .x4)
        let start = viewport.center
        viewport.move(.right)
        XCTAssertEqual(viewport.center.x - start.x, 99, accuracy: 0.001)
        viewport.move(.down)
        XCTAssertEqual(viewport.center.y - start.y, 99, accuracy: 0.001)
        viewport.move(.up)
        viewport.move(.up)
        XCTAssertEqual(start.y - viewport.center.y, 99, accuracy: 0.001)
    }

    func testAMoveStopsAtTheEdgeRatherThanOvershooting() {
        var viewport = LensPageViewport(pageSize: portrait, center: CGPoint(x: 560, y: 400), zoom: .x2)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        viewport.move(.left)
        XCTAssertEqual(viewport.center.x, 612 - 198 - 198, accuracy: 0.001)
        viewport.move(.left)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
    }

    /// On a page shorter than the crop, the crop is centred on that axis and moves along it do nothing.
    func testAWidePageIsCentredVerticallyAtX2() {
        var viewport = centred(wide, .x2)
        XCTAssertEqual(viewport.cropSide, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.midY, 198, accuracy: 0.001)
        XCTAssertFalse(viewport.canMove(.up))
        XCTAssertFalse(viewport.canMove(.down))
        XCTAssertTrue(viewport.canMove(.right))
        viewport.move(.right)
        XCTAssertEqual(viewport.cropRect.maxX, 1224, accuracy: 0.001)
    }

    func testZoomKeepsTheCentreAndStopsAtEitherEnd() {
        var viewport = LensPageViewport(pageSize: portrait, center: CGPoint(x: 300, y: 400), zoom: .x2)
        viewport.zoomIn()
        XCTAssertEqual(viewport.zoom, .x3)
        XCTAssertEqual(viewport.center, CGPoint(x: 300, y: 400))
        viewport.zoomIn()
        XCTAssertEqual(viewport.zoom, .x4)
        XCTAssertFalse(viewport.canZoomIn)
        viewport.zoomIn()
        XCTAssertEqual(viewport.zoom, .x4)

        var whole = LensPageViewport(wholePage: portrait)
        XCTAssertFalse(whole.canZoomOut)
        whole.zoomOut()
        XCTAssertEqual(whole.zoom, .fit)
        XCTAssertTrue(whole.canZoomIn)
    }

    func testZoomingOutNearAnEdgeReclamps() {
        var viewport = centred(portrait, .x4)
        viewport.jump(to: .bottomRight)
        viewport.zoomOut()
        XCTAssertEqual(viewport.zoom, .x3)
        assertInside(viewport)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        viewport.showWholePage()
        XCTAssertEqual(viewport.center, CGPoint(x: 306, y: 396))
    }

    func testCornersPushTheCropIntoEachCorner() {
        var viewport = centred(portrait, .x3)
        viewport.jump(to: .topLeft)
        XCTAssertEqual(viewport.cropRect.origin, .zero)
        viewport.jump(to: .topRight)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.minY, 0, accuracy: 0.001)
        viewport.jump(to: .bottomLeft)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        viewport.jump(to: .bottomRight)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        XCTAssertEqual(viewport.zoom, .x3, "a corner keeps a zoomed step")
    }

    func testACornerFromTheWholePageZoomsToX2First() {
        var viewport = LensPageViewport(wholePage: portrait)
        viewport.jump(to: .topLeft)
        XCTAssertEqual(viewport.zoom, .x2)
        XCTAssertEqual(viewport.cropRect.origin, .zero)
    }

    func testResetGoesBackToTheOpeningView() {
        var viewport = LensPageViewport(pageSize: portrait, center: CGPoint(x: 200, y: 300), zoom: .x3)
        XCTAssertTrue(viewport.isAtOpening)
        XCTAssertTrue(viewport.opensOnPart)
        viewport.move(.down)
        viewport.zoomOut()
        XCTAssertFalse(viewport.isAtOpening)
        viewport.reset()
        XCTAssertTrue(viewport.isAtOpening)
        XCTAssertEqual(viewport.zoom, .x3)
        XCTAssertEqual(viewport.center, CGPoint(x: 200, y: 300))
    }

    func testTheOpeningCentreIsClamped() {
        let viewport = LensPageViewport(pageSize: portrait, center: CGPoint(x: -50, y: 2_000), zoom: .x2)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        XCTAssertEqual(viewport.openingCenter, viewport.center)
    }
}
