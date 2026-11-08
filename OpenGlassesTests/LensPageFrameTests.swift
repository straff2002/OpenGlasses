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

    /// Reading mode's frames have no picture: the citation (first page only), the lines of text and
    /// the footer, and the row. Every shape `HUDAnswerPager` cuts with the reading geometry fits: a
    /// single page (no footer), a paged first page and a later page, with and without the citation
    /// (which takes one line of the first page, `LensPageReading.pages`).
    func testEveryReadingFrameFitsTheLens() {
        for geometry in [LensPageFrame.readingGeometry, .evenG2] {
            for citation in [false, true] {
                let reserved = citation ? 1 : 0
                let cite = citation ? 1 : 0
                let shapes: [(meta: Int, body: Int)] = [
                    (cite, geometry.maxLines - reserved),           // a single page
                    (cite + 1, geometry.maxLines - 1 - reserved),   // a paged first page, its footer
                    (1, geometry.maxLines - 1),                     // a later page, its footer
                ]
                for shape in shapes {
                    for lines in 0...shape.body {
                        let content = LensPageFrame.Content(metaLines: shape.meta, bodyLines: lines,
                                                            hasPicture: false, hasButtons: true)
                        XCTAssertLessThanOrEqual(LensPageFrame.height(content), lens, "\(content)")
                    }
                }
            }
        }
    }

    /// The reading geometry is the frame's budget: 600 px less the padding, the meta lines, the row
    /// and its glow padding, over the body token's 1.35× line (and the gap between lines); the
    /// answer card's 32 characters across the 576 px column. KP's card geometry is untouched.
    func testTheReadingGeometryIsTheFramesBudget() {
        XCTAssertEqual(LensPageFrame.bodyLinePixels, HUDCanvas.metaDisplay.textSize(.body).lineHeightPixels,
                       "a body line is the body token's line")
        XCTAssertEqual(LensPageFrame.readingBodyLines(metaLines: 0), 10)
        XCTAssertEqual(LensPageFrame.readingBodyLines(metaLines: 1), 9, "the footer")
        XCTAssertEqual(LensPageFrame.readingBodyLines(metaLines: 2), 9, "the citation and the footer")
        XCTAssertEqual(LensPageFrame.readingCharAdvancePixels, 18)
        let geometry = LensPageFrame.readingGeometry
        XCTAssertEqual(geometry.maxLines, 10)
        XCTAssertEqual(geometry.maxChars, TeleprompterPaginator.Geometry.raybanDisplay.maxChars)
        XCTAssertEqual(LensPageFrame.readingGeometry(for: .metaDisplay).maxLines, geometry.maxLines)
        let even = LensPageFrame.readingGeometry(for: .evenG2)
        XCTAssertEqual(even.maxLines, TeleprompterPaginator.Geometry.evenG2.maxLines, "Even's own, unchanged")
        XCTAssertEqual(even.maxChars, TeleprompterPaginator.Geometry.evenG2.maxChars)
        XCTAssertEqual(TeleprompterPaginator.Geometry.raybanDisplay.maxLines, 4, "the answer card's, unchanged")
        XCTAssertEqual(TeleprompterPaginator.Geometry.raybanDisplay.maxChars, 32)
    }

    /// A full reading page, laid out by the pager and the screen builder as the lens gets it, with
    /// and without the citation line: no wider than a line, it fits in 600 px, and it holds at
    /// least six lines of text.
    func testAFullReadingPageFitsAndHoldsSixLinesOrMore() throws {
        let words = (1...40).map { "Invented step \($0) of the purge on the board." }.joined(separator: " ")
        let reading = LensPageReading(passages: [.init(number: 1, words: words)], showsNumbers: false)
        let geometry = LensPageFrame.readingGeometry
        let pages = reading.pages(geometry: geometry)
        XCTAssertGreaterThan(pages.count, 2)
        for citation in ["Figure 9 · p. 3", nil] {
            for page in pages.prefix(2) {
                var state = HUDPageViewState(viewport: LensPageViewport(wholePage: CGSize(width: 612, height: 792)),
                                             legibility: LensLegibility(), citation: citation)
                state.readingPages = pages
                state.readingIndex = page.index
                state.isReading = true
                let lines = HUDPageScreenBuilder.lines(state)
                let meta = lines.filter { $0.emphasis == .meta }.count
                let body = lines.count - meta
                XCTAssertEqual(meta, (citation != nil && page.index == 0 ? 1 : 0) + 1, "the citation and the footer")
                XCTAssertGreaterThanOrEqual(body, 6, "page \(page.index + 1), citation \(citation != nil)")
                XCTAssertTrue(lines.allSatisfy { $0.text.count <= geometry.maxChars }, "one lens line each")
                let content = LensPageFrame.Content(metaLines: meta, bodyLines: body, hasPicture: false, hasButtons: true)
                XCTAssertLessThanOrEqual(LensPageFrame.height(content), lens,
                                         "page \(page.index + 1), citation \(citation != nil)")
            }
        }
        XCTAssertEqual(pages[0].lines.count, 8, "the first page gives the citation a line")
        XCTAssertEqual(pages[1].lines.count, 9)
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
