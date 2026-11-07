#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KV P1b on the glasses: **Next diagram ›** after Zoom in on the opening view of a page with
/// two drawings or more, cycling them in reading order; "next diagram" and "the bottom one" by
/// voice; the turn's words reaching the layout; and (the P1 fix) the view's opening frame waiting
/// for a notification that is showing instead of cutting it short.
///
/// Headless, as `LensPageSessionTests`: fresh services, frames through `testRenderSink`, band
/// presses through `testInteractiveButtonActions`, layouts and pictures from fakes.
@MainActor
final class LensPageDiagramTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID

    /// Two drawings small enough to open at ×2, in reading order.
    private static let upper = PageDrawing(rect: CGRect(x: 100, y: 80, width: 240, height: 160), labels: [], heading: nil)
    private static let lower = PageDrawing(rect: CGRect(x: 300, y: 450, width: 240, height: 160), labels: [], heading: nil)

    @MainActor
    private final class Box {
        var requests: [LensPageRequest] = []
        var frames: [GlassesDisplayService.HUDFrame] = []
        var audit: [LensPageAuditLine] = []
    }

    private struct Rig {
        let display: GlassesDisplayService
        let router: HUDRouter
        let session: LensPageSession
        let box: Box
    }

    private var savedDisplayEnabled = false
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.setGlassesDisplayEnabled(true)
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        try await super.tearDown()
    }

    private func makeRig(drawings: [PageDrawing] = [upper, lower], said: String? = "show me the diagram") -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        let box = Box()
        display.testRenderSink = { box.frames.append($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        session.sourceURL = { _ in URL(fileURLWithPath: "/invented/guide.pdf") }
        session.requestWords = { said }
        session.layoutPage = { request in
            box.requests.append(request)
            let choice = PageFigureChoice.choose(drawings, ask: request.ask)
            return LensPageLayout(pageSize: LensPageFixtures.letter, marks: nil, pictureAreas: [], tone: .lineArt,
                                  drawings: choice.drawings, figureIndex: choice.index,
                                  drawingFocus: request.ask.drawingFocus)
        }
        session.renderPicture = { _, _ in LensPageFixtures.picture() }
        session.scheduleTimer = { _, _ in }
        session.audit = { box.audit.append($0) }
        session.backend = { "metaRayBan" }
        return Rig(display: display, router: router, session: session, box: box)
    }

    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    private func press(_ rig: Rig, _ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let screen = rig.session.shownScreen,
              let index = screen.items.firstIndex(where: { $0.id == id }) else {
            XCTFail("no \(id) on the lens", file: file, line: line)
            return
        }
        rig.display.testInteractiveButtonActions(for: screen)[index]()
        await drain(rig)
    }

    private func itemIDs(_ rig: Rig) -> [String] { rig.session.shownScreen?.items.map(\.id) ?? [] }

    private var lastScreenKey: (Rig) -> String? {
        { rig in
            for frame in rig.box.frames.reversed() { if case .screen(let key) = frame { return key } }
            return nil
        }
    }

    // MARK: - Next diagram

    func testNextDiagramCyclesThePageDrawingsInReadingOrder() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)

        XCTAssertEqual(itemIDs(rig), [ID.zoomIn, ID.nextDiagram, ID.wholePage, ID.close],
                       "Next diagram › right after Zoom in; Move gives way to keep the row to four (P4)")
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 0)
        XCTAssertTrue(rig.session.shownState?.viewport.cropRect.contains(Self.upper.rect) == true,
                      "opened on the whole first drawing")

        await press(rig, ID.nextDiagram)
        let second = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(second.diagramIndex, 1)
        XCTAssertTrue(second.viewport.cropRect.contains(Self.lower.rect), "the whole next drawing")
        XCTAssertTrue(second.viewport.isAtOpening, "Back to part returns to this drawing now")
        XCTAssertTrue(itemIDs(rig).contains(ID.nextDiagram))

        await press(rig, ID.nextDiagram)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 0, "round to the first")
        XCTAssertEqual(rig.box.audit.map(\.event), [.opened, .moved, .moved])
        XCTAssertEqual(rig.session.stats["metaRayBan"].moves, 2)
    }

    func testAFollowUpAboutTheSamePageKeepsTheViewWorking() async {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        rig.session.requestWords = { "what does the invented fuse do" }
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertEqual(rig.box.requests.count, 1, "the same page is not laid out again")
        await press(rig, ID.nextDiagram)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 1, "the view's drawings are still known")
        await press(rig, ID.zoomIn)
        XCTAssertEqual(rig.box.audit.map(\.event), [.opened, .moved, .zoomed])
    }

    func testNoNextDiagramForAPageWithOneDrawingOrAwayFromTheOpening() async {
        let single = makeRig(drawings: [Self.upper])
        single.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(single)
        XCTAssertFalse(itemIDs(single).contains(ID.nextDiagram))

        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        await press(rig, ID.zoomIn)
        XCTAssertFalse(itemIDs(rig).contains(ID.nextDiagram), "only on the opening view")
    }

    func testTheDeepestOpeningPutsNextDiagramAfterZoomOut() {
        let page = LensPageFixtures.letter
        let viewport = LensPageViewport(pageSize: page, center: CGPoint(x: 200, y: 200), zoom: .deepest)
        let state = HUDPageViewState(viewport: viewport, legibility: LensLegibility(), diagramCount: 3, diagramIndex: 0)
        XCTAssertEqual(HUDPageScreenBuilder.items(state, { _ in }).map(\.id),
                       [ID.zoomOut, ID.nextDiagram, ID.move, ID.close])
    }

    // MARK: - Voice

    func testNextDiagramAndTheBottomOneByVoice() async {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)

        let next = await rig.router.handleVoiceCommand("next diagram")
        await drain(rig)
        XCTAssertTrue(next)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 1)

        let top = await rig.router.handleVoiceCommand("the top one")
        await drain(rig)
        XCTAssertTrue(top)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 0)

        let again = await rig.router.handleVoiceCommand("the top one")
        XCTAssertFalse(again, "already there: the words go on")

        let bottom = await rig.router.handleVoiceCommand("the one at the bottom")
        await drain(rig)
        XCTAssertTrue(bottom)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 1)
    }

    func testDiagramWordsParseStrictly() {
        XCTAssertEqual(HUDPageCommand.parse("next diagram"), .nextDiagram)
        XCTAssertEqual(HUDPageCommand.parse("OK the next drawing please"), .nextDiagram)
        XCTAssertEqual(HUDPageCommand.parse("the bottom one"), .diagram(.bottom))
        XCTAssertEqual(HUDPageCommand.parse("second diagram"), .diagram(.second))
        XCTAssertEqual(HUDPageCommand.parse("the one on the left"), .diagram(.left))
        XCTAssertEqual(HUDPageCommand.parse("left"), .move(.left), "a bare direction is still a move")
        XCTAssertEqual(HUDPageCommand.parse("top left"), .corner(.topLeft))
        XCTAssertNil(HUDPageCommand.parse("show me the bottom one on the blower wiring"))
    }

    // MARK: - The turn's words

    func testTheTurnsWordsReachTheLayout() async {
        let rig = makeRig(said: "show me the bottom diagram")
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertEqual(rig.box.requests.first?.ask.position, .bottom)
        XCTAssertEqual(rig.box.requests.first?.ask.asksForDrawing, true)
        XCTAssertEqual(rig.session.shownState?.diagramIndex, 1, "the bottom one opened")
        XCTAssertNotNil(rig.box.requests.first?.figureKey, "keyed for the analysis cache")
    }

    // MARK: - When the drawing is a focus

    func testARequestForThePageOpensItWholeWithNextDiagramOffered() async throws {
        let rig = makeRig(drawings: [Self.upper], said: "show me page 7")
        rig.session.stage([LensPageFixtures.staged(page: 7, origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)
        XCTAssertTrue(opening.viewport.isWholePage, "nothing cited, no drawing asked for: the whole page")
        XCTAssertNil(opening.diagramIndex)
        XCTAssertEqual(itemIDs(rig), [ID.zoomIn, ID.nextDiagram, ID.close],
                       "Next diagram › is there to jump to the page's one drawing")

        await press(rig, ID.nextDiagram)
        let onDrawing = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(onDrawing.diagramIndex, 0)
        XCTAssertTrue(onDrawing.viewport.cropRect.contains(Self.upper.rect))
        XCTAssertFalse(itemIDs(rig).contains(ID.nextDiagram), "one drawing, and the view is on it")
    }

    func testTheDiagramOnPageSevenOpensOnTheDrawing() async throws {
        let rig = makeRig(drawings: [Self.upper], said: "show me the diagram on page 7")
        rig.session.stage([LensPageFixtures.staged(page: 7, origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(opening.diagramIndex, 0)
        XCTAssertFalse(opening.viewport.isWholePage)
        XCTAssertTrue(opening.viewport.cropRect.contains(Self.upper.rect))
    }

    func testAnAutomaticPageForAFigureOpensOnTheDrawing() async throws {
        let rig = makeRig(drawings: [Self.upper], said: "what does the invented relay do")
        rig.session.stage([LensPageFixtures.staged(page: 7, figure: "Figure 9", origin: .automatic)])
        await drain(rig)
        XCTAssertEqual(rig.session.held, .cue, "the app's own page waits for Show here")
        await press(rig, ID.showHere)
        let opening = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(rig.box.requests.first?.ask.drawingFocus, .afterMarks)
        XCTAssertEqual(opening.diagramIndex, 0, "opened on the figure it was put up for")
        XCTAssertTrue(opening.viewport.cropRect.contains(Self.upper.rect))
    }

    // MARK: - The P1 fix: a notification that is showing is not cut short

    func testTheOpeningFrameWaitsForAShowingNotification() async throws {
        let rig = makeRig()
        rig.display.showNotification(title: nil, body: "Invented notice", icon: .info, duration: 0.3)
        await drain(rig)
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)

        XCTAssertEqual(rig.session.held, .view, "the view is open, under the notification")
        guard case .content(let body, _, _)? = rig.box.frames.last else {
            return XCTFail("the notification should still be the frame on the lens, got \(String(describing: rig.box.frames.last))")
        }
        XCTAssertEqual(body, "Invented notice")
        XCTAssertNil(lastScreenKey(rig), "no page frame went out over it")

        // A press under the notification is dropped, as any is.
        let opening = try XCTUnwrap(rig.session.shownState)
        await press(rig, ID.zoomIn)
        XCTAssertEqual(rig.session.shownState, opening)

        try await Task.sleep(nanoseconds: 800_000_000)
        await drain(rig)
        let key = try XCTUnwrap(lastScreenKey(rig), "the notification's end draws the view")
        XCTAssertTrue(key.contains("|pic:"))
        if case .content? = rig.box.frames.last { XCTFail("the view should be on the lens now") }

        await press(rig, ID.zoomIn)
        XCTAssertNotEqual(rig.session.shownState?.viewport.zoom, opening.viewport.zoom, "and presses work again")
    }

    func testWithNoNotificationTheViewOpensAtOnce() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertTrue(try XCTUnwrap(lastScreenKey(rig)).contains("|pic:"))
    }
}
#endif
