import XCTest
@testable import OpenGlasses

/// Headless tests for the interactive HUD layer in `GlassesDisplayService` (Display
/// Phase 3 / Plan X). No Ray-Ban Display hardware exists in CI, so we drive the real
/// queue/gate/dedup/flash-restore logic through the test seam: `testCapabilityOverride`
/// fakes a display-capable device, `testRenderSink` captures the frame each render
/// *would* send, and the Neural Band is simulated by firing the rendered buttons'
/// `onClick`. These tests are the only validation this code gets — keep them thorough.
@MainActor
final class GlassesDisplayInteractiveTests: XCTestCase {

    private var svc: GlassesDisplayService!
    private var frames: [GlassesDisplayService.HUDFrame] = []
    private var savedFlag = false

    override func setUp() {
        super.setUp()
        savedFlag = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        frames = []
        svc = GlassesDisplayService()
        svc.testCapabilityOverride = true
        svc.testRenderSink = { [weak self] frame in self?.frames.append(frame) }
    }

    override func tearDown() {
        Config.setGlassesDisplayEnabled(savedFlag)
        svc = nil
        super.tearDown()
    }

    /// Let the render queue's drain Task run (it's spawned, not synchronous).
    private func settle(_ ms: UInt64 = 40) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func card(_ key: String, items: [String] = ["done"]) -> HUDScreen {
        HUDScreen(title: key, items: items.map { id in HUDItem(id: id, label: id.capitalized) {} })
    }

    // MARK: - Presentation & interactive mode

    func testPresentScreenEntersInteractiveAndRenders() async {
        let screen = card("Card")
        svc.present(screen: screen) { _ in }
        await settle()
        XCTAssertTrue(svc.isInteractive)
        XCTAssertEqual(frames, [.screen(renderKey: screen.renderKey)])
    }

    func testEndInteractiveClearsAndExits() async {
        svc.present(screen: card("Card")) { _ in }
        await settle()
        frames.removeAll()
        svc.endInteractive()
        await settle()
        XCTAssertFalse(svc.isInteractive)
        XCTAssertEqual(frames, [.clear])
    }

    // MARK: - Ambient suppression gate

    func testPersistentAmbientTextSuppressedWhileInteractive() async {
        svc.present(screen: card("Card")) { _ in }
        await settle()
        frames.removeAll()
        svc.showText("an AI reply")          // persistent ambient → suppressed
        svc.showNavigation("turn left")      // persistent ambient → suppressed
        await settle()
        XCTAssertEqual(frames, [])
    }

    func testNotificationFlashesThenRestoresScreenWhileInteractive() async {
        let screen = card("Card")
        svc.present(screen: screen) { _ in }
        await settle()
        frames.removeAll()

        svc.showNotification(title: nil, body: "ping", icon: .message, duration: 0.05)
        await settle(25)                     // before the flash auto-clears
        XCTAssertEqual(frames, [.content(body: "ping", title: nil, icon: .message)])

        await settle(120)                    // after the flash duration
        XCTAssertEqual(frames.last, .screen(renderKey: screen.renderKey))   // screen restored
    }

    // MARK: - Ambient behaviour when NOT interactive

    func testAmbientTextRendersWhenNotInteractive() async {
        svc.showText("hello there")
        await settle()
        XCTAssertEqual(frames, [.content(body: "hello there", title: nil, icon: .none)])
    }

    func testNonInteractiveFlashAutoClears() async {
        svc.flash("brief", duration: 0.05)
        await settle(25)
        XCTAssertEqual(frames, [.content(body: "brief", title: nil, icon: .none)])
        await settle(120)
        XCTAssertEqual(frames.last, .clear)
    }

    // MARK: - Dedup (latest-wins / render-key collapse)

    func testIdenticalScreenRendersOnce() async {
        let screen = card("Card")
        svc.present(screen: screen) { _ in }
        svc.present(screen: screen) { _ in }
        await settle()
        XCTAssertEqual(frames, [.screen(renderKey: screen.renderKey)])
    }

    func testIdenticalAmbientContentRendersOnce() async {
        svc.showText("same line")
        svc.showText("same line")
        await settle()
        XCTAssertEqual(frames, [.content(body: "same line", title: nil, icon: .none)])
    }

    // MARK: - Capability / feature-flag guards

    func testNoDisplayCapabilitySuppressesEverything() async {
        svc.testCapabilityOverride = false
        svc.present(screen: card("Card")) { _ in }
        svc.showText("x")
        await settle()
        XCTAssertFalse(svc.isInteractive)
        XCTAssertEqual(frames, [])
    }

    func testFeatureFlagOffSuppressesEverything() async {
        Config.setGlassesDisplayEnabled(false)
        svc.present(screen: card("Card")) { _ in }
        svc.showText("x")
        await settle()
        XCTAssertEqual(frames, [])
    }

    // MARK: - Simulated Neural-Band selection

    func testBandSelectionRoutesToHandlerById() async {
        let screen = card("Card", items: ["done", "skip", "back"])
        var received: [String] = []
        svc.present(screen: screen) { received.append($0) }
        await settle()

        let actions = svc.testInteractiveButtonActions(for: screen)
        XCTAssertEqual(actions.count, 3)
        for fire in actions { fire() }       // simulate pinch-select on each button
        await settle()

        XCTAssertEqual(received, ["done", "skip", "back"])
    }
}
