import XCTest
@testable import OpenGlasses

/// Plan NB §3–§4 — what a twist rung and an arm-pan step do to the page view, through the same
/// one-send gate as the swipes, and the press that ends a gesture, wired through the display's
/// seams. Only a flagged build hears the band's motion; this is compiled and tested in every
/// build. Every page here is invented.
@MainActor
final class LensPageSessionTwistTests: XCTestCase {

    private let letter = LensPageFixtures.letter

    // MARK: - Each view, pure

    private func state(_ viewport: LensPageViewport) -> HUDPageViewState {
        HUDPageViewState(viewport: viewport, legibility: LensLegibility()).framed()
    }

    func testRowsAndReadingTakeNoRungAndNoStep() {
        var rows = state(LensPageViewport(wholePage: letter))
        rows.rows = LensPageRows(title: "Table 1 (Invented codes)",
                                 rows: [.init(label: "E1", text: "E1 Invented", headings: "Code", spoken: "E1.")],
                                 highlighted: nil)
        rows.showsRows = true
        XCTAssertEqual(rows.view, .rows)
        var reading = state(LensPageViewport(wholePage: letter))
        reading.readingPages = [HUDAnswerPage(body: "Invented words.", lines: ["Invented words."], index: 0, count: 1,
                                              isCapped: false)]
        reading.isReading = true
        XCTAssertEqual(reading.view, .reading)
        for shown in [rows, reading] {
            XCTAssertNil(LensPageSession.twisted(shown, .zoomIn))
            XCTAssertNil(LensPageSession.twisted(shown, .zoomOut))
            for step in LensPageViewport.Step.allCases { XCTAssertNil(LensPageSession.panned(shown, step)) }
        }
    }

    func testTheWholePageZoomsInAroundTheHighlightOrThePageCentre() throws {
        let whole = state(LensPageViewport(wholePage: letter))
        XCTAssertNil(LensPageSession.twisted(whole, .zoomOut), "nothing below the whole page")
        let plain = try XCTUnwrap(LensPageSession.twisted(whole, .zoomIn))
        XCTAssertEqual(plain.view, .zoomed)
        XCTAssertEqual(plain.viewport.center.y, letter.height / 2, accuracy: 0.5, "no highlight: the page's centre")

        var marked = whole
        let part = CGRect(x: 60, y: 600, width: 200, height: 40)
        marked.highlight = LensPageHighlight(reason: .citedMark, rects: [part], part: part,
                                             legibility: LensLegibility(), words: nil)
        XCTAssertEqual(LensPageSession.twistCentre(marked), CGPoint(x: part.midX, y: part.midY))
        let zoomed = try XCTUnwrap(LensPageSession.twisted(marked.framed(), .zoomIn))
        XCTAssertGreaterThan(zoomed.viewport.center.y, letter.height / 2 + 50, "towards the highlight, low on the page")
        XCTAssertEqual(zoomed.view, .zoomed)
    }

    func testAZoomedViewStepsUpToTheCapAndBackToTheWholeView() throws {
        var shown = try XCTUnwrap(LensPageSession.twisted(state(LensPageViewport(wholePage: letter)), .zoomIn))
        var rungs = 1
        while let next = LensPageSession.twisted(shown, .zoomIn) {
            shown = next
            rungs += 1
            XCTAssertLessThan(rungs, 20)
        }
        XCTAssertTrue(shown.viewport.isDeepest, "nothing at the cap")
        while let next = LensPageSession.twisted(shown, .zoomOut) {
            shown = next
        }
        XCTAssertEqual(shown.view, .whole, "rung out at the bottom of the ladder: the whole view")
        XCTAssertNil(LensPageSession.twisted(shown, .zoomOut))
    }

    func testAnArmStepMovesAZoomedViewToTheEdgeAndNothingOnTheWholePage() throws {
        let whole = state(LensPageViewport(wholePage: letter))
        for step in LensPageViewport.Step.allCases { XCTAssertNil(LensPageSession.panned(whole, step), "\(step)") }
        var zoomed = whole
        zoomed.viewport.zoom(rungs: 3, around: CGPoint(x: letter.width / 2, y: letter.height / 2))
        zoomed = zoomed.framed()
        let moved = try XCTUnwrap(LensPageSession.panned(zoomed, .left))
        XCTAssertLessThan(moved.viewport.center.x, zoomed.viewport.center.x)
        var shown = moved
        while let next = LensPageSession.panned(shown, .left) { shown = next }
        XCTAssertFalse(shown.viewport.canMove(.left), "stopped at the edge")
        XCTAssertNotNil(LensPageSession.panned(shown, .right))
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

    private static let rowRect = CGRect(x: 60, y: 600, width: 492, height: 12)

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

    private func twist(_ rig: Rig, _ rung: TwistRung) async -> LensTwistOutcome {
        let outcome = rig.session.handleTwist(rung)
        await drain(rig)
        rig.clock.advance()
        return outcome
    }

    private func pan(_ rig: Rig, _ step: LensPageViewport.Step) async -> LensTwistOutcome {
        let outcome = rig.session.handleArmPan(step)
        await drain(rig)
        rig.clock.advance()
        return outcome
    }

    func testNothingHappensWhenThePageViewIsNotOnTheLens() {
        let rig = makeRig(marked: false)
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .notOnLens)
        XCTAssertEqual(rig.session.handleArmPan(.left), .notOnLens)
        XCTAssertTrue(rig.session.stats.isEmpty)
    }

    func testATwistFromTheWholePageZoomsTowardsTheHighlight() async throws {
        let rig = makeRig(marked: true)
        rig.session.stage([cited(page: 3)])
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .whole)
        XCTAssertNotNil(rig.session.shownState?.highlight.part)
        XCTAssertEqual(rig.session.shownView, .whole)
        let out = await twist(rig, .zoomOut)
        XCTAssertEqual(out, .nothingToDo, "nothing below the whole page")
        let first = await twist(rig, .zoomIn)
        XCTAssertEqual(first, .sent)
        let shown = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(shown.view, .zoomed)
        XCTAssertEqual(rig.session.shownView, .zoomed)
        XCTAssertGreaterThan(shown.viewport.center.y, LensPageFixtures.letter.height / 2, "towards the highlight")
        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.twistRungs, 1)
        XCTAssertEqual(stats.twistNothingToDo, 1)
        XCTAssertEqual(stats.zooms, 1, "drawn as a zoom")
        XCTAssertEqual(stats.presses, 0, "a rung is counted on its own, not as a press")
    }

    func testFromACloseUpATwistIsTheSpokenZoom() async throws {
        let rig = makeRig(marked: true)
        rig.session.stage([cited(page: 3)])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        let closeUp = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(closeUp.view, .closeUp)
        let carried = LensPageSession.leavingCloseUp(closeUp).viewport.pixelsPerPoint
        rig.clock.advance()
        let inward = await twist(rig, .zoomIn)
        XCTAssertEqual(inward, .sent)
        let zoomed = try XCTUnwrap(rig.session.shownState)
        XCTAssertNil(zoomed.closeUp)
        XCTAssertEqual(zoomed.view, .zoomed)
        XCTAssertGreaterThan(zoomed.viewport.pixelsPerPoint, carried, "one rung in from the close-up's own zoom")
        XCTAssertEqual(zoomed, LensPageSession.twisted(closeUp, .zoomIn), "what \"zoom in\" by voice would show")

        // And out, from a fresh close-up: one rung below the close-up's zoom.
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        let again = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(again.view, .closeUp)
        let outward = await twist(rig, .zoomOut)
        XCTAssertEqual(outward, .sent)
        XCTAssertNil(rig.session.shownState?.closeUp)
        XCTAssertLessThan(rig.session.shownState?.viewport.pixelsPerPoint ?? .infinity,
                          LensPageSession.leavingCloseUp(again).viewport.pixelsPerPoint)
    }

    func testABurstOfRungsSendsOnceAndSharesTheSwipesGate() async throws {
        let rig = makeRig(marked: false)
        rig.session.stage([LensPageFixtures.staged(page: 3, figure: nil)])
        await drain(rig)
        rig.clock.advance()
        let before = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .sent)
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .dropped, "a send is in flight")
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .dropped)
        await drain(rig)
        XCTAssertEqual(rig.session.shownState, LensPageSession.twisted(before, .zoomIn), "one rung drawn, nothing queued")
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .dropped, "delivered, but too soon after the last")
        rig.clock.advance()
        XCTAssertEqual(rig.session.handleTwist(.zoomIn), .sent)
        await drain(rig)

        // One gate for the band's swipes, the twist and the pan. The pan needs a crop narrower than
        // the page (the first rungs on a letter page still show its whole width), so zoom further
        // by voice first, then send a pan and try the other two while it is in flight.
        var zooms = 0
        while rig.session.shownState?.viewport.canMove(.left) != true, zooms < 10 {
            rig.clock.advance()
            XCTAssertTrue(rig.session.handle(.zoomIn))
            await drain(rig)
            zooms += 1
        }
        rig.clock.advance()
        XCTAssertEqual(rig.session.handleArmPan(.left), .sent)
        XCTAssertEqual(rig.session.handleTwist(.zoomOut), .dropped, "a pan is in flight")
        XCTAssertEqual(rig.session.handleBand(.nav(.right)), .dropped)
        await drain(rig)
        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.twistRungs, 2)
        XCTAssertEqual(stats.twistDropped, 4)
        XCTAssertEqual(stats.armPanSteps, 1)
        XCTAssertEqual(stats.bandDropped, 1)
    }

    func testTheArmPansAZoomedViewAndACloseUpButNotTheWholePage() async throws {
        let rig = makeRig(marked: true)
        rig.session.stage([cited(page: 3)])
        await drain(rig)
        let onWhole = await pan(rig, .left)
        XCTAssertEqual(onWhole, .nothingToDo)
        XCTAssertTrue(rig.session.handle(.closeUp))
        await drain(rig)
        rig.clock.advance()
        let closeUp = try XCTUnwrap(rig.session.shownState)
        let fromCloseUp = await pan(rig, .up)
        XCTAssertEqual(fromCloseUp, .sent, "a close-up carries on at its zoom, as a spoken move does")
        let moved = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(moved.view, .zoomed)
        XCTAssertLessThan(moved.viewport.center.y, LensPageSession.leavingCloseUp(closeUp).viewport.center.y)
        var outcome = LensTwistOutcome.sent
        var steps = 0
        while outcome == .sent, steps < 30 {
            outcome = await pan(rig, .up)
            steps += 1
        }
        XCTAssertEqual(outcome, .nothingToDo, "the top edge")
        let stats = rig.session.stats["metaRayBan"]
        XCTAssertEqual(stats.armPanSteps, steps)
        XCTAssertEqual(stats.armPanNothingToDo, 2)
        XCTAssertEqual(stats.moves, stats.armPanSteps, "drawn as moves")
    }

    func testThePressThatEndsATwistIsNotBack() async throws {
        let rig = makeRig(marked: false)
        rig.session.stage([LensPageFixtures.staged(page: 3, figure: nil)])
        await drain(rig)
        rig.clock.advance()
        rig.session.wristClutchOpened()
        let sent = await twist(rig, .zoomIn)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(rig.session.shownState?.view, .zoomed)
        rig.session.wristClutchClosed()
        let back = HUDPageScreenBuilder.ItemID.back
        XCTAssertTrue(rig.session.shownScreen?.items.contains { $0.id == back } ?? false, "the zoomed view has Back")
        XCTAssertFalse(rig.session.press(itemID: back), "Meta's press with the pinch's select is dropped")
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .zoomed, "the view the twist was changing stays")
        XCTAssertEqual(rig.session.stats["metaRayBan"].twistPressesSwallowed, 1)

        XCTAssertTrue(rig.session.press(itemID: back), "the next press is the wearer's")
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .whole)
    }

    func testAPlainPinchsPressGoesThrough() async throws {
        let rig = makeRig(marked: false)
        rig.session.stage([LensPageFixtures.staged(page: 3, figure: nil)])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomIn))
        await drain(rig)
        rig.session.wristClutchOpened()
        rig.session.wristClutchClosed()
        XCTAssertTrue(rig.session.press(itemID: HUDPageScreenBuilder.ItemID.back), "no rung was sent: a press is a press")
        XCTAssertEqual(rig.session.stats["metaRayBan"].twistPressesSwallowed, 0)
    }

    #endif

    // MARK: - The report

    func testTheReportCarriesAWristLineOnlyOnceTheWristWasHeard() {
        var stats = LensPageStats()
        stats.update("metaRayBan") { $0.viewsOpened = 1 }
        XCTAssertFalse(LensPageReport.lines(for: stats).contains { $0.contains("Wrist:") }, "a store build never says it")
        stats.update("metaRayBan") { entry in
            entry.twistRungs = 4; entry.twistNothingToDo = 1; entry.twistDropped = 2
            entry.armPanSteps = 3; entry.armPanDropped = 1; entry.twistPressesSwallowed = 2; entry.wristListening = 1
        }
        XCTAssertTrue(LensPageReport.lines(for: stats).contains(
            "    Wrist: twist rungs 4 (nothing to do 1, dropped 2), arm pans 3 (nothing to do 0, dropped 1),"
                + " presses swallowed 2; listening 1, failed 0"))
    }
}
