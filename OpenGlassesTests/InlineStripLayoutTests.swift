import XCTest
@testable import OpenGlasses

/// Plan MC: the shrunk strip's tap targets — easy to hit, edge to edge, with even borders.
final class InlineStripLayoutTests: XCTestCase {

    private let pill = CGSize(width: 280, height: 52)

    func testTwoControlsGetThePreferredWidthAndThePillsHeightLessTheBorder() {
        let layout = InlineStripLayout.make(pill: pill, count: 2)
        XCTAssertEqual(layout.targetSize.width, InlineStripLayout.preferredTargetWidth)
        XCTAssertEqual(layout.border, InlineStripLayout.preferredBorder)
        XCTAssertEqual(layout.targetSize.height, pill.height - 2 * layout.border)
    }

    func testTargetsAreBiggerThanTodaysFortyFourPointSquares() {
        let size = InlineStripLayout.make(pill: pill, count: 2).targetSize
        XCTAssertGreaterThan(size.width, 44)
        XCTAssertGreaterThanOrEqual(size.height, 44)
    }

    func testTargetsTouchWithNoGapBetweenThem() {
        let frames = InlineStripLayout.make(pill: pill, count: 2).frames(in: pill)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].maxX, frames[1].minX, accuracy: 0.001)
    }

    func testTheTrailingBorderEqualsTheBordersAboveAndBelow() {
        let layout = InlineStripLayout.make(pill: pill, count: 2)
        let last = layout.frames(in: pill).last!
        let trailing = pill.width - last.maxX
        let top = last.minY
        let bottom = pill.height - last.maxY
        XCTAssertEqual(trailing, top, accuracy: 0.001)
        XCTAssertEqual(top, bottom, accuracy: 0.001)
    }

    func testTheControlsKeepToTheTrailingEnd() {
        let layout = InlineStripLayout.make(pill: pill, count: 2)
        let first = layout.frames(in: pill).first!
        XCTAssertEqual(first.minX, pill.width - layout.occupiedWidth, accuracy: 0.001)
        XCTAssertGreaterThan(first.minX, pill.width / 2, "Two targets take well under half of a phone's pill")
    }

    func testTheMicAloneIsOneTargetOfTheSameSizeNotTheWholePill() {
        let alone = InlineStripLayout.make(pill: pill, count: 1)
        let pair = InlineStripLayout.make(pill: pill, count: 2)
        XCTAssertEqual(alone.targetSize, pair.targetSize)
        XCTAssertLessThan(alone.occupiedWidth, pill.width / 2)
    }

    func testAShortPillGivesUpItsBorderBeforeATargetGoesUnderTheFloor() {
        let short = CGSize(width: 280, height: 46)
        let layout = InlineStripLayout.make(pill: short, count: 2)
        XCTAssertEqual(layout.border, 1, accuracy: 0.001)
        XCTAssertEqual(layout.targetSize.height, 44, accuracy: 0.001)

        let tooShort = InlineStripLayout.make(pill: CGSize(width: 280, height: 40), count: 2)
        XCTAssertEqual(tooShort.border, 0)
        XCTAssertEqual(tooShort.targetSize.height, 44, "Never under the 44 pt floor, even if the pill is")
    }

    func testANarrowPillNarrowsTheTargetsDownToTheFloorButNoFurther() {
        let narrow = CGSize(width: 108, height: 52)
        let layout = InlineStripLayout.make(pill: narrow, count: 2)
        XCTAssertEqual(layout.targetSize.width, 50, accuracy: 0.001)
        let frames = layout.frames(in: narrow)
        XCTAssertGreaterThanOrEqual(frames.first!.minX, layout.border - 0.001,
                                    "The targets stay inside the pill's leading edge")

        let tiny = InlineStripLayout.make(pill: CGSize(width: 60, height: 50), count: 2)
        XCTAssertEqual(tiny.targetSize.width, 44)
    }

    func testThreeControlsWithTheKeyboardStillFitAPhonesPillAtFullWidth() {
        let layout = InlineStripLayout.make(pill: pill, count: 3)
        XCTAssertEqual(layout.targetSize.width, InlineStripLayout.preferredTargetWidth)
        let frames = layout.frames(in: pill)
        XCTAssertEqual(frames[1].maxX, frames[2].minX, accuracy: 0.001)
        XCTAssertGreaterThan(frames[0].minX, 0)
    }

    func testNoControlsTakeNoRoom() {
        let layout = InlineStripLayout.make(pill: pill, count: 0)
        XCTAssertTrue(layout.frames(in: pill).isEmpty)
        XCTAssertEqual(layout.occupiedWidth, layout.border)
    }

    func testTheUnmeasuredPillGivesTheSameLayoutAsAPhonesPill() {
        let unmeasured = InlineStripLayout.make(pill: InlineStripLayout.unmeasuredPill, count: 2)
        XCTAssertEqual(unmeasured.targetSize.width, InlineStripLayout.preferredTargetWidth)
        XCTAssertGreaterThanOrEqual(unmeasured.targetSize.height, 44)
    }
}
