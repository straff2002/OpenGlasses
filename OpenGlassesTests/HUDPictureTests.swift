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
            "  metaRayBan: views opened 2, Show here cues 1 (pressed 1), zooms 4, moves 3, next pages 0,"
                + " reading views 0 (pages turned 0), refused 0, stale presses dropped 0",
            "    Render: 3, median 60 ms, largest 90 ms",
            "    Sent: 2, median 3 KB, largest 4 KB; send time 1, median 200 ms, largest 200 ms",
            "    Highlighted: none",
            "    Presses: 0 (close-ups 0, fit width 0, back 0, rows 0, rows spoken 0); per view none",
            "    Pictures sent: none; factor 1",
        ])
    }

    /// Plan MU: what each view highlighted, the presses getting around took (per view), and every
    /// picture's size as sent, with the factor.
    func testTheLinesSayWhatWasHighlightedThePressesAndThePictureSizes() {
        var stats = LensPageStats()
        stats.update("metaRayBan") {
            $0.viewsOpened = 3
            $0.highlights = ["table_row": 2, "none": 1]
            $0.presses = 4
            $0.closeUps = 2
            $0.backs = 1
            $0.rowsViews = 1
            $0.pressesPerView = [1, 3]
            $0.pictureSizes = ["576×338", "576×600", "576×338"]
            $0.pictureFactor = 1.3333
        }
        let lines = LensPageReport.lines(for: stats)
        XCTAssertTrue(lines.contains("    Highlighted: none 1, table_row 2"), "\(lines)")
        XCTAssertTrue(lines.contains("    Presses: 4 (close-ups 2, fit width 0, back 1, rows 1, rows spoken 0);"
                                     + " per view 2, median 2 presses, largest 3 presses"), "\(lines)")
        XCTAssertTrue(lines.contains("    Pictures sent: 576×338 ×2, 576×600 ×1; factor 1.33"), "\(lines)")
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
                                       crop: CGRect(x: 10.4, y: 20.6, width: 198, height: 159), zoom: 2.4567,
                                       route: "requested", backend: "metaRayBan", view: .picture)
        let zoomed = FieldSessionService.pageOnGlassesEvent(viewed, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(zoomed.payload?["crop"]?.value as? String, "10,20,199,160")
        XCTAssertEqual(zoomed.payload?["zoom"]?.value as? Double, 2.46, "the scale to two places")
        XCTAssertEqual(zoomed.payload?["view"]?.value as? String, "picture")

        // Reading mode: the page reference and the view, never a crop or the words.
        let read = LensPageAuditLine(event: .readPage, documentTitle: "Invented Unit Guide", page: 3, figure: nil,
                                     crop: .zero, zoom: 0, route: "requested", backend: "metaRayBan", view: .reading)
        let reading = FieldSessionService.pageOnGlassesEvent(read, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reading.payload?["view"]?.value as? String, "reading")
        XCTAssertEqual(reading.payload?["event"]?.value as? String, "read_page")
        XCTAssertNil(reading.payload?["crop"])
        XCTAssertNil(reading.payload?["zoom"])

        // Plan MU §6: the rows view carries no crop either; a picture line says what it highlighted.
        let rows = LensPageAuditLine(event: .rows, documentTitle: "Invented Unit Guide", page: 3, figure: nil,
                                     crop: .zero, zoom: 0, route: "requested", backend: "metaRayBan", view: .rows,
                                     highlight: "table_row")
        let rowsEvent = FieldSessionService.pageOnGlassesEvent(rows, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rowsEvent.payload?["view"]?.value as? String, "rows")
        XCTAssertEqual(rowsEvent.payload?["highlight"]?.value as? String, "table_row")
        XCTAssertNil(rowsEvent.payload?["crop"])
        XCTAssertNil(zoomed.payload?["highlight"], "no reason given, none written")
    }
}
#endif
