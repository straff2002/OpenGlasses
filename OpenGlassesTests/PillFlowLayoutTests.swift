import XCTest
@testable import OpenGlasses

/// The session card's pill row: one line while the pills fit, a new line only for the pill that
/// does not, and never a pill dropped or split across lines.
final class PillFlowLayoutTests: XCTestCase {

    func testPillsThatFitShareOneLine() {
        XCTAssertEqual(PillFlowLayout.lines(widths: [120, 110], maxWidth: 330, spacing: 6), [[0, 1]])
    }

    func testThePillThatDoesNotFitStartsTheNextLine() {
        // Mode, wake word, glasses: 120 + 6 + 110 = 236, + 6 + 130 = 372 > 330.
        XCTAssertEqual(PillFlowLayout.lines(widths: [120, 110, 130], maxWidth: 330, spacing: 6),
                       [[0, 1], [2]])
    }

    func testSpacingCountsTowardsTheFit() {
        XCTAssertEqual(PillFlowLayout.lines(widths: [100, 100], maxWidth: 200, spacing: 6), [[0], [1]])
        XCTAssertEqual(PillFlowLayout.lines(widths: [97, 97], maxWidth: 200, spacing: 6), [[0, 1]])
    }

    /// At accessibility sizes a pill can be wider than the row on its own: it still gets a line
    /// (it is offered the row's width and wraps inside itself), and it is never dropped.
    func testAPillWiderThanTheRowTakesALineOfItsOwn() {
        XCTAssertEqual(PillFlowLayout.lines(widths: [400, 60, 500], maxWidth: 330, spacing: 6),
                       [[0], [1], [2]])
    }

    func testNoPillsNoLines() {
        XCTAssertEqual(PillFlowLayout.lines(widths: [], maxWidth: 330, spacing: 6), [])
    }

    func testEveryPillIsPlacedOnceInOrder() {
        let widths: [CGFloat] = [80, 140, 60, 200, 30, 90]
        let lines = PillFlowLayout.lines(widths: widths, maxWidth: 250, spacing: 8)
        XCTAssertEqual(lines.flatMap { $0 }, Array(widths.indices))
    }
}
