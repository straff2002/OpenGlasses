import CoreGraphics
import UIKit
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
        XCTAssertEqual(TeleprompterPaginator.Geometry.raybanDisplay.maxLines, 4, "the teleprompter's, unchanged")
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
                // The citation over the picture, the hint (or the part's words) under it.
                let lines = HUDPageScreenBuilder.lines(state)
                let meta = lines.filter { $0.emphasis == .meta }.count
                let body = lines.count - meta + state.lineUnderPicture
                XCTAssertEqual(state.viewport.box, LensPageFrame.pictureBox(metaLines: meta, bodyLines: body))
                let content = LensPageFrame.Content(metaLines: meta, bodyLines: body, hasPicture: true)
                XCTAssertEqual(LensPageFrame.height(content, pictureHeight: state.viewport.box.height), lens,
                               accuracy: 0.001)
            }
        }
    }

    /// A tester's build-728 report: every picture opens on the whole page under the citation line,
    /// with the hint (or, Plan MU §6, the highlighted part's words, up to two lines) under it and
    /// the row in sight: 12 + 30 + 6 + 382 + 6 + 38 + 6 + 88 + 32 = 600 with one line under it,
    /// 338 px of picture with two. One picture, alone in its row (MU §0: no tiles).
    func testTheWholePageOpeningFitsTheLens() {
        let page = CGSize(width: 612, height: 792)
        let part = LensPageViewport(pageSize: page, center: CGPoint(x: 300, y: 300), pixelsPerPoint: 2)
        for words in [nil, "E7 · Low", "E7 · Low supply voltage · Check the supply"] as [String?] {
            var state = HUDPageViewState(viewport: part.startingOnWholePage(), legibility: LensLegibility(),
                                         citation: "Figure 9 · p. 3", hasNextPage: true, diagramCount: 2,
                                         diagramIndex: 0)
            if let words {
                state.highlight = LensPageHighlight(reason: .tableRow, rects: [], part: nil,
                                                    legibility: LensLegibility(), words: words)
            }
            state = state.framed()
            XCTAssertTrue(state.showsCitation)
            XCTAssertEqual(state.showsZoomHint, words == nil)
            let under = words.map { $0.count > 32 ? 2 : 1 } ?? 1
            XCTAssertEqual(state.lineUnderPicture, under)
            XCTAssertEqual(state.viewport.box, CGSize(width: 576, height: under == 1 ? 382 : 338))
            let content = LensPageFrame.Content(metaLines: 1, bodyLines: under, hasPicture: true, hasButtons: true)
            XCTAssertEqual(LensPageFrame.height(content, pictureHeight: state.viewport.box.height), lens, accuracy: 0.001)
            let row = HUDPageScreenBuilder.items(state, { _ in })
            XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons)
            XCTAssertEqual(row.map(\.id), [HUDPageScreenBuilder.ItemID.nextPage, HUDPageScreenBuilder.ItemID.close])
        }
    }

    // MARK: - The answer card (Plan MG P0)

    /// The answer card's geometry is the same budget as reading mode's: 10 lines of 32 characters,
    /// so a paged page holds 9 lines of text and the footer, 8 under the question; a single page 10,
    /// 9 under the question. The teleprompter keeps its 4 × 32 and Even its 3 × 40.
    func testTheAnswerGeometryIsTheFramesBudget() {
        let geometry = LensPageFrame.answerGeometry
        XCTAssertEqual(geometry.maxLines, 10)
        XCTAssertEqual(geometry.maxChars, 32, "the answer card's 32-character estimate")
        XCTAssertEqual(geometry.maxLines, LensPageFrame.readingBodyLines(metaLines: 1) + 1, "9 lines of text and the footer")
        XCTAssertEqual(geometry.maxLines, LensPageFrame.readingBodyLines(metaLines: 0), "a single page")
        // What the pager gives each page of a paged answer, and the first under the question.
        let pagedText = geometry.maxLines - 1
        XCTAssertEqual(pagedText, 9)
        XCTAssertEqual(pagedText - 1, 8, "page 1 under the question")
        XCTAssertEqual(geometry.maxLines - 1, 9, "a single page under the question")
        XCTAssertEqual(TeleprompterPaginator.Geometry.raybanDisplay.maxLines, 4, "the teleprompter's, unchanged")
        XCTAssertEqual(TeleprompterPaginator.Geometry.raybanDisplay.maxChars, 32)
        XCTAssertEqual(TeleprompterPaginator.Geometry.evenG2.maxLines, 3, "Even's, unchanged")
        XCTAssertEqual(TeleprompterPaginator.Geometry.evenG2.maxChars, 40)

        // Every page shape the geometry lays out fits the lens with the row.
        for (meta, body) in [(1, 9), (2, 8), (0, 10)] {
            let content = LensPageFrame.Content(metaLines: meta, bodyLines: body, hasPicture: false, hasButtons: true)
            XCTAssertLessThanOrEqual(LensPageFrame.height(content), lens, "\(meta) meta, \(body) body")
        }
    }

    /// A picture takes its drawn height and the gap before it in body lines and their gaps,
    /// rounded up: the tallest answer thumbnail (209 px drawn) takes 5.
    func testAPictureTakesItsDrawnHeightInBodyLines() {
        XCTAssertEqual(LensPageFrame.pictureBodyLines(drawnHeight: 0), 0)
        XCTAssertEqual(LensPageFrame.pictureBodyLines(drawnHeight: 38), 1, "one body line's height")
        XCTAssertEqual(LensPageFrame.pictureBodyLines(drawnHeight: 39), 2)
        XCTAssertEqual(LensPageFrame.pictureBodyLines(drawnHeight: 209), 5)
        let strip = HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 200),
                               contentKey: "mg.strip")
        XCTAssertEqual(HUDAnswerThumbnail.drawnHeight(of: strip), 209)
        XCTAssertEqual(HUDAnswerThumbnail.firstPageLines(of: strip), 5)
        let panorama = HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 552, height: 100),
                                  contentKey: "mg.panorama")
        XCTAssertEqual(HUDAnswerThumbnail.firstPageLines(of: panorama), 3, "105 px drawn")
    }
}
