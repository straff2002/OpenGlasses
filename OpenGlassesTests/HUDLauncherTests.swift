import XCTest
import Combine
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

    // MARK: - Workflows / SOPs builders (pure)

    private func makePlaybook(_ name: String) -> Playbook {
        Playbook(name: name, steps: [PlaybookStep(title: "Step 1")])
    }

    private func makeProcedure(_ id: String, _ title: String) -> Procedure {
        Procedure(id: id, title: title, version: "1",
                  steps: [Procedure.Step(id: "s1", title: "S", instruction: "i")])
    }

    func testWorkflowsBuildsItemsAndStarts() {
        let pbs = [makePlaybook("Site Walkthrough"), makePlaybook("Vehicle Inspection")]
        var startedId: String?
        var backed = false
        let screen = HUDMenuBuilder.workflows(pbs, onStart: { startedId = $0 }, onBack: { backed = true })
        XCTAssertEqual(screen.title, "Workflows")
        XCTAssertEqual(screen.items.map(\.id), ["pb:site-walkthrough", "pb:vehicle-inspection", "back"])
        screen.items.first { $0.id == "pb:site-walkthrough" }?.action()
        XCTAssertEqual(startedId, "site-walkthrough")
        screen.items.first { $0.id == "back" }?.action()
        XCTAssertTrue(backed)
    }

    func testProceduresBuildsItemsAndStarts() {
        let procs = [makeProcedure("diag", "Diagnose No Cooling"), makeProcedure("startup", "Startup Check")]
        var startedId: String?
        let screen = HUDMenuBuilder.procedures(procs, onStart: { startedId = $0 }, onBack: {})
        XCTAssertEqual(screen.title, "SOPs")
        XCTAssertEqual(screen.items.map(\.id), ["sop:diag", "sop:startup", "back"])
        screen.items.first { $0.id == "sop:startup" }?.action()
        XCTAssertEqual(startedId, "startup")
    }

    func testPaginationAppendsMoreBeyondPageSize() {
        let pbs = (1...8).map { makePlaybook("Playbook \($0)") }   // > pageSize (6)
        var morePage: Int?
        let page0 = HUDMenuBuilder.workflows(pbs, page: 0, onStart: { _ in },
                                             onMore: { morePage = $0 }, onBack: {})
        // 6 leaves + "More…" + "back"
        XCTAssertEqual(page0.items.count, 8)
        XCTAssertEqual(page0.items[6].id, "more:1")
        XCTAssertEqual(page0.items.last?.id, "back")
        page0.items[6].action()
        XCTAssertEqual(morePage, 1)

        // Page 1 holds the remaining 2 with no further "More…".
        let page1 = HUDMenuBuilder.workflows(pbs, page: 1, onStart: { _ in },
                                             onMore: { _ in }, onBack: {})
        XCTAssertEqual(page1.items.map(\.id), ["pb:playbook-7", "pb:playbook-8", "back"])
    }

    func testNoMoreWhenOnMoreOmitted() {
        let pbs = (1...8).map { makePlaybook("PB \($0)") }
        let screen = HUDMenuBuilder.workflows(pbs, onStart: { _ in }, onBack: {})  // no onMore
        XCTAssertFalse(screen.items.contains { $0.id.hasPrefix("more:") })
        XCTAssertEqual(screen.items.filter { $0.id.hasPrefix("pb:") }.count, 6)     // still capped at a page
    }

    // MARK: - Launcher root composition + routing

    private func makeRig() -> (GlassesDisplayService, HUDRouter, HUDLauncher) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let router = HUDRouter(display: display)
        let launcher = HUDLauncher(router: router)
        launcher.availablePlaybooks = { [] }
        launcher.availableProcedures = { [] }
        launcher.fieldAssistActive = { false }
        return (display, router, launcher)
    }

    /// Fire the rendered button with `id` on the router's current screen (simulating a band
    /// selection through the same path the SDK `onClick` uses).
    private func fire(_ id: String, _ display: GlassesDisplayService, _ router: HUDRouter) {
        guard let screen = router.currentScreen,
              let idx = screen.items.firstIndex(where: { $0.id == id }) else {
            return XCTFail("no item '\(id)' on current screen")
        }
        display.testInteractiveButtonActions(for: screen)[idx]()
    }

    private func rootIds(_ router: HUDRouter) -> [String] { router.currentScreen?.items.map(\.id) ?? [] }

    func testRootShowsWorkflowsBranchWhenPlaybooksExist() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (_, router, launcher) = makeRig()
        launcher.availablePlaybooks = { [self.makePlaybook("Site Walkthrough")] }
        launcher.open()
        await settle()
        XCTAssertTrue(rootIds(router).contains("branch:workflows"))
        XCTAssertFalse(rootIds(router).contains("branch:sops"))     // field assist off
        XCTAssertFalse(rootIds(router).contains("branch:resume"))   // no task active
    }

    func testSopsBranchGatedOnFieldAssistAndContent() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        // Field Assist on + procedures present → branch shows.
        let (_, router, launcher) = makeRig()
        launcher.fieldAssistActive = { true }
        launcher.availableProcedures = { [self.makeProcedure("diag", "Diagnose No Cooling")] }
        launcher.open()
        await settle()
        XCTAssertTrue(rootIds(router).contains("branch:sops"))

        // Field Assist off (even with procedures) → hidden.
        let (_, router2, launcher2) = makeRig()
        launcher2.fieldAssistActive = { false }
        launcher2.availableProcedures = { [self.makeProcedure("diag", "Diagnose No Cooling")] }
        launcher2.open()
        await settle()
        XCTAssertFalse(rootIds(router2).contains("branch:sops"))

        // Field Assist on but no procedures (no active session) → hidden.
        let (_, router3, launcher3) = makeRig()
        launcher3.fieldAssistActive = { true }
        launcher3.availableProcedures = { [] }
        launcher3.open()
        await settle()
        XCTAssertFalse(rootIds(router3).contains("branch:sops"))
    }

    func testWorkflowBranchPushesAndStartsPlaybook() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, router, launcher) = makeRig()
        launcher.availablePlaybooks = { [self.makePlaybook("Site Walkthrough")] }
        var startedId: String?
        var startCount = 0
        launcher.startPlaybook = { startedId = $0; startCount += 1 }

        launcher.open()
        await settle()
        fire("branch:workflows", display, router)
        await settle()
        XCTAssertEqual(router.menuDepth, 2)
        XCTAssertEqual(router.currentScreen?.title, "Workflows")

        fire("pb:site-walkthrough", display, router)
        await settle()
        XCTAssertEqual(startedId, "site-walkthrough")
        XCTAssertEqual(startCount, 1)
    }

    // MARK: - Resume task root item

    func testResumeTaskItemAppearsAndRepresentsCard() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, router, launcher) = makeRig()
        let source = StubTaskSource()
        router.startTask(source)               // a Plan X card is now on the HUD
        await settle()
        XCTAssertEqual(router.currentScreen?.title, "Now")

        launcher.open()                        // overlay the launcher menu
        await settle()
        XCTAssertTrue(router.isPresentingMenu)
        XCTAssertEqual(rootIds(router).first, "branch:resume")   // Resume sits at the top

        fire("branch:resume", display, router) // → back to the card
        await settle()
        XCTAssertFalse(router.isPresentingMenu)
        XCTAssertEqual(router.menuDepth, 0)
        XCTAssertTrue(router.isPresentingTask)
        XCTAssertEqual(router.currentScreen?.title, "Now")
    }

    func testStartingTaskSupersedesOpenMenu() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (_, router, launcher) = makeRig()
        launcher.open()
        await settle()
        XCTAssertTrue(router.isPresentingMenu)

        router.startTask(StubTaskSource())     // launching a task drops the menu for the card
        await settle()
        XCTAssertFalse(router.isPresentingMenu)
        XCTAssertEqual(router.menuDepth, 0)
        XCTAssertEqual(router.currentScreen?.title, "Now")
    }

    // MARK: - In-menu voice navigation

    func testVoiceSelectionMatchesLabelAndVerbs() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (_, router, launcher) = makeRig()
        launcher.open()
        await settle()

        XCTAssertTrue(launcher.handleVoiceSelection("quick actions"))   // matches "Quick Actions"
        XCTAssertEqual(router.currentScreen?.title, "Quick Actions")
        XCTAssertEqual(router.menuDepth, 2)

        XCTAssertTrue(launcher.handleVoiceSelection("back"))            // global verb pops
        XCTAssertEqual(router.menuDepth, 1)

        XCTAssertTrue(launcher.handleVoiceSelection("close"))           // global verb dismisses
        XCTAssertFalse(router.isPresentingMenu)

        // Closed menu → not consumed.
        XCTAssertFalse(launcher.handleVoiceSelection("quick actions"))
    }

    func testVoiceSelectionIgnoresAmbiguousAndUnknown() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (_, router, launcher) = makeRig()
        launcher.open()
        await settle()
        let before = router.menuDepth

        // "o" is a substring of both "Quick Actions" and "Close" → ambiguous → no-op.
        XCTAssertFalse(launcher.handleVoiceSelection("o"))
        // Pure gibberish → no-op.
        XCTAssertFalse(launcher.handleVoiceSelection("xyzzy"))
        XCTAssertEqual(router.menuDepth, before)
        XCTAssertTrue(router.isPresentingMenu)
    }
}

/// Minimal `HUDTaskSource` double for launcher/router overlay tests.
@MainActor
private final class StubTaskSource: HUDTaskSource {
    var title = "Stub"
    var current: HUDStep? = HUDStep(index: 0, total: 1, title: "Now")
    var next: HUDStep?
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func complete() async {}
    func skip() async {}
    func back() async {}
}
