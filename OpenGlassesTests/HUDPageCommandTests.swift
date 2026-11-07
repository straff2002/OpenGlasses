import XCTest
@testable import OpenGlasses

/// Plan KV P0 — the page view's words, and what isn't one.
final class HUDPageCommandTests: XCTestCase {

    func testTheZoomWords() {
        XCTAssertEqual(HUDPageCommand.parse("zoom in"), .zoomIn)
        XCTAssertEqual(HUDPageCommand.parse("Closer"), .zoomIn)
        XCTAssertEqual(HUDPageCommand.parse("zoom out"), .zoomOut)
        XCTAssertEqual(HUDPageCommand.parse("whole page"), .wholePage)
        XCTAssertEqual(HUDPageCommand.parse("Show the whole page."), .wholePage)
    }

    func testTheMoveWords() {
        XCTAssertEqual(HUDPageCommand.parse("up"), .move(.up))
        XCTAssertEqual(HUDPageCommand.parse("Down."), .move(.down))
        XCTAssertEqual(HUDPageCommand.parse("left"), .move(.left))
        XCTAssertEqual(HUDPageCommand.parse("move right"), .move(.right))
    }

    func testTheCorners() {
        XCTAssertEqual(HUDPageCommand.parse("top left"), .corner(.topLeft))
        XCTAssertEqual(HUDPageCommand.parse("Top right"), .corner(.topRight))
        XCTAssertEqual(HUDPageCommand.parse("bottom left corner"), .corner(.bottomLeft))
        XCTAssertEqual(HUDPageCommand.parse("the bottom right"), .corner(.bottomRight))
    }

    func testPagingAndClosing() {
        XCTAssertEqual(HUDPageCommand.parse("next page"), .nextPage)
        XCTAssertEqual(HUDPageCommand.parse("back"), .back)
        XCTAssertEqual(HUDPageCommand.parse("go back"), .back)
        XCTAssertEqual(HUDPageCommand.parse("close the page"), .close)
        XCTAssertEqual(HUDPageCommand.parse("close"), .close)
    }

    func testFillerIsTolerated() {
        XCTAssertEqual(HUDPageCommand.parse("ok, zoom in"), .zoomIn)
        XCTAssertEqual(HUDPageCommand.parse("um, next page please"), .nextPage)
        XCTAssertEqual(HUDPageCommand.parse("Hey, top left!"), .corner(.topLeft))
    }

    /// Anything longer is an ordinary request: "next", "up" or "zoom in" inside a sentence is not a command.
    func testWordsInsideASentenceAreNotCommands() {
        XCTAssertNil(HUDPageCommand.parse("zoom in on the wiring"))
        XCTAssertNil(HUDPageCommand.parse("what's on the next page"))
        XCTAssertNil(HUDPageCommand.parse("go to the next page of the manual"))
        XCTAssertNil(HUDPageCommand.parse("what is next"))
        XCTAssertNil(HUDPageCommand.parse("next"))
        XCTAssertNil(HUDPageCommand.parse("is the top left terminal live"))
        XCTAssertNil(HUDPageCommand.parse("turn it up"))
        XCTAssertNil(HUDPageCommand.parse("close the valve"))
        XCTAssertNil(HUDPageCommand.parse(""))
    }
}
