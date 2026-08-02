import XCTest
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
