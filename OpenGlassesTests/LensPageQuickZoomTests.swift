#if !AVENKIN_PHONE_ONLY
import XCTest
@testable import OpenGlasses

/// Plan MG P4 — the page view, quicker: the whole page as tiles to point at (each a crop inside the
/// page, a press two rungs in), a zoomed view as a strip the lens scrolls, the views one press away
/// drawn ahead, and the words that combine a zoom and a place.
///
/// Headless: pure geometry, and the session through the display's seams (a fresh
/// `GlassesDisplayService`, frames to `testRenderSink`, presses through the real
/// `MetaDisplayBackend` tree). Pages are laid out and drawn by fakes.
@MainActor
final class LensPageQuickZoomTests: XCTestCase {

    private let letter = LensPageFixtures.letter
    private let box = LensPageFrame.pictureBox(citation: false, hint: false)

    // MARK: - Tiles

    func testEveryTileIsANinthOfThePageInsideIt() {
        let tiles = LensPageTileGrid.tiles(pageSize: letter, box: box)
        XCTAssertEqual(tiles.count, 9)
        let page = CGRect(origin: .zero, size: letter)
        var area: CGFloat = 0
        for tile in tiles {
            XCTAssertTrue(page.insetBy(dx: -0.001, dy: -0.001).contains(tile.crop), "\(tile.area) leaves the page")
            area += tile.crop.width * tile.crop.height
        }
        XCTAssertEqual(area, letter.width * letter.height, accuracy: 0.5, "together they are the whole page")
        XCTAssertEqual(Set(tiles.map { "\($0.area)" }).count, 9)
        XCTAssertEqual(tiles.first { $0.area == .bottomRight }?.crop.maxX ?? 0, letter.width, accuracy: 0.001)
        XCTAssertEqual(tiles.first { $0.area == .bottomRight }?.crop.maxY ?? 0, letter.height, accuracy: 0.001)
    }

    func testTilesAreDrawnAtASizeThatFitsThreeAcrossAndThreeDown() {
        for page in [letter, CGSize(width: 792, height: 612), CGSize(width: 400, height: 1200)] {
            let tiles = LensPageTileGrid.tiles(pageSize: page, box: box)
            let size = tiles[0].drawnSize
            XCTAssertTrue(tiles.allSatisfy { $0.drawnSize == size })
            XCTAssertLessThanOrEqual(size.width, LensPageTileGrid.maxTileWidth)
            XCTAssertLessThanOrEqual(3 * size.width + 2 * LensPageFrame.tileGapPixels, LensPageFrame.contentWidthPixels)
            XCTAssertLessThanOrEqual(3 * size.height + 2 * LensPageFrame.gapPixels, box.height)
            XCTAssertEqual(size.width / size.height, page.width / page.height, accuracy: 0.02, "a ninth's own shape")
        }
        XCTAssertEqual(LensPageTileGrid.maxTileWidth, 186, "measured: 186 px three across with 8 px gaps")
    }

    func testAPressOnATileZoomsTwoRungsIntoItsCentre() throws {
        let tile = try XCTUnwrap(LensPageTileGrid.tile(row: 2, column: 2, pageSize: letter, box: box))
        var viewport = LensPageViewport(wholePage: letter, box: box)
        viewport.zoom(rungs: LensPageViewport.pointZoomRungs, around: tile.center)
        XCTAssertEqual(viewport.scale, LensPageViewport.zoomStep * LensPageViewport.zoomStep, accuracy: 0.001)
        XCTAssertTrue(viewport.cropRect.contains(tile.center) || viewport.cropRect.maxX >= letter.width - 0.01,
                      "the bottom right is on the lens")
        XCTAssertEqual(viewport.cropRect.maxX, letter.width, accuracy: 0.01, "pushed against the page's edge")
        XCTAssertEqual(viewport.cropRect.maxY, letter.height, accuracy: 0.01)
    }

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

    func testTheTilesReplaceZoomInAndAStripMovesOnlyAcross() {
        typealias ID = HUDPageScreenBuilder.ItemID
        var whole = HUDPageViewState(viewport: LensPageViewport(wholePage: letter, box: box),
                                     legibility: LensLegibility(lineRects: []))
        whole.tilesAndStrips = true
        XCTAssertTrue(whole.showsTiles)
        XCTAssertFalse(HUDPageScreenBuilder.items(whole) { _ in }.map(\.id).contains(ID.zoomIn))
        XCTAssertEqual(HUDPageScreenBuilder.items(whole) { _ in }.map(\.id).last, ID.close)

        var moving = HUDPageViewState(viewport: zoomed(center: CGPoint(x: 306, y: 396)),
                                      legibility: LensLegibility(lineRects: []))
        moving.tilesAndStrips = true
        moving.isMoving = true
        XCTAssertTrue(moving.showsStrip)
        XCTAssertEqual(HUDPageScreenBuilder.items(moving) { _ in }.map(\.id), [ID.left, ID.right, ID.done])

        moving.tilesAndStrips = false
        XCTAssertEqual(HUDPageScreenBuilder.items(moving) { _ in }.map(\.id), [ID.up, ID.down, ID.left, ID.right, ID.done],
                       "without the strip, the four arrows as before")
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
        session.tilesAndStrips = true
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

    func testTheWholePageOpensAsTilesAndAPressOnOneZoomsIntoIt() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let screen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertTrue(try XCTUnwrap(rig.session.shownState).viewport.isWholePage)
        XCTAssertNil(screen.picture, "the page is its tiles")
        XCTAssertEqual(screen.flow.count, 3, "three rows")
        XCTAssertEqual(screen.flow.flatMap(\.blocks).count, 9)
        XCTAssertTrue(screen.flow.flatMap(\.blocks).allSatisfy { $0.style == .card && $0.picture != nil })
        XCTAssertFalse(screen.items.map(\.id).contains(HUDPageScreenBuilder.ItemID.zoomIn))
        let size = try XCTUnwrap(screen.flow.flatMap(\.blocks).first?.picture?.pixelSize)
        XCTAssertLessThanOrEqual(size.width, LensPageTileGrid.maxTileWidth)

        // The bottom right tile, pressed as the band would.
        rig.display.testInteractiveBlockActions(for: screen)[8]()
        await drain(rig)
        let state = try XCTUnwrap(rig.session.shownState)
        // Two rungs from the frame the press was made on; the later frame has no citation line, so
        // its box (and the whole page's fit) is a little larger.
        XCTAssertGreaterThan(state.viewport.scale, 1.9, "two rungs in")
        XCTAssertEqual(state.viewport.cropRect.maxX, letter.width, accuracy: 0.01)
        let zoomedScreen = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertNil(zoomedScreen.picture, "a zoomed view is its strip")
        XCTAssertFalse(zoomedScreen.trailingFlow.isEmpty)
        XCTAssertTrue(zoomedScreen.trailingFlow.flatMap(\.blocks).allSatisfy { $0.style == .plain })
        XCTAssertGreaterThan(rig.session.stats["metaRayBan"].zooms, 0)
    }

    func testAZoomedViewMovesOnlyAcrossAndDrawsTheNextViewsAhead() async throws {
        let rig = makeRig(pictureAreas: [CGRect(x: 100, y: 300, width: 300, height: 250)])
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertFalse(try XCTUnwrap(rig.session.shownState).viewport.isWholePage, "opened on the table")
        let before = rig.drawn.plans.count
        XCTAssertTrue(rig.session.press(itemID: HUDPageScreenBuilder.ItemID.move))
        await drain(rig)
        XCTAssertEqual(rig.session.shownScreen?.items.map(\.id),
                       [HUDPageScreenBuilder.ItemID.left, HUDPageScreenBuilder.ItemID.right,
                        HUDPageScreenBuilder.ItemID.done])
        XCTAssertGreaterThanOrEqual(rig.drawn.plans.count, before, "neighbours drawn ahead")
        XCTAssertTrue(rig.drawn.plans.contains { $0.outputSize.height > box.height }, "strips drawn taller than the box")
    }

    func testZoomInOnTheBottomRightByVoice() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertTrue(rig.session.handle(.zoomInto(.bottomRight)))
        await drain(rig)
        let viewport = try XCTUnwrap(rig.session.shownState).viewport
        XCTAssertGreaterThan(viewport.scale, 1.9)
        XCTAssertEqual(viewport.cropRect.maxY, letter.height, accuracy: 0.01)
        XCTAssertFalse(rig.session.handle(.zoomIntoTable), "no table on this page: the words go on")
    }
}
#endif
