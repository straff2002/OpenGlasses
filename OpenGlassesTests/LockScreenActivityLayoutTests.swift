import XCTest
@testable import OpenGlasses

/// The Lock Screen Live Activity's one row of buttons, held to the slot the system gives it.
///
/// The row used to be a 2 × 2 grid of 44 pt capsules under a header and a status line, and the
/// Lock Screen cut its bottom row off on a phone. These pin the replacement: one row, at most four,
/// Connect in a place of its own when disconnected, and a height that leaves margin in the slot at
/// the largest text size the presentation allows.
final class LockScreenActivityLayoutTests: XCTestCase {

    func testConnectedShowsUpToFourActionsInOneRow() {
        for available in 0...7 {
            let plan = LockScreenActivityLayout.plan(availableActions: available, isConnected: true)
            XCTAssertFalse(plan.showsConnect)
            XCTAssertEqual(plan.actionCount, min(available, 4))
            XCTAssertLessThanOrEqual(plan.buttonCount, LockScreenActivityLayout.maxButtons)
        }
    }

    /// Disconnected, Connect takes one of the four places rather than a row of its own — the same
    /// height in both states.
    func testDisconnectedConnectLeadsTheSameRow() {
        for available in 0...7 {
            let plan = LockScreenActivityLayout.plan(availableActions: available, isConnected: false)
            XCTAssertTrue(plan.showsConnect)
            XCTAssertEqual(plan.actionCount, min(available, 3))
            XCTAssertLessThanOrEqual(plan.buttonCount, LockScreenActivityLayout.maxButtons)
        }
    }

    func testOneOrTwoButtonsSitBesideTheirLabelsAndMoreStackThem() {
        XCTAssertEqual(LockScreenActivityLayout.plan(availableActions: 2, isConnected: true).style,
                       .glyphBesideLabel)
        XCTAssertEqual(LockScreenActivityLayout.plan(availableActions: 1, isConnected: false).style,
                       .glyphBesideLabel)
        XCTAssertEqual(LockScreenActivityLayout.plan(availableActions: 3, isConnected: true).style,
                       .glyphOverLabel)
        XCTAssertEqual(LockScreenActivityLayout.plan(availableActions: 4, isConnected: false).style,
                       .glyphOverLabel)
    }

    /// The slot is 160 pt. The line heights are the system fonts' at the default size and at
    /// xLarge, the presentation's cap: `.caption` (status), `.callout` glyph, `.caption2` caption.
    func testTheRowFitsTheSlotWithMarginUpToTheTextSizeCap() {
        let sizes: [(name: String, status: CGFloat, glyph: CGFloat, caption: CGFloat)] = [
            ("default", 16, 21, 13),
            ("xLarge", 19, 25, 16),
        ]
        for size in sizes {
            for style in [LockScreenActivityLayout.ButtonStyle.glyphOverLabel, .glyphBesideLabel] {
                let height = LockScreenActivityLayout.estimatedHeight(
                    statusLine: size.status, glyph: size.glyph, caption: size.caption, style: style)
                XCTAssertLessThanOrEqual(height, LockScreenActivityLayout.systemHeightLimit - 12,
                                         "\(size.name), \(style): \(height) pt leaves no margin")
            }
        }
    }

    /// Even an empty status line keeps every button a fingertip tall.
    func testButtonsStayATouchTargetTall() {
        let height = LockScreenActivityLayout.estimatedHeight(statusLine: 0, glyph: 10, caption: 8,
                                                              style: .glyphOverLabel)
        let chrome = LockScreenActivityLayout.outerPadding * 2
            + LockScreenActivityLayout.headerRowHeight + LockScreenActivityLayout.sectionSpacing
        XCTAssertGreaterThanOrEqual(height - chrome, LockScreenActivityLayout.minimumButtonHeight)
    }
}
