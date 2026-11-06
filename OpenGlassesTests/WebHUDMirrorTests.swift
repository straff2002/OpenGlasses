import XCTest
import JavaScriptCore
@testable import OpenGlasses

/// Plan BP — the deterministic mirror: payload mapping, the single-file HTML renderer's
/// platform properties (additive-black, self-contained, no-cyan focus, escaping,
/// determinism), the pure request router, and the display service's mirror tap.
@MainActor
final class WebHUDMirrorTests: XCTestCase {

    private func sampleScreen() -> HUDScreen {
        HUDScreen(title: "Pump check", lines: [
            HUDLine("Close the valve", icon: .hazard),
            HUDLine("Step 2 of 5", emphasis: .meta),
        ], items: [
            HUDItem(id: "done", label: "Done", style: .primary) {},
            HUDItem(id: "skip", label: "Skip") {},
        ])
    }

    // MARK: - Payload

    func testPayloadMappingIsStable() throws {
        let payload = WebHUDPayload.from(screen: sampleScreen())
        XCTAssertEqual(payload.title, "Pump check")
        XCTAssertEqual(payload.lines.map(\.icon), ["hazard", "none"])
        XCTAssertEqual(payload.lines.map(\.emphasis), ["primary", "meta"])
        XCTAssertEqual(payload.items.map(\.style), ["primary", "secondary"])
        XCTAssertEqual(payload.renderKey, sampleScreen().renderKey)

        let decoded = try JSONDecoder().decode(WebHUDPayload.self, from: payload.jsonData())
        XCTAssertEqual(decoded, payload)
    }

    func testAllIconsHaveWireNames() {
        let icons: [HUDIcon] = [.none, .info, .success, .warning, .error, .navigation,
                                .hazard, .calendar, .location, .reminder, .message]
        let names = icons.map(WebHUDPayload.iconName)
        XCTAssertEqual(Set(names).count, icons.count, "wire names must be distinct")
    }

    // MARK: - Renderer platform properties

    func testPageIsAdditiveBlackAndSelfContained() {
        let html = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: sampleScreen())))
        XCTAssertTrue(html.contains("background: #000"), "black = transparent on the additive display")
        XCTAssertTrue(html.contains("mrbd-web-app-capable"))
        XCTAssertFalse(html.contains("https://"), "no external fetches — self-contained page")
        XCTAssertFalse(html.contains("http://"), "no external fetches")
        XCTAssertFalse(html.lowercased().contains("cyan"), "house rule: focus is never cyan")
        XCTAssertFalse(html.contains("#0ff"))
        XCTAssertFalse(html.lowercased().contains("#00ffff"))
        XCTAssertTrue(html.contains("#ffb000"), "amber focus indicator")
    }

    func testInlineModeCarriesEveryItemExactlyOnce() {
        let html = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: sampleScreen())))
        XCTAssertEqual(html.components(separatedBy: "\"Done\"").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "\"Skip\"").count - 1, 1)
        XCTAssertTrue(html.contains("INLINE_PAYLOAD = {"))
    }

    func testPollingModeHasNoInlinePayload() {
        let html = WebHUDRenderer.page(mode: .polling(intervalSeconds: 2))
        XCTAssertTrue(html.contains("INLINE_PAYLOAD = null"))
        XCTAssertTrue(html.contains("POLL_SECONDS = 2"))
        XCTAssertTrue(html.contains("hud.json?t="), "poll forwards the hash token as a query param")
    }

    func testScriptCloseSequenceIsEscaped() {
        let hostile = HUDScreen(title: "</script><script>alert(1)</script>",
                                lines: [HUDLine("</script> body")])
        let html = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: hostile)))
        // The inline JSON must not be able to close our script tag.
        XCTAssertFalse(html.contains("</script><script>alert"),
                       "payload text must not escape the script block")
        XCTAssertTrue(html.contains("<\\/script>"))
    }

    func testRenderIsDeterministic() {
        let a = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: sampleScreen())))
        let b = WebHUDRenderer.page(mode: .inline(WebHUDPayload.from(screen: sampleScreen())))
        XCTAssertEqual(a, b)
    }

    // MARK: - Router

    func testRouterServesPageWithoutToken() {
        let response = WebHUDMirrorServer.routeResponse(
            method: "GET", target: "/", hipaa: false, expectedToken: "secret", payload: .empty)
        XCTAssertEqual(response.status, "200 OK")
        XCTAssertTrue(response.contentType.hasPrefix("text/html"))
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("INLINE_PAYLOAD = null"),
                      "the served page carries no data — data needs the token")
    }

    func testRouterGuardsDataEndpoint() throws {
        let payload = WebHUDPayload.from(screen: sampleScreen())
        let ok = WebHUDMirrorServer.routeResponse(
            method: "GET", target: "/hud.json?t=secret", hipaa: false,
            expectedToken: "secret", payload: payload)
        XCTAssertEqual(ok.status, "200 OK")
        XCTAssertEqual(try JSONDecoder().decode(WebHUDPayload.self, from: ok.body), payload)

        let bad = WebHUDMirrorServer.routeResponse(
            method: "GET", target: "/hud.json?t=wrong", hipaa: false,
            expectedToken: "secret", payload: payload)
        XCTAssertEqual(bad.status, "401 Unauthorized")
        let missing = WebHUDMirrorServer.routeResponse(
            method: "GET", target: "/hud.json", hipaa: false,
            expectedToken: "secret", payload: payload)
        XCTAssertEqual(missing.status, "401 Unauthorized")
    }

    func testRouterHIPAARefusesEverything() {
        for target in ["/", "/hud.json?t=secret", "/anything"] {
            let response = WebHUDMirrorServer.routeResponse(
                method: "GET", target: target, hipaa: true,
                expectedToken: "secret", payload: .empty)
            XCTAssertEqual(response.status, "503 Service Unavailable", target)
        }
    }

    func testRouterIsReadOnlyAnd404s() {
        XCTAssertEqual(WebHUDMirrorServer.routeResponse(
            method: "POST", target: "/hud.json?t=secret", hipaa: false,
            expectedToken: "secret", payload: .empty).status, "405 Method Not Allowed")
        XCTAssertEqual(WebHUDMirrorServer.routeResponse(
            method: "GET", target: "/etc/passwd", hipaa: false,
            expectedToken: "secret", payload: .empty).status, "404 Not Found")
    }

    func testConstantTimeEqualsAndTokenParsing() {
        XCTAssertTrue(WebHUDMirrorServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(WebHUDMirrorServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(WebHUDMirrorServer.constantTimeEquals("abc", "ab"))
        XCTAssertEqual(WebHUDMirrorServer.queryToken(in: "/hud.json?t=a%2Bb"), "a+b")
        XCTAssertEqual(WebHUDMirrorServer.queryToken(in: "/hud.json?x=1&t=tok"), "tok")
        XCTAssertNil(WebHUDMirrorServer.queryToken(in: "/hud.json"))
    }

    // MARK: - Answer card pages (Plan KP P1)

    private let longAnswer = """
    Turn the isolator off before you open the panel. Check the capacitor with a meter, \
    because it can hold a charge for minutes after the power is cut. If the reading is above \
    five volts, discharge it with an insulated resistor. Then swap the contactor, refit the \
    cover and restore the power.
    """

    /// An answer card, as the display service holds it and the mirror reads it.
    private func answerCardScreen() async -> HUDScreen? {
        let service = GlassesDisplayService()
        service.testCapabilityOverride = true
        service.testRenderSink = { _ in }
        let card = HUDAnswerCard(display: service)
        card.geometry = { .raybanDisplay }
        card.absorb(longAnswer, streamed: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        return service.mirrorScreen
    }

    func testTheAnswerCardsPagesAndFootersReachTheMirror() async throws {
        let wasEnabled = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(wasEnabled) }

        let held = await answerCardScreen()
        let screen = try XCTUnwrap(held)
        let payload = WebHUDPayload.from(screen: screen)
        let pages = try XCTUnwrap(payload.pages)
        XCTAssertGreaterThan(pages.count, 2)
        XCTAssertEqual(payload.pageIndex, 0)
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.lines.last?.text, "\(index + 1)/\(pages.count)", "the footer shows")
            XCTAssertEqual(page.lines.last?.emphasis, "meta")
        }
        XCTAssertEqual(payload.lines, pages[0].lines, "the frame itself is page 1")
        XCTAssertEqual(pages.last?.items.map(\.id), [HUDAnswerCardBuilder.ItemID.actions,
                                                      HUDAnswerCardBuilder.ItemID.back])

        // The page shown can stay the same while pages become readable behind it, so the key the
        // page re-renders on names the card and its pages as well.
        XCTAssertTrue(payload.renderKey.hasPrefix(screen.renderKey))
        XCTAssertNotEqual(payload.renderKey, screen.renderKey)
        XCTAssertNotNil(payload.card)

        let decoded = try JSONDecoder().decode(WebHUDPayload.self, from: payload.jsonData())
        XCTAssertEqual(decoded, payload)

        // Every other frame carries no pages, so its JSON is unchanged.
        XCTAssertNil(WebHUDPayload.from(screen: sampleScreen()).pages)
        XCTAssertFalse(String(decoding: WebHUDPayload.from(screen: sampleScreen()).jsonData(),
                              as: UTF8.self).contains("pages"))
    }

    func testTheArrowKeysTurnPagesAndEscapeCloses() {
        let html = WebHUDRenderer.page(mode: .polling(intervalSeconds: 2))
        XCTAssertTrue(html.contains(WebHUDRenderer.pagingScript))
        XCTAssertTrue(html.contains("\"ArrowRight\""))
        XCTAssertTrue(html.contains("\"ArrowLeft\""))
        XCTAssertTrue(html.contains("\"Escape\""))
        XCTAssertFalse(html.contains("method: \"POST\""), "paging stays on the page: the mirror is read-only")

        // The paging rule itself, run as the page runs it.
        guard let context = JSContext() else { return XCTFail("no JavaScript context") }
        context.evaluateScript(WebHUDRenderer.pagingScript)
        func page(_ key: String, _ index: Int, _ count: Int) -> Int32 {
            context.evaluateScript("pageAfterKey(\"\(key)\", \(index), \(count))").toInt32()
        }
        XCTAssertEqual(page("ArrowRight", 0, 3), 1)
        XCTAssertEqual(page("ArrowRight", 2, 3), 2, "clamped at the last page")
        XCTAssertEqual(page("ArrowLeft", 2, 3), 1)
        XCTAssertEqual(page("ArrowLeft", 0, 3), 0, "clamped at the first page")
        XCTAssertEqual(page("ArrowDown", 1, 3), 1, "other keys leave the page")
        XCTAssertEqual(page("ArrowRight", 0, 0), 0)
    }

    // MARK: - Mirror tap on the display service

    func testMirrorScreenFollowsTheRenderQueue() async {
        let wasEnabled = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(wasEnabled) }
        let service = GlassesDisplayService()
        service.testCapabilityOverride = true
        service.testRenderSink = { _ in }

        service.showText("hello")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.mirrorScreen?.lines.first?.text, "hello")
        XCTAssertNil(service.mirrorScreen?.title)

        service.present(screen: sampleScreen()) { _ in }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.mirrorScreen?.renderKey, sampleScreen().renderKey)

        service.endInteractive()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(service.mirrorScreen, "clear empties the mirror")
    }

    func testMirrorOnlyModeWorksWithoutNativeDisplay() async {
        // The entitlement-free story: no DAT display, mirror flag on → the queue still
        // resolves frames for the mirror (the backend send is capability-gated away).
        let wasEnabled = Config.glassesDisplayEnabled
        let wasMirror = Config.hudMirrorEnabled
        Config.setGlassesDisplayEnabled(true)
        Config.hudMirrorEnabled = true
        defer {
            Config.setGlassesDisplayEnabled(wasEnabled)
            Config.hudMirrorEnabled = wasMirror
        }
        let service = GlassesDisplayService()
        service.testCapabilityOverride = false   // no native display
        service.testRenderSink = { _ in }

        service.showText("mirror only")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.mirrorScreen?.lines.first?.text, "mirror only")
    }
}
