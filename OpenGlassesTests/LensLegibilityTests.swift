import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — how tall a page's text draws on the lens, the floor, and the hint.
final class LensLegibilityTests: XCTestCase {

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)

    private func view(_ zoom: LensPageViewport.Zoom) -> LensPageViewport {
        LensPageViewport(pageSize: page, center: CGPoint(x: 306, y: 396), zoom: zoom)
    }

    func testTheFloorIsKPsMetaTokenAndAnEstimate() {
        let legibility = LensLegibility()
        XCTAssertEqual(legibility.floorPixels, HUDCanvas.metaDisplay.textSize(.meta).pixels)
        XCTAssertEqual(legibility.floorPixels, 22)
        XCTAssertTrue(legibility.isEstimate)
        // P4: the square picture as drawn under the frame's lines and above its button row, not the
        // 600 px canvas (`LensPageFrame`).
        XCTAssertEqual(legibility.pictureSidePixels, LensPageFrame.pictureSidePixels)
        XCTAssertEqual(legibility.pictureSidePixels, 382)
        XCTAssertEqual(LensLegibility(canvas: .evenG2).pictureSidePixels, 288, "a canvas with no page view keeps its side")
    }

    func testWithNoCitedLinesTheTextIsTakenAsEightPoints() {
        XCTAssertEqual(LensLegibility().textHeightPoints, 8)
        XCTAssertEqual(LensLegibility(lineRects: []).textHeightPoints, 8)
        XCTAssertEqual(LensLegibility(textHeightPoints: 0).textHeightPoints, 8)
    }

    /// 8 pt labels draw about 4 px on a fitted letter page, and three times that at ×3.
    func testTheEstimateIsTextHeightTimesLensPixelsPerPoint() {
        let legibility = LensLegibility()
        XCTAssertEqual(legibility.estimatedPixels(at: view(.fit)), 8 * 382 / 792, accuracy: 0.001)
        XCTAssertEqual(legibility.estimatedPixels(at: view(.x3)), 8 * 382 / 264, accuracy: 0.001)
        XCTAssertEqual(legibility.estimatedPixels(at: view(.x3)) / legibility.estimatedPixels(at: view(.fit)),
                       3, accuracy: 0.001)
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

    /// The hint shows exactly when the estimate is under the floor and a deeper step exists.
    func testTheHintShowsExactlyWhenUnderTheFloor() {
        for height in [CGFloat(4), 6, 8, 10, 12, 16, 30] {
            let legibility = LensLegibility(textHeightPoints: height)
            for zoom in LensPageViewport.Zoom.allCases {
                let viewport = view(zoom)
                let under = legibility.estimatedPixels(at: viewport) < 22
                XCTAssertEqual(legibility.isUnderFloor(at: viewport), under)
                XCTAssertEqual(legibility.needsZoomHint(at: viewport), under && zoom != .x4, "\(height) pt at \(zoom)")
            }
        }
    }

    func testNoHintAtTheDeepestStepEvenWhenUnreadable() {
        let tiny = LensLegibility(textHeightPoints: 2)
        XCTAssertTrue(tiny.isUnderFloor(at: view(.x4)))
        XCTAssertFalse(tiny.needsZoomHint(at: view(.x4)))
    }

    /// With the 382 px picture (P4), 8 pt labels stay under the estimated floor even at ×4 (about
    /// 15 px); P5 measures both the floor and the picture on the glasses.
    func testTheReadableStepIsTheWidestThatReachesTheFloor() {
        XCTAssertNil(LensLegibility().readableZoom(pageSize: page))
        XCTAssertEqual(LensLegibility(textHeightPoints: 12).readableZoom(pageSize: page), .x4)
        XCTAssertEqual(LensLegibility(textHeightPoints: 30).readableZoom(pageSize: page), .x2)
        XCTAssertEqual(LensLegibility(textHeightPoints: 46).readableZoom(pageSize: page), .fit)
        XCTAssertNil(LensLegibility(textHeightPoints: 2).readableZoom(pageSize: page))
    }
}
