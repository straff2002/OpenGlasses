import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P1b — the pure locator on hand-built ink masks: blocks found from ink alone, text never
/// counted, gaps closed, rule lines, borders, grids and logos dropped, reading order kept, and
/// each drawing's labels and heading kept for choosing.
final class PageFigureLocatorTests: XCTestCase {

    /// A letter page at the default 4 pt cell.
    private let page = CGSize(width: 612, height: 792)
    private var cell: CGFloat { PageFigureLocator.defaultCellSize }

    private func mask(_ build: (inout PageInkMask) -> Void) -> PageInkMask {
        var mask = PageInkMask(pageSize: page, cellSize: cell)
        build(&mask)
        return mask
    }

    /// A box outline, a stroke `width` points wide.
    private func box(_ rect: CGRect, width: CGFloat = 2, into mask: inout PageInkMask) {
        mask.ink(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width))
        mask.ink(CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width))
        mask.ink(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
        mask.ink(CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
    }

    /// Three boxes joined by a wire: a small block diagram filling `rect`.
    private func diagram(_ rect: CGRect, into mask: inout PageInkMask) {
        let w = rect.width * 0.3, h = rect.height * 0.4
        box(CGRect(x: rect.minX, y: rect.minY, width: w, height: h), into: &mask)
        box(CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: h), into: &mask)
        box(CGRect(x: rect.midX - w / 2, y: rect.maxY - h, width: w, height: h), into: &mask)
        mask.ink(CGRect(x: rect.minX + w, y: rect.minY + h / 2, width: rect.width - 2 * w, height: 2))
        mask.ink(CGRect(x: rect.midX, y: rect.minY + h / 2, width: 2, height: rect.height - h * 1.5))
    }

    private func assertNear(_ found: CGRect, _ expected: CGRect, tolerance: CGFloat = 4,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.minX, expected.minX, accuracy: tolerance, "minX", file: file, line: line)
        XCTAssertEqual(found.minY, expected.minY, accuracy: tolerance, "minY", file: file, line: line)
        XCTAssertEqual(found.maxX, expected.maxX, accuracy: tolerance, "maxX", file: file, line: line)
        XCTAssertEqual(found.maxY, expected.maxY, accuracy: tolerance, "maxY", file: file, line: line)
    }

    // MARK: - Finding

    func testABlockDiagramIsFoundFromItsInkAlone() {
        let rect = CGRect(x: 120, y: 200, width: 300, height: 200)
        let drawings = PageFigureLocator.locate(mask: mask { diagram(rect, into: &$0) }, textLines: [])
        XCTAssertEqual(drawings.count, 1)
        assertNear(drawings[0].rect, rect)
        XCTAssertTrue(drawings[0].labels.isEmpty)
        XCTAssertNil(drawings[0].heading, "no caption, no title, nothing above it, and still found")
    }

    func testTextIsNeverInk() {
        // Paragraphs as solid ink, exactly where their lines are: all of it is blanked.
        let lines = (0..<30).map { PageTextLine(rect: CGRect(x: 72, y: 60 + CGFloat($0) * 14, width: 468, height: 11),
                                                text: "Invented line \($0)") }
        let inked = mask { m in lines.forEach { m.ink($0.rect) } }
        XCTAssertGreaterThan(inked.inkedCount, 1000)
        XCTAssertEqual(PageFigureLocator.locate(mask: inked, textLines: lines), [])
    }

    func testALabelBlankedOutOfAWireDoesNotSplitTheDrawing() {
        let rect = CGRect(x: 100, y: 300, width: 400, height: 160)
        // A label sits across the wire down to the lower box, so blanking it cuts the wire.
        let label = PageTextLine(rect: CGRect(x: 280, y: 360, width: 40, height: 6), text: "blower")
        let drawings = PageFigureLocator.locate(mask: mask { m in
            diagram(rect, into: &m)
            m.ink(label.rect)
        }, textLines: [label])
        XCTAssertEqual(drawings.count, 1, "the gap is closed")
        assertNear(drawings[0].rect, rect)
        XCTAssertEqual(drawings[0].labels.map(\.text), ["blower"], "the label is kept for choosing")
    }

    func testTwoDrawingsFarApartStayApartInReadingOrder() {
        let upperRight = CGRect(x: 340, y: 80, width: 200, height: 160)
        let upperLeft = CGRect(x: 72, y: 90, width: 200, height: 150)
        let lower = CGRect(x: 100, y: 420, width: 380, height: 200)
        let drawings = PageFigureLocator.locate(mask: mask { m in
            diagram(lower, into: &m)
            diagram(upperRight, into: &m)
            diagram(upperLeft, into: &m)
        }, textLines: [])
        XCTAssertEqual(drawings.count, 3)
        assertNear(drawings[0].rect, upperLeft)
        assertNear(drawings[1].rect, upperRight)
        assertNear(drawings[2].rect, lower)
    }

    func testPiecesInsideAFrameAreOneDrawing() {
        let frame = CGRect(x: 80, y: 100, width: 420, height: 300)
        let drawings = PageFigureLocator.locate(mask: mask { m in
            box(frame, into: &m)
            diagram(frame.insetBy(dx: 60, dy: 60), into: &m)
            m.ink(CGRect(x: 120, y: 140, width: 30, height: 30))
        }, textLines: [])
        XCTAssertEqual(drawings.count, 1)
        assertNear(drawings[0].rect, frame)
    }

    func testASolidPictureIsKept() {
        let photo = CGRect(x: 152, y: 152, width: 240, height: 180)
        let drawings = PageFigureLocator.locate(mask: mask { $0.ink(photo) }, textLines: [])
        XCTAssertEqual(drawings.map(\.rect), [photo], "dense, so not a border")
    }

    // MARK: - Dropping

    func testAThinRuleLineIsDropped() {
        XCTAssertEqual(PageFigureLocator.locate(mask: mask { $0.ink(CGRect(x: 72, y: 400, width: 468, height: 2)) },
                                                textLines: []), [])
        XCTAssertEqual(PageFigureLocator.locate(mask: mask { $0.ink(CGRect(x: 300, y: 72, width: 3, height: 600)) },
                                                textLines: []), [], "a vertical rule too")
    }

    func testATableBorderAloneIsDropped() {
        let border = CGRect(x: 72, y: 200, width: 468, height: 300)
        let rows = (0..<10).map { PageTextLine(rect: CGRect(x: 90, y: 214 + CGFloat($0) * 27, width: 200, height: 10),
                                               text: "Invented row \($0)") }
        let drawings = PageFigureLocator.locate(mask: mask { m in
            box(border, into: &m)
            rows.forEach { m.ink($0.rect) }
        }, textLines: rows)
        XCTAssertEqual(drawings, [])
    }

    func testARuledGridTableIsDropped() {
        let table = CGRect(x: 72, y: 200, width: 468, height: 300)
        let drawings = PageFigureLocator.locate(mask: mask { m in
            box(table, into: &m)
            for row in 1..<6 { m.ink(CGRect(x: table.minX, y: table.minY + CGFloat(row) * 50, width: table.width, height: 2)) }
            for column in 1..<3 { m.ink(CGRect(x: table.minX + CGFloat(column) * 156, y: table.minY, width: 2, height: table.height)) }
        }, textLines: [])
        XCTAssertEqual(drawings, [], "lines that run right across, and nothing else")
    }

    func testALogoIsDropped() {
        let drawings = PageFigureLocator.locate(mask: mask { m in
            box(CGRect(x: 500, y: 30, width: 60, height: 40), into: &m)
            m.ink(CGRect(x: 515, y: 40, width: 30, height: 20))
        }, textLines: [])
        XCTAssertEqual(drawings, [], "under a square inch")
    }

    // MARK: - Labels and heading

    func testLabelsAreTheLinesInsideAndTheHeadingIsTheNearestLineAbove() {
        let rect = CGRect(x: 100, y: 300, width: 400, height: 200)
        let heading = PageTextLine(rect: CGRect(x: 100, y: 280, width: 160, height: 10), text: "Invented layout")
        let further = PageTextLine(rect: CGRect(x: 100, y: 200, width: 200, height: 10), text: "Invented far line")
        let inside = PageTextLine(rect: CGRect(x: 130, y: 330, width: 40, height: 8), text: "blower")
        let below = PageTextLine(rect: CGRect(x: 100, y: 520, width: 200, height: 10), text: "Invented note")
        let drawings = PageFigureLocator.locate(mask: mask { diagram(rect, into: &$0) },
                                                textLines: [further, heading, inside, below])
        XCTAssertEqual(drawings.count, 1)
        XCTAssertEqual(drawings[0].labels, [inside])
        XCTAssertEqual(drawings[0].heading, heading)
    }

    // MARK: - The mask

    func testTheMaskFromLumaInksDarkCellsOnly() {
        // A 16 × 8 pixel page of 16 × 8 points: one dark pixel at (5, 1), one mid-grey at (12, 6).
        var luma = [UInt8](repeating: 255, count: 16 * 8)
        luma[1 * 16 + 5] = 20
        luma[6 * 16 + 12] = 230
        let mask = PageInkMask(luma: luma, width: 16, height: 8, pageSize: CGSize(width: 16, height: 8),
                               cellSize: 4, threshold: PageFigureAnalysis.inkThreshold)
        XCTAssertEqual(mask.columns, 4)
        XCTAssertEqual(mask.rows, 2)
        XCTAssertTrue(mask[1, 0])
        XCTAssertEqual(mask.inkedCount, 1, "light grey is paper")
    }
}
