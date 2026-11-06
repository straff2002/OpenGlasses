#if !AVENKIN_PHONE_ONLY
import XCTest
import Combine
@testable import OpenGlasses

/// Plan KP P3 — the band check on the glasses, headless: the service through its test seams (the
/// reading driven with `updateGlassesLink`/`applySessionReading`), the band simulated by firing the
/// rendered buttons (`testInteractiveButtonActions`), the timers captured and fired by hand, and
/// the clock a seam. No test waits on the clock: a band press is awaited through `onPressReceived`.
@MainActor
final class BandPracticeSessionTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedBackend: String?
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var timers: [@MainActor () -> Void] = []
    private var lensChecks: [@MainActor () -> Void] = []
    private var cues: [BandPracticeSession.Cue] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.setGlassesDisplayEnabled(true)
        Config.displayBackend = .metaRayBan
        suiteName = "BandPracticeSessionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        timers = []
        lensChecks = []
        cues = []
    }

    override func tearDown() async throws {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeDisplay() -> GlassesDisplayService {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return display
    }

    private func makeSession(_ display: GlassesDisplayService) -> BandPracticeSession {
        let session = BandPracticeSession(display: display, store: BandCheckStore(defaults: defaults))
        session.scheduleIdleTimer = { [unowned self] _, fire in self.timers.append(fire) }
        session.deferLensCheck = { [unowned self] check in self.lensChecks.append(check) }
        session.playCue = { [unowned self] in self.cues.append($0) }
        session.now = { [unowned self] in
            self.clock = self.clock.addingTimeInterval(0.5)
            return self.clock
        }
        session.backend = { "metaRayBan" }
        return session
    }

    /// Fire button `slot` of the card on the lens, as the band does, and wait until the session's
    /// handler has it. Returns whether it got past the gate.
    @discardableResult
    private func bandPress(_ session: BandPracticeSession, _ display: GlassesDisplayService,
                           slot: Int) async -> Bool {
        guard let screen = session.shownScreen else {
            XCTFail("no card on the lens")
            return false
        }
        let actions = display.testInteractiveButtonActions(for: screen)
        guard actions.indices.contains(slot) else {
            XCTFail("no button \(slot)")
            return false
        }
        let received = expectation(description: "press received")
        var accepted = false
        session.onPressReceived = { _, ok in
            accepted = ok
            received.fulfill()
        }
        actions[slot]()
        await fulfillment(of: [received], timeout: 5)
        session.onPressReceived = nil
        return accepted
    }

    private func pressTarget(_ session: BandPracticeSession, _ display: GlassesDisplayService) async {
        await bandPress(session, display, slot: session.practice?.targetSlot ?? 0)
    }

    private func runLensChecks() {
        let pending = lensChecks
        lensChecks = []
        pending.forEach { $0() }
    }

    // MARK: - Starting

    func testStartPutsTheFirstLessonOnTheLens() {
        let display = makeDisplay()
        let session = makeSession(display)
        XCTAssertNil(session.start())
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(display.isInteractive)
        XCTAssertFalse(display.showsAnswerCard)
        XCTAssertTrue(session.ownsLens)
        XCTAssertEqual(display.heldScreenRenderKey, session.shownScreen?.renderKey)
        XCTAssertEqual(session.shownScreen?.items.map(\.label), ["Press me"])
    }

    func testStartIsRefusedWhileAnotherAppHasTheDisplay() {
        let display = makeDisplay()
        display.applySessionReading(.init(state: .paused))
        XCTAssertEqual(display.displayAvailability, .inUse)
        let session = makeSession(display)
        XCTAssertEqual(session.start(), .displayInUse)
        XCTAssertEqual(session.refusal, .displayInUse)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(display.isInteractive, "nothing starts")
    }

    func testStartIsRefusedWhileTheDisplayIsOff() {
        let display = makeDisplay()
        display.updateGlassesLink(connected: false, worn: nil)
        let session = makeSession(display)
        XCTAssertEqual(session.start(), .displayOff)
        XCTAssertFalse(display.isInteractive)

        display.updateGlassesLink(connected: true, worn: false)
        XCTAssertEqual(session.start(), .displayOff, "taken off")

        display.updateGlassesLink(connected: true, worn: true)
        Config.setGlassesDisplayEnabled(false)
        XCTAssertEqual(session.start(), .hudOff)
        XCTAssertFalse(session.isRunning)
    }

    func testStartIsRefusedOverATaskCardAndClosesAnOpenMenu() {
        let display = makeDisplay()
        let router = HUDRouter(display: display)
        let session = makeSession(display)
        session.router = router

        router.openLauncher(HUDScreen(title: "Menu", items: [HUDItem(id: "close", label: "Close") {}]))
        XCTAssertTrue(router.isPresentingMenu)
        XCTAssertNil(session.start())
        XCTAssertFalse(router.isPresentingMenu, "the launcher closes for the check")
        XCTAssertTrue(session.ownsLens)
        session.stop()

        router.startTask(BandFakeTaskSource())
        XCTAssertEqual(session.start(), .taskRunning)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(router.isPresentingTask)
    }

    func testTheLauncherOffersPractiseTheBandOnlyWhenAvailable() {
        let display = makeDisplay()
        let router = HUDRouter(display: display)
        let launcher = HUDLauncher(router: router)
        let session = makeSession(display)
        session.router = router
        var available = false
        launcher.bandPracticeAvailable = { available }
        launcher.startBandPractice = { session.start() }

        launcher.open()
        XCTAssertFalse(router.currentScreen?.items.contains { $0.id == "branch:band" } ?? false)
        router.dismiss()

        available = true
        XCTAssertTrue(launcher.hasContent)
        launcher.open()
        let root = router.currentScreen
        XCTAssertEqual(Array(root?.items.map(\.id).suffix(2) ?? []), ["branch:band", "close"])
        XCTAssertEqual(root?.items.first { $0.id == "branch:band" }?.label, BandPracticeCardBuilder.title)
        root?.items.first { $0.id == "branch:band" }?.action()
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(router.isPresentingMenu)
        XCTAssertTrue(session.ownsLens)
    }

    // MARK: - Presses

    func testLessonsAdvanceOnBandPressesToTheEnd() async {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        var labels: [[String]] = []
        while session.practice?.isFinished == false {
            labels.append(session.shownScreen?.items.map(\.label) ?? [])
            let revision = display.heldScreenRevision
            await pressTarget(session, display)
            XCTAssertGreaterThan(display.heldScreenRevision, revision, "each press redraws the card")
        }
        XCTAssertEqual(labels.count, 12)
        XCTAssertEqual(labels[3], ["○", "●"])
        XCTAssertEqual(labels[4], ["●", "○"], "the marked one moved")
        XCTAssertEqual(labels[6], ["3", "1", "5", "6", "2", "4"])
        XCTAssertEqual(cues, Array(repeating: .right, count: 12))

        // The result is written when the last lesson passes, before Done.
        XCTAssertEqual(session.lastResult?.ending, .finished)
        XCTAssertEqual(session.lastResult?.lessonsPassed, 3)
        XCTAssertEqual(session.lastResult?.intervalsMs, Array(repeating: 500, count: 11))
        XCTAssertEqual(BandCheckStore(defaults: defaults).load(), session.lastResult)

        XCTAssertEqual(session.shownScreen?.items.map(\.id), [BandPractice.doneID])
        await bandPress(session, display, slot: 0)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(display.isInteractive, "Done ends interactive mode")
        XCTAssertEqual(session.lastResult?.ending, .finished)
    }

    func testAWrongPressIsRecordedWithTheRefusedToneAndNotAdvanced() async {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        for _ in 0..<3 { await pressTarget(session, display) }
        XCTAssertEqual(session.practice?.currentLesson, .move)
        let screen = session.shownScreen?.renderKey
        let accepted = await bandPress(session, display, slot: 0)   // the marked one is slot 1
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.practice?.step, 0)
        XCTAssertEqual(session.practice?.wrong, [0, 1, 0])
        XCTAssertEqual(cues.last, .wrong)
        XCTAssertEqual(session.shownScreen?.renderKey, screen, "the card is unchanged")
    }

    func testABandPressWhileANotificationIsOverTheCardIsStale() async {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        display.showNotification(title: nil, body: "Battery low", duration: 5)
        XCTAssertNotEqual(display.frameRevision, display.heldScreenRevision)
        let accepted = await bandPress(session, display, slot: 0)
        XCTAssertFalse(accepted, "dropped by the revision gate")
        XCTAssertEqual(session.practice?.step, 0)
        XCTAssertEqual(session.practice?.wrong, [0, 0, 0])
        XCTAssertEqual(session.practice?.stalePresses, 1)
        XCTAssertTrue(cues.isEmpty, "no tone for a dropped press")
    }

    func testAPressAgainstAnOlderRevisionIsIgnored() {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        let id = BandPractice.itemID(lesson: 0, step: 0, slot: 0)
        session.handle(id, issuedAgainst: display.heldScreenRevision &- 1)
        XCTAssertEqual(session.practice?.step, 0)
        XCTAssertEqual(session.practice?.stalePresses, 1)
        session.handle(id, issuedAgainst: display.heldScreenRevision)
        XCTAssertEqual(session.practice?.step, 1)
        // The same id again is from the frame before: stale by its id.
        session.handle(id, issuedAgainst: display.heldScreenRevision)
        XCTAssertEqual(session.practice?.step, 1)
        XCTAssertEqual(session.practice?.stalePresses, 2)
    }

    // MARK: - Ending

    func testStopEndsInteractiveModeAndRecordsWhatDidNotArrive() async {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        await pressTarget(session, display)
        session.stop()
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(display.isInteractive)
        XCTAssertNil(display.heldScreenRenderKey)
        XCTAssertEqual(session.lastResult?.ending, .stopped)
        XCTAssertEqual(session.lastResult?.pressesNotArrived, 11)
        XCTAssertEqual(session.lastResult?.backend, "metaRayBan")
        XCTAssertTrue(BandCheckReport.lines(for: session.lastResult)[0].contains("stopped"))
        session.stop()   // a second stop is nothing
        XCTAssertEqual(session.lastResult?.ending, .stopped)
    }

    func testNoPressForTheLifetimeEndsTheRun() {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        XCTAssertEqual(timers.count, 1)
        session.handle(BandPractice.itemID(lesson: 0, step: 0, slot: 0), issuedAgainst: display.heldScreenRevision)
        XCTAssertEqual(timers.count, 2)
        timers[0]()                        // the older timer finds a newer press
        XCTAssertTrue(session.isRunning)
        timers[1]()
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(display.isInteractive)
        XCTAssertEqual(session.lastResult?.ending, .timedOut)
    }

    func testSomethingElseTakingTheLensEndsTheRunWithoutClearingIt() {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        runLensChecks()
        XCTAssertTrue(session.isRunning, "its own card is not a takeover")

        display.present(screen: HUDScreen(title: "Task", items: [HUDItem(id: "done", label: "Done") {}])) { _ in }
        runLensChecks()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.lastResult?.ending, .interrupted)
        XCTAssertTrue(display.isInteractive, "the screen that replaced the card stays")
        XCTAssertEqual(display.heldScreenRenderKey?.hasPrefix("Task"), true)
    }

    func testTheCardIsKeptWhileAnotherAppHasTheDisplay() {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        display.applySessionReading(.init(state: .paused))
        runLensChecks()
        XCTAssertTrue(session.isRunning)
        display.applySessionReading(.init(state: .started))
        runLensChecks()
        XCTAssertTrue(session.ownsLens)
    }

    func testInteractiveModeEndedElsewhereEndsTheRun() {
        let display = makeDisplay()
        let session = makeSession(display)
        session.start()
        display.endInteractive()
        runLensChecks()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.lastResult?.ending, .interrupted)
    }

    func testTheLastRunIsLoadedForTheReport() {
        let display = makeDisplay()
        let first = makeSession(display)
        first.start()
        first.stop()
        let again = BandPracticeSession(display: display, store: BandCheckStore(defaults: defaults))
        XCTAssertEqual(again.lastResult, first.lastResult)
    }
}

@MainActor
private final class BandFakeTaskSource: HUDTaskSource {
    let title = "Task"
    var current: HUDStep? = HUDStep(index: 0, total: 1, title: "Step")
    var next: HUDStep? { nil }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func complete() async {}
    func skip() async {}
    func back() async {}
}
#endif
