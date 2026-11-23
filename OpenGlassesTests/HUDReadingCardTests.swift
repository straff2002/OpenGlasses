#if !AVENKIN_PHONE_ONLY
import MWDATDisplay
import XCTest
@testable import OpenGlasses

/// Plan MG P3 — the reading view on the lens, wired: the answer card shows it on the Meta Display,
/// sends it at settle points, says a row again on a press, opens and leaves an earlier answer,
/// stays until closed (or three minutes when chosen), forgets the conversation when it should, and draws on every surface.
///
/// Headless, through the display's seams: a fresh `GlassesDisplayService` (never `.shared`), frames
/// captured by `testRenderSink`, presses through the real `MetaDisplayBackend` tree
/// (`testInteractiveBlockActions`, `testInteractiveButtonActions`), never `Wearables`.
@MainActor
final class HUDReadingCardTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedBackend: String?
    private var savedStyle: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        savedStyle = UserDefaults.standard.string(forKey: LensAnswerStyle.storageKey)
        Config.glassesDisplayEnabled = true
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.glassesDisplayEnabled = savedDisplayEnabled
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        UserDefaults.standard.set(savedStyle, forKey: LensAnswerStyle.storageKey)
        try await super.tearDown()
    }

    @MainActor
    private final class Timers {
        var armed: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        func fireAll() {
            let pending = armed
            armed = []
            pending.forEach { $0.fire() }
        }
    }

    private struct Rig {
        let display: GlassesDisplayService
        let card: HUDAnswerCard
        let timers: Timers
        let spoken: SpokenBox
    }

    @MainActor
    private final class SpokenBox { var lines: [String] = [] }

    private func makeRig(reading: Bool = true) -> Rig {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testDrawsPicturesOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        let card = HUDAnswerCard(display: display)
        card.geometry = { LensPageFrame.answerGeometry }
        card.usesReadingView = { reading }
        let timers = Timers()
        card.scheduleIdleTimer = { delay, fire in timers.armed.append((delay, fire)) }
        let spoken = SpokenBox()
        card.speakAgain = { spoken.lines.append($0) }
        return Rig(display: display, card: card, timers: timers, spoken: spoken)
    }

    private let reply = "Isolate the unit at the disconnect.\nMeasure TP1 at the intake filter.\nThen measure TP2."

    private func answer(_ rig: Rig, _ text: String? = nil, question: String = "how do I find the fault") {
        rig.card.beginTurn(question: question)
        rig.card.finishTurn(reply: text ?? reply)
        rig.card.endTurn()
    }

    private func yieldALittle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func rowIDs(_ screen: HUDScreen?) -> [String] { screen?.flow.flatMap(\.blocks).map(\.id) ?? [] }
    private func earlierIDs(_ screen: HUDScreen?) -> [String] { screen?.trailingFlow.flatMap(\.blocks).map(\.id) ?? [] }

    // MARK: - The view

    func testTheAnswerGoesUpAsTheReadingView() throws {
        let rig = makeRig()
        answer(rig)
        XCTAssertTrue(rig.card.isShowing)
        XCTAssertTrue(rig.card.isReadingView)
        let screen = try XCTUnwrap(rig.card.screenOnLens)
        XCTAssertEqual(rowIDs(screen).count, 3)
        XCTAssertEqual(screen.lines.first?.text, "You: how do I find the fault")
        XCTAssertTrue(screen.focusesFirstBlock)
        XCTAssertEqual(screen.items.map(\.id), [HUDAnswerCardBuilder.ItemID.actions, HUDAnswerCardBuilder.ItemID.close])
        XCTAssertFalse(rig.card.canTurn(.next), "no pages to turn")
        XCTAssertFalse(rig.card.canTurn(.back))
    }

    func testPagesKeepsThePagedCard() throws {
        let rig = makeRig(reading: false)
        answer(rig)
        XCTAssertFalse(rig.card.isReadingView)
        XCTAssertTrue(try XCTUnwrap(rig.card.screenOnLens).flow.isEmpty)
    }

    func testTheSettingChoosesScrollOnTheMetaDisplayOnly() {
        Config.lensAnswerStyle = .scroll
        XCTAssertTrue(HUDAnswerCard.activeUsesReadingView())
        Config.lensAnswerStyle = .pages
        XCTAssertFalse(HUDAnswerCard.activeUsesReadingView())
        Config.lensAnswerStyle = .scroll
        Config.displayBackend = .evenG2
        XCTAssertFalse(HUDAnswerCard.activeUsesReadingView(), "Even keeps pages")
        UserDefaults.standard.removeObject(forKey: LensAnswerStyle.storageKey)
        XCTAssertEqual(LensAnswerStyle.stored(), .scroll, "scroll by default")
    }

    func testWhileStreamingTheViewIsSentOnlyAtSettlePointsAndAtTheEnd() {
        let rig = makeRig()
        rig.card.beginTurn(question: "what next")
        let sentences = (1...20).map { "Sentence \($0) is about the next check on the board." }
        for sentence in sentences { rig.card.absorb(sentence, streamed: true) }
        XCTAssertTrue(rig.card.isShowing, "up once a row settled")
        XCTAssertEqual(rig.card.readingStats.viewsDrawn, 1, "one paragraph streaming: no redraw per sentence")
        rig.card.finishTurn(reply: sentences.joined(separator: " "))
        XCTAssertEqual(rig.card.readingStats.viewsDrawn, 2, "the final draw")
        rig.card.endTurn()
        XCTAssertEqual(rig.card.readingStats.viewsDrawn, 2, "nothing more for the text")
    }

    // MARK: - Presses

    func testAPressOnARowSaysTheAnswerAgainFromThatRow() async throws {
        let rig = makeRig()
        answer(rig)
        let screen = try XCTUnwrap(rig.card.screenOnLens)
        let taps = rig.display.testInteractiveBlockActions(for: screen)
        XCTAssertEqual(taps.count, 3, "every row is tappable")
        taps[1]()
        await yieldALittle()
        XCTAssertEqual(rig.spoken.lines, ["Measure TP1 at the intake filter.\nThen measure TP2."])
        XCTAssertEqual(rig.card.readingStats.rowPresses, 1)
    }

    func testAPressOnAnEarlierAnswerOpensItAndLatestComesBack() async throws {
        let rig = makeRig()
        answer(rig, "R-410A, 7 lb 4 oz factory charge.", question: "refrigerant charge")
        answer(rig)
        let latest = try XCTUnwrap(rig.card.screenOnLens)
        XCTAssertEqual(earlierIDs(latest).count, 1)
        let taps = rig.display.testInteractiveBlockActions(for: latest)
        taps.last?()     // the earlier answer, under the buttons
        await yieldALittle()
        let opened = try XCTUnwrap(rig.card.screenOnLens)
        XCTAssertEqual(opened.lines.first?.text, "You: refrigerant charge")
        XCTAssertEqual(opened.items.first?.id, HUDReadingViewBuilder.ItemID.latest)
        XCTAssertTrue(earlierIDs(opened).isEmpty, "nothing older")
        XCTAssertEqual(rig.card.readingStats.earlierOpened, 1)
        XCTAssertTrue(rig.card.canTurn(.back), "back goes to the newest")
        rig.display.testInteractiveButtonActions(for: opened)[0]()
        await yieldALittle()
        XCTAssertNil(rig.card.openedTurnID)
        XCTAssertEqual(rig.card.screenOnLens?.lines.first?.text, "You: how do I find the fault")
    }

    func testTheWordsOpenTheEarlierAnswerAndGoBackToTheLatest() {
        let rig = makeRig()
        answer(rig, "First answer.", question: "first")
        answer(rig, "Second answer.", question: "second")
        answer(rig, "Third answer.", question: "third")
        XCTAssertTrue(rig.card.handleReadingCommand(.earlier))
        XCTAssertEqual(rig.card.screenOnLens?.lines.first?.text, "You: second")
        XCTAssertTrue(rig.card.handleReadingCommand(.earlier))
        XCTAssertEqual(rig.card.screenOnLens?.lines.first?.text, "You: first")
        XCTAssertFalse(rig.card.handleReadingCommand(.earlier), "nothing earlier: the words go to the model")
        XCTAssertTrue(rig.card.handleReadingCommand(.sayAgain))
        XCTAssertEqual(rig.spoken.lines, ["First answer."], "the answer at the top")
        XCTAssertTrue(rig.card.handleReadingCommand(.latest))
        XCTAssertEqual(rig.card.screenOnLens?.lines.first?.text, "You: third")
        XCTAssertFalse(rig.card.handleReadingCommand(.latest), "already the newest")
    }

    func testPreviousAnswerOnThePagedCardShowsItAsPages() {
        let rig = makeRig(reading: false)
        answer(rig, "First answer.", question: "first")
        answer(rig, "Second answer.", question: "second")
        XCTAssertTrue(rig.card.handleReadingCommand(.earlier))
        XCTAssertEqual(rig.card.answer, "First answer.")
        XCTAssertFalse(rig.card.isReadingView)
        XCTAssertTrue(rig.card.handleReadingCommand(.latest))
        XCTAssertEqual(rig.card.answer, "Second answer.")
    }

    // MARK: - Lifetime and forgetting

    // Plan MU §4 changed MG decision 4: the reading view no longer clears after 3 minutes by
    // default; it stays until closed, and 3 minutes is the other choice in Display & HUD.
    func testTheReadingViewStaysUntilClosedOrLastsThreeMinutesWhenChosen() {
        let rig = makeRig()
        rig.card.readingIdleLifetime = { LensAnswerLifetime.untilClosed.idleLifetime }
        answer(rig)
        XCTAssertTrue(rig.timers.armed.isEmpty, "no idle timer for a view kept until closed")
        let timed = makeRig()
        timed.card.readingIdleLifetime = { LensAnswerLifetime.threeMinutes.idleLifetime }
        answer(timed)
        XCTAssertEqual(timed.timers.armed.last?.delay, 180)
        let paged = makeRig(reading: false)
        answer(paged)
        XCTAssertEqual(paged.timers.armed.last?.delay, HUDAnswerCard.defaultIdleLifetime)
    }

    func testTheLensForgetsTheConversationWhenItEnds() {
        let rig = makeRig()
        answer(rig, "One.")
        answer(rig, "Two.")
        XCTAssertEqual(rig.card.log.count, 2)
        rig.card.conversationEnded()
        XCTAssertTrue(rig.card.log.isEmpty)
        rig.card.close()
        XCTAssertFalse(rig.card.reopen(), "the ended conversation's answer isn't brought back")
    }

    func testTheLensForgetsWhenTheHUDIsTurnedOff() async {
        let rig = makeRig()
        answer(rig)
        XCTAssertEqual(rig.card.log.count, 1)
        Config.glassesDisplayEnabled = false
        await rig.display.shutdown()
        XCTAssertTrue(rig.card.log.isEmpty)
    }

    func testADisconnectLongerThanTheLifetimeForgetsAndAShortOneDoesNot() {
        let rig = makeRig()
        answer(rig)
        rig.timers.armed = []
        rig.display.updateGlassesLink(connected: false, worn: nil)
        rig.display.updateGlassesLink(connected: true, worn: true)
        rig.timers.fireAll()
        XCTAssertEqual(rig.card.log.count, 1, "back before the lifetime: nothing forgotten")
        rig.display.updateGlassesLink(connected: false, worn: nil)
        XCTAssertEqual(rig.timers.armed.last?.delay, HUDAnswerCard.readingDisconnectWindow)
        XCTAssertEqual(HUDAnswerCard.readingDisconnectWindow, 180, "the forgetting rule is unchanged")
        rig.timers.fireAll()
        XCTAssertTrue(rig.card.log.isEmpty)
    }

    func testAPrivateConversationLeavesNothingInTheLog() throws {
        let rig = makeRig()
        answer(rig, "Before.", question: "before")
        answer(rig, "A private answer.", question: "private question")
        rig.card.forgetForReopen()    // the private conversation ended
        XCTAssertTrue(rig.card.log.isEmpty)
        rig.card.offerFollowUps([])   // nothing re-records the private answer
        answer(rig, "After.", question: "after")
        XCTAssertEqual(rig.card.log.newestFirst.map(\.answer), ["After."])
        XCTAssertTrue(earlierIDs(try XCTUnwrap(rig.card.screenOnLens)).isEmpty, "no private answer under the new one")
    }

    func testShowThatAgainBringsTheReadingViewBack() throws {
        let rig = makeRig()
        answer(rig)
        rig.card.close()
        XCTAssertFalse(rig.card.isShowing)
        XCTAssertTrue(rig.card.reopen())
        XCTAssertTrue(rig.card.isReadingView)
        XCTAssertEqual(rowIDs(try XCTUnwrap(rig.card.screenOnLens)).count, 3)
    }

    // MARK: - Surfaces

    func testTheMetaDisplayDrawsRowsAsTappableCardsAndNoButtonTakesFocus() throws {
        let rig = makeRig()
        answer(rig, "One.", question: "first")
        answer(rig)
        let screen = try XCTUnwrap(rig.card.screenOnLens)
        let tree = MetaDisplayBackend().makeScreenView(screen)
        let boxes = tree.children.compactMap { $0 as? FlexBox }
        let tappable = boxes.filter { $0.onClick != nil }
        XCTAssertEqual(tappable.count, 4, "three rows and the earlier answer")
        for box in tappable {
            guard case .card = box.background else { return XCTFail("a row without a card shows no focus") }
        }
        XCTAssertNotNil(tree.children.compactMap { $0 as? ButtonGroup }.first)
        XCTAssertNil(screen.resolvedFocusItemID, "a primary button would open the lens scrolled to it")
        XCTAssertTrue(tree.children.last is FlexBox, "the earlier answers come after the button row")
    }

    func testEvenDrawsTheRowsAsLines() throws {
        let rig = makeRig()
        answer(rig, "One.", question: "first")
        answer(rig)
        let screen = try XCTUnwrap(rig.card.screenOnLens)
        guard case .lines(let even) = EvenScreenRenderer.render(screen: screen) else { return XCTFail() }
        XCTAssertTrue(even.contains("Isolate the unit at the"), "\(even)")
    }

    func testTheSupportReportHasCountsNotText() {
        let rig = makeRig()
        answer(rig)
        let report = rig.card.reportLines.joined(separator: "\n")
        XCTAssertTrue(report.contains("earlier answers held now 1"), report)
        XCTAssertFalse(report.contains("Isolate"), "no answer text")
        XCTAssertFalse(report.contains("fault"), "no question text")
    }
}
#endif
