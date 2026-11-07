#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KV P1 §6 — the picture on a HUD screen: part of `renderKey` by its content key only, drawn
/// by the Meta backend as an `Image` above the button row, and never handed to a backend that
/// draws text only (the Even G2), which renders the same lines as before.
@MainActor
final class HUDPictureTests: XCTestCase {

    private func picture(_ key: String) -> HUDPicture {
        HUDPicture(image: LensPageFixtures.picture(), pixelSize: CGSize(width: 600, height: 600), contentKey: key)
    }

    private func screen(_ picture: HUDPicture?) -> HUDScreen {
        var screen = HUDScreen(title: nil, lines: [HUDLine("p. 3", emphasis: .meta)],
                               items: [HUDItem(id: "kv.page.close", label: "Close", style: .outline) {}])
        screen.picture = picture
        return screen
    }

    // MARK: - renderKey

    func testRenderKeyChangesWithThePicturesKeyOnly() {
        let plain = screen(nil)
        XCTAssertEqual(plain.renderKey, "|meta:none:p. 3|kv.page.close:outline:none:Close",
                       "a screen without a picture keys as it always has")
        XCTAssertNotEqual(screen(picture("a")).renderKey, plain.renderKey)
        XCTAssertNotEqual(screen(picture("a")).renderKey, screen(picture("b")).renderKey)
        let redrawn = HUDPicture(image: LensPageFixtures.picture(16), pixelSize: CGSize(width: 600, height: 600),
                                 contentKey: "a")
        XCTAssertEqual(screen(picture("a")).renderKey, screen(redrawn).renderKey,
                       "the same content key is the same frame, whatever the pixels")
    }

    // MARK: - Backends

    func testTheMetaBackendDrawsThePictureAboveTheButtons() throws {
        let backend = MetaDisplayBackend()
        XCTAssertTrue(backend.drawsPictures)
        let tree = backend.makeScreenView(screen(picture("a")))
        let imageIndex = try XCTUnwrap(tree.children.firstIndex { $0 is MWDATDisplay.Image })
        let buttonsIndex = try XCTUnwrap(tree.children.firstIndex { $0 is ButtonGroup })
        XCTAssertLessThan(imageIndex, buttonsIndex)
        XCTAssertEqual((tree.children[imageIndex] as? MWDATDisplay.Image)?.sizePreset, .fill)
        XCTAssertNotNil(MetaDisplayBackend.pictureBytes(in: tree))

        let plain = backend.makeScreenView(screen(nil))
        XCTAssertFalse(plain.children.contains { $0 is MWDATDisplay.Image })
        XCTAssertNil(MetaDisplayBackend.pictureBytes(in: plain))
    }

    func testTheButtonsStillRouteBackWithAPictureOnTheScreen() {
        let backend = MetaDisplayBackend()
        var selected: [String] = []
        backend.onItemSelected = { selected.append($0) }
        let actions = backend.testButtonActions(for: screen(picture("a")))
        XCTAssertEqual(actions.count, 1)
    }

    private final class RecordingTransport: EvenTransporting {
        var isConnected = false
        var sent: [[UInt8]] = []
        var onEvent: (([UInt8]) -> Void)?
        var onDisconnect: ((Error?) -> Void)?
        func connect() async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func sendRenderPacket(_ bytes: [UInt8]) async throws { sent.append(bytes) }
    }

    func testTheEvenBackendNeverGetsAPicture() async throws {
        let withPicture = RecordingTransport()
        let withoutPicture = RecordingTransport()
        let even = EvenDisplayBackend(transport: withPicture)
        XCTAssertFalse(even.drawsPictures)
        try await even.send(screen: screen(picture("a")))
        try await EvenDisplayBackend(transport: withoutPicture).send(screen: screen(nil))
        XCTAssertFalse(withPicture.sent.isEmpty)
        XCTAssertEqual(withPicture.sent, withoutPicture.sent, "the same text frame, byte for byte")
        XCTAssertNil(even.lastPictureBytes)
    }

    func testTheServiceStripsThePictureForABackendThatDrawsTextOnly() {
        let shown = screen(picture("a"))
        XCTAssertNil(GlassesDisplayService.screen(shown, forBackendDrawingPictures: false).picture)
        XCTAssertEqual(GlassesDisplayService.screen(shown, forBackendDrawingPictures: false).lines, shown.lines)
        XCTAssertEqual(GlassesDisplayService.screen(shown, forBackendDrawingPictures: true).picture?.contentKey, "a")
    }

    func testTheUnsupportedBackendDrawsNoPictures() {
        XCTAssertFalse(UnsupportedGlassesDisplayBackend().drawsPictures)
    }
}

/// Plan KV P1 §5 — the support report's **Page on the lens** lines and the audit event's shape.
final class LensPageReportTests: XCTestCase {

    func testANewRunSaysTheLensWasNotUsed() {
        XCTAssertEqual(LensPageReport.lines(for: LensPageStats()), ["Page on the lens: not used since the app started"])
    }

    func testTheLinesCountAndTimeByBackend() {
        var stats = LensPageStats()
        stats.update("metaRayBan") {
            $0.viewsOpened = 2
            $0.cuesShown = 1
            $0.showHerePressed = 1
            $0.zooms = 4
            $0.moves = 3
            $0.renderMs = [90, 30, 60]
            $0.sentBytes = [2048, 4096]
            $0.sendMs = [200]
        }
        let lines = LensPageReport.lines(for: stats)
        XCTAssertEqual(lines, [
            "Page on the lens (since the app started):",
            "  metaRayBan: views opened 2, Show here cues 1 (pressed 1), zooms 4, moves 3, next pages 0, refused 0, stale presses dropped 0",
            "    Render: 3, median 60 ms, largest 90 ms",
            "    Sent: 2, median 3 KB, largest 4 KB; send time 1, median 200 ms, largest 200 ms",
        ])
    }

    func testTimingsAreKeptToTheLastFifty() {
        var stats = LensPageStats()
        stats.update("metaRayBan") { $0.renderMs = Array(0..<80) }
        XCTAssertEqual(stats["metaRayBan"].renderMs.count, LensPageStats.keep)
        XCTAssertEqual(stats["metaRayBan"].renderMs.first, 30)
    }

    func testACueLineCarriesNoCrop() {
        let line = LensPageAuditLine(event: .cueShown, documentTitle: "Invented Unit Guide", page: 3, figure: nil,
                                     crop: .zero, zoom: 0, route: "automatic", backend: "metaRayBan")
        let event = FieldSessionService.pageOnGlassesEvent(line, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(event.kind, .pageOnGlasses)
        XCTAssertNil(event.payload?["crop"])
        XCTAssertEqual(event.payload?["event"]?.value as? String, "cue_shown")

        let viewed = LensPageAuditLine(event: .zoomed, documentTitle: "Invented Unit Guide", page: 3, figure: "Figure 9",
                                       crop: CGRect(x: 10.4, y: 20.6, width: 198, height: 198), zoom: 4,
                                       route: "requested", backend: "metaRayBan")
        let zoomed = FieldSessionService.pageOnGlassesEvent(viewed, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(zoomed.payload?["crop"]?.value as? String, "10,20,199,199")
        XCTAssertEqual(zoomed.payload?["zoom"]?.value as? Int, 4)
    }
}
#endif
