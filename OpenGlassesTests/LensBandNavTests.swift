import XCTest
@testable import OpenGlasses

/// Plan MU §7 (P6) — the band's left and right on the page view, headless: which inputs are
/// swipes (`LensBandNav`), what each view does with them (`LensBandNavMap`), one send at a time
/// (`LensBandNavGate`), and the page view wired through the display's seams. Only a flagged build
/// hears the band; the mapping is compiled and tested in every build. Every page here is invented.
@MainActor
final class LensBandNavTests: XCTestCase {

    private typealias Map = LensBandNavMap
    private typealias Context = LensBandNavMap.Context

    // MARK: - Which inputs are swipes

    func testOnlyLeftAndRightAreSwipesAndUpDownAndBackAreNeverTaken() {
        XCTAssertEqual(LensBandNav(.nav(.left)), .left)
        XCTAssertEqual(LensBandNav(.nav(.right)), .right)
        let never: [GlassesInputKind] = [.nav(.up), .nav(.down), .back, .select, .actionButton,
                                         .capture(.shortPress), .capture(.hold), .capture(.doublePress),
                                         .drag(.down), .drag(.move), .drag(.up), .unknown]
        for kind in never { XCTAssertNil(LensBandNav(kind), kind.reportToken) }
    }

    // MARK: - Each view

    private let halves = Context(view: .closeUp, closeUpKind: .part, hasHalves: true)

    func testACloseUpsHalves() {
        XCTAssertEqual(Map.action(for: .right, in: halves), .rightHalf, "as it opens: right jumps to the right half")
        XCTAssertNil(Map.action(for: .left, in: halves), "as it opens the strip starts at the left half: nothing to do")

        var right = halves
        right.only = .right
        XCTAssertEqual(Map.action(for: .left, in: right), .leftHalf, "back to both halves, from the left")
        XCTAssertNil(Map.action(for: .right, in: right), "the right half is the edge: no wrap")

        var left = halves
        left.only = .left
        XCTAssertEqual(Map.action(for: .right, in: left), .rightHalf)
        XCTAssertNil(Map.action(for: .left, in: left), "the left half is the edge")
    }

    func testACloseUpInOneColumnMapsNothing() {
        let one = Context(view: .closeUp, closeUpKind: .part, hasHalves: false, pageIndex: 0, pageCount: 3)
        for nav in LensBandNav.allCases { XCTAssertNil(Map.action(for: nav, in: one), nav.rawValue) }
    }

    func testFitWidthTurnsThePageWithNoWrap() {
        let middle = Context(view: .closeUp, closeUpKind: .fitWidth, pageIndex: 1, pageCount: 3)
        XCTAssertEqual(Map.action(for: .left, in: middle), .previousPage)
        XCTAssertEqual(Map.action(for: .right, in: middle), .nextPage)

        let first = Context(view: .closeUp, closeUpKind: .fitWidth, pageIndex: 0, pageCount: 3)
        XCTAssertNil(Map.action(for: .left, in: first), "the first page: nothing before it")
        XCTAssertEqual(Map.action(for: .right, in: first), .nextPage)

        let last = Context(view: .closeUp, closeUpKind: .fitWidth, pageIndex: 2, pageCount: 3)
        XCTAssertEqual(Map.action(for: .left, in: last), .previousPage)
        XCTAssertNil(Map.action(for: .right, in: last), "the last page: nothing after it, no wrap")

        let alone = Context(view: .closeUp, closeUpKind: .fitWidth, pageIndex: 0, pageCount: 1)
        for nav in LensBandNav.allCases { XCTAssertNil(Map.action(for: nav, in: alone), nav.rawValue) }
    }

    func testTheWholePageRowsAndReadingMapNothing() {
        for view in [HUDPageViewState.View.whole, .rows, .reading] {
            let context = Context(view: view, pageIndex: 1, pageCount: 3, canPanLeft: true, canPanRight: true)
            for nav in LensBandNav.allCases { XCTAssertNil(Map.action(for: nav, in: context), "\(view) \(nav)") }
        }
    }

    /// Plan NB §1: a spoken zoom pans half a crop left or right, nothing at the edge.
    func testASpokenZoomPansLeftAndRightToTheEdge() {
        let middle = Context(view: .zoomed, pageIndex: 1, pageCount: 3, canPanLeft: true, canPanRight: true)
        XCTAssertEqual(Map.action(for: .left, in: middle), .panLeft)
        XCTAssertEqual(Map.action(for: .right, in: middle), .panRight)
        let atLeft = Context(view: .zoomed, canPanLeft: false, canPanRight: true)
        XCTAssertNil(Map.action(for: .left, in: atLeft), "the left edge: nothing, no wrap")
        XCTAssertEqual(Map.action(for: .right, in: atLeft), .panRight)
        let atRight = Context(view: .zoomed, canPanLeft: true, canPanRight: false)
        XCTAssertEqual(Map.action(for: .left, in: atRight), .panLeft)
        XCTAssertNil(Map.action(for: .right, in: atRight), "the right edge")
        let narrow = Context(view: .zoomed, pageIndex: 0, pageCount: 3)
        for nav in LensBandNav.allCases { XCTAssertNil(Map.action(for: nav, in: narrow), "a crop as wide as the page") }
    }

    /// The pan reaches no other view: a close-up and fit width keep their rows exactly.
    func testThePanRowLeavesTheOtherViewsAsTheyWere() {
        var halves = self.halves
        halves.canPanLeft = true
        halves.canPanRight = true
        XCTAssertEqual(Map.action(for: .right, in: halves), .rightHalf)
        XCTAssertNil(Map.action(for: .left, in: halves))
        let fit = Context(view: .closeUp, closeUpKind: .fitWidth, pageIndex: 1, pageCount: 3,
                          canPanLeft: true, canPanRight: true)
        XCTAssertEqual(Map.action(for: .left, in: fit), .previousPage)
        XCTAssertEqual(Map.action(for: .right, in: fit), .nextPage)
    }

    /// The context reads the edges from the zoomed view's own viewport, and only there.
    func testTheContextReadsTheEdgesOnlyInTheZoomedView() {
        let page = CGSize(width: 612, height: 792)
        var state = HUDPageViewState(viewport: LensPageViewport(wholePage: page), legibility: LensLegibility())
        var context = Context(state, pageIndex: 0, pageCount: 1)
        XCTAssertEqual(context.view, .whole)
        XCTAssertFalse(context.canPanLeft || context.canPanRight, "the whole page does not pan")
        state.viewport.zoom(rungs: 3, around: CGPoint(x: 0, y: 400))
        context = Context(state, pageIndex: 0, pageCount: 1)
        XCTAssertEqual(context.view, .zoomed)
        XCTAssertFalse(context.canPanLeft, "pushed against the left edge")
        XCTAssertTrue(context.canPanRight)
    }

    // MARK: - One send at a time

    func testABurstIsDroppedNotQueued() {
        let start = ContinuousClock.now
        var gate = LensBandNavGate()
        XCTAssertTrue(gate.admit(at: start))
        XCTAssertTrue(gate.isSending)
        for ms in [40, 90, 140, 300, 900] {
            XCTAssertFalse(gate.admit(at: start + .milliseconds(ms)), "a send is in flight at +\(ms) ms")
        }
        gate.finished()
        XCTAssertFalse(gate.isSending)
        XCTAssertTrue(gate.admit(at: start + .milliseconds(950)), "the frame reached the glasses: the next swipe goes")
        XCTAssertFalse(gate.admit(at: start + .milliseconds(960)), "nothing was queued behind it")
    }

    func testSwipesAreSpacedEvenWhenTheSendIsQuick() {
        let start = ContinuousClock.now
        var gate = LensBandNavGate()
        XCTAssertTrue(gate.admit(at: start))
        gate.finished()
        XCTAssertFalse(gate.admit(at: start + .milliseconds(100)), "too soon after the last")
        XCTAssertFalse(gate.admit(at: start + LensBandNavGate.minimumSpacing - .milliseconds(1)))
        XCTAssertTrue(gate.admit(at: start + LensBandNavGate.minimumSpacing))
    }

    func testASendThatNeverAnswersFreesTheGate() {
        let start = ContinuousClock.now
        var gate = LensBandNavGate()
        XCTAssertTrue(gate.admit(at: start))
        XCTAssertFalse(gate.admit(at: start + LensBandNavGate.sendTimeout - .milliseconds(1)))
        XCTAssertTrue(gate.admit(at: start + LensBandNavGate.sendTimeout))
    }

    // MARK: - The report

    func testTheReportCarriesABandLineOnlyOnceTheBandWasHeard() {
        var stats = LensPageStats()
        stats.update("metaRayBan") { $0.viewsOpened = 1 }
        XCTAssertFalse(LensPageReport.lines(for: stats).contains { $0.contains("Band:") }, "a store build never says it")
        stats.update("metaRayBan") { entry in
            entry.bandSwipes = 3; entry.bandHalves = 2; entry.bandPages = 1
            entry.bandNothingToDo = 1; entry.bandDropped = 4; entry.bandOther = 6; entry.bandListening = 1
        }
        XCTAssertTrue(LensPageReport.lines(for: stats).contains(
            "    Band: swipes acted on 3 (halves 2, pages 1, pans 0), nothing to do 1, dropped in a burst 4,"
                + " other inputs 6; listening 1, failed 0"))
    }

    // MARK: - Wired

    #if !AVENKIN_PHONE_ONLY

    private final class Clock: @unchecked Sendable {
        var now = ContinuousClock.now
        func advance(_ by: Duration = .seconds(1)) { now = now.advanced(by: by) }
    }

    private struct Rig {
        let display: GlassesDisplayService
        let session: LensPageSession
        let clock: Clock
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

    /// A row as wide as the page, as its text layer would mark it: its close-up has two halves.
    private static let rowRect = CGRect(x: 60, y: 340, width: 492, height: 12)

    private func makeRig(marked: Bool) -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        let clock = Clock()
        session.sourceURL = { _ in URL(fileURLWithPath: "/invented/guide.pdf") }
        session.requestWords = { "show me the page" }
        let letter = LensPageFixtures.letter
        session.layoutPage = { _ in
            let marks = marked
                ? LensPageMarks(marks: [.init(number: 1, lineRects: [Self.rowRect], bounds: Self.rowRect)], showsNumbers: false)
                : nil
            return LensPageLayout(pageSize: letter, marks: marks, pictureAreas: [], tone: .lineArt)
        }
        session.renderPicture = { _, _ in LensPageFixtures.picture() }
        session.scheduleTimer = { _, _ in }
        session.backend = { "metaRayBan" }
        session.pictureFactor = { 1 }
        session.clock = { clock.now }
        return Rig(display: display, session: session, clock: clock)
    }

    private func cited(page: Int) -> FieldSessionService.StagedFigure {
        var staged = LensPageFixtures.staged(page: page, figure: nil)
        staged.citedPassages = [CitedPassage(number: 1, anchor: PassageAnchor(documentId: "doc-invented", chunkIndex: 7,
                                                                              text: "The supply must read 24 V.", page: page))]
        return staged
    }

    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    /// One swipe, then the time it takes to make the next.
    private func swipe(_ rig: Rig, _ kind: GlassesInputKind) async -> LensBandOutcome {
        let outcome = rig.session.handleBand(kind)
        await drain(rig)
        rig.clock.advance()
        return outcome
    }

    func testRightAndLeftJumpBetweenACloseUpsHalvesOneSendEach() async throws {
        let rig = makeRig(marked: true)
        rig.session.stage([cited(page: 3)])
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .whole)
        let onWhole = await swipe(rig, .nav(.right))
        XCTAssertEqual(onWhole, .nothingToDo, "the whole page maps nothing")
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.closeUp?.hasHalves, true)

        let atLeft = await swipe(rig, .nav(.left))
        XCTAssertEqual(atLeft, .nothingToDo, "the strip starts at the left half")
        let right = await swipe(rig, .nav(.right))
        XCTAssertEqual(right, .sent(.rightHalf))
        XCTAssertEqual(rig.session.shownState?.closeUp?.only, .right)
        let edge = await swipe(rig, .nav(.right))
        XCTAssertEqual(edge, .nothingToDo, "no wrap")
        let left = await swipe(rig, .nav(.left))
        XCTAssertEqual(left, .sent(.leftHalf))
        XCTAssertNil(rig.session.shownState?.closeUp?.only, "both halves again, from the left")

        for kind: GlassesInputKind in [.nav(.up), .nav(.down), .back, .select] {
            let outcome = await swipe(rig, kind)
            XCTAssertEqual(outcome, .notMapped, kind.reportToken)
        }
        XCTAssertNil(rig.session.shownState?.closeUp?.only, "up, down, back and a pinch changed nothing")

        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.bandSwipes, 2)
        XCTAssertEqual(stats.bandHalves, 2)
        XCTAssertEqual(stats.bandNothingToDo, 3)
        XCTAssertEqual(stats.bandOther, 4)
        XCTAssertEqual(stats.presses, 1, "a swipe is counted on its own, not as a press")
    }

    func testABurstOfSwipesSendsOnce() async throws {
        let rig = makeRig(marked: true)
        rig.session.stage([cited(page: 3)])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        rig.clock.advance()
        XCTAssertEqual(rig.session.handleBand(.nav(.right)), .sent(.rightHalf))
        // The band's 40–140 ms bursts: the next swipes come before the frame is on the lens.
        XCTAssertEqual(rig.session.handleBand(.nav(.right)), .dropped)
        XCTAssertEqual(rig.session.handleBand(.nav(.right)), .dropped)
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.closeUp?.only, .right, "one send, nothing queued")
        XCTAssertEqual(rig.session.handleBand(.nav(.left)), .dropped, "delivered, but too soon after the last")
        rig.clock.advance()
        XCTAssertEqual(rig.session.handleBand(.nav(.left)), .sent(.leftHalf))
        await drain(rig)
        XCTAssertEqual(rig.session.stats["metaRayBan"].bandDropped, 3)
    }

    func testAtFitWidthLeftAndRightTurnThePageAndStayAtFitWidth() async throws {
        let rig = makeRig(marked: false)
        rig.session.stage([LensPageFixtures.staged(page: 3, figure: nil), LensPageFixtures.staged(page: 4, figure: nil)])
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.highlight.reason, LensPageHighlight.Reason.none)
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.closeUp?.kind, .fitWidth)

        let first = await swipe(rig, .nav(.left))
        XCTAssertEqual(first, .nothingToDo, "nothing before the first page")
        let next = await swipe(rig, .nav(.right))
        XCTAssertEqual(next, .sent(.nextPage))
        XCTAssertEqual(rig.session.pageIndex, 1)
        XCTAssertEqual(rig.session.shownState?.closeUp?.kind, .fitWidth, "the next page at fit width, from its top")
        XCTAssertEqual(rig.session.shownState?.closeUp?.columns.first?.minY, 0)
        let last = await swipe(rig, .nav(.right))
        XCTAssertEqual(last, .nothingToDo, "nothing after the last page, no wrap")
        let back = await swipe(rig, .nav(.left))
        XCTAssertEqual(back, .sent(.previousPage))
        XCTAssertEqual(rig.session.pageIndex, 0)
        XCTAssertEqual(rig.session.shownState?.closeUp?.kind, .fitWidth)

        XCTAssertTrue(rig.session.handle(.wholePage))
        await drain(rig)
        let onWhole = await swipe(rig, .nav(.right))
        XCTAssertEqual(onWhole, .nothingToDo, "the whole page keeps Next page › for that")
        XCTAssertEqual(rig.session.pageIndex, 0)
        XCTAssertEqual(rig.session.stats["metaRayBan"].bandPages, 2)
    }

    /// Plan NB §1: in a spoken zoom left and right move half a crop, one send each, counted as
    /// moves and as band pans; up and down stay the lens's own scroll.
    func testInASpokenZoomLeftAndRightPanToTheEdge() async throws {
        let rig = makeRig(marked: false)
        rig.session.stage([LensPageFixtures.staged(page: 3, figure: nil)])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomIn))
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomIn))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .zoomed)
        rig.clock.advance()
        let start = try XCTUnwrap(rig.session.shownState?.viewport.center)

        let left = await swipe(rig, .nav(.left))
        XCTAssertEqual(left, .sent(.panLeft))
        let afterLeft = try XCTUnwrap(rig.session.shownState?.viewport.center)
        XCTAssertLessThan(afterLeft.x, start.x)
        XCTAssertEqual(afterLeft.y, start.y, accuracy: 0.001)
        XCTAssertEqual(rig.session.shownState?.view, .zoomed)
        var outcome = LensBandOutcome.sent(.panLeft)
        var guardSteps = 0
        while outcome == .sent(.panLeft), guardSteps < 20 {
            outcome = await swipe(rig, .nav(.left))
            guardSteps += 1
        }
        XCTAssertEqual(outcome, .nothingToDo, "the left edge: nothing, no wrap")
        let right = await swipe(rig, .nav(.right))
        XCTAssertEqual(right, .sent(.panRight))
        let down = await swipe(rig, .nav(.down))
        XCTAssertEqual(down, .notMapped, "up and down stay the lens's own scroll of the strip")

        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.bandPans, stats.bandSwipes)
        XCTAssertGreaterThanOrEqual(stats.bandPans, 2)
        XCTAssertEqual(stats.moves, stats.bandPans, "each pan is drawn as a move")
        XCTAssertEqual(stats.presses, 2, "only the two zoom words were presses")
    }

    func testNothingHappensWhenThePageViewIsNotOnTheLens() async {
        let rig = makeRig(marked: false)
        XCTAssertEqual(rig.session.handleBand(.nav(.right)), .notOnLens)
        XCTAssertEqual(rig.session.handleBand(.nav(.up)), .notOnLens)
        XCTAssertTrue(rig.session.stats.isEmpty)
    }

    #endif
}
