import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P1b — reading what a request asks of a page's drawings, and choosing one: a named
/// caption, the request's words against each drawing's labels and heading, a position word, or
/// else the largest; and the focus order a drawing request changes.
final class PageFigureChoiceTests: XCTestCase {

    private let page = CGSize(width: 612, height: 792)

    private func drawing(_ rect: CGRect, labels: [String] = [], heading: String? = nil) -> PageDrawing {
        PageDrawing(rect: rect,
                    labels: labels.enumerated().map {
                        PageTextLine(rect: CGRect(x: rect.minX + 10, y: rect.minY + 10 + CGFloat($0.offset) * 12,
                                                  width: 40, height: 8), text: $0.element)
                    },
                    heading: heading.map { PageTextLine(rect: CGRect(x: rect.minX, y: rect.minY - 18, width: 120, height: 10),
                                                        text: $0) })
    }

    private lazy var upper = drawing(CGRect(x: 90, y: 100, width: 420, height: 240), labels: ["blower", "motor"],
                                     heading: "Invented upper layout")
    private lazy var lower = drawing(CGRect(x: 120, y: 450, width: 360, height: 200), labels: ["board", "fuse"],
                                     heading: "Invented lower layout")

    // MARK: - Reading the ask

    func testADrawingWordAsksForADrawing() {
        for said in ["show me the wiring diagram on page 7", "Show me figure 12", "can I see the schematic",
                     "show me the drawing", "the picture of the board please"] {
            XCTAssertTrue(PageFigureAsk.parse(said: said, caption: nil, origin: .requested).asksForDrawing, said)
        }
        for said in ["show me the page", "what does the relay do", "show me table 99"] {
            XCTAssertFalse(PageFigureAsk.parse(said: said, caption: "Table 99", origin: .requested).asksForDrawing, said)
        }
    }

    func testTheNamedCaptionAndTheStagedOne() {
        let named = PageFigureAsk.parse(said: "show me fig. 13 please", caption: "Figure 12", origin: .requested)
        XCTAssertEqual(named.captionNumber, "13", "what the technician said wins")
        let staged = PageFigureAsk.parse(said: "show me that", caption: "Figure 12", origin: .automatic)
        XCTAssertEqual(staged.captionNumber, "12")
        XCTAssertFalse(staged.asksForDrawing, "the words asked for nothing drawn")
        XCTAssertTrue(PageFigureAsk.parse(said: "show me 12", caption: "Figure 12", origin: .requested).asksForDrawing,
                      "the figure's number on its own")
        XCTAssertFalse(PageFigureAsk.parse(said: "show me page 12", caption: "Figure 12", origin: .requested).asksForDrawing,
                       "a page number is not the figure's")
        XCTAssertNil(PageFigureAsk.parse(said: nil, caption: "Table 99", origin: .requested).captionNumber,
                     "a table's caption is not a drawing's")
    }

    func testWithNoWordsARequestedFigureCaptionAsksForADrawing() {
        XCTAssertTrue(PageFigureAsk.parse(said: nil, caption: "Figure 12", origin: .requested).asksForDrawing)
        XCTAssertTrue(PageFigureAsk.parse(said: "  ", caption: "Fig. 3", origin: .requested).asksForDrawing)
        XCTAssertFalse(PageFigureAsk.parse(said: nil, caption: "Figure 12", origin: .automatic).asksForDrawing)
        XCTAssertFalse(PageFigureAsk.parse(said: nil, caption: "Table 98", origin: .requested).asksForDrawing)
        XCTAssertFalse(PageFigureAsk.parse(said: nil, caption: nil, origin: .requested).asksForDrawing)
    }

    func testContentWordsAndPosition() {
        let ask = PageFigureAsk.parse(said: "Show me the blower wiring diagram on the bottom of page 7",
                                      caption: nil, origin: .requested)
        XCTAssertEqual(ask.words, ["blower"], "filler, drawing words, positions and numbers are not content")
        XCTAssertEqual(ask.position, .bottom)
        XCTAssertEqual(PageFigureAsk.parse(said: "the second drawing", caption: nil, origin: .requested).position, .second)
        XCTAssertEqual(PageFigureAsk.parse(said: "the lower one", caption: nil, origin: .requested).position, .bottom)
        XCTAssertNotEqual(ask.key, PageFigureAsk.none.key)
    }

    // MARK: - Choosing

    func testANamedCaptionChoosesTheDrawingNearestIt() {
        let captionUnderUpper = CGRect(x: 90, y: 350, width: 160, height: 10)
        let choice = PageFigureChoice.choose([upper, lower], ask: .none, captionRects: [captionUnderUpper])
        XCTAssertEqual(choice.index, 0)
        XCTAssertEqual(choice.reason, .caption)
        let captionAboveLower = CGRect(x: 120, y: 432, width: 160, height: 10)
        XCTAssertEqual(PageFigureChoice.choose([upper, lower], ask: .none, captionRects: [captionAboveLower]).index, 1,
                       "a caption above its drawing counts too")
    }

    func testACaptionHalfwayDecidesNothing() {
        let between = CGRect(x: 90, y: 390, width: 160, height: 10)    // 50 below one, 50 above the other
        let choice = PageFigureChoice.choose([upper, lower], ask: .none, captionRects: [between])
        XCTAssertEqual(choice.reason, .largest)
        XCTAssertEqual(choice.index, 0)
    }

    func testTwoUncaptionedDrawingsAreToldApartByTheirLabels() {
        let blower = PageFigureAsk.parse(said: "show me the blowers", caption: nil, origin: .requested)
        XCTAssertEqual(PageFigureChoice.choose([upper, lower], ask: blower).index, 0)
        let board = PageFigureAsk.parse(said: "show me the control board diagram", caption: nil, origin: .requested)
        let choice = PageFigureChoice.choose([upper, lower], ask: board)
        XCTAssertEqual(choice.index, 1)
        XCTAssertEqual(choice.reason, .words)
    }

    func testWordsBothDrawingsShareDecideNothing() {
        let ask = PageFigureAsk.parse(said: "show me the invented layout", caption: nil, origin: .requested)
        XCTAssertEqual(PageFigureChoice.choose([upper, lower], ask: ask).reason, .largest, "both headings say it")
    }

    func testTheBottomOne() {
        let ask = PageFigureAsk.parse(said: "show me the bottom one", caption: nil, origin: .requested)
        let choice = PageFigureChoice.choose([upper, lower], ask: ask)
        XCTAssertEqual(choice.index, 1)
        XCTAssertEqual(choice.reason, .position)
    }

    func testPositionsAgainstReadingOrder() {
        let left = drawing(CGRect(x: 72, y: 100, width: 200, height: 200))
        let right = drawing(CGRect(x: 340, y: 110, width: 200, height: 200))
        let below = drawing(CGRect(x: 100, y: 450, width: 400, height: 200))
        let drawings = [left, right, below]
        XCTAssertEqual(PageFigureChoice.index(for: .left, in: drawings), 0, "wholly left of the others' middles")
        XCTAssertEqual(PageFigureChoice.index(for: .right, in: drawings), 1)
        let wide = drawing(CGRect(x: 60, y: 450, width: 500, height: 200))
        XCTAssertNil(PageFigureChoice.index(for: .right, in: [left, wide]), "the wide one reaches past the other's middle")
        XCTAssertEqual(PageFigureChoice.index(for: .left, in: [left, right]), 0)
        XCTAssertEqual(PageFigureChoice.index(for: .right, in: [left, right]), 1)
        XCTAssertNil(PageFigureChoice.index(for: .top, in: drawings), "two share the top")
        XCTAssertEqual(PageFigureChoice.index(for: .bottom, in: drawings), 2)
        XCTAssertEqual(PageFigureChoice.index(for: .second, in: drawings), 1)
        XCTAssertEqual(PageFigureChoice.index(for: .last, in: drawings), 2)
        XCTAssertNil(PageFigureChoice.index(for: .third, in: [left, right]))
    }

    func testOtherwiseTheLargestAndOneIsOne() {
        XCTAssertEqual(PageFigureChoice.choose([lower, upper], ask: .none).index, 1)
        XCTAssertEqual(PageFigureChoice.choose([lower], ask: .none).reason, .only)
        XCTAssertNil(PageFigureChoice.choose([], ask: .none).index)
    }

    func testCaptionRangesPreferTheLineThatStartsWithIt() {
        let text = "Invented intro. See Figure 12 for the coil.\nFigure 12. Invented coil layout\nFigure 120 is elsewhere"
        let ranges = PageFigureChoice.captionRanges(number: "12", in: text)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "Figure 12")
        XCTAssertEqual(PageFigureChoice.captionRanges(number: "12", in: "as in fig. 12, the coil").count, 1,
                       "a mention is used when no line starts with it")
    }

    // MARK: - The focus order

    func testADrawingRequestPutsTheFigureAheadOfACitedPassage() {
        let passage = CGRect(x: 72, y: 700, width: 300, height: 12)
        let figure = upper.rect
        let asked = LensPageFocus.pick(pageSize: page, passageRects: [passage], figure: figure, figureFirst: true)
        XCTAssertEqual(asked.source, .figure)
        XCTAssertTrue(LensPageViewport(opening: asked).cropRect.contains(figure), "the whole drawing at the opening zoom")
        let plain = LensPageFocus.pick(pageSize: page, passageRects: [passage], figure: figure)
        XCTAssertEqual(plain.source, .citedPassages, "a request for no drawing keeps the passage first")
    }

    func testTheLayoutOpensOnTheChosenDrawing() {
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [CGRect(x: 72, y: 700, width: 300, height: 12)],
                                                bounds: CGRect(x: 72, y: 700, width: 300, height: 12))],
                                  showsNumbers: false)
        let asked = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [], tone: .lineArt,
                                   drawings: [upper, lower], figureIndex: 1, drawingFocus: .first)
        XCTAssertEqual(asked.focus.source, .figure)
        XCTAssertEqual(asked.openingDrawing, 1)
        XCTAssertTrue(asked.openingViewport.cropRect.contains(lower.rect))
        let plain = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [], tone: .lineArt,
                                   drawings: [upper, lower], figureIndex: 1, drawingFocus: .afterMarks)
        XCTAssertEqual(plain.focus.source, .citedPassages)
        XCTAssertNil(plain.openingDrawing)
        let unmarked = LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt,
                                      drawings: [upper, lower], figureIndex: 0)
        XCTAssertEqual(unmarked.focus.source, .figure, "with nothing cited, the drawing still beats the whole page")
        let page7 = LensPageLayout(pageSize: page, marks: nil, pictureAreas: [], tone: .lineArt,
                                   drawings: [upper, lower], figureIndex: 0, drawingFocus: .none)
        XCTAssertEqual(page7.focus.source, .wholePage, "a request for the page opens it whole")
        XCTAssertNil(page7.openingDrawing)
        XCTAssertEqual(page7.drawings.count, 2, "the drawings are kept for Next diagram")
    }

    func testTheDrawingIsAFocusOnlyWhenAskedForOrPutUpForItsFigure() {
        XCTAssertEqual(PageFigureAsk.parse(said: "show me page 7", caption: "Figure 9", origin: .requested).drawingFocus,
                       .none, "a request for the page")
        XCTAssertEqual(PageFigureAsk.parse(said: "show me the diagram on page 7", caption: nil,
                                           origin: .requested).drawingFocus, .first)
        XCTAssertEqual(PageFigureAsk.parse(said: nil, caption: "Figure 9", origin: .automatic).drawingFocus,
                       .afterMarks, "the app put the page up for its figure")
        XCTAssertEqual(PageFigureAsk.parse(said: "what does the relay do", caption: "Figure 9",
                                           origin: .automatic).drawingFocus, .afterMarks)
        XCTAssertEqual(PageFigureAsk.parse(said: nil, caption: "Table 98", origin: .automatic).drawingFocus, .none,
                       "a table's page is not a figure's")
        XCTAssertEqual(PageFigureAsk.none.drawingFocus, .none)
        XCTAssertNotEqual(PageFigureAsk.parse(said: "show me page 7", caption: "Figure 9", origin: .automatic).key,
                          PageFigureAsk.parse(said: "show me page 7", caption: "Figure 9", origin: .requested).key,
                          "the layout cache tells them apart")
    }
}
