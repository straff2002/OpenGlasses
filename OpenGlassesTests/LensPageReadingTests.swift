import CoreGraphics
import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan KV §1 — reading mode: a cited text passage read on the lens as the page's own words, paged
/// like the answer card; and which pages keep the picture.
final class LensPageReadingTests: XCTestCase {

    /// An invented page's text, with a line break inside the first cited sentence.
    private let pageText = "Invented relay note.\nHold the invented key\nfor five seconds. Then wait for the lamp.\n"
        + "Record the invented reading in the log."

    private func mark(_ number: Int, _ words: String) -> PassageMarks.Mark {
        let range = (pageText as NSString).range(of: words)
        return PassageMarks.Mark(number: number, location: .located(ranges: [range], dropped: 0))
    }

    func testTheWordsAreThePagesOwnByTheLocatedRanges() throws {
        let marks = PassageMarks(marks: [mark(1, "Hold the invented key\nfor five seconds.")])
        let reading = try XCTUnwrap(LensPageReading(marks, pageText: pageText))
        XCTAssertEqual(reading.passages, [.init(number: 1, words: "Hold the invented key for five seconds.")],
                       "line breaks collapse to spaces")
        XCTAssertFalse(reading.showsNumbers)
        XCTAssertEqual(reading.text, "Hold the invented key for five seconds.")
    }

    func testSeveralPassagesFollowOneAnotherNumberedAsTheMarksAre() throws {
        let marks = PassageMarks(marks: [mark(1, "Hold the invented key\nfor five seconds."),
                                         mark(2, "Record the invented reading in the log.")])
        let reading = try XCTUnwrap(LensPageReading(marks, pageText: pageText))
        XCTAssertTrue(reading.showsNumbers)
        XCTAssertEqual(reading.text, "1 · Hold the invented key for five seconds.\n2 · Record the invented reading in the log.")

        let pages = reading.pages(geometry: .raybanDisplay)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages[0].lines.first?.hasPrefix("1 · ") == true)
        XCTAssertEqual(reading.passageNumber(atPage: 0, of: pages), 1)
        let second = try XCTUnwrap(pages.firstIndex { $0.lines.contains { $0.hasPrefix("2 · ") } })
        XCTAssertEqual(reading.passageNumber(atPage: second, of: pages), pages[second].lines.first?.hasPrefix("2 · ") == true ? 2 : 1)
        XCTAssertEqual(reading.passageNumber(atPage: pages.count - 1, of: pages), 2)
    }

    func testAPassageNotLocatedHasNothingToRead() {
        let lost = PassageMarks(marks: [.init(number: 1, location: .notLocatable(.notFound))])
        XCTAssertNil(LensPageReading(lost, pageText: pageText))
        XCTAssertNil(LensPageReading(PassageMarks(marks: [mark(1, "Then wait for the lamp.")]), pageText: nil))
    }

    /// The first page is budgeted one line for the citation, as the answer card's question line is.
    func testThePagesAreTheAnswerCardsWithTheCitationsLine() {
        let words = String(repeating: "Invented purge step on the board. ", count: 6)
        let reading = LensPageReading(passages: [.init(number: 1, words: words)], showsNumbers: false)
        XCTAssertEqual(reading.pages(geometry: .raybanDisplay),
                       HUDAnswerPager.pages(for: reading.text, geometry: .raybanDisplay, firstPageReservedLines: 1))
    }

    // MARK: - Which pages read

    private let page = CGSize(width: 612, height: 792)
    private let line = CGRect(x: 72, y: 300, width: 400, height: 11)
    private var marks: LensPageMarks {
        LensPageMarks(marks: [.init(number: 1, lineRects: [line], bounds: line)], showsNumbers: false)
    }
    private let words = LensPageReading(passages: [.init(number: 1, words: "Invented words.")], showsNumbers: false)

    func testOnlyAViewOpenedOnACitedTextPassageReads() {
        let reads = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [], tone: .lineArt, reading: words)
        XCTAssertEqual(reads.reading, words)

        let pictured = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [CGRect(x: 50, y: 400, width: 300, height: 100)],
                                      tone: .lineArt, reading: words)
        XCTAssertNil(pictured.reading, "a pictured table keeps the picture")
        let photographed = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [], tone: .photographed, reading: words)
        XCTAssertNil(photographed.reading, "a photographed page keeps the picture")
        let drawing = PageDrawing(rect: CGRect(x: 100, y: 450, width: 300, height: 200), labels: [], heading: nil)
        let onDrawing = LensPageLayout(pageSize: page, marks: marks, pictureAreas: [], tone: .lineArt,
                                       drawings: [drawing], figureIndex: 0, drawingFocus: .first, reading: words)
        XCTAssertEqual(onDrawing.focus.source, .figure)
        XCTAssertNil(onDrawing.reading, "a drawing asked for keeps the picture")
    }

    /// From an invented PDF: the cited line's words come from the page's text layer; a table row
    /// (located by its printed runs) and a pictured table keep the picture.
    func testAnInventedPageReadsItsCitedLineAndATableRowDoesNot() async throws {
        let url = try LensPageFixtures.pdf(text: "Invented relay note 7")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        let anchor = PassageAnchor(documentId: "doc-invented", chunkIndex: 0, text: "Invented relay note 7", page: 1)
        let request = LensPageRequest(source: url, page: 1, citedPassages: [CitedPassage(number: 1, anchor: anchor)])
        let reading = try XCTUnwrap(LensPageRenderer.reading(pdfPage, request: request))
        XCTAssertEqual(reading.passages.map(\.words), ["Invented relay note 7"])
        let layout = LensPageRenderer.layout(pdfPage, request: request)
        XCTAssertEqual(layout.focus.source, .citedPassages)
        XCTAssertEqual(layout.reading, reading)

        let row = PassageAnchor(documentId: "doc-invented", chunkIndex: 1, text: "Invented relay row: note 7",
                                page: 1, printedRuns: ["Invented relay note 7"])
        let rowRequest = LensPageRequest(source: url, page: 1, citedPassages: [CitedPassage(number: 1, anchor: row)])
        XCTAssertNil(LensPageRenderer.reading(pdfPage, request: rowRequest), "a table row keeps the picture")

        let tableRequest = LensPageRequest(source: url, page: 1, citedPassages: [CitedPassage(number: 1, anchor: anchor)],
                                           pictureAreas: [.init(physical: 1, rect: CGRect(x: 50, y: 400, width: 300, height: 100))])
        XCTAssertNil(LensPageRenderer.reading(pdfPage, request: tableRequest), "so does a pictured table")
    }
}
