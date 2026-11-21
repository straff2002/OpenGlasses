#if !AVENKIN_PHONE_ONLY
import XCTest
@testable import OpenGlasses

/// Plan MG P4, as Plan MU left it — a zoomed view as a strip the lens scrolls, the views one press
/// away, and the words that combine a zoom and a place. MU §0 dropped MG's 3 × 3 tile grid (the
/// glasses drew a row of pictures as its first picture): the whole page is one picture, and a
/// press on it reads the highlighted part closely (`LensPageAtWorkTests`).
///
/// Headless: pure geometry, and the session through the display's seams (a fresh
/// `GlassesDisplayService`, frames to `testRenderSink`, presses through the real
/// `MetaDisplayBackend` tree). Pages are laid out and drawn by fakes.
@MainActor
final class LensPageQuickZoomTests: XCTestCase {

    private let letter = LensPageFixtures.letter
    private let box = LensPageFrame.pictureBox(citation: false, hint: false)

    // MARK: - The words' places

    func testTwoRungsStopAtTheZoomCap() {
        let fit = LensPageViewport.fitPixelsPerPoint(pageSize: letter, box: box)
        var viewport = LensPageViewport(pageSize: letter, box: box, center: CGPoint(x: 306, y: 396),
                                        pixelsPerPoint: nil, maxPixelsPerPoint: fit * 2)
        viewport.zoom(rungs: 2, around: CGPoint(x: 100, y: 100))
        XCTAssertTrue(viewport.isDeepest)
        XCTAssertEqual(viewport.pixelsPerPoint, fit * 2, accuracy: 0.0001)
        let page = CGRect(origin: .zero, size: letter)
        XCTAssertTrue(page.insetBy(dx: -0.01, dy: -0.01).contains(viewport.cropRect), "the crop stays inside the page")
    }

    func testEveryAreaNamesItsTile() {
        for area in LensPageViewport.Area.allCases {
            XCTAssertEqual(LensPageViewport.Area(row: area.cell.row, column: area.cell.column), area)
        }
        XCTAssertNil(LensPageViewport.Area(row: 3, column: 0))
    }

    // MARK: - The strip

    private func zoomed(center: CGPoint, scale: CGFloat = 2.25) -> LensPageViewport {
        let fit = LensPageViewport.fitPixelsPerPoint(pageSize: letter, box: box)
        return LensPageViewport(pageSize: letter, box: box, center: center, pixelsPerPoint: fit * scale)
    }

    func testTheStripIsTheCropsColumnFromItsTopDownToTwoLensHeights() {
        let viewport = zoomed(center: CGPoint(x: 306, y: 200))
        let strip = LensPageStrip(viewport: viewport)
        let crop = viewport.cropRect
        XCTAssertEqual(strip.rect.minX, crop.minX, accuracy: 0.001)
        XCTAssertEqual(strip.rect.width, crop.width, accuracy: 0.001)
        XCTAssertEqual(strip.rect.minY, crop.minY, accuracy: 0.001, "the lens opens on what the wearer zoomed into")
        XCTAssertGreaterThan(strip.rect.height, crop.height, "more of the page below to scroll to")
        XCTAssertLessThanOrEqual(strip.outputSize.height, LensPageStrip.maxHeightPixels)
        XCTAssertEqual(strip.outputSize.width, box.width)
        XCTAssertEqual(strip.slices.first?.minY, 0)
        XCTAssertEqual(strip.slices.last?.maxY ?? 0, strip.outputSize.height, accuracy: 0.5)
        for (a, b) in zip(strip.slices, strip.slices.dropFirst()) {
            XCTAssertEqual(a.maxY, b.minY, accuracy: 0.001, "the slices are seamless")
        }
        XCTAssertTrue(strip.slices.allSatisfy { $0.height <= LensPageStrip.sliceHeightPixels + 1 })
        XCTAssertEqual(LensPageStrip.maxHeightPixels, 1200)
    }

    func testAStripNearTheBottomStopsAtThePage() {
        let viewport = zoomed(center: CGPoint(x: 306, y: 780))
        let strip = LensPageStrip(viewport: viewport)
        XCTAssertEqual(strip.rect.maxY, letter.height, accuracy: 0.01)
        XCTAssertLessThan(strip.outputSize.height, LensPageStrip.maxHeightPixels)
        let middle = try? XCTUnwrap(strip.center(ofSlice: 0))
        XCTAssertNotNil(middle)
        XCTAssertNil(strip.center(ofSlice: strip.slices.count))
    }

    // MARK: - Neighbours

    func testTheNeighboursAreTheViewsOnePressAwayEachOnce() {
        let viewport = zoomed(center: CGPoint(x: 306, y: 396), scale: 1.5)
        let neighbours = viewport.neighbours()
        XCTAssertFalse(neighbours.contains { $0.showsSame(as: viewport) })
        for (index, a) in neighbours.enumerated() {
            for b in neighbours.dropFirst(index + 1) { XCTAssertFalse(a.showsSame(as: b)) }
        }
        var zoomIn = viewport
        zoomIn.zoomIn()
        XCTAssertTrue(neighbours.first?.showsSame(as: zoomIn) ?? false, "the likeliest press first")
        XCTAssertTrue(neighbours.contains { $0.isWholePage })
        var down = viewport
        down.move(.down)
        XCTAssertTrue(neighbours.contains { $0.showsSame(as: down) })
        var right = viewport
        right.move(.right)
        XCTAssertTrue(right.showsSame(as: viewport), "the page is narrower than the crop here")
        XCTAssertFalse(neighbours.contains { $0.showsSame(as: right) }, "a move that does nothing isn't drawn")

        let whole = LensPageViewport(wholePage: letter, box: box)
        XCTAssertFalse(whole.neighbours().contains { $0.isWholePage }, "nothing out from the whole page")
    }

    // MARK: - Words

    func testTheCombinedWords() {
        XCTAssertEqual(HUDPageCommand.parse("zoom in on the bottom right"), .zoomInto(.bottomRight))
        XCTAssertEqual(HUDPageCommand.parse("Zoom into the top left corner."), .zoomInto(.topLeft))
        XCTAssertEqual(HUDPageCommand.parse("closer at the top"), .zoomInto(.top))
        XCTAssertEqual(HUDPageCommand.parse("ok get closer to the middle please"), .zoomInto(.centre))
        XCTAssertEqual(HUDPageCommand.parse("zoom into the table"), .zoomIntoTable)
        XCTAssertEqual(HUDPageCommand.parse("zoom in on the diagram"), .zoomIntoDiagram)
        XCTAssertEqual(HUDPageCommand.parse("zoom in"), .zoomIn, "a bare zoom keeps its meaning")
        XCTAssertEqual(HUDPageCommand.parse("bottom right"), .corner(.bottomRight))
        for sentence in ["zoom in on the wiring", "zoom into the table on page 4", "closer", "zoom in on",
                         "can you zoom in on the bottom right"] {
            XCTAssertNotEqual(HUDPageCommand.parse(sentence).map { "\($0)" }?.hasPrefix("zoomInto"), true, sentence)
        }
        XCTAssertNil(HUDPageCommand.parse("zoom in on the wiring"))
    }

    // MARK: - The builder

    /// A spoken zoom is drawn as a strip with Back · Close only: no Move, no arrows, no Done.
    func testASpokenZoomIsAStripWithBackAndClose() {
        typealias ID = HUDPageScreenBuilder.ItemID
        let state = HUDPageViewState(viewport: zoomed(center: CGPoint(x: 306, y: 396)),
                                     legibility: LensLegibility(lineRects: []))
        XCTAssertTrue(state.showsStrip)
        XCTAssertEqual(HUDPageScreenBuilder.items(state) { _ in }.map(\.id), [ID.back, ID.close])
    }

    // MARK: - The session

    @MainActor
    private final class Drawn { var plans: [LensPageRenderPlan] = [] }

    private struct Rig {
        let display: GlassesDisplayService
        let session: LensPageSession
        let drawn: Drawn
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

    private func makeRig(pictureAreas: [CGRect] = []) -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        let drawn = Drawn()
        session.sourceURL = { _ in URL(fileURLWithPath: "/invented/guide.pdf") }
        let letter = self.letter
        session.layoutPage = { _ in
            LensPageLayout(pageSize: letter, marks: nil, pictureAreas: pictureAreas, tone: .lineArt)
        }
        session.renderPicture = { _, plan in
            drawn.plans.append(plan)
            return LensPageFixtures.picture()
        }
        session.scheduleTimer = { _, _ in }
        session.backend = { "metaRayBan" }
        return Rig(display: display, session: session, drawn: drawn)
    }

    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    /// Plan MU §0/§6: the whole page is one picture, alone in its row, a card focus opens on; a
    /// press on it (nothing highlighted) opens the page at fit width, drawn as a strip of slices.
    func testTheWholePageIsOnePictureAndAPressOpensFitWidth() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let screen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertTrue(try XCTUnwrap(rig.session.shownState).viewport.isWholePage)
        XCTAssertEqual(screen.flow.first?.blocks.count, 1, "one picture a row")
        XCTAssertEqual(screen.allBlocks.filter { $0.picture != nil }.count, 1, "no tiles")
        XCTAssertFalse(screen.hasPicturesSideBySide)
        XCTAssertTrue(screen.focusesFirstBlock)
        XCTAssertEqual(screen.flow.first?.blocks.first?.picture?.pixelSize, rig.session.shownState?.pictureBox)

        rig.display.testInteractiveBlockActions(for: screen)[0]()
        await drain(rig)
        let state = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(state.view, .closeUp)
        XCTAssertEqual(state.closeUp?.kind, .fitWidth)
        let fitScreen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertFalse(fitScreen.trailingFlow.isEmpty)
        XCTAssertTrue(fitScreen.trailingFlow.flatMap(\.blocks).allSatisfy { $0.style == .plain })
        XCTAssertEqual(fitScreen.items.map(\.id), [HUDPageScreenBuilder.ItemID.back, HUDPageScreenBuilder.ItemID.close])
        XCTAssertEqual(rig.session.stats["metaRayBan"].fitWidths, 1)
        XCTAssertTrue(rig.drawn.plans.contains { $0.outputSize.height > box.height }, "strips drawn taller than the box")
    }

    /// A pictured table opens whole with the table highlighted; its close-up was drawn before the
    /// press, so the press only sends; Back returns to the whole page.
    func testAPageWithATableOpensWholeAndItsCloseUpIsDrawnAhead() async throws {
        typealias ID = HUDPageScreenBuilder.ItemID
        let table = CGRect(x: 100, y: 300, width: 300, height: 250)
        let rig = makeRig(pictureAreas: [table])
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let state = try XCTUnwrap(rig.session.shownState)
        let screen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertEqual(state.view, .whole)
        XCTAssertEqual(state.highlight.reason, .table)
        XCTAssertEqual(screen.items.map(\.id), [ID.close])
        XCTAssertEqual(screen.lines.map(\.text), ["Figure 9 · p. 3"])
        // The frame: padding, the citation, the picture, the hint, the row and its glow, on the lens.
        let picture = try XCTUnwrap(screen.allBlocks.first?.picture?.pixelSize)
        let fixed = LensPageFrame.fixedHeight(.init(metaLines: 1, bodyLines: state.lineUnderPicture,
                                                    hasPicture: true, hasButtons: true))
        XCTAssertLessThanOrEqual(fixed + picture.height, CGFloat(HUDCanvas.metaDisplay.heightPixels))

        let closeUp = LensPageSession.closeUpState(state)
        let ahead = LensPageSession.renderPlans(closeUp, layout: LensPageLayout(pageSize: letter, marks: nil,
                                                                                pictureAreas: [table], tone: .lineArt))
        let drawnBefore = rig.drawn.plans
        XCTAssertFalse(ahead.isEmpty)
        XCTAssertTrue(ahead.allSatisfy { drawnBefore.contains($0) }, "the close-up was drawn before the press")
        rig.display.testInteractiveBlockActions(for: screen)[0]()
        await drain(rig)
        let shown = try XCTUnwrap(rig.session.shownState)
        XCTAssertEqual(shown.view, .closeUp)
        let columns = try XCTUnwrap(shown.closeUp?.columns)
        XCTAssertLessThanOrEqual(columns.map(\.minX).min() ?? .infinity, table.minX)
        XCTAssertGreaterThanOrEqual(columns.map(\.maxX).max() ?? 0, table.maxX)
        XCTAssertTrue(rig.session.press(itemID: ID.back))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .whole)
    }

    func testZoomInOnTheBottomRightByVoice() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let whole = try XCTUnwrap(rig.session.shownState).viewport
        XCTAssertTrue(whole.isWholePage)
        XCTAssertTrue(rig.session.handle(.zoomInto(.bottomRight)))
        await drain(rig)
        let shown = try XCTUnwrap(rig.session.shownState)
        let viewport = shown.viewport
        // Two rungs in from the whole page as it was shown. (The strip's box is taller than the
        // whole page's, which gives up lines to the citation and the words, so `scale`, which is
        // against the strip's own fit, reads lower.)
        XCTAssertGreaterThan(viewport.pixelsPerPoint, 1.9 * whole.pixelsPerPoint)
        XCTAssertEqual(viewport.cropRect.maxY, letter.height, accuracy: 0.01)
        XCTAssertEqual(shown.view, .zoomed, "drawn as a strip")
        XCTAssertEqual(rig.session.shownScreen?.items.map(\.id),
                       [HUDPageScreenBuilder.ItemID.back, HUDPageScreenBuilder.ItemID.close])
        XCTAssertFalse(rig.session.handle(.zoomIntoTable), "no table on this page: the words go on")
        XCTAssertTrue(rig.session.handle(.wholePage))
        await drain(rig)
        XCTAssertEqual(rig.session.shownState?.view, .whole)
    }
}
#endif
