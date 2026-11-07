import CoreGraphics
import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — passage marks as numbered rectangles for the lens, through `PageTextGeometry`,
/// with a fake in tests and PDFKit's selection bounds behind the real one.
final class LensPageMarksTests: XCTestCase {

    /// Hands back canned line rectangles per range location.
    private struct FakeGeometry: PageTextGeometry {
        let pageSize = CGSize(width: 612, height: 792)
        let lines: [Int: [CGRect]]
        func lineRects(for range: NSRange) -> [CGRect] { lines[range.location] ?? [] }
    }

    private func mark(_ number: Int, _ ranges: [NSRange]) -> PassageMarks.Mark {
        .init(number: number, location: .located(ranges: ranges, dropped: 0))
    }

    func testLocatedMarksBecomeNumberedRectangles() throws {
        let geometry = FakeGeometry(lines: [
            0: [CGRect(x: 50, y: 100, width: 200, height: 10), CGRect(x: 50, y: 112, width: 120, height: 10)],
            40: [CGRect(x: 60, y: 300, width: 80, height: 12)],
        ])
        let marks = LensPageMarks(PassageMarks(marks: [
            mark(1, [NSRange(location: 0, length: 30)]),
            mark(2, [NSRange(location: 40, length: 10)]),
        ]), geometry: geometry)

        XCTAssertEqual(marks.marks.map(\.number), [1, 2])
        XCTAssertTrue(marks.showsNumbers)
        XCTAssertEqual(marks.marks[0].lineRects.count, 2)
        XCTAssertEqual(marks.marks[0].bounds, CGRect(x: 50, y: 100, width: 200, height: 22))
        XCTAssertEqual(marks.lineRects.count, 3)
        let bounds = try XCTUnwrap(marks.bounds)
        XCTAssertEqual(bounds, CGRect(x: 50, y: 100, width: 200, height: 212))
    }

    func testUnlocatedOrUnplacedMarksAreLeftOut() {
        let geometry = FakeGeometry(lines: [0: [CGRect(x: 10, y: 10, width: 40, height: 9)]])
        let marks = LensPageMarks(PassageMarks(marks: [
            mark(1, [NSRange(location: 0, length: 5)]),
            .init(number: 2, location: .notLocatable(.notFound)),
            mark(3, [NSRange(location: 99, length: 5)]),
        ]), geometry: geometry)
        XCTAssertEqual(marks.marks.map(\.number), [1])
        XCTAssertTrue(marks.showsNumbers, "numbered as the phone numbers them: the page cites three")
    }

    func testOnePassageIsNotNumbered() {
        let geometry = FakeGeometry(lines: [0: [CGRect(x: 10, y: 10, width: 40, height: 9)]])
        let marks = LensPageMarks(PassageMarks(marks: [mark(1, [NSRange(location: 0, length: 5)])]),
                                  geometry: geometry)
        XCTAssertFalse(marks.showsNumbers)
        XCTAssertFalse(marks.isEmpty)
    }

    func testNoMarksHaveNoBounds() {
        let marks = LensPageMarks(PassageMarks(marks: []), geometry: FakeGeometry(lines: [:]))
        XCTAssertTrue(marks.isEmpty)
        XCTAssertNil(marks.bounds)
    }

    func testPDFSpaceIsTurnedTopDown() {
        let mediaBox = CGRect(x: 10, y: 20, width: 600, height: 800)
        let pdf = CGRect(x: 110, y: 720, width: 50, height: 10)
        XCTAssertEqual(PDFKitPageTextGeometry.topDown(pdf, mediaBox: mediaBox),
                       CGRect(x: 100, y: 90, width: 50, height: 10))
        XCTAssertEqual(PictureRegion.pdfRect(ofPageRect: PDFKitPageTextGeometry.topDown(pdf, mediaBox: mediaBox),
                                             mediaBox: mediaBox), pdf, "the inverse of the outline's conversion")
    }

    /// A small invented PDF drawn here: PDFKit finds a word's line, in top-down page points near
    /// where it was drawn.
    func testPDFKitGeometryReturnsALineForARange() throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
            ("Zorbex flange 42 torque" as NSString).draw(at: CGPoint(x: 72, y: 100), withAttributes: attributes)
            ("Quillet spacer 7" as NSString).draw(at: CGPoint(x: 72, y: 500), withAttributes: attributes)
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let geometry = PDFKitPageTextGeometry(page: page)
        XCTAssertEqual(geometry.pageSize, bounds.size)

        let flange = text.range(of: "flange")
        XCTAssertNotEqual(flange.location, NSNotFound)
        let rects = geometry.lineRects(for: flange)
        let rect = try XCTUnwrap(rects.first)
        XCTAssertFalse(rect.isEmpty)
        XCTAssertTrue(bounds.contains(rect))
        XCTAssertEqual(rect.minY, 100, accuracy: 12, "top-down: near where the line was drawn")
        XCTAssertGreaterThan(rect.minX, 72)

        let spacer = geometry.lineRects(for: text.range(of: "spacer"))
        XCTAssertEqual(try XCTUnwrap(spacer.first).minY, 500, accuracy: 12)

        XCTAssertTrue(geometry.lineRects(for: NSRange(location: text.length + 5, length: 3)).isEmpty)
        XCTAssertTrue(geometry.lineRects(for: NSRange(location: NSNotFound, length: 0)).isEmpty)
    }
}
