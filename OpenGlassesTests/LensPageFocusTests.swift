import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — where the page view opens: the four sources in order, the padding, and the
/// magnification that fits the padded focus into the picture box exactly.
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
        XCTAssertNil(focus.padded)
        XCTAssertFalse(LensPageViewport(opening: focus).opensOnPart)
        XCTAssertTrue(LensPageViewport(opening: focus).isWholePage)
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

    func testTheFocusIsPadded() throws {
        let focus = LensPageFocus.pick(pageSize: page, pictureAreas: [pictured])
        let padded = try XCTUnwrap(focus.padded)
        XCTAssertTrue(padded.contains(pictured))
        XCTAssertGreaterThan(padded.width, pictured.width, "padded on every side")
        XCTAssertGreaterThan(padded.height, pictured.height)
        XCTAssertEqual(focus.center, CGPoint(x: pictured.midX, y: pictured.midY))
    }

    /// The opening magnification fits the padded focus exactly: no rounding to a step. A focus
    /// wider than the box's shape fills its width; a taller one fills its height.
    func testTheOpeningFitsThePaddedFocusExactly() throws {
        for box in [LensPageFrame.pictureBox(citation: true, hint: false),
                    LensPageFrame.pictureBox(citation: true, hint: true),
                    LensPageFrame.pictureBox(citation: false, hint: false)] {
            for region in [pictured, tableRow, CGRect(x: 300, y: 100, width: 120, height: 400)] {
                let focus = LensPageFocus.pick(pageSize: page, pictureAreas: [region])
                let padded = try XCTUnwrap(focus.padded)
                let viewport = LensPageViewport(opening: focus, box: box)
                let crop = viewport.cropRect
                XCTAssertTrue(crop.insetBy(dx: -0.01, dy: -0.01).contains(padded), "\(region) in \(box)")
                let fillsWidth = abs(crop.width - padded.width) < 0.01
                let fillsHeight = abs(crop.height - padded.height) < 0.01
                XCTAssertTrue(fillsWidth || fillsHeight, "fitted exactly: \(crop) for \(padded)")
                XCTAssertEqual(fillsWidth, padded.width / padded.height >= box.width / box.height - 0.0001)
            }
        }
    }

    /// A cited table row and a wide diagram open filling the picture box's width, the row at a size
    /// its text reads at.
    func testATableRowAndADiagramOpenFillingTheBoxsWidth() throws {
        let box = LensPageFrame.pictureBox(citation: true, hint: false)
        let rowFocus = LensPageFocus.pick(pageSize: page, passageRects: [tableRow])
        let rowView = LensPageViewport(opening: rowFocus, box: box)
        let rowPadded = try XCTUnwrap(rowFocus.padded)
        XCTAssertEqual(rowPadded.width * rowView.pixelsPerPoint, box.width, accuracy: 0.01, "the row fills the width")
        XCTAssertEqual(rowView.cropRect.minX, rowPadded.minX, accuracy: 0.01)
        let rowText = LensLegibility(lineRects: [tableRow])
        XCTAssertGreaterThanOrEqual(rowText.estimatedPixels(at: rowView), 22, "a 10 pt row reads at the opening")
        XCTAssertFalse(rowText.needsZoomHint(at: rowView))

        let diagram = CGRect(x: 60, y: 120, width: 480, height: 220)
        let diagramFocus = LensPageFocus.pick(pageSize: page, figure: diagram)
        let diagramView = LensPageViewport(opening: diagramFocus, box: box)
        let diagramPadded = try XCTUnwrap(diagramFocus.padded)
        XCTAssertEqual(diagramPadded.width * diagramView.pixelsPerPoint, box.width, accuracy: 0.01,
                       "the diagram fills the width")
        XCTAssertTrue(diagramView.cropRect.insetBy(dx: -0.01, dy: -0.01).contains(diagram))
        XCTAssertFalse(diagramView.isWholePage)
    }

    /// A drawing as large as the page opens on the whole page, whose labels need zooming.
    func testAWholeDrawingOpensOnTheWholePage() {
        let drawing = CGRect(x: 30, y: 40, width: 552, height: 700)
        let drawingFocus = LensPageFocus.pick(pageSize: page, figure: drawing)
        let drawingView = LensPageViewport(opening: drawingFocus)
        XCTAssertTrue(drawingView.isWholePage)
        XCTAssertFalse(drawingView.opensOnPart)
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
