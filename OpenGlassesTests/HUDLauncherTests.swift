import XCTest
@testable import OpenGlasses

/// Tests for the HUD launcher (Display Phase 4 / Plan Y): the pure menu builders, the
/// open-command parser, and the router's navigation stack (driven headlessly via the
/// GlassesDisplayService test seam, simulating the band by firing rendered buttons).
@MainActor
final class HUDLauncherTests: XCTestCase {

    private func settle(_ ms: UInt64 = 40) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func makePersona(_ id: String, _ name: String) -> Persona {
        Persona(id: id, name: name, wakePhrase: "hey \(name.lowercased())", alternativeWakePhrases: [],
                modelId: "model-\(id)", presetId: "preset-default", enabled: true,
                icon: nil, isBuiltIn: nil, soulOverride: nil, chattinessRaw: nil,
                allowedTools: nil, ownedTaskIds: nil)
    }

    // MARK: - Menu builders (pure)

    func testRootAppendsClose() {
        var closed = false
        let screen = HUDMenuBuilder.root(branches: [HUDItem(id: "b", label: "Branch") {}],
                                         onClose: { closed = true })
        XCTAssertEqual(screen.title, "Menu")
        XCTAssertEqual(screen.items.map(\.id), ["b", "close"])
        screen.items.first { $0.id == "close" }?.action()
        XCTAssertTrue(closed)
    }

    func testQuickActionsBuildsItemsAndRuns() {
        let actions = [QuickAction(id: "1", label: "Take Photo", icon: "camera", type: .photo),
                       QuickAction(id: "2", label: "Ask", icon: "bubble", type: .prompt)]
        var ran: QuickAction?
        var backed = false
        let screen = HUDMenuBuilder.quickActions(actions, onRun: { ran = $0 }, onBack: { backed = true })
        XCTAssertEqual(screen.items.map(\.id), ["qa:1", "qa:2", "back"])
        screen.items.first { $0.id == "qa:1" }?.action()
        XCTAssertEqual(ran?.id, "1")
        screen.items.first { $0.id == "back" }?.action()
        XCTAssertTrue(backed)
    }

    func testPersonasMarksActive() {
        let screen = HUDMenuBuilder.personas([makePersona("a", "Claude"), makePersona("b", "Jarvis")],
                                             activeId: "b", onSelect: { _ in }, onBack: {})
        XCTAssertEqual(screen.items.map(\.id), ["persona:a", "persona:b", "back"])
        XCTAssertEqual(screen.items.first { $0.id == "persona:b" }?.label, "✓ Jarvis")
        XCTAssertEqual(screen.items.first { $0.id == "persona:a" }?.label, "Claude")
    }

    // MARK: - Open command

    func testIsOpenCommand() {
        XCTAssertTrue(HUDLauncher.isOpenCommand("menu"))
        XCTAssertTrue(HUDLauncher.isOpenCommand("Show menu."))
        XCTAssertTrue(HUDLauncher.isOpenCommand("open the menu"))
        XCTAssertFalse(HUDLauncher.isOpenCommand("what's on the menu for dinner"))
        XCTAssertFalse(HUDLauncher.isOpenCommand("next"))
    }

    // MARK: - Router navigation stack

    func testRouterStackPushPopDismiss() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        var frames: [GlassesDisplayService.HUDFrame] = []
        display.testRenderSink = { frames.append($0) }
        let router = HUDRouter(display: display)

        let child = HUDScreen(title: "Child", items: [HUDItem(id: "back", label: "Back") { router.pop() }])
        let root = HUDScreen(title: "Root", items: [HUDItem(id: "go", label: "Go") { router.push(child) }])

        router.openLauncher(root)
        await settle()
        XCTAssertEqual(router.menuDepth, 1)
        XCTAssertTrue(router.isPresentingMenu)

        // Simulate band-selecting "Go" → pushes the child screen.
        display.testInteractiveButtonActions(for: root).first?()
        await settle()
        XCTAssertEqual(router.menuDepth, 2)

        // Simulate band-selecting "Back" → pops to root.
        display.testInteractiveButtonActions(for: child).first?()
        await settle()
        XCTAssertEqual(router.menuDepth, 1)

        router.dismiss()
        await settle()
        XCTAssertFalse(router.isPresentingMenu)
        XCTAssertEqual(router.menuDepth, 0)
        XCTAssertEqual(frames.last, .clear)
    }

    func testRouterPublishesCurrentScreenForMirror() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let router = HUDRouter(display: display)

        XCTAssertNil(router.currentScreen)
        router.openLauncher(HUDScreen(title: "Root"))
        await settle()
        XCTAssertEqual(router.currentScreen?.title, "Root")   // the live mirror binds to this
        router.dismiss()
        await settle()
        XCTAssertNil(router.currentScreen)
    }

    func testPopFromRootDismisses() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let router = HUDRouter(display: display)

        router.openLauncher(HUDScreen(title: "Root"))
        await settle()
        XCTAssertEqual(router.menuDepth, 1)

        router.pop()        // popping the last screen closes the launcher
        await settle()
        XCTAssertEqual(router.menuDepth, 0)
        XCTAssertFalse(router.isPresentingMenu)
    }
}
