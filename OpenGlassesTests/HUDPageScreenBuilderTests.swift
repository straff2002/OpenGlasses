import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — the page view's lines and button rows (§3), by viewport state.
final class HUDPageScreenBuilderTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)
    private let citation = "Figure 12 · p. 30"

    private func zoomedOpening() -> LensPageViewport {
        LensPageViewport(pageSize: page, center: CGPoint(x: 300, y: 300), zoom: .x2)
    }

    private func state(_ viewport: LensPageViewport, moving: Bool = false, firstFrame: Bool = false,
                       nextPage: Bool = false, textHeight: CGFloat = 30) -> HUDPageViewState {
        HUDPageViewState(viewport: viewport, legibility: LensLegibility(textHeightPoints: textHeight),
                         isMoving: moving, isFirstFrame: firstFrame, citation: citation, hasNextPage: nextPage)
    }

    private func ids(_ state: HUDPageViewState) -> [String] {
        HUDPageScreenBuilder.screen(state) { _ in }.items.map(\.id)
    }

    func testTheZoomedOpeningView() {
        let screen = HUDPageScreenBuilder.screen(state(zoomedOpening())) { _ in }
        XCTAssertEqual(screen.items.map(\.id), [ID.zoomIn, ID.wholePage, ID.move, ID.close])
        XCTAssertEqual(screen.items.map(\.label), ["Zoom in", "Whole page", "Move", "Close"])
        XCTAssertEqual(screen.items.first?.style, .primary)
        XCTAssertEqual(screen.items.last?.style, .outline)
        XCTAssertNil(screen.title)
    }

    func testTheWholePageOffersBackToPartOnlyWhenTheViewOpenedOnOne() {
        var fromPart = zoomedOpening()
        fromPart.showWholePage()
        XCTAssertEqual(ids(state(fromPart)), [ID.zoomIn, ID.backToPart, ID.close])

        let noFocus = LensPageViewport(wholePage: page)
        XCTAssertEqual(ids(state(noFocus)), [ID.zoomIn, ID.close])
    }

    func testTheDeepestZoom() {
        var viewport = zoomedOpening()
        viewport.zoomIn()
        viewport.zoomIn()
        XCTAssertTrue(viewport.isDeepest)
        let screen = HUDPageScreenBuilder.screen(state(viewport)) { _ in }
        XCTAssertEqual(screen.items.map(\.id), [ID.zoomOut, ID.move, ID.close])
        XCTAssertEqual(screen.items.map(\.label), ["Zoom out", "Move", "Close"])
    }

    func testTheMoveRowIsFourArrowsAndDoneAtEveryEdge() {
        var viewport = zoomedOpening()
        for corner in LensPageViewport.Corner.allCases {
            viewport.jump(to: corner)
            let screen = HUDPageScreenBuilder.screen(state(viewport, moving: true, nextPage: true)) { _ in }
            XCTAssertEqual(screen.items.map(\.id), [ID.up, ID.down, ID.left, ID.right, ID.done], "\(corner)")
            XCTAssertEqual(screen.items.map(\.label), ["↑", "↓", "←", "→", "Done"])
        }
    }

    /// Next page shows on the opening view, and only when another page follows.
    func testNextPageOnlyWithSeveralPagesAndOnlyOnTheOpeningView() {
        XCTAssertEqual(ids(state(zoomedOpening(), nextPage: true)),
                       [ID.zoomIn, ID.wholePage, ID.nextPage, ID.close], "Move gives way: four at most (P4)")
        XCTAssertFalse(ids(state(zoomedOpening(), nextPage: false)).contains(ID.nextPage))
        XCTAssertEqual(ids(state(LensPageViewport(wholePage: page), nextPage: true)),
                       [ID.zoomIn, ID.nextPage, ID.close], "a whole-page opening view gets it too")

        var moved = zoomedOpening()
        moved.move(.down)
        XCTAssertFalse(ids(state(moved, nextPage: true)).contains(ID.nextPage))
        moved.reset()
        XCTAssertTrue(ids(state(moved, nextPage: true)).contains(ID.nextPage))
    }

    func testTheCitationShowsOnTheFirstFrameOnly() {
        let first = HUDPageScreenBuilder.lines(state(zoomedOpening(), firstFrame: true))
        XCTAssertEqual(first.map(\.text), [citation])
        XCTAssertEqual(first.first?.emphasis, .meta)
        XCTAssertTrue(HUDPageScreenBuilder.lines(state(zoomedOpening(), firstFrame: false)).isEmpty)
    }

    func testTheZoomHintFollowsLegibility() {
        let unreadable = HUDPageScreenBuilder.lines(state(LensPageViewport(wholePage: page), textHeight: 8))
        XCTAssertEqual(unreadable.map(\.text), ["Zoom in for labels"])
        let readable = HUDPageScreenBuilder.lines(state(zoomedOpening(), textHeight: 30))
        XCTAssertTrue(readable.isEmpty)
        let moving = HUDPageScreenBuilder.lines(state(LensPageViewport(wholePage: page), moving: true, textHeight: 8))
        XCTAssertTrue(moving.isEmpty, "no hint over the arrow row")
        let both = HUDPageScreenBuilder.lines(state(LensPageViewport(wholePage: page), firstFrame: true, textHeight: 8))
        XCTAssertEqual(both.map(\.text), [citation, "Zoom in for labels"])
    }

    func testEveryPressReportsItsAction() {
        var pressed: [HUDPageAction] = []
        let record: (HUDPageAction) -> Void = { pressed.append($0) }

        HUDPageScreenBuilder.screen(state(zoomedOpening(), nextPage: true), onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.zoomIn, .wholePage, .nextPage, .close])

        pressed = []
        HUDPageScreenBuilder.screen(state(zoomedOpening()), onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.zoomIn, .wholePage, .move, .close])

        pressed = []
        HUDPageScreenBuilder.screen(state(zoomedOpening(), moving: true), onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.step(.up), .step(.down), .step(.left), .step(.right), .doneMoving])

        pressed = []
        var whole = zoomedOpening()
        whole.showWholePage()
        HUDPageScreenBuilder.screen(state(whole), onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.zoomIn, .backToPart, .close])

        pressed = []
        var deepest = zoomedOpening()
        deepest.zoomIn()
        deepest.zoomIn()
        HUDPageScreenBuilder.screen(state(deepest), onAction: record).items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.zoomOut, .move, .close])
    }

    func testItemIdsAreStableAndPrefixed() {
        let all = [ID.zoomIn, ID.zoomOut, ID.wholePage, ID.backToPart, ID.move, ID.up, ID.down, ID.left,
                   ID.right, ID.done, ID.nextPage, ID.close]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.hasPrefix("kv.page.") })
    }

    /// P4: on the simulated Display a five-button row ran wider than the lens and DAT cut the labels
    /// short. No state gets more than four; Move gives way first, then Next diagram ›, never Close.
    func testNoRowHoldsMoreThanFourButtons() {
        var crowded = HUDPageViewState(viewport: zoomedOpening(), legibility: LensLegibility(), hasNextPage: true,
                                       diagramCount: 2, diagramIndex: 0)
        XCTAssertEqual(ids(crowded), [ID.zoomIn, ID.wholePage, ID.nextPage, ID.close])
        crowded.hasNextPage = false
        XCTAssertEqual(ids(crowded), [ID.zoomIn, ID.nextDiagram, ID.wholePage, ID.close])

        for zoom in LensPageViewport.Zoom.allCases {
            for nextPage in [false, true] {
                for diagrams in [0, 1, 3] {
                    for moving in [false, true] {
                        let viewport = LensPageViewport(pageSize: page, center: CGPoint(x: 306, y: 396), zoom: zoom)
                        let state = HUDPageViewState(viewport: viewport, legibility: LensLegibility(), isMoving: moving,
                                                     hasNextPage: nextPage, diagramCount: diagrams,
                                                     diagramIndex: diagrams > 0 ? 0 : nil)
                        let row = HUDPageScreenBuilder.items(state, { _ in })
                        if !moving {
                            XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons, "\(zoom) \(nextPage) \(diagrams)")
                            XCTAssertEqual(row.last?.id, ID.close)
                        }
                    }
                }
            }
        }
    }
}
