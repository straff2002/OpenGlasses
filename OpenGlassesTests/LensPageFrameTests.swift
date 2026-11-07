import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P4 — the page view's frame fits the lens. On the simulated Display the frame scrolled:
/// first with a full-width square picture, then by 20 px on every frame, because the focused
/// button's glow reached past a 12 px bottom margin. The picture now takes exactly what the lines,
/// the row and the margins leave, and the margin under a row holds the glow.
final class LensPageFrameTests: XCTestCase {

    private let lens: CGFloat = 600

    func testThePictureBoxForEachLineCount() {
        XCTAssertEqual(LensPageFrame.contentWidthPixels, 576, "the canvas less the backend's padding")
        XCTAssertEqual(LensPageFrame.pictureBox(citation: false, hint: false), CGSize(width: 576, height: 462))
        XCTAssertEqual(LensPageFrame.pictureBox(citation: true, hint: false), CGSize(width: 576, height: 426))
        XCTAssertEqual(LensPageFrame.pictureBox(citation: false, hint: true), CGSize(width: 576, height: 418))
        XCTAssertEqual(LensPageFrame.pictureBox(citation: true, hint: true), CGSize(width: 576, height: 382))
    }

    /// Every combination a page-view frame can have: 0, 1 or 2 lines over the picture, a reading
    /// page's footer, with and without the row. With its picture box the frame is never taller
    /// than the lens, and with the picture's whole box it is exactly the lens.
    func testEveryCombinationFitsTheLens() {
        for meta in 0...2 {
            for body in 0...2 {
                for buttons in [false, true] {
                    let content = LensPageFrame.Content(metaLines: meta, bodyLines: body, hasPicture: true,
                                                        hasButtons: buttons)
                    let box = LensPageFrame.pictureBox(metaLines: meta, bodyLines: body, hasButtons: buttons)
                    XCTAssertEqual(box.width, 576)
                    XCTAssertGreaterThan(box.height, 300, "\(content)")
                    XCTAssertEqual(LensPageFrame.height(content, pictureHeight: box.height), lens, accuracy: 0.001,
                                   "\(content)")
                }
            }
        }
    }

    /// Reading mode's frames have no picture: the citation (first page only), the backend's lines of
    /// text and the footer, and the row. Every page of the answer card's geometry fits.
    func testEveryReadingFrameFitsTheLens() {
        for geometry in [TeleprompterPaginator.Geometry.raybanDisplay, .evenG2] {
            for citation in [false, true] {
                for lines in 0...geometry.maxLines {
                    for footer in [false, true] {
                        let content = LensPageFrame.Content(metaLines: (citation ? 1 : 0) + (footer ? 1 : 0),
                                                            bodyLines: lines, hasPicture: false, hasButtons: true)
                        XCTAssertLessThanOrEqual(LensPageFrame.height(content), lens, "\(content)")
                    }
                }
            }
        }
    }

    /// The margin under a row holds the focused button's glow, which reaches 32 px below it.
    func testTheMarginUnderARowHoldsTheGlow() {
        XCTAssertEqual(LensPageFrame.bottomPadding(hasButtons: true), 32)
        XCTAssertEqual(LensPageFrame.bottomPadding(hasButtons: false), LensPageFrame.paddingPixels)
        XCTAssertEqual(LensPageFrame.height(LensPageFrame.Content(metaLines: 1, bodyLines: 1, hasPicture: true),
                                            pictureHeight: 382), lens)
    }

    /// Every frame a page view draws has the picture box of its own lines.
    func testAFramedStateDrawsIntoTheBoxOfItsOwnLines() {
        let page = CGSize(width: 612, height: 792)
        let whole = LensPageViewport(wholePage: page)
        for first in [false, true] {
            for textHeight in [CGFloat(8), 40] {
                let state = HUDPageViewState(viewport: whole, legibility: LensLegibility(textHeightPoints: textHeight),
                                             isFirstFrame: first, citation: "p. 3").framed()
                let lines = HUDPageScreenBuilder.lines(state)
                let meta = lines.filter { $0.emphasis == .meta }.count
                let body = lines.count - meta
                XCTAssertEqual(state.viewport.box, LensPageFrame.pictureBox(metaLines: meta, bodyLines: body))
                let content = LensPageFrame.Content(metaLines: meta, bodyLines: body, hasPicture: true)
                XCTAssertEqual(LensPageFrame.height(content, pictureHeight: state.viewport.box.height), lens,
                               accuracy: 0.001)
            }
        }
    }
}
