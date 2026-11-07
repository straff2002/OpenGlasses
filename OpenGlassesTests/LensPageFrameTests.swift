import CoreGraphics
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan KV P4 — the page view's frame fits the lens. On the simulated Display a frame whose picture
/// was the full canvas width scrolled: the citation and the hint went off the top. The picture now
/// takes what the lines and the button row leave.
final class LensPageFrameTests: XCTestCase {

    func testTheFrameAddsUpToTheLensColumn() {
        let size = LensPageFrame.pictureSize
        XCTAssertEqual(size.width, 576, "the canvas less the backend's padding")
        XCTAssertEqual(size.height, 382)
        let column = 2 * LensPageFrame.paddingPixels + LensPageFrame.metaLinePixels + LensPageFrame.bodyLinePixels
            + 3 * LensPageFrame.gapPixels + size.height + LensPageFrame.buttonRowPixels
        XCTAssertEqual(column + LensPageFrame.reservedHeightPixels, 600, "two lines, the picture and the row fill the lens")
        XCTAssertEqual(LensPageFrame.pictureSidePixels, 382)
        XCTAssertEqual(LensPageFrame.squareRect, CGRect(x: 97, y: 0, width: 382, height: 382))
    }

    func testTheFittedPictureIsTheSquareCentredOnBlack() throws {
        // An invented 600 × 600 picture: white, as an inverted page's ink would be.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        let fitted = LensPageFrame.fitted(square)
        XCTAssertEqual(fitted.size, CGSize(width: 576, height: 382))
        XCTAssertEqual(fitted.scale, 1, "one lens pixel per image pixel")

        let centre = try XCTUnwrap(LensPageFixtures.pixel(fitted, x: 288, y: 191))
        XCTAssertGreaterThan(centre.r, 240, "the picture, in the middle")
        let bar = try XCTUnwrap(LensPageFixtures.pixel(fitted, x: 20, y: 191))
        XCTAssertLessThan(bar.r, 10, "black either side, which the lens shows as nothing")
        let right = try XCTUnwrap(LensPageFixtures.pixel(fitted, x: 560, y: 191))
        XCTAssertLessThan(right.r, 10)
    }
}
