import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — the lens page viewport: the crop in the picture box's shape, the zoom ladder and its
/// cap, half-crop moves, corners, clamping, reset.
final class LensPageViewportTests: XCTestCase {

    /// An invented portrait page, 612 × 792 points.
    private let portrait = CGSize(width: 612, height: 792)
    /// An invented very wide page, 1224 × 396 points.
    private let wide = CGSize(width: 1224, height: 396)
    /// The box of a frame with nothing over the picture: 576 × 462.
    private let box = LensPageFrame.pictureBox(metaLines: 0, bodyLines: 0)

    private func centred(_ size: CGSize, _ pixelsPerPoint: CGFloat?) -> LensPageViewport {
        LensPageViewport(pageSize: size, box: box, center: CGPoint(x: size.width / 2, y: size.height / 2),
                         pixelsPerPoint: pixelsPerPoint)
    }

    /// On each axis the page is longer than the crop, the crop lies inside it; on any other it is centred.
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

    /// Every rung from the whole page to the cap.
    private func rungs(_ size: CGSize) -> [LensPageViewport] {
        var viewport = LensPageViewport(wholePage: size, box: box)
        var all = [viewport]
        while viewport.canZoomIn {
            viewport.zoomIn()
            all.append(viewport)
        }
        return all
    }

    // MARK: The box's shape

    func testTheCropHasThePictureBoxsShape() {
        for size in [portrait, wide] {
            for viewport in rungs(size) {
                XCTAssertEqual(viewport.cropSize.width / viewport.cropSize.height, box.width / box.height,
                               accuracy: 0.0001)
                XCTAssertEqual(viewport.pixelsPerPoint, box.width / viewport.cropSize.width, accuracy: 0.0001)
            }
        }
    }

    /// A portrait page at scale 1 fills the box's height and is centred across it, with black (clear
    /// on the lens) either side.
    func testAPortraitWholePageIsCentred() {
        let viewport = LensPageViewport(wholePage: portrait, box: box)
        XCTAssertTrue(viewport.isWholePage)
        XCTAssertEqual(viewport.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(viewport.pixelsPerPoint, 462.0 / 792, accuracy: 0.0001)
        let crop = viewport.cropRect
        XCTAssertEqual(crop.height, 792, accuracy: 0.001, "the page's height fills the box")
        XCTAssertEqual(crop.midX, 306, accuracy: 0.001)
        XCTAssertEqual(-crop.minX, crop.maxX - 612, accuracy: 0.001, "equal margins either side")
        XCTAssertTrue(crop.insetBy(dx: -0.001, dy: -0.001).contains(CGRect(origin: .zero, size: portrait)))
        for step in LensPageViewport.Step.allCases {
            var moved = viewport
            XCTAssertFalse(moved.canMove(step))
            moved.move(step)
            XCTAssertEqual(moved, viewport)
        }
    }

    // MARK: The ladder and the cap

    /// The cap: 8 pt labels at the 22 px floor (2.75 px per point), and one more ×1.5 press.
    func testTheCapIsEightPointLabelsAtTheFloorAndOneMorePress() {
        let cap = LensLegibility.zoomCapPixelsPerPoint()
        XCTAssertEqual(cap, 22.0 / 8 * 1.5, accuracy: 0.0001)
        XCTAssertEqual(cap, 4.125, accuracy: 0.0001)
        XCTAssertEqual(LensPageViewport(wholePage: portrait).maxPixelsPerPoint, cap)
        XCTAssertEqual(LensLegibility().estimatedPixels(pixelsPerPoint: cap), 33, accuracy: 0.001,
                       "8 pt labels draw 33 px at the cap")
    }

    /// The ladder runs ×1.5 a press from the opening magnification, its last rung stopped at the
    /// cap; down, it runs back through the same rungs and stops at the whole page.
    func testTheLadderIsOneAndAHalfAPressFromTheOpening() {
        var viewport = centred(portrait, 1)
        XCTAssertEqual(viewport.pixelsPerPoint, 1, accuracy: 0.0001)
        var up: [CGFloat] = []
        while viewport.canZoomIn {
            viewport.zoomIn()
            up.append(viewport.pixelsPerPoint)
        }
        XCTAssertEqual(up.count, 4)
        for (value, expected) in zip(up, [1.5, 2.25, 3.375, 4.125] as [CGFloat]) {
            XCTAssertEqual(value, expected, accuracy: 0.0001)
        }
        XCTAssertTrue(viewport.isDeepest)
        viewport.zoomIn()
        XCTAssertEqual(viewport.pixelsPerPoint, 4.125, accuracy: 0.0001, "nothing past the cap")

        var down: [CGFloat] = []
        while viewport.canZoomOut {
            viewport.zoomOut()
            down.append(viewport.pixelsPerPoint)
        }
        let fit: CGFloat = 462.0 / 792
        for (value, expected) in zip(down, [3.375, 2.25, 1.5, 1, 1 / 1.5, fit] as [CGFloat]) {
            XCTAssertEqual(value, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(down.count, 6)
        XCTAssertTrue(viewport.isWholePage)
        XCTAssertFalse(viewport.canZoomOut)
    }

    /// The opening magnification is any value, not a rounded step; from the whole page the ladder
    /// is anchored at scale 1.
    func testFromTheWholePageTheLadderStartsAtScaleOne() {
        var viewport = LensPageViewport(wholePage: portrait, box: box)
        viewport.zoomIn()
        XCTAssertEqual(viewport.scale, 1.5, accuracy: 0.0001)
        viewport.zoomIn()
        XCTAssertEqual(viewport.scale, 2.25, accuracy: 0.0001)
        viewport.showWholePage()
        XCTAssertEqual(viewport.scale, 1, accuracy: 0.0001)
        XCTAssertTrue(viewport.isWholePage)
    }

    func testAnOpeningPastTheCapStopsAtIt() {
        let viewport = centred(portrait, 12)
        XCTAssertEqual(viewport.pixelsPerPoint, 4.125, accuracy: 0.0001)
        XCTAssertTrue(viewport.isDeepest)
        XCTAssertFalse(viewport.canZoomIn)
        XCTAssertTrue(viewport.opensOnPart)
    }

    // MARK: Moves

    func testNoMoveChangesTheWholePage() {
        for step in LensPageViewport.Step.allCases {
            var viewport = LensPageViewport(wholePage: portrait, box: box)
            XCTAssertFalse(viewport.canMove(step))
            viewport.move(step)
            XCTAssertEqual(viewport, LensPageViewport(wholePage: portrait, box: box))
        }
    }

    /// Every move clamps at every edge and at every rung.
    func testEveryMoveClampsAtEveryEdgeAndZoom() {
        for size in [portrait, wide] {
            for rung in rungs(size) {
                for step in LensPageViewport.Step.allCases {
                    var viewport = rung
                    for _ in 0..<30 {
                        viewport.move(step)
                        assertInside(viewport)
                    }
                    XCTAssertFalse(viewport.canMove(step), "\(size) \(rung.scale) \(step)")
                    let atEdge = viewport
                    viewport.move(step)
                    XCTAssertEqual(viewport, atEdge, "a move past the edge changes nothing")
                }
            }
        }
    }

    func testAMoveIsHalfACrop() {
        var viewport = centred(portrait, 3)
        let size = viewport.cropSize
        let start = viewport.center
        viewport.move(.right)
        XCTAssertEqual(viewport.center.x - start.x, size.width / 2, accuracy: 0.001)
        viewport.move(.down)
        XCTAssertEqual(viewport.center.y - start.y, size.height / 2, accuracy: 0.001)
        viewport.move(.up)
        viewport.move(.up)
        XCTAssertEqual(start.y - viewport.center.y, size.height / 2, accuracy: 0.001)
    }

    func testAMoveStopsAtTheEdgeRatherThanOvershooting() {
        var viewport = LensPageViewport(pageSize: portrait, box: box, center: CGPoint(x: 600, y: 400), pixelsPerPoint: 2)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        let width = viewport.cropSize.width
        viewport.move(.left)
        XCTAssertEqual(viewport.center.x, 612 - width / 2 - width / 2, accuracy: 0.001)
        viewport.move(.left)
        viewport.move(.left)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
    }

    /// On a page shorter than the crop, the crop is centred on that axis and moves along it do nothing.
    func testAWidePageIsCentredVertically() {
        var viewport = LensPageViewport(wholePage: wide, box: box)
        viewport.zoomIn()
        XCTAssertGreaterThan(viewport.cropSize.height, 396)
        XCTAssertEqual(viewport.cropRect.midY, 198, accuracy: 0.001)
        XCTAssertFalse(viewport.canMove(.up))
        XCTAssertFalse(viewport.canMove(.down))
        XCTAssertTrue(viewport.canMove(.right))
        viewport.move(.right)
        XCTAssertEqual(viewport.cropRect.maxX, 1224, accuracy: 0.001)
    }

    func testZoomKeepsTheCentreAndReclampsNearAnEdge() {
        var viewport = LensPageViewport(pageSize: portrait, box: box, center: CGPoint(x: 300, y: 400), pixelsPerPoint: 2)
        viewport.zoomIn()
        XCTAssertEqual(viewport.center, CGPoint(x: 300, y: 400))

        viewport.jump(to: .bottomRight)
        viewport.zoomOut()
        assertInside(viewport)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        viewport.showWholePage()
        XCTAssertEqual(viewport.center, CGPoint(x: 306, y: 396))
    }

    func testCornersPushTheCropIntoEachCorner() {
        var viewport = centred(portrait, 3)
        viewport.jump(to: .topLeft)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.minY, 0, accuracy: 0.001)
        viewport.jump(to: .topRight)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.minY, 0, accuracy: 0.001)
        viewport.jump(to: .bottomLeft)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        viewport.jump(to: .bottomRight)
        XCTAssertEqual(viewport.cropRect.maxX, 612, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        XCTAssertEqual(viewport.pixelsPerPoint, 3, accuracy: 0.0001, "a corner keeps the zoom")
    }

    func testACornerFromTheWholePageZoomsInOneRungFirst() {
        var viewport = LensPageViewport(wholePage: portrait, box: box)
        viewport.jump(to: .topLeft)
        XCTAssertEqual(viewport.scale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(viewport.cropRect.minY, 0, accuracy: 0.001)
    }

    func testResetGoesBackToTheOpeningView() {
        var viewport = LensPageViewport(pageSize: portrait, box: box, center: CGPoint(x: 200, y: 300), pixelsPerPoint: 2.6)
        XCTAssertTrue(viewport.isAtOpening)
        XCTAssertTrue(viewport.opensOnPart)
        viewport.move(.down)
        viewport.zoomOut()
        XCTAssertFalse(viewport.isAtOpening)
        viewport.reset()
        XCTAssertTrue(viewport.isAtOpening)
        XCTAssertEqual(viewport.pixelsPerPoint, 2.6, accuracy: 0.0001)
        XCTAssertEqual(viewport.center, CGPoint(x: 200, y: 300))
    }

    func testTheOpeningCentreIsClamped() {
        let viewport = LensPageViewport(pageSize: portrait, box: box, center: CGPoint(x: -50, y: 2_000), pixelsPerPoint: 2)
        XCTAssertEqual(viewport.cropRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.cropRect.maxY, 792, accuracy: 0.001)
        XCTAssertEqual(viewport.openingCenter, viewport.center)
    }

    // MARK: A new box

    /// When a line comes or goes, the box changes: the magnification (the text's size) stays, the
    /// whole page stays whole, and the view is still at its opening.
    func testANewBoxKeepsTheMagnification() {
        let tall = LensPageFrame.pictureBox(citation: true, hint: true)
        var zoomed = LensPageViewport(pageSize: portrait, box: tall, center: CGPoint(x: 300, y: 300), pixelsPerPoint: 2)
        zoomed.setBox(box)
        XCTAssertEqual(zoomed.pixelsPerPoint, 2, accuracy: 0.0001)
        XCTAssertEqual(zoomed.cropSize.height, 462.0 / 2, accuracy: 0.001)
        XCTAssertTrue(zoomed.isAtOpening)

        var whole = LensPageViewport(wholePage: portrait, box: tall)
        whole.setBox(box)
        XCTAssertTrue(whole.isWholePage)
        XCTAssertEqual(whole.cropRect.height, 792, accuracy: 0.001)
    }
}
