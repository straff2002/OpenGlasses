import CoreGraphics
import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan KV P1b — finding and choosing the diagram on invented PDF pages drawn with
/// `UIGraphicsPDFRenderer`: the ink mask from a 72 dpi render, the text lines from PDFKit, the
/// right blocks found and chosen, text never counted, the opening zoom holding the whole drawing,
/// and a page analysed once.
final class PageFigureAnalysisTests: XCTestCase {

    private typealias F = PageFigureFixtures

    private func drawings(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [PageDrawing] {
        let page = try XCTUnwrap(F.page(url), file: file, line: line)
        return PageFigureAnalysis.drawings(on: page)
    }

    /// Found within the mask's cells and a stroke's width of where the fixture drew it.
    private func assertNear(_ found: CGRect, _ expected: CGRect, tolerance: CGFloat = 6,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.minX, expected.minX, accuracy: tolerance, "minX of \(found)", file: file, line: line)
        XCTAssertEqual(found.minY, expected.minY, accuracy: tolerance, "minY of \(found)", file: file, line: line)
        XCTAssertEqual(found.maxX, expected.maxX, accuracy: tolerance, "maxX of \(found)", file: file, line: line)
        XCTAssertEqual(found.maxY, expected.maxY, accuracy: tolerance, "maxY of \(found)", file: file, line: line)
    }

    private func layout(_ url: URL, said: String?, caption: String? = nil, origin: PageOrigin = .requested,
                        citedRect: CGRect? = nil) async throws -> LensPageLayout {
        let ask = PageFigureAsk.parse(said: said, caption: caption, origin: origin)
        let request = LensPageRequest(source: url, page: 1, ask: ask)
        let laid = try await unwrapLayout(await LensPageRenderer.layout(request))
        guard let citedRect else { return laid }
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [citedRect], bounds: citedRect)], showsNumbers: false)
        return LensPageLayout(pageSize: laid.pageSize, marks: marks, pictureAreas: [], tone: .lineArt,
                              drawings: laid.drawings, figureIndex: laid.figureIndex, drawingFocus: ask.drawingFocus)
    }

    private func unwrapLayout(_ layout: LensPageLayout?, file: StaticString = #filePath,
                              line: UInt = #line) throws -> LensPageLayout {
        try XCTUnwrap(layout, "the invented page lays out", file: file, line: line)
    }

    // MARK: - Finding

    func testABlockDiagramWithTextAroundItIsFound() throws {
        let url = try F.blockDiagramPage()
        let found = try drawings(url)
        XCTAssertEqual(found.count, 1, "\(found.map(\.rect))")
        assertNear(found[0].rect, F.blockDiagram)
        XCTAssertEqual(Set(found[0].labels.map(\.text)), ["relay", "board", "fan"], "its labels, each its own line")
        // The paragraphs above and below are text, never ink.
        let lines = PageFigureAnalysis.textLines(of: try XCTUnwrap(F.page(url)))
        let paragraphs = lines.filter { $0.text.hasPrefix("Invented note") }
        XCTAssertEqual(paragraphs.count, 11)
        XCTAssertFalse(paragraphs.contains { $0.rect.intersects(found[0].rect) })
    }

    func testTextLinesAreInTopDownPagePoints() throws {
        let page = try XCTUnwrap(F.page(try F.blockDiagramPage()))
        let footer = try XCTUnwrap(PageFigureAnalysis.textLines(of: page).first { $0.text.contains("footer") })
        XCTAssertEqual(footer.rect.minY, 740, accuracy: 4, "drawn at y 740 from the top")
        XCTAssertEqual(footer.rect.minX, 72, accuracy: 3)
    }

    func testAPageOfTextOnlyHasNoDrawing() throws {
        XCTAssertEqual(try drawings(try F.textOnlyPage()), [])
    }

    func testADrawingWithNoCaptionAtAllIsFound() throws {
        let found = try drawings(try F.bareDrawingPage())
        XCTAssertEqual(found.count, 1, "\(found.map(\.rect))")
        assertNear(found[0].rect, F.bareDrawing)
        XCTAssertTrue(found[0].labels.isEmpty)
    }

    func testAPageThatIsAllDrawingIsOneBlockAndOpensFitted() async throws {
        let url = try F.wholeSheetPage()
        let found = try drawings(url)
        XCTAssertEqual(found.count, 1, "\(found.map(\.rect))")
        assertNear(found[0].rect, F.wholeSheet)
        let laid = try await layout(url, said: "show me the wiring diagram")
        XCTAssertEqual(laid.focus.source, .figure)
        XCTAssertTrue(laid.openingViewport.isWholePage, "a page-sized drawing opens whole, which is right")
    }

    func testATableWithOnlyItsBorderIsNotADrawing() throws {
        XCTAssertEqual(try drawings(try F.tableBorderPage()), [])
    }

    func testAThinRuleLineIsNotADrawing() throws {
        XCTAssertEqual(try drawings(try F.ruleLinePage()), [])
    }

    func testTwoDrawingsAreFoundInReadingOrder() throws {
        let found = try drawings(try F.twoCaptionedPage())
        XCTAssertEqual(found.count, 2, "\(found.map(\.rect))")
        assertNear(found[0].rect, F.captionedUpper)
        assertNear(found[1].rect, F.captionedLower)
    }

    // MARK: - Choosing

    func testTwoCaptionsChooseByTheCaptionNamed() async throws {
        let url = try F.twoCaptionedPage()
        let thirteen = try await layout(url, said: "show me figure 13")
        XCTAssertEqual(thirteen.figureIndex, 1, "the drawing over Figure 13's caption, not the mention under the page")
        let twelve = try await layout(url, said: nil, caption: "Figure 12")
        XCTAssertEqual(twelve.figureIndex, 0)
        XCTAssertTrue(twelve.openingViewport.cropRect.contains(F.captionedUpper), "the whole chosen drawing")
    }

    func testTwoUncaptionedDrawingsAreToldApartByLabelsAndPosition() async throws {
        let url = try F.twoUncaptionedPage()
        let found = try drawings(url)
        XCTAssertEqual(found.count, 2, "\(found.map(\.rect))")
        XCTAssertEqual(found.map { $0.heading?.text }, ["Invented upper layout", "Invented lower layout"])

        let largest = try await layout(url, said: "show me the diagram")
        XCTAssertEqual(largest.figureIndex, 0, "nothing tells them apart: the larger")
        let board = try await layout(url, said: "show me the board wiring")
        XCTAssertEqual(board.figureIndex, 1)
        let blower = try await layout(url, said: "show me the blower")
        XCTAssertEqual(blower.figureIndex, 0)
        // A drawing asked for by where it is: the drawing is a focus only when one is asked for.
        let bottom = try await layout(url, said: "the bottom diagram")
        XCTAssertEqual(bottom.figureIndex, 1)
        XCTAssertTrue(bottom.openingViewport.cropRect.contains(found[1].rect), "the opening zoom holds the whole drawing")
        XCTAssertFalse(bottom.openingViewport.isWholePage)
    }

    func testTheOpeningZoomHoldsTheWholeDiagram() async throws {
        let laid = try await layout(try F.blockDiagramPage(), said: "show me the diagram")
        XCTAssertEqual(laid.focus.source, .figure)
        XCTAssertFalse(laid.openingViewport.isWholePage)
        XCTAssertTrue(laid.openingViewport.cropRect.contains(F.blockDiagram))
    }

    func testADrawingRequestOpensOnTheDrawingAheadOfACitedPassage() async throws {
        let url = try F.blockDiagramPage()
        let cited = CGRect(x: 72, y: 500, width: 380, height: 12)
        let asked = try await layout(url, said: "show me the wiring diagram", citedRect: cited)
        XCTAssertEqual(asked.focus.source, .figure)
        XCTAssertTrue(asked.openingViewport.cropRect.contains(F.blockDiagram))
        let plain = try await layout(url, said: "what does the relay do", citedRect: cited)
        XCTAssertEqual(plain.focus.source, .citedPassages, "a request for no drawing keeps the passage first")
    }

    // MARK: - The thin edge

    func testAPhotographedPageFindsNoDrawing() async throws {
        let url = try F.blockDiagramPage()
        let request = LensPageRequest(source: url, page: 1, tone: .photographed,
                                      ask: PageFigureAsk.parse(said: "show me the diagram", caption: nil, origin: .requested))
        let laid = try await unwrapLayout(await LensPageRenderer.layout(request))
        XCTAssertEqual(laid.drawings, [])
        XCTAssertEqual(laid.focus.source, .wholePage, "it opens on the whole page, as before")
    }

    func testAPageIsAnalysedOncePerRevision() throws {
        let url = try F.blockDiagramPage()
        let page = try XCTUnwrap(F.page(url))
        let cache = PageFigureCache()
        let key = PageFigureCache.key(documentId: "doc-invented", page: 1, sourceRevision: "r1", sourceFile: "invented.pdf")
        let first = LensPageRenderer.figureChoice(page, request: LensPageRequest(source: url, page: 1, figureKey: key), cache: cache)
        let again = LensPageRenderer.figureChoice(page, request: LensPageRequest(
            source: url, page: 1, ask: PageFigureAsk.parse(said: "the bottom one", caption: nil, origin: .requested),
            figureKey: key), cache: cache)
        XCTAssertEqual(first.drawings, again.drawings)
        XCTAssertEqual(cache.analyses, 1, "the second ask reuses the first analysis")
        let revised = PageFigureCache.key(documentId: "doc-invented", page: 1, sourceRevision: "r2", sourceFile: "invented.pdf")
        _ = LensPageRenderer.figureChoice(page, request: LensPageRequest(source: url, page: 1, figureKey: revised), cache: cache)
        XCTAssertEqual(cache.analyses, 2, "a new revision is analysed afresh")
    }
}
