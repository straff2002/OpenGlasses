#if !AVENKIN_PHONE_ONLY
import Combine
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KV P1 — the page view on the glasses, wired: which route opens what (§4), the band and the
/// voice driving it, Close returning to what was under it, stale renders dropped, the picture-less
/// backend, the Display in use, the audit trail and the support report's counts.
///
/// Headless, through the display's seams: fresh services only (never `.shared`), frames captured by
/// `testRenderSink`, a capability override instead of a device, and band presses through
/// `testInteractiveButtonActions` (the real `MetaDisplayBackend` button tree, never `Wearables`).
/// Pages are laid out and drawn by fakes, except where a test says it uses an invented PDF.
@MainActor
final class LensPageSessionTests: XCTestCase {

    // MARK: - Fixtures

    @MainActor
    private final class FrameRecorder {
        private(set) var frames: [GlassesDisplayService.HUDFrame] = []
        func record(_ frame: GlassesDisplayService.HUDFrame) { frames.append(frame) }

        var lastScreenKey: String? {
            for frame in frames.reversed() { if case .screen(let key) = frame { return key } }
            return nil
        }
        var last: GlassesDisplayService.HUDFrame? { frames.last }
        var screenKeys: [String] {
            frames.compactMap { if case .screen(let key) = $0 { return key } else { return nil } }
        }
    }

    /// Draws a stand-in picture, or holds every render until released.
    @MainActor
    private final class Renderer {
        var holding = false
        private(set) var calls = 0
        private var held: [CheckedContinuation<Void, Never>] = []

        func render(_ request: LensPageRequest, _ plan: LensPageRenderPlan) async -> UIImage? {
            calls += 1
            if holding { await withCheckedContinuation { held.append($0) } }
            return LensPageFixtures.picture()
        }

        func release() {
            holding = false
            let waiting = held
            held = []
            waiting.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class Timers {
        private(set) var armed: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) { armed.append((delay, fire)) }
        func fireLast() { armed.last?.fire() }
    }

    private struct Rig {
        let display: GlassesDisplayService
        let router: HUDRouter
        let session: LensPageSession
        let frames: FrameRecorder
        let renderer: Renderer
        let timers: Timers
        let audit: AuditBox
    }

    @MainActor
    private final class AuditBox {
        var lines: [LensPageAuditLine] = []
    }

    /// A table outline large enough that the view opens at ×2, with Zoom in still to go.
    private static let tableArea = CGRect(x: 100, y: 300, width: 300, height: 250)

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

    private func makeRig(drawsPictures: Bool = true, source: URL? = URL(fileURLWithPath: "/invented/guide.pdf"),
                         fakeDrawing: Bool = true) -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = drawsPictures
        let frames = FrameRecorder()
        display.testRenderSink = { frames.record($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        let renderer = Renderer()
        let timers = Timers()
        let audit = AuditBox()
        session.sourceURL = { _ in source }
        if fakeDrawing {
            session.layoutPage = { _ in
                LensPageLayout(pageSize: LensPageFixtures.letter, marks: nil, pictureAreas: [Self.tableArea],
                               tone: .lineArt)
            }
            session.renderPicture = { request, plan in await renderer.render(request, plan) }
        }
        session.scheduleTimer = { delay, fire in timers.schedule(delay, fire) }
        session.audit = { audit.lines.append($0) }
        session.backend = { "metaRayBan" }
        return Rig(display: display, router: router, session: session, frames: frames, renderer: renderer,
                   timers: timers, audit: audit)
    }

    private func makeCard(on display: GlassesDisplayService) -> HUDAnswerCard {
        let card = HUDAnswerCard(display: display)
        card.geometry = { .raybanDisplay }
        card.scheduleIdleTimer = { _, _ in }
        return card
    }

    /// Let the band's tasks, the session's renders and the render queue run.
    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    /// Let the band's tasks and the render queue run, without waiting on a render held open.
    private func yieldOnly() async {
        for _ in 0..<12 { await Task.yield() }
    }

    /// Press the button `id` on the frame last drawn, as the band would. `settling: false` leaves a
    /// held render held.
    private func press(_ rig: Rig, _ id: String, settling: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) async {
        guard let screen = rig.session.shownScreen,
              let index = screen.items.firstIndex(where: { $0.id == id }) else {
            XCTFail("no \(id) on the lens", file: file, line: line)
            return
        }
        rig.display.testInteractiveButtonActions(for: screen)[index]()
        if settling { await drain(rig) } else { await yieldOnly() }
    }

    private func itemIDs(_ rig: Rig) -> [String] { rig.session.shownScreen?.items.map(\.id) ?? [] }

    private typealias ID = HUDPageScreenBuilder.ItemID

    // MARK: - Routes

    func testARequestedPageOpensTheViewWithItsPicture() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)

        XCTAssertEqual(rig.session.held, .view)
        XCTAssertTrue(rig.router.isPresentingPage)
        XCTAssertEqual(rig.display.heldPage, .view)
        let key = try XCTUnwrap(rig.frames.lastScreenKey)
        XCTAssertTrue(key.contains("|pic:"), "the frame on the lens carries the page's picture")
        XCTAssertEqual(itemIDs(rig), [ID.zoomIn, ID.wholePage, ID.move, ID.close], "opened on the table, zoomed")
        XCTAssertEqual(rig.session.shownState?.viewport.zoom, .x2)
        XCTAssertEqual(rig.session.shownScreen?.lines.first?.text, "Figure 9 · p. 3", "the citation over the first frame")
        XCTAssertEqual(rig.session.shownScreen?.picture?.pixelSize, CGSize(width: 600, height: 600))
        XCTAssertEqual(rig.audit.lines.map(\.event), [.opened])
        XCTAssertEqual(rig.audit.lines.first?.route, "requested")
        XCTAssertEqual(rig.audit.lines.first?.zoom, 2)
        XCTAssertEqual(rig.renderer.calls, 2, "the opening view and the whole page, drawn ahead of any press")
        XCTAssertEqual(rig.session.stats["metaRayBan"].viewsOpened, 1)
    }

    func testAnAutomaticPageGetsOnlyTheCueAndShowHereOpensIt() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .automatic)])
        await drain(rig)

        XCTAssertEqual(rig.session.held, .cue)
        XCTAssertEqual(itemIDs(rig), [ID.showHere], "one button")
        XCTAssertFalse(rig.frames.screenKeys.contains { $0.contains("|pic:") }, "no page on the lens unasked")
        XCTAssertTrue(rig.session.shownScreen?.lines.first?.text.hasSuffix("on your phone") == true)
        XCTAssertEqual(rig.audit.lines.map(\.event), [.cueShown])

        await press(rig, ID.showHere)
        XCTAssertEqual(rig.session.held, .view)
        XCTAssertTrue(rig.frames.lastScreenKey?.contains("|pic:") == true)
        XCTAssertEqual(rig.audit.lines.map(\.event), [.cueShown, .opened])
        XCTAssertEqual(rig.audit.lines.last?.route, "automatic")
        XCTAssertEqual(rig.session.stats["metaRayBan"].showHerePressed, 1)
    }

    func testTheCueGoesAfterItsLifetime() async {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .automatic)])
        await drain(rig)
        XCTAssertEqual(rig.timers.armed.last?.delay, LensPageSession.defaultCueLifetime)
        rig.timers.fireLast()
        await drain(rig)
        XCTAssertNil(rig.session.held)
        XCTAssertFalse(rig.display.isInteractive)
        XCTAssertEqual(rig.frames.last, .clear)
    }

    func testAPictureLessBackendKeepsTheOneLineCue() async {
        let rig = makeRig(drawsPictures: false)
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertNil(rig.session.held)
        XCTAssertTrue(rig.frames.screenKeys.isEmpty, "no page view")
        guard case .content(let body, _, _)? = rig.frames.last else {
            return XCTFail("expected the cue line, got \(String(describing: rig.frames.last))")
        }
        XCTAssertEqual(body, "Figure 9, page 3, on your phone")
        XCTAssertEqual(rig.renderer.calls, 0)
    }

    func testAPageWithNoPDFKeepsTheOneLineCue() async {
        let rig = makeRig(source: nil)
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertNil(rig.session.held)
        XCTAssertTrue(rig.frames.screenKeys.isEmpty)
    }

    func testNothingOpensWhileAnotherAppHasTheDisplay() async {
        let rig = makeRig()
        rig.display.applySessionReading(.init(state: .paused))
        XCTAssertEqual(rig.display.displayAvailability, .inUse)
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertNil(rig.session.held)
        XCTAssertTrue(rig.frames.frames.isEmpty, "the lens isn't taken back")
        XCTAssertEqual(rig.session.stats["metaRayBan"].refused, 1)
    }

    // MARK: - The band

    func testZoomMoveAndCloseThroughTheBand() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState?.viewport)

        await press(rig, ID.zoomIn)
        XCTAssertEqual(rig.session.shownState?.viewport.zoom, .x3)
        XCTAssertNotEqual(rig.session.shownScreen?.lines.first?.text, "Figure 9 · p. 3",
                          "the citation goes once the technician zooms")

        await press(rig, ID.move)
        XCTAssertEqual(itemIDs(rig), [ID.up, ID.down, ID.left, ID.right, ID.done])
        let before = try XCTUnwrap(rig.session.shownState?.viewport.center)
        await press(rig, ID.down)
        XCTAssertGreaterThan(try XCTUnwrap(rig.session.shownState?.viewport.center.y), before.y)
        await press(rig, ID.done)
        XCTAssertTrue(itemIDs(rig).contains(ID.zoomIn))

        await press(rig, ID.wholePage)
        XCTAssertEqual(rig.session.shownState?.viewport.zoom, .fit)
        XCTAssertEqual(itemIDs(rig), [ID.zoomIn, ID.backToPart, ID.close])
        await press(rig, ID.backToPart)
        XCTAssertEqual(rig.session.shownState?.viewport, opening)

        await press(rig, ID.close)
        XCTAssertNil(rig.session.held)
        XCTAssertFalse(rig.router.isPresentingPage)
        XCTAssertFalse(rig.display.isInteractive)
        XCTAssertEqual(rig.frames.last, .clear, "nothing was under it")
        XCTAssertEqual(rig.audit.lines.map(\.event), [.opened, .zoomed, .moved, .zoomed, .zoomed, .closed])
        XCTAssertEqual(rig.session.stats["metaRayBan"].zooms, 3)
        XCTAssertEqual(rig.session.stats["metaRayBan"].moves, 1)
    }

    func testNextPageOpensTheNextCitedPageOnItsOwnFocus() async {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(page: 3, origin: .requested),
                           LensPageFixtures.staged(page: 4, figure: nil, origin: .requested)])
        await drain(rig)
        XCTAssertTrue(itemIDs(rig).contains(ID.nextPage))
        await press(rig, ID.nextPage)
        XCTAssertEqual(rig.session.pageIndex, 1)
        XCTAssertEqual(rig.session.shownScreen?.lines.first?.text, "p. 4")
        XCTAssertFalse(itemIDs(rig).contains(ID.nextPage), "the last cited page")
        XCTAssertEqual(rig.audit.lines.last?.event, .nextPage)
        XCTAssertEqual(rig.audit.lines.last?.page, 4)
    }

    // MARK: - What it returns to

    func testCloseReturnsToTheAnswerCardUnderIt() async throws {
        let rig = makeRig()
        let card = makeCard(on: rig.display)
        XCTAssertTrue(card.absorb("The invented relay closes when the coil sees power. Check it first.", streamed: false))
        await drain(rig)
        let cardKey = try XCTUnwrap(card.screenOnLens?.renderKey)
        XCTAssertEqual(rig.frames.lastScreenKey, cardKey)

        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertEqual(rig.session.held, .view)
        XCTAssertTrue(rig.display.holdsAnswerCardUnderPage)
        XCTAssertFalse(card.isShowing)
        XCTAssertTrue(card.isHeld)

        await press(rig, ID.close)
        XCTAssertTrue(rig.display.showsAnswerCard)
        XCTAssertTrue(card.isShowing)
        XCTAssertEqual(rig.frames.lastScreenKey, cardKey, "back to the answer")
    }

    func testAnAnswerArrivingUnderTheViewWaitsForItToClose() async throws {
        let rig = makeRig()
        let card = makeCard(on: rig.display)
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let pageKey = try XCTUnwrap(rig.frames.lastScreenKey)

        XCTAssertTrue(card.absorb("The invented fuse is the one nearest the door.", streamed: false))
        await drain(rig)
        XCTAssertEqual(rig.display.heldPage, .view, "the answer didn't take the lens")
        XCTAssertEqual(rig.frames.lastScreenKey, pageKey)
        XCTAssertTrue(rig.display.holdsAnswerCardUnderPage)

        await press(rig, ID.close)
        XCTAssertTrue(card.isShowing)
        XCTAssertEqual(rig.frames.lastScreenKey, card.screenOnLens?.renderKey)
    }

    func testCloseReturnsToTheTaskCardUnderIt() async throws {
        let rig = makeRig()
        let source = StubTaskSource()
        rig.router.startTask(source)
        await drain(rig)
        let taskKey = try XCTUnwrap(rig.frames.lastScreenKey)

        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertEqual(rig.session.held, .view)
        XCTAssertTrue(rig.router.isPresentingTask)

        await press(rig, ID.close)
        XCTAssertNil(rig.session.held)
        XCTAssertEqual(rig.frames.lastScreenKey, taskKey)
        XCTAssertFalse(rig.display.showsAnswerCard)
    }

    func testTheAnswerCardOffersPageWhenItsTurnStagedOne() async throws {
        let rig = makeRig()
        let card = makeCard(on: rig.display)
        card.pageCanOpen = { rig.session.canOpenStaged }
        card.openPage = { rig.session.openStaged() }

        card.beginTurn()
        rig.session.stage([LensPageFixtures.staged(origin: .automatic)])
        card.notePageStaged()
        await drain(rig)
        XCTAssertEqual(rig.session.held, .cue)

        card.finishTurn(reply: "Figure 9 shows the invented contactor. The coil is on the left.")
        await drain(rig)
        XCTAssertTrue(card.isShowing, "the answer replaced the cue")
        XCTAssertNil(rig.session.held)

        card.press(.actions)
        await drain(rig)
        let actions = try XCTUnwrap(card.screenOnLens?.items.map(\.id))
        XCTAssertEqual(actions.first, HUDAnswerCardBuilder.ItemID.page)

        card.press(.page)
        await drain(rig)
        XCTAssertEqual(rig.session.held, .view)
        XCTAssertEqual(rig.audit.lines.last?.route, "answer_card")
        XCTAssertTrue(rig.display.holdsAnswerCardUnderPage)
    }

    func testAnAnswerWithoutAPageHasNoPageAction() async throws {
        let rig = makeRig()
        let card = makeCard(on: rig.display)
        card.pageCanOpen = { rig.session.canOpenStaged }
        card.beginTurn()
        card.finishTurn(reply: "The invented unit has no page for this.")
        card.press(.actions)
        await drain(rig)
        let actions = try XCTUnwrap(card.screenOnLens?.items.map(\.id))
        XCTAssertFalse(actions.contains(HUDAnswerCardBuilder.ItemID.page))
    }

    // MARK: - Stale frames

    func testAStaleRenderIsDroppedWhenANotificationLandsFirst() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)
        let openingKey = try XCTUnwrap(rig.frames.lastScreenKey)

        rig.renderer.holding = true
        await press(rig, ID.zoomIn, settling: false)     // the ×3 crop isn't drawn yet
        XCTAssertEqual(rig.renderer.calls, 3, "the ×3 render is in flight")
        XCTAssertEqual(rig.session.shownState, opening)

        rig.display.showNotification(title: nil, body: "Invented notice", icon: .info, duration: 5)
        await yieldOnly()
        rig.renderer.release()
        await drain(rig)

        guard case .content(let body, _, _)? = rig.frames.last else {
            return XCTFail("the notification should be the last frame, got \(String(describing: rig.frames.last))")
        }
        XCTAssertEqual(body, "Invented notice", "the notification wins")
        XCTAssertEqual(rig.session.shownState, opening, "the view stays as it was")
        XCTAssertFalse(rig.frames.screenKeys.contains { $0 != openingKey }, "the ×3 frame never went out")
        XCTAssertEqual(rig.session.stats["metaRayBan"].stalePressesDropped, 1)
        XCTAssertFalse(rig.audit.lines.contains { $0.event == .zoomed })
    }

    func testAPressUnderANotificationIsDropped() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)
        rig.display.showNotification(title: nil, body: "Invented notice", icon: .info, duration: 5)
        await drain(rig)
        await press(rig, ID.zoomIn)
        XCTAssertEqual(rig.session.shownState, opening)
        XCTAssertEqual(rig.session.stats["metaRayBan"].stalePressesDropped, 1)
    }

    // MARK: - Voice

    func testPageWordsWorkOnlyWhileTheViewIsOnTheLens() async {
        let rig = makeRig()
        let before = await rig.router.handleVoiceCommand("zoom in")
        XCTAssertFalse(before, "no view, so it is an ordinary request")

        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let zoomed = await rig.router.handleVoiceCommand("zoom in")
        await drain(rig)
        XCTAssertTrue(zoomed)
        XCTAssertEqual(rig.session.shownState?.viewport.zoom, .x3)

        let next = await rig.router.handleVoiceCommand("next page")
        XCTAssertFalse(next, "one page: the word goes on")
        let sentence = await rig.router.handleVoiceCommand("zoom in on the invented relay")
        XCTAssertFalse(sentence)

        let closed = await rig.router.handleVoiceCommand("close the page")
        await drain(rig)
        XCTAssertTrue(closed)
        XCTAssertNil(rig.session.held)
    }

    func testPageWordsAreNotTakenOnTheCue() async {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .automatic)])
        await drain(rig)
        let handled = await rig.router.handleVoiceCommand("zoom in")
        XCTAssertFalse(handled)
    }

    // MARK: - Identity

    func testTheKeyNamesNoDocument() {
        let staged = LensPageFixtures.staged(title: "Invented Unit Guide")
        let identity = LensPageSession.identity(of: staged)
        XCTAssertEqual(identity.count, 16)
        XCTAssertFalse(identity.contains("Invented"))
        XCTAssertFalse(identity.contains("doc-invented"))
        var marked = staged
        marked.pictureAreas = [ManualTable.PictureArea(physical: 3, rect: CGRect(x: 1, y: 2, width: 3, height: 4))]
        XCTAssertNotEqual(LensPageSession.identity(of: marked), identity, "what the page marks is part of it")
    }

    // MARK: - The phone preview, the audit, the report

    func testThePhonePreviewShowsTheFrameSent() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let mirrored = try XCTUnwrap(rig.display.mirrorScreen)
        XCTAssertEqual(mirrored.renderKey, rig.frames.lastScreenKey)
        XCTAssertEqual(mirrored.picture?.contentKey, rig.session.shownScreen?.picture?.contentKey)
        let preview = GlassesDisplayService.previewFlexBox(for: mirrored)
        XCTAssertTrue(preview.children.contains { $0 is MWDATDisplay.Image }, "the preview draws the picture too")
    }

    func testTheAuditHoldsThePageReferenceNeverItsText() async throws {
        let token = "Invented relay note QX7731"
        let url = try LensPageFixtures.pdf(text: token)
        let rig = makeRig(source: url, fakeDrawing: false)
        rig.session.stage([LensPageFixtures.staged(page: 1, origin: .requested,
                                                   pictureAreas: [.init(physical: 1, rect: Self.tableArea)])])
        await drain(rig)
        XCTAssertEqual(rig.session.held, .view, "the invented page is drawn for real")
        XCTAssertEqual(rig.session.shownScreen?.picture?.image.cgImage?.width, 600)
        await press(rig, ID.zoomIn)
        await press(rig, ID.close)

        XCTAssertEqual(rig.audit.lines.map(\.event), [.opened, .zoomed, .closed])
        let events = rig.audit.lines.map { FieldSessionService.pageOnGlassesEvent($0, at: Date(timeIntervalSince1970: 0)) }
        XCTAssertTrue(events.allSatisfy { $0.kind == .pageOnGlasses })
        XCTAssertEqual(events.first?.text, "Invented Unit Guide, page 1, Figure 9, shown on the glasses")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("QX7731"), "no page text in the audit")
        XCTAssertFalse(encoded.contains("relay note"))
        XCTAssertTrue(encoded.contains("\"crop\""))
        XCTAssertTrue(encoded.contains("\"zoom\""))
        XCTAssertFalse(rig.session.reportLines.joined().contains("QX7731"))
    }

    func testTheSupportReportCountsViewsZoomsMovesAndTimings() async {
        let rig = makeRig()
        XCTAssertEqual(rig.session.reportLines, ["Page on the lens: not used since the app started"])
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        await press(rig, ID.zoomIn)
        await press(rig, ID.move)
        await press(rig, ID.left)
        rig.session.notePictureSent(bytes: 40_960, milliseconds: 120)
        rig.session.notePictureSent(bytes: nil, milliseconds: 80)

        let lines = rig.session.reportLines
        XCTAssertEqual(lines.first, "Page on the lens (since the app started):")
        let summary = lines.first { $0.hasPrefix("  metaRayBan:") } ?? ""
        XCTAssertTrue(summary.contains("views opened 1"), summary)
        XCTAssertTrue(summary.contains("zooms 1"), summary)
        XCTAssertTrue(summary.contains("moves 1"), summary)
        let renders = rig.renderer.calls
        XCTAssertTrue(lines.contains { $0.hasPrefix("    Render: \(renders),") }, "\(lines)")
        XCTAssertTrue(lines.contains("    Sent: 1, median 40 KB, largest 40 KB; send time 2, median 100 ms, largest 120 ms"),
                      "\(lines)")
    }
}

/// A one-step task, for the page view pushed over a task card.
@MainActor
private final class StubTaskSource: HUDTaskSource {
    let title = "Invented check"
    var current: HUDStep? = HUDStep(index: 0, total: 1, title: "Check the invented fuse")
    var next: HUDStep? { nil }
    var choices: [HUDChoice] { [] }
    let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func complete() async {}
    func skip() async {}
    func back() async {}
    func choose(_ id: String) async {}
}
#endif
