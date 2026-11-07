import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — where the page view opens: the four sources in order, the padding, the square,
/// and the step the focus fits at.
final class LensPageFocusTests: XCTestCase {

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)

    /// A narrow invented table row (top-down page points).
    private let tableRow = CGRect(x: 100, y: 400, width: 160, height: 10)
    private let pictured = CGRect(x: 60, y: 120, width: 300, height: 200)
    private let figure = CGRect(x: 40, y: 500, width: 200, height: 150)

    func testCitedPassagesWinOverEverythingElse() {
        let focus = LensPageFocus.pick(pageSize: page, passageRects: [tableRow],
                                       pictureAreas: [pictured], figure: figure)
        XCTAssertEqual(focus.source, .citedPassages)
        XCTAssertEqual(focus.region, tableRow)
    }

    func testPictureAreasComeBeforeTheFigure() {
        let focus = LensPageFocus.pick(pageSize: page, pictureAreas: [pictured], figure: figure)
        XCTAssertEqual(focus.source, .pictureArea)
        XCTAssertEqual(focus.region, pictured)
    }

    func testTheFigureIsUsedWhenNothingElseIsKnown() {
        let focus = LensPageFocus.pick(pageSize: page, figure: figure)
        XCTAssertEqual(focus.source, .figure)
        XCTAssertEqual(focus.region, figure)
    }

    func testNothingKnownOpensTheWholePage() {
        let focus = LensPageFocus.pick(pageSize: page)
        XCTAssertEqual(focus.source, .wholePage)
        XCTAssertNil(focus.region)
        XCTAssertFalse(focus.hasFocus)
        XCTAssertEqual(focus.zoom, .fit)
        XCTAssertFalse(LensPageViewport(opening: focus).opensOnPart)
    }

    /// A source whose rectangles are all off the page or empty falls through to the next.
    func testOffPageAndEmptyRectanglesFallThrough() {
        let offPage = CGRect(x: 700, y: 900, width: 50, height: 20)
        let empty = CGRect(x: 100, y: 100, width: 0, height: 12)
        let focus = LensPageFocus.pick(pageSize: page, passageRects: [offPage, empty], pictureAreas: [pictured])
        XCTAssertEqual(focus.source, .pictureArea)
    }

    func testSeveralPassagesAreUnited() {
        let second = CGRect(x: 120, y: 440, width: 100, height: 10)
        let focus = LensPageFocus.pick(pageSize: page, passageRects: [tableRow, second])
        XCTAssertEqual(focus.region, tableRow.union(second))
    }

    func testTheFocusIsPaddedAndSquare() throws {
        let focus = LensPageFocus.pick(pageSize: page, pictureAreas: [pictured])
        let square = try XCTUnwrap(focus.square)
        XCTAssertEqual(square.width, square.height, accuracy: 0.001)
        XCTAssertTrue(square.contains(pictured))
        XCTAssertGreaterThan(square.width, pictured.width, "padded on every side")
        XCTAssertEqual(focus.center, CGPoint(x: pictured.midX, y: pictured.midY))
    }

    /// The opening step is the deepest one whose crop still holds the padded focus.
    func testTheOpeningStepIsTheDeepestTheFocusFitsAt() throws {
        let focus = LensPageFocus.pick(pageSize: page, pictureAreas: [pictured])
        let square = try XCTUnwrap(focus.square)
        let viewport = LensPageViewport(opening: focus)
        XCTAssertEqual(focus.zoom, .x2)
        XCTAssertGreaterThanOrEqual(viewport.cropSide, square.width)
        XCTAssertLessThan(LensPageViewport.cropSide(zoom: .x3, pageSize: page), square.width)
        XCTAssertTrue(viewport.cropRect.insetBy(dx: -0.001, dy: -0.001).contains(pictured))
    }

    /// A cited table row opens at a step its text reads at; a whole drawing opens whole.
    func testATableRowOpensReadableAndAWholeDrawingOpensAtFit() {
        let rowFocus = LensPageFocus.pick(pageSize: page, passageRects: [tableRow])
        let rowView = LensPageViewport(opening: rowFocus)
        XCTAssertEqual(rowFocus.zoom, .x4)
        let rowText = LensLegibility(lineRects: [tableRow])
        // The deepest step: the most the view can do for the row, so no hint asks for more. (A 10 pt
        // row draws about 19 px there in the 382 px picture P4 measured, under the 22 px estimate.)
        XCTAssertTrue(rowView.isDeepest)
        XCTAssertGreaterThan(rowText.estimatedPixels(at: rowView), rowText.estimatedPixels(
            at: LensPageViewport(pageSize: page, center: rowView.center, zoom: .x3)))
        XCTAssertFalse(rowText.needsZoomHint(at: rowView))

        let drawing = CGRect(x: 30, y: 40, width: 552, height: 700)
        let drawingFocus = LensPageFocus.pick(pageSize: page, figure: drawing)
        let drawingView = LensPageViewport(opening: drawingFocus)
        XCTAssertEqual(drawingFocus.zoom, .fit)
        XCTAssertTrue(drawingView.isWholePage)
        XCTAssertTrue(LensLegibility().needsZoomHint(at: drawingView), "a drawing's labels need zooming at fit")
    }

    func testPictureAreasAreTakenForTheirOwnPageOnly() {
        let areas = [
            ManualTable.PictureArea(physical: 7, rect: pictured),
            ManualTable.PictureArea(physical: 8, rect: figure),
        ]
        let onEight = LensPageFocus.pick(pageSize: page, marks: nil, pictureAreas: areas, physical: 8)
        XCTAssertEqual(onEight.source, .pictureArea)
        XCTAssertEqual(onEight.region, figure)
        let onNine = LensPageFocus.pick(pageSize: page, marks: nil, pictureAreas: areas, physical: 9)
        XCTAssertEqual(onNine.source, .wholePage)
    }

    func testLensMarksFeedTheFocus() {
        let marks = LensPageMarks(marks: [.init(number: 1, lineRects: [tableRow], bounds: tableRow)],
                                  showsNumbers: false)
        let focus = LensPageFocus.pick(pageSize: page, marks: marks,
                                       pictureAreas: [ManualTable.PictureArea(physical: 3, rect: pictured)],
                                       physical: 3)
        XCTAssertEqual(focus.source, .citedPassages)
        XCTAssertEqual(focus.region, tableRow)
    }
}
