#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KV P3 — the page view in the phone preview: the frame the preview draws is the session's
/// frame (the picture, the same buttons as the lens), and a press on the preview reaches the same
/// `LensPageSession` a band press does. Every other screen stays view-only on the phone.
///
/// Headless, as `LensPageSessionTests`: fresh services, frames through `testRenderSink`, layouts
/// and pictures from fakes.
@MainActor
final class LensPagePreviewTests: XCTestCase {

    private typealias ID = HUDPageScreenBuilder.ItemID

    private struct Rig {
        let display: GlassesDisplayService
        let router: HUDRouter
        let session: LensPageSession
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

    private func makeRig() -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let router = HUDRouter(display: display)
        let session = LensPageSession(display: display, router: router)
        router.pageView = session
        session.sourceURL = { _ in URL(fileURLWithPath: "/invented/guide.pdf") }
        session.requestWords = { "show me the page" }
        session.layoutPage = { _ in
            LensPageLayout(pageSize: LensPageFixtures.letter, marks: nil,
                           pictureAreas: [CGRect(x: 72, y: 300, width: 200, height: 60)], tone: .lineArt)
        }
        session.renderPicture = { _, _ in LensPageFixtures.picture() }
        session.scheduleTimer = { _, _ in }
        session.backend = { "metaRayBan" }
        return Rig(display: display, router: router, session: session)
    }

    private func drain(_ rig: Rig) async {
        for _ in 0..<12 {
            await Task.yield()
            await rig.session.settle()
        }
    }

    private func buttons(in tree: MWDATDisplay.FlexBox) -> [MWDATDisplay.Button] {
        tree.children.flatMap { child -> [MWDATDisplay.Button] in
            if let group = child as? MWDATDisplay.ButtonGroup { return group.buttons }
            if let button = child as? MWDATDisplay.Button { return [button] }
            return []
        }
    }

    // MARK: - What the preview draws

    func testThePreviewFrameIsTheSessionsFrame() async throws {
        let rig = makeRig()
        XCTAssertNil(rig.router.previewFrame, "nothing on the lens, nothing in the preview")
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)

        let frame = try XCTUnwrap(rig.router.previewFrame)
        let shown = try XCTUnwrap(rig.session.shownScreen)
        XCTAssertNotNil(frame.picture, "the picture the lens got")
        XCTAssertTrue(frame.picture === shown.picture?.image)
        XCTAssertEqual(frame.itemIDs, shown.items.map(\.id), "the same buttons as the lens")
        XCTAssertEqual(frame.itemIDs, [ID.zoomIn, ID.wholePage, ID.move, ID.close])
        XCTAssertTrue(frame.isPressable)

        // The tree the preview draws: the picture, and the lens's button labels in order.
        let preview = GlassesDisplayService.previewFlexBox(for: frame.screen)
        XCTAssertTrue(preview.children.contains { ($0 as? MWDATDisplay.Image)?.sizePreset == .fill })
        let lens = MetaDisplayBackend().makeScreenView(shown)
        XCTAssertEqual(buttons(in: preview).map(\.label), buttons(in: lens).map(\.label))
    }

    func testThePreviewFollowsEachFrame() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertTrue(rig.router.pressFromPreview(ID.move))
        await drain(rig)
        XCTAssertEqual(rig.router.previewFrame?.itemIDs, [ID.up, ID.down, ID.left, ID.right, ID.done],
                       "the arrow row, as on the lens")
        XCTAssertEqual(rig.router.previewFrame?.itemIDs, rig.session.shownScreen?.items.map(\.id))
    }

    // MARK: - Presses

    func testAPreviewPressReachesTheSession() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        let opening = try XCTUnwrap(rig.session.shownState)

        XCTAssertTrue(rig.router.pressFromPreview(ID.zoomIn))
        await drain(rig)
        XCTAssertGreaterThan(try XCTUnwrap(rig.session.shownState).viewport.pixelsPerPoint,
                             opening.viewport.pixelsPerPoint)
        XCTAssertEqual(rig.session.stats["metaRayBan"].zooms, 1)

        // Through the tree the preview draws: its buttons press the session too.
        let frame = try XCTUnwrap(rig.router.previewFrame)
        let router = rig.router
        let tree = GlassesDisplayService.previewFlexBox(for: frame.screen,
                                                        onSelect: { id in router.pressFromPreview(id) })
        XCTAssertEqual(frame.itemIDs, [ID.zoomIn, ID.wholePage, ID.move, ID.close], "one rung in")
        let index = try XCTUnwrap(frame.itemIDs.firstIndex(of: ID.wholePage))
        buttons(in: tree)[index].onClick?()
        await drain(rig)
        XCTAssertTrue(try XCTUnwrap(rig.session.shownState).viewport.isWholePage)
        XCTAssertEqual(rig.session.stats["metaRayBan"].zooms, 2)

        XCTAssertTrue(rig.router.pressFromPreview(ID.close))
        await drain(rig)
        XCTAssertNil(rig.session.held)
        XCTAssertNil(rig.router.previewFrame, "closed: the preview is idle again")
    }

    func testShowHereWorksFromThePreview() async throws {
        let rig = makeRig()
        rig.session.stage([LensPageFixtures.staged(origin: .automatic)])
        await drain(rig)
        XCTAssertEqual(rig.router.previewFrame?.itemIDs, [ID.showHere])
        XCTAssertTrue(rig.router.previewFrame?.isPressable == true)
        XCTAssertTrue(rig.router.pressFromPreview(ID.showHere))
        await drain(rig)
        XCTAssertEqual(rig.session.held, .view)
        XCTAssertNotNil(rig.router.previewFrame?.picture)
    }

    func testOtherScreensStayViewOnly() async {
        let rig = makeRig()
        XCTAssertFalse(rig.router.pressFromPreview(ID.zoomIn), "no page view")
        rig.session.stage([LensPageFixtures.staged(origin: .requested)])
        await drain(rig)
        XCTAssertFalse(rig.router.pressFromPreview("kv.page.invented"), "an id the frame doesn't have")

        // An answer card in the preview: drawn, not pressable.
        rig.session.close()
        let card = HUDAnswerCard(display: rig.display)
        card.geometry = { .raybanDisplay }
        card.scheduleIdleTimer = { _, _ in }
        card.absorb("The invented filter is behind the front grille.", streamed: false)
        XCTAssertFalse(rig.router.previewFrame?.isPressable ?? false)
        XCTAssertFalse(rig.router.pressFromPreview(HUDAnswerCardBuilder.ItemID.actions))
    }
}
#endif
