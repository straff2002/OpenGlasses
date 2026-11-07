import CoreGraphics
import XCTest
@testable import OpenGlasses

/// Plan KV P0 — the page view's lines and button rows (§3), by viewport state.
final class HUDPageScreenBuilderTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID

    /// An invented portrait page, 612 × 792 points.
    private let page = CGSize(width: 612, height: 792)
    private let citation = "Figure 12 · p. 30"

    /// A view opened on a part of the page, two presses short of the cap (2 → 3 → 4.125 px/pt).
    private func zoomedOpening() -> LensPageViewport {
        LensPageViewport(pageSize: page, center: CGPoint(x: 300, y: 300), pixelsPerPoint: 2)
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
                   ID.right, ID.done, ID.nextPage, ID.nextDiagram, ID.close, ID.showHere, ID.nextText,
                   ID.previousText, ID.showPicture, ID.readIt]
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

        for zoom in [nil, 1, 2, 4.125] as [CGFloat?] {
            for nextPage in [false, true] {
                for diagrams in [0, 1, 3] {
                    for moving in [false, true] {
                        for reading in [false, true] {
                            let viewport = LensPageViewport(pageSize: page, center: CGPoint(x: 306, y: 396),
                                                            pixelsPerPoint: zoom)
                            var state = HUDPageViewState(viewport: viewport, legibility: LensLegibility(), isMoving: moving,
                                                         hasNextPage: nextPage, diagramCount: diagrams,
                                                         diagramIndex: diagrams > 0 ? 0 : nil)
                            if reading { state.readingPages = readingPages(3) }
                            let row = HUDPageScreenBuilder.items(state, { _ in })
                            if !moving {
                                XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons,
                                                         "\(String(describing: zoom)) \(nextPage) \(diagrams) \(reading)")
                                XCTAssertEqual(row.last?.id, ID.close)
                                XCTAssertEqual(row.contains { $0.id == ID.readIt }, reading, "Read it never gives way")
                            }
                        }
                    }
                }
            }
        }
        for index in 0..<3 {
            for nextPage in [false, true] {
                var state = HUDPageViewState(viewport: zoomedOpening(), legibility: LensLegibility(),
                                             hasNextPage: nextPage)
                state.readingPages = readingPages(3)
                state.readingIndex = index
                state.isReading = true
                let row = HUDPageScreenBuilder.items(state, { _ in })
                XCTAssertLessThanOrEqual(row.count, HUDPageScreenBuilder.maxButtons)
                XCTAssertEqual(row.last?.id, ID.close)
            }
        }
    }

    // MARK: - Reading mode

    /// `count` invented reading pages of the Display's geometry.
    private func readingPages(_ count: Int) -> [HUDAnswerPage] {
        let words = (1...(count * 3)).map { "Invented step \($0) of the purge on the board." }.joined(separator: " ")
        let pages = HUDAnswerPager.pages(for: words, geometry: .raybanDisplay, maxPages: count,
                                         firstPageReservedLines: 1)
        XCTAssertEqual(pages.count, count)
        return pages
    }

    private func reading(_ index: Int, of count: Int, nextPage: Bool = false) -> HUDPageViewState {
        var state = HUDPageViewState(viewport: zoomedOpening(), legibility: LensLegibility(),
                                     citation: citation, hasNextPage: nextPage)
        state.readingPages = readingPages(count)
        state.readingIndex = index
        state.isReading = true
        return state
    }

    /// Reading mode: Next › while pages remain, Page, ‹ Back after the first page, Close.
    func testTheReadingRows() {
        XCTAssertEqual(ids(reading(0, of: 3)), [ID.nextText, ID.showPicture, ID.close])
        XCTAssertEqual(ids(reading(1, of: 3)), [ID.nextText, ID.showPicture, ID.previousText, ID.close])
        XCTAssertEqual(ids(reading(2, of: 3)), [ID.showPicture, ID.previousText, ID.close])
        XCTAssertEqual(ids(reading(2, of: 3, nextPage: true)),
                       [ID.showPicture, ID.previousText, ID.nextPage, ID.close])
        let screen = HUDPageScreenBuilder.screen(reading(0, of: 3)) { _ in }
        XCTAssertEqual(screen.items.map(\.label), ["Next ›", "Page", "Close"])

        var pressed: [HUDPageAction] = []
        HUDPageScreenBuilder.screen(reading(1, of: 3)) { pressed.append($0) }.items.forEach { $0.action() }
        XCTAssertEqual(pressed, [.nextText, .showPicture, .previousText, .close])
    }

    /// The citation over the first reading page only, the page's lines, and its "1/3" footer.
    func testTheReadingLines() {
        let first = HUDPageScreenBuilder.lines(reading(0, of: 3))
        let pages = readingPages(3)
        XCTAssertEqual(first.map(\.text), [citation] + pages[0].lines + ["1/3"])
        XCTAssertEqual(first.first?.emphasis, .meta)
        XCTAssertEqual(first.last?.emphasis, .meta)
        XCTAssertTrue(first.dropFirst().dropLast().allSatisfy { $0.emphasis == .primary })
        let second = HUDPageScreenBuilder.lines(reading(1, of: 3))
        XCTAssertEqual(second.map(\.text), pages[1].lines + ["2/3"], "no citation after the first page")
        XCTAssertFalse(second.contains { $0.text == "Zoom in for labels" })
        XCTAssertLessThanOrEqual(first.count, TeleprompterPaginator.Geometry.raybanDisplay.maxLines)
    }

    /// The picture of a page with words to read offers Read it, second, on every row.
    func testThePictureOfAPassageOffersReadIt() {
        var state = HUDPageViewState(viewport: zoomedOpening(), legibility: LensLegibility(textHeightPoints: 30))
        state.readingPages = readingPages(2)
        XCTAssertEqual(ids(state), [ID.zoomIn, ID.readIt, ID.wholePage, ID.close],
                       "Move gives way to keep four")
        state.viewport.showWholePage()
        XCTAssertEqual(ids(state), [ID.zoomIn, ID.readIt, ID.backToPart, ID.close])
        state.viewport.reset()
        state.viewport.zoomIn()
        state.viewport.zoomIn()
        XCTAssertEqual(ids(state), [ID.zoomOut, ID.readIt, ID.move, ID.close])
        state.isMoving = true
        XCTAssertFalse(ids(state).contains(ID.readIt), "not on the arrow row")
    }
}
