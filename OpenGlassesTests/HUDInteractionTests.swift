import XCTest
import Combine
@testable import OpenGlasses

/// Tests for the interactive HUD foundation (Display Phase 3 / Plan X): the Playbook
/// task-source adapter, the Now/Next card layout, and screen render-key dedup. All
/// headless — no device or SDK needed.
@MainActor
final class HUDInteractionTests: XCTestCase {

    // MARK: - PlaybookHUDTaskSource

    private func makeStartedSource(id: String) -> (PlaybookStore, PlaybookHUDTaskSource) {
        let store = PlaybookStore()
        let pb = Playbook(id: id, name: "HUD Test", steps: [
            PlaybookStep(title: "Step A", detail: "Do A"),
            PlaybookStep(title: "Step B", detail: "Do B"),
            PlaybookStep(title: "Step C", detail: "Do C"),
        ])
        store.add(pb)
        _ = store.startPlaybook(pb.id)
        return (store, PlaybookHUDTaskSource(store: store))
    }

    func testSourceReportsCurrentAndNext() {
        let (store, source) = makeStartedSource(id: "hud-cn")
        defer { _ = store.finishPlaybook() }

        XCTAssertEqual(source.title, "HUD Test")
        XCTAssertEqual(source.current?.index, 0)
        XCTAssertEqual(source.current?.total, 3)
        XCTAssertEqual(source.current?.title, "Step A")
        XCTAssertEqual(source.current?.instruction, "Do A")
        XCTAssertNil(source.current?.safetyNote)            // Playbooks carry no safety notes
        XCTAssertEqual(source.next?.index, 1)
        XCTAssertEqual(source.next?.title, "Step B")
        XCTAssertNil(source.next?.instruction)              // next is a preview — title only
    }

    func testCompleteAdvancesAndBackReturns() async {
        let (store, source) = makeStartedSource(id: "hud-cb")
        defer { _ = store.finishPlaybook() }

        await source.complete()
        XCTAssertEqual(source.current?.index, 1)
        XCTAssertEqual(source.current?.title, "Step B")

        await source.back()
        XCTAssertEqual(source.current?.index, 0)
    }

    func testSkipAdvances() async {
        let (store, source) = makeStartedSource(id: "hud-skip")
        defer { _ = store.finishPlaybook() }

        await source.skip()
        XCTAssertEqual(source.current?.index, 1)
    }

    func testCompletingLastStepEndsWorkflow() async {
        let (store, source) = makeStartedSource(id: "hud-end")
        defer { _ = store.finishPlaybook() }

        await source.complete()   // → B
        await source.complete()   // → C
        await source.complete()   // → finished
        XCTAssertNil(source.current)
        XCTAssertNil(store.activeSession)
    }

    // MARK: - Card layout

    func testTaskCardLayout() {
        let source = FakeTaskSource()
        let current = HUDStep(index: 0, total: 3, title: "Torque bolts", instruction: "45 Nm, 2 passes")
        let next = HUDStep(index: 1, total: 3, title: "Reconnect sensor")
        let screen = HUDRouter.taskCard(source: source, current: current, next: next)

        XCTAssertEqual(screen.title, "Torque bolts")
        XCTAssertTrue(screen.lines.contains { $0.text == "Step 1 of 3" })
        XCTAssertTrue(screen.lines.contains { $0.text == "45 Nm, 2 passes" })
        XCTAssertTrue(screen.lines.contains { $0.text == "Next: Reconnect sensor" })
        XCTAssertEqual(screen.items.map(\.id), ["done", "skip", "back"])
    }

    func testTaskCardShowsSafetyNoteWithHazardIcon() {
        let source = FakeTaskSource()
        let current = HUDStep(index: 2, total: 7, title: "Contact terminals",
                              instruction: "Check continuity", safetyNote: "De-energize first")
        let screen = HUDRouter.taskCard(source: source, current: current, next: nil)

        let safety = screen.lines.first { $0.text == "De-energize first" }
        XCTAssertNotNil(safety)
        XCTAssertEqual(safety?.icon, .hazard)
        XCTAssertFalse(screen.lines.contains { $0.text.hasPrefix("Next:") })  // no next on last step
    }

    func testTaskCardButtonsInvokeSource() async {
        let source = FakeTaskSource()
        let screen = HUDRouter.taskCard(
            source: source,
            current: HUDStep(index: 0, total: 1, title: "Only step"),
            next: nil
        )
        screen.items.first { $0.id == "done" }?.action()
        screen.items.first { $0.id == "skip" }?.action()
        screen.items.first { $0.id == "back" }?.action()
        // Actions launch detached tasks; let them run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(source.completeCount, 1)
        XCTAssertEqual(source.skipCount, 1)
        XCTAssertEqual(source.backCount, 1)
    }

    // MARK: - Router lifecycle (with the real GlassesDisplayService via its test seam)

    private func makeDisplay() -> (GlassesDisplayService, () -> [GlassesDisplayService.HUDFrame]) {
        let svc = GlassesDisplayService()
        svc.testCapabilityOverride = true
        var frames: [GlassesDisplayService.HUDFrame] = []
        svc.testRenderSink = { frames.append($0) }
        return (svc, { frames })
    }

    func testRouterPresentsCardOnStart() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, frames) = makeDisplay()
        let router = HUDRouter(display: display)
        let source = FakeTaskSource()
        source.current = HUDStep(index: 0, total: 2, title: "First")
        source.next = HUDStep(index: 1, total: 2, title: "Second")

        router.startTask(source)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(router.isPresentingTask)
        XCTAssertEqual(frames().count, 1)
        guard case .screen? = frames().first else { return XCTFail("expected a screen frame") }
    }

    func testRouterFlashesCompleteAndStopsWhenSourceFinishes() async {
        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }

        let (display, frames) = makeDisplay()
        let router = HUDRouter(display: display)
        let source = FakeTaskSource()
        source.current = HUDStep(index: 0, total: 1, title: "Only")
        router.startTask(source)
        try? await Task.sleep(nanoseconds: 50_000_000)

        source.current = nil          // workflow done
        source.emitChange()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(router.isPresentingTask)
        XCTAssertTrue(frames().contains {
            if case .content(let body, _, _) = $0 { return body.contains("complete") }
            return false
        })
    }

    // MARK: - Render-key dedup

    func testRenderKeyStableForIdenticalContent() {
        let a = HUDScreen(title: "T", lines: [HUDLine("x", emphasis: .meta)],
                          items: [HUDItem(id: "i", label: "Go") {}])
        let b = HUDScreen(title: "T", lines: [HUDLine("x", emphasis: .meta)],
                          items: [HUDItem(id: "i", label: "Go") {}])
        XCTAssertEqual(a.renderKey, b.renderKey)
    }

    func testRenderKeyDiffersWhenLabelChanges() {
        let a = HUDScreen(title: "T", items: [HUDItem(id: "i", label: "Go") {}])
        let b = HUDScreen(title: "T", items: [HUDItem(id: "i", label: "Stop") {}])
        XCTAssertNotEqual(a.renderKey, b.renderKey)
    }
}

/// In-memory `HUDTaskSource` double for layout/wiring tests.
@MainActor
private final class FakeTaskSource: HUDTaskSource {
    var title = "Fake"
    var current: HUDStep?
    var next: HUDStep?
    private let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    var completeCount = 0
    var skipCount = 0
    var backCount = 0

    func complete() async { completeCount += 1 }
    func skip() async { skipCount += 1 }
    func back() async { backCount += 1 }

    func emitChange() { subject.send(()) }
}
