import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — how tall a page's text draws on the lens, the floor, the hint and the zoom cap.
final class LensLegibilityTests: XCTestCase {

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)
    /// The picture box with both lines over it: 576 × 382.
    private let box = LensPageFrame.pictureBox(citation: true, hint: true)

    private func view(_ pixelsPerPoint: CGFloat?) -> LensPageViewport {
        LensPageViewport(pageSize: page, box: box, center: CGPoint(x: 306, y: 396), pixelsPerPoint: pixelsPerPoint)
    }

    func testTheFloorIsKPsMetaTokenAndAnEstimate() {
        let legibility = LensLegibility()
        XCTAssertEqual(legibility.floorPixels, HUDCanvas.metaDisplay.textSize(.meta).pixels)
        XCTAssertEqual(legibility.floorPixels, 22)
        XCTAssertTrue(legibility.isEstimate)
        XCTAssertEqual(legibility.readablePixelsPerPoint, 2.75, accuracy: 0.0001, "8 pt labels at 22 px")
    }

    func testWithNoCitedLinesTheTextIsTakenAsEightPoints() {
        XCTAssertEqual(LensLegibility().textHeightPoints, 8)
        XCTAssertEqual(LensLegibility(lineRects: []).textHeightPoints, 8)
        XCTAssertEqual(LensLegibility(textHeightPoints: 0).textHeightPoints, 8)
    }

    /// The estimate is the text's height times lens pixels per page point: the picture box's width
    /// over the crop's. 8 pt labels draw under 4 px on a whole letter page in the 382 px box.
    func testTheEstimateIsTextHeightTimesLensPixelsPerPoint() {
        let legibility = LensLegibility()
        let whole = view(nil)
        XCTAssertEqual(whole.pixelsPerPoint, 382.0 / 792, accuracy: 0.0001)
        XCTAssertEqual(legibility.estimatedPixels(at: whole), 8 * 382.0 / 792, accuracy: 0.001)
        XCTAssertEqual(legibility.estimatedPixels(at: view(3)), 24, accuracy: 0.001)
        XCTAssertEqual(legibility.estimatedPixels(at: view(3)),
                       8 * box.width / view(3).cropRect.width, accuracy: 0.001)
    }

    func testTheTextHeightIsTheMedianCitedLine() {
        let lines = [
            CGRect(x: 0, y: 0, width: 100, height: 9),
            CGRect(x: 0, y: 12, width: 100, height: 11),
            CGRect(x: 0, y: 24, width: 100, height: 40),
        ]
        XCTAssertEqual(LensLegibility(lineRects: lines).textHeightPoints, 11)
        XCTAssertEqual(LensLegibility.medianHeight(Array(lines.prefix(2))), 10)
    }

    /// The hint shows exactly when the estimate is under the floor and the view can zoom in further.
    func testTheHintShowsExactlyWhenUnderTheFloor() {
        for height in [CGFloat(4), 6, 8, 10, 12, 16, 30] {
            let legibility = LensLegibility(textHeightPoints: height)
            for pixelsPerPoint in [nil, 1, 1.5, 2.25, 3.375, 4.125] as [CGFloat?] {
                let viewport = view(pixelsPerPoint)
                let under = legibility.estimatedPixels(at: viewport) < 22
                XCTAssertEqual(legibility.isUnderFloor(at: viewport), under)
                XCTAssertEqual(legibility.needsZoomHint(at: viewport), under && !viewport.isDeepest,
                               "\(height) pt at \(String(describing: pixelsPerPoint))")
            }
        }
    }

    /// At the cap 8 pt labels draw 33 px, over the floor; a smaller text left under it gets no hint
    /// asking for a zoom the view can't do.
    func testNoHintAtTheCapEvenWhenUnreadable() {
        let deepest = view(LensLegibility.zoomCapPixelsPerPoint())
        XCTAssertTrue(deepest.isDeepest)
        XCTAssertFalse(LensLegibility().isUnderFloor(at: deepest))
        let tiny = LensLegibility(textHeightPoints: 2)
        XCTAssertTrue(tiny.isUnderFloor(at: deepest))
        XCTAssertFalse(tiny.needsZoomHint(at: deepest))
    }
}
