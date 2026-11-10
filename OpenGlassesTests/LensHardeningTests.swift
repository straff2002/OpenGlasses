#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan KX P0–P1: the display offered on connect, and the lens hardened for the real Display.
/// Headless: pure policies directly, the service through `testRenderSink`, the Meta backend through a
/// fake session (never `Wearables.shared`).
@MainActor
final class LensHardeningTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedOfferAnswered = false
    private var savedKeepPhoneMic = true
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedOfferAnswered = Config.displayOfferAnswered
        savedKeepPhoneMic = Config.lensKeepsPhoneMic
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.glassesDisplayEnabled = true
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.glassesDisplayEnabled = savedDisplayEnabled
        Config.displayOfferAnswered = savedOfferAnswered
        Config.lensKeepsPhoneMic = savedKeepPhoneMic
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        LensMicPolicy.metaDisplayPresent = false
        try await super.tearDown()
    }

    // MARK: - P0: the offer on connect

    func testTheOfferNeedsDisplayGlassesConnectedWithTheHUDOffAndNoAnswer() {
        XCTAssertTrue(DisplayOfferPolicy.shouldOffer(supported: true, connected: true, hasDisplay: true,
                                                     hudEnabled: false, answered: false))
        XCTAssertFalse(DisplayOfferPolicy.shouldOffer(supported: false, connected: true, hasDisplay: true,
                                                      hudEnabled: false, answered: false), "no glasses in this copy")
        XCTAssertFalse(DisplayOfferPolicy.shouldOffer(supported: true, connected: false, hasDisplay: true,
                                                      hudEnabled: false, answered: false), "listed is not connected")
        XCTAssertFalse(DisplayOfferPolicy.shouldOffer(supported: true, connected: true, hasDisplay: false,
                                                      hudEnabled: false, answered: false), "glasses without a display")
        XCTAssertFalse(DisplayOfferPolicy.shouldOffer(supported: true, connected: true, hasDisplay: true,
                                                      hudEnabled: true, answered: false), "already on")
        XCTAssertFalse(DisplayOfferPolicy.shouldOffer(supported: true, connected: true, hasDisplay: true,
                                                      hudEnabled: false, answered: true), "asked once")
    }

    func testOnlyTurnOnTurnsTheDisplayOn() {
        XCTAssertTrue(DisplayOfferPolicy.hudEnabled(after: .turnOn, current: false))
        XCTAssertFalse(DisplayOfferPolicy.hudEnabled(after: .notNow, current: false))
        XCTAssertTrue(DisplayOfferPolicy.hudEnabled(after: .notNow, current: true), "Not now changes nothing")
    }

    func testMovingTheSwitchByHandAnswersTheOffer() {
        Config.displayOfferAnswered = false
        Config.setGlassesDisplayEnabled(false)
        XCTAssertTrue(Config.displayOfferAnswered)
    }

    // MARK: - P1 §2.1: focus

    private func item(_ id: String, _ style: HUDButtonStyle) -> HUDItem {
        HUDItem(id: id, label: id, style: style) {}
    }

    func testFocusGoesToTheExplicitChoiceThenPrimaryThenSecondaryThenFirst() {
        XCTAssertEqual(HUDScreen(items: [item("a", .outline), item("b", .primary), item("c", .primary)])
            .resolvedFocusItemID, "b", "the first primary, never a later one")
        XCTAssertEqual(HUDScreen(items: [item("a", .outline), item("b", .secondary)]).resolvedFocusItemID, "b")
        XCTAssertEqual(HUDScreen(items: [item("a", .outline), item("b", .outline)]).resolvedFocusItemID, "a")
        XCTAssertEqual(HUDScreen(items: [item("a", .primary), item("b", .outline)], focusItemID: "b")
            .resolvedFocusItemID, "b")
        XCTAssertEqual(HUDScreen(items: [item("a", .primary)], focusItemID: "gone").resolvedFocusItemID, "a",
                       "a stale explicit choice falls back")
        XCTAssertNil(HUDScreen(lines: [HUDLine("text")]).resolvedFocusItemID)
    }

    func testAnExplicitFocusChangesTheRenderKeyAndNoFocusKeepsIt() {
        let plain = HUDScreen(items: [item("a", .primary), item("b", .outline)])
        let focused = HUDScreen(items: [item("a", .primary), item("b", .outline)], focusItemID: "b")
        XCTAssertFalse(plain.renderKey.contains("focus"))
        XCTAssertNotEqual(plain.renderKey, focused.renderKey)
    }

    func testAnswerCardsFocusNextThenActionsThenMore() {
        let pages = HUDAnswerPager.pages(for: String(repeating: "A sentence that fills the lens. ", count: 30),
                                         geometry: .raybanDisplay)
        XCTAssertGreaterThan(pages.count, 1)
        let first = HUDAnswerCardBuilder.page(pages, index: 0, followUps: [], onAction: { _ in })
        XCTAssertEqual(first?.resolvedFocusItemID, HUDAnswerCardBuilder.ItemID.next)
        let last = HUDAnswerCardBuilder.page(pages, index: pages.count - 1, followUps: ["Why?"], onAction: { _ in })
        XCTAssertEqual(last?.resolvedFocusItemID, HUDAnswerCardBuilder.ItemID.actions)
        let actions = HUDAnswerCardBuilder.actions(pages, followUps: [], onAction: { _ in })
        XCTAssertEqual(actions.resolvedFocusItemID, HUDAnswerCardBuilder.ItemID.more)
    }

    func testTheMetaTreeStillHasEveryButtonWithAFocusedOne() {
        let screen = HUDScreen(items: [item("a", .outline), item("b", .primary), item("close", .outline)])
        XCTAssertEqual(MetaDisplayBackend().testButtonActions(for: screen).count, 3)
    }

    // MARK: - P1 §2.3: exits

    func testTheAnswerCardsActionsScreenHasAWayOut() {
        let pages = HUDAnswerPager.pages(for: "Short answer.", geometry: .raybanDisplay)
        XCTAssertTrue(HUDExit.hasExit(HUDAnswerCardBuilder.actions(pages, followUps: [], onAction: { _ in })))
        XCTAssertFalse(HUDExit.hasExit(HUDScreen(items: [item("next", .primary)])))
        XCTAssertTrue(HUDExit.hasExit(HUDScreen(items: [item("kx.approval.deny", .outline)])))
    }

    // MARK: - P1 §2.4: the send pump

    func testThePacerSpacesTextAndPictures() {
        var pacer = HUDSendPacer()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(pacer.delay(at: t0), 0, "the first send goes at once")
        pacer.sent(endingAt: t0, hadPicture: false)
        XCTAssertEqual(pacer.delay(at: t0.addingTimeInterval(0.1)), 0.3, accuracy: 0.001)
        XCTAssertEqual(pacer.delay(at: t0.addingTimeInterval(0.5)), 0)
        pacer.sent(endingAt: t0, hadPicture: true)
        XCTAssertEqual(pacer.delay(at: t0.addingTimeInterval(0.5)), 0.5, accuracy: 0.001)
        pacer.reset()
        XCTAssertEqual(pacer.delay(at: t0), 0)
    }

    func testASendPastItsDeadlineFails() async {
        do {
            try await HUDSendDeadline.run(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            XCTFail("should have timed out")
        } catch {
            guard case GlassesDisplayError.sendTimedOut = error else { return XCTFail("\(error)") }
        }
    }

    func testASendInsideItsDeadlinePasses() async throws {
        try await HUDSendDeadline.run(seconds: 2) {}
    }

    func testOnlyRealFailuresRetryWithoutThePicture() {
        XCTAssertTrue(GlassesDisplayService.retriesWithoutPicture(after: GlassesDisplayError.sendTimedOut))
        XCTAssertFalse(GlassesDisplayService.retriesWithoutPicture(after: GlassesDisplayError.displayInUse))
        XCTAssertFalse(GlassesDisplayService.retriesWithoutPicture(after: GlassesDisplayError.noDisplay))
    }

    func testTheSendRecordReadsAsOneReportLine() {
        XCTAssertEqual(HUDSendRecord(kind: .picture, milliseconds: 155, outcome: .timedOut).reportLine,
                       "Last display send: picture, 155 ms, timed-out")
    }

    // MARK: - P1 §2.5: the mic

    func testOnlyTheGlassesMicMovesAndOnlyToThePhone() {
        XCTAssertEqual(LensMicPolicy.conversationRoute(preferred: .glasses, lensOn: true, keepPhoneMic: true), .phone)
        XCTAssertEqual(LensMicPolicy.conversationRoute(preferred: .headset, lensOn: true, keepPhoneMic: true), .headset)
        XCTAssertEqual(LensMicPolicy.conversationRoute(preferred: .phone, lensOn: true, keepPhoneMic: true), .phone)
        XCTAssertEqual(LensMicPolicy.conversationRoute(preferred: .glasses, lensOn: false, keepPhoneMic: true), .glasses)
        XCTAssertEqual(LensMicPolicy.conversationRoute(preferred: .glasses, lensOn: true, keepPhoneMic: false), .glasses,
                       "the rollback")
        XCTAssertTrue(LensMicPolicy.overrides(preferred: .glasses, lensOn: true, keepPhoneMic: true))
    }

    func testTheConversationRouteFollowsTheDisplay() {
        Config.lensKeepsPhoneMic = true
        LensMicPolicy.metaDisplayPresent = true
        Config.glassesDisplayEnabled = true
        XCTAssertTrue(Config.lensIsOn)
        Config.glassesDisplayEnabled = false
        XCTAssertFalse(Config.lensIsOn)
    }

    // MARK: - P1 §2.2: a session the glasses ended is a dismissal

    private final class Frames {
        var frames: [GlassesDisplayService.HUDFrame] = []
    }

    private func makeDisplay() -> (GlassesDisplayService, Frames) {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        let frames = Frames()
        display.testRenderSink = { frames.frames.append($0) }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return (display, frames)
    }

    /// Let the render queue's task run.
    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testAfterADismissalAmbientFramesDoNotReopenTheLens() async {
        let (display, frames) = makeDisplay()
        display.showText("first")
        await drain()
        XCTAssertEqual(frames.frames.count, 1)

        display.lensEndedByDevice()
        XCTAssertTrue(display.lensDismissed)
        display.showText("a caption")
        display.showNotification(title: "Reminder", body: "Call Sam")
        display.showNavigation("Turn left")
        display.clear()
        await drain()
        XCTAssertEqual(frames.frames.count, 1, "nothing ambient is sent")
    }

    func testAMenuTheWearerOpensReopensTheLens() async {
        let (display, frames) = makeDisplay()
        display.lensEndedByDevice()
        display.present(screen: HUDScreen(title: "Menu", items: [item("close", .outline)]), onSelect: { _ in })
        await drain()
        XCTAssertFalse(display.lensDismissed)
        XCTAssertEqual(frames.frames.count, 1)
    }

    func testTheDismissedAnswerGrowingStaysOffButANewAnswerShows() async {
        let (display, frames) = makeDisplay()
        var card = HUDScreen(lines: [HUDLine("Part one")], items: [item(HUDAnswerCardBuilder.ItemID.actions, .secondary)])
        card.pageSet = HUDPageSet(pages: [card], index: 0, card: 7)
        XCTAssertTrue(display.presentAnswerCard(card, onSelect: { _ in }))
        await drain()
        display.lensEndedByDevice()

        var grown = HUDScreen(lines: [HUDLine("Part one, part two")], items: [item(HUDAnswerCardBuilder.ItemID.actions, .secondary)])
        grown.pageSet = HUDPageSet(pages: [grown], index: 0, card: 7)
        XCTAssertFalse(display.presentAnswerCard(grown, onSelect: { _ in }))
        XCTAssertTrue(display.lensDismissed)

        var next = HUDScreen(lines: [HUDLine("A new answer")], items: [item(HUDAnswerCardBuilder.ItemID.actions, .secondary)])
        next.pageSet = HUDPageSet(pages: [next], index: 0, card: 8)
        XCTAssertTrue(display.presentAnswerCard(next, onSelect: { _ in }))
        XCTAssertFalse(display.lensDismissed)
        await drain()
        XCTAssertEqual(frames.frames.count, 2)
    }

    func testTheLinkComingUpAgainEndsTheDismissal() {
        let (display, _) = makeDisplay()
        display.lensEndedByDevice()
        display.updateGlassesLink(connected: false, worn: true)
        XCTAssertTrue(display.lensDismissed)
        display.updateGlassesLink(connected: true, worn: true)
        XCTAssertFalse(display.lensDismissed)
    }

    func testTurningTheHUDOnEndsTheDismissal() {
        let (display, _) = makeDisplay()
        display.lensEndedByDevice()
        display.wearerTurnedLensOn()
        XCTAssertFalse(display.lensDismissed)
    }

    // MARK: - The backend hears the glasses end the session

    @MainActor
    private final class FakeSession: DisplaySessionControl {
        var sessionState: DisplaySessionState = .idle
        private(set) var stopCount = 0
        private let stream: AsyncStream<DisplaySessionState>
        private let continuation: AsyncStream<DisplaySessionState>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: DisplaySessionState.self) }

        func start() throws { sessionState = .started }
        func stop() { stopCount += 1 }
        func stateUpdates() -> AsyncStream<DisplaySessionState> { stream }
        func addDisplay() throws -> Display { throw GlassesDisplayError.sessionUnavailable }

        func emit(_ state: DisplaySessionState) {
            sessionState = state
            continuation.yield(state)
        }
    }

    func testAStopTheAppDidNotAskForIsHeardAsTheGlassesEndingIt() async throws {
        let fake = FakeSession()
        let backend = MetaDisplayBackend()
        backend.testIsAvailable = true
        backend.testMakeSession = { fake }
        let ended = expectation(description: "ended by device")
        backend.onSessionEndedByDevice = { ended.fulfill() }
        try await backend.prepareSession()
        fake.emit(.started)
        fake.emit(.stopped)
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(fake.stopCount, 0, "the app does not stop a session that is already gone")
        XCTAssertNil(backend.sessionReading.state)
    }

    func testTheAppsOwnShutdownIsNotADismissal() async throws {
        let fake = FakeSession()
        let backend = MetaDisplayBackend()
        backend.testIsAvailable = true
        backend.testMakeSession = { fake }
        var ended = false
        backend.onSessionEndedByDevice = { ended = true }
        try await backend.prepareSession()
        fake.emit(.started)
        await backend.shutdown()
        fake.emit(.stopped)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(ended)
        XCTAssertEqual(fake.stopCount, 1)
    }
}
#endif
