#if !AVENKIN_PHONE_ONLY
import Combine
import XCTest
@testable import OpenGlasses

/// Plan KT P3 — the cards on the Display, wired: the stack in `HUDRouter` (Next, the draft a page
/// at a time, Send on phone, Read it, Later, Dismiss, Close, the words), presses through
/// `PageTurnGate`, and the glances pushed unasked (`PreparedCardGlances`) with KP's and X's
/// precedence. Headless: the display service through its test seams, the band by firing the
/// rendered buttons, the feed as a plain list.
@MainActor
final class PreparedCardLensTests: XCTestCase {

    private var savedDisplayEnabled = false
    private var savedBackend: String?

    override func setUp() async throws {
        try await super.setUp()
        savedDisplayEnabled = Config.glassesDisplayEnabled
        savedBackend = UserDefaults.standard.string(forKey: "displayBackend")
        Config.setGlassesDisplayEnabled(true)
        Config.displayBackend = .metaRayBan
    }

    override func tearDown() async throws {
        Config.setGlassesDisplayEnabled(savedDisplayEnabled)
        UserDefaults.standard.set(savedBackend, forKey: "displayBackend")
        try await super.tearDown()
    }

    // MARK: - Rig

    /// The feed, and what the stack asked the app to do.
    private final class Feed {
        var cards: [PreparedCard]
        var ran: [(PreparedAction, PreparedCardID)] = []
        var staged: [PreparedCardID] = []
        var read: [String] = []
        var later: [PreparedCardID] = []
        var dismissed: [PreparedCardID] = []
        var notUseful: [PreparedCardID] = []
        var presses: [PreparedCardLensAction] = []
        var stageOutcome: PreparedCardStager.Outcome = .notified

        init(_ cards: [PreparedCard]) { self.cards = cards }

        func remove(_ id: PreparedCardID) { cards.removeAll { $0.id == id } }
    }

    private func makeDisplay() -> GlassesDisplayService {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        display.updateGlassesLink(connected: true, worn: true)
        display.applySessionReading(.init(state: .started))
        return display
    }

    private func makeRouter(_ display: GlassesDisplayService, _ feed: Feed) -> HUDRouter {
        let router = HUDRouter(display: display)
        router.cardGeometry = { .raybanDisplay }
        router.cardHooks = PreparedCardLensHooks(
            cards: { feed.cards },
            run: { action, card in feed.ran.append((action, card.id)) },
            stage: { card in
                feed.staged.append(card.id)
                return feed.stageOutcome
            },
            readAloud: { feed.read.append($0) },
            later: { card in feed.later.append(card.id); feed.remove(card.id) },
            dismiss: { card in feed.dismissed.append(card.id); feed.remove(card.id) },
            notUseful: { card in feed.notUseful.append(card.id); feed.remove(card.id) },
            notePress: { feed.presses.append($0) })
        return router
    }

    private func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Fire the button `id` on the frame the display holds, as the band would.
    private func band(_ id: String, _ router: HUDRouter, _ display: GlassesDisplayService,
                      file: StaticString = #filePath, line: UInt = #line) async {
        guard let screen = router.currentScreen, let index = screen.items.firstIndex(where: { $0.id == id }) else {
            return XCTFail("no '\(id)' on \(router.currentScreen?.items.map(\.id) ?? [])", file: file, line: line)
        }
        display.testInteractiveButtonActions(for: screen)[index]()
        await drain()   // the backend delivers a press on the next main-actor turn
    }

    private var three: [PreparedCard] {
        [LensCardFixtures.leaveBy, LensCardFixtures.shortNight, LensCardFixtures.fitItIn]
    }

    // MARK: - The stack

    func testTheStackOpensAtTheFirstCardAndNextWalksIt() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        XCTAssertTrue(router.openCards())
        XCTAssertTrue(router.isPresentingCards)
        XCTAssertTrue(display.isInteractive)
        XCTAssertEqual(router.currentScreen?.title, "Leave by 18:15")
        XCTAssertEqual(display.heldScreenRenderKey, router.currentScreen?.renderKey)

        await band(PreparedCardHUDBuilder.ItemID.nextCard, router, display)
        XCTAssertEqual(router.shownCardID, LensCardFixtures.shortNight.id)
        await band(PreparedCardHUDBuilder.ItemID.nextCard, router, display)
        XCTAssertEqual(router.shownCardID, LensCardFixtures.fitItIn.id)
        XCTAssertEqual(router.currentScreen?.items.last?.id, PreparedCardHUDBuilder.ItemID.close)

        await band(PreparedCardHUDBuilder.ItemID.close, router, display)
        XCTAssertFalse(router.isPresentingCards)
        XCTAssertFalse(display.isInteractive)
        XCTAssertEqual(feed.presses, [.nextCard, .nextCard, .close])
    }

    func testOpeningWithNoCardsDoesNothing() {
        let display = makeDisplay()
        let router = makeRouter(display, Feed([]))
        XCTAssertFalse(router.hasCards)
        XCTAssertFalse(router.openCards())
        XCTAssertFalse(display.isInteractive)
    }

    func testAGlancesOpenLandsOnItsCard() {
        let display = makeDisplay()
        let router = makeRouter(display, Feed(three))
        router.openCards(at: LensCardFixtures.fitItIn.id)
        XCTAssertEqual(router.currentScreen?.title, LensCardFixtures.fitItIn.headline)
    }

    func testTheDraftPagesAndSendOnPhoneComesOnlyOnTheLastPage() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        router.openCards(at: LensCardFixtures.shortNight.id)
        await band(PreparedCardHUDBuilder.ItemID.primary, router, display)
        XCTAssertEqual(router.cardDraftPage, 0)
        XCTAssertEqual(router.currentScreen?.title, "To Tom Example · Email")
        let pages = PreparedCardHUDBuilder.draftPages(LensCardFixtures.shortNight, geometry: .raybanDisplay).count
        XCTAssertGreaterThan(pages, 1)
        for page in 1..<pages {
            XCTAssertFalse(router.currentScreen?.items.contains { $0.id == PreparedCardHUDBuilder.ItemID.send } ?? true)
            await band(PreparedCardHUDBuilder.ItemID.draftNext, router, display)
            XCTAssertEqual(router.cardDraftPage, page)
        }
        XCTAssertEqual(router.currentScreen?.items.first?.id, PreparedCardHUDBuilder.ItemID.send)

        await band(PreparedCardHUDBuilder.ItemID.read, router, display)
        XCTAssertEqual(feed.read, [LensCardFixtures.longEmail])

        await band(PreparedCardHUDBuilder.ItemID.back, router, display)
        XCTAssertEqual(router.cardDraftPage, pages - 2, "back a page")
    }

    func testBackFromTheDraftsFirstPageReturnsToTheCard() async {
        let display = makeDisplay()
        let router = makeRouter(display, Feed(three))
        router.openCards()
        await band(PreparedCardHUDBuilder.ItemID.second, router, display)   // "Text Ana" opens the draft
        XCTAssertEqual(router.cardDraftPage, 0)
        await band(PreparedCardHUDBuilder.ItemID.back, router, display)
        XCTAssertNil(router.cardDraftPage)
        XCTAssertEqual(router.currentScreen?.title, "Leave by 18:15")
    }

    // MARK: - Presses through PageTurnGate

    func testAPressUnderANotificationIsDroppedAndTheStackRedraws() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        router.openCards(at: LensCardFixtures.shortNight.id)
        await band(PreparedCardHUDBuilder.ItemID.primary, router, display)
        let issued = display.heldScreenRevision
        // A notification arrives between the press and its frame.
        display.flash("A notification", duration: 30)
        XCTAssertGreaterThan(display.frameRevision, issued)
        router.pressCard(PreparedCardLensPress(action: .nextPage, cardID: LensCardFixtures.shortNight.id),
                         issuedAgainst: issued)
        XCTAssertEqual(router.cardDraftPage, 0, "the stale turn is dropped")
        XCTAssertEqual(display.heldScreenRevision, display.frameRevision, "and the stack drawn again")
        XCTAssertFalse(feed.presses.contains(.nextPage))

        router.pressCard(PreparedCardLensPress(action: .nextPage, cardID: LensCardFixtures.shortNight.id),
                         issuedAgainst: display.heldScreenRevision)
        XCTAssertEqual(router.cardDraftPage, 1, "a press on the current frame turns")
    }

    func testAPressOnACardThatExpiredIsDroppedAndTheNextCardShows() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        router.openCards()
        feed.remove(LensCardFixtures.leaveBy.id)       // its validUntil passed
        await band(PreparedCardHUDBuilder.ItemID.primary, router, display)
        XCTAssertTrue(feed.ran.isEmpty, "directions for a card that has gone never run")
        XCTAssertEqual(router.currentScreen?.title, LensCardFixtures.shortNight.headline)
    }

    func testAPressOnACardRebuiltSinceItWasDrawnIsDroppedAndRedrawn() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        router.openCards()
        let old = LensCardFixtures.leaveBy
        feed.cards[0] = PreparedCard(id: old.id, headline: "Leave now", subject: old.subject, signals: old.signals,
                                     facts: old.facts, primary: old.primary, secondary: old.secondary,
                                     draft: old.draft, urgency: old.urgency, dueAt: old.dueAt,
                                     validUntil: old.validUntil)
        await band(PreparedCardHUDBuilder.ItemID.primary, router, display)
        XCTAssertTrue(feed.ran.isEmpty)
        XCTAssertEqual(router.currentScreen?.title, "Leave now")
        await band(PreparedCardHUDBuilder.ItemID.primary, router, display)
        XCTAssertEqual(feed.ran.map(\.1), [old.id], "the redrawn card takes the press")
    }

    func testTheStackFollowsTheFeedAndClosesWhenItEmpties() {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.leaveBy])
        let router = makeRouter(display, feed)
        router.openCards()
        let key = router.currentScreen?.renderKey
        let revision = display.frameRevision
        router.cardsChanged()
        XCTAssertEqual(display.frameRevision, revision, "an unchanged card is not drawn again")
        XCTAssertEqual(router.currentScreen?.renderKey, key)
        feed.cards = []
        router.cardsChanged()
        XCTAssertFalse(router.isPresentingCards)
        XCTAssertFalse(display.isInteractive)
    }

    // MARK: - Send on phone, later, not useful

    func testSendOnPhoneStagesFlashesAndMovesToTheNextCard() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        router.openCards()
        await band(PreparedCardHUDBuilder.ItemID.second, router, display)
        await band(PreparedCardHUDBuilder.ItemID.send, router, display)
        XCTAssertEqual(router.shownCardID, LensCardFixtures.shortNight.id, "the stack returns on the next card")
        XCTAssertNil(router.cardDraftPage)
        await drain()
        XCTAssertEqual(feed.staged, [LensCardFixtures.leaveBy.id])
        XCTAssertEqual(display.mirrorScreen?.lines.first?.text, PreparedCardHUDBuilder.stagedLine)
    }

    func testSendOnPhoneOnTheLastCardClosesTheStack() async {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.runningLate])
        feed.stageOutcome = .openedComposer
        let router = makeRouter(display, feed)
        router.openCards()
        do { let said = await router.handleVoiceCommand("send it on my phone"); XCTAssertTrue(said) }
        XCTAssertFalse(router.isPresentingCards)
        await drain()
        XCTAssertEqual(feed.staged, [LensCardFixtures.runningLate.id])
        XCTAssertEqual(display.mirrorScreen?.lines.first?.text, PreparedCardHUDBuilder.stagedOpenLine)
    }

    func testTheWords() async {
        let display = makeDisplay()
        let feed = Feed(three)
        let router = makeRouter(display, feed)
        do { let said = await router.handleVoiceCommand("later"); XCTAssertFalse(said, "no stack, no words") }
        router.openCards()
        do { let said = await router.handleVoiceCommand("next card"); XCTAssertTrue(said) }
        XCTAssertEqual(router.shownCardID, LensCardFixtures.shortNight.id)
        do { let said = await router.handleVoiceCommand("later"); XCTAssertTrue(said) }
        XCTAssertEqual(feed.later, [LensCardFixtures.shortNight.id])
        XCTAssertEqual(router.shownCardID, LensCardFixtures.fitItIn.id, "the next card takes its place")
        do { let said = await router.handleVoiceCommand("next card"); XCTAssertFalse(said, "nothing after the last card: left to the model") }
        do { let said = await router.handleVoiceCommand("send it on my phone"); XCTAssertFalse(said, "fit it in has no draft") }
        do { let said = await router.handleVoiceCommand("not useful"); XCTAssertTrue(said) }
        XCTAssertEqual(feed.notUseful, [LensCardFixtures.fitItIn.id])
        XCTAssertEqual(router.shownCardID, LensCardFixtures.leaveBy.id)
        do { let said = await router.handleVoiceCommand("dismiss"); XCTAssertTrue(said) }
        XCTAssertEqual(feed.dismissed, [LensCardFixtures.leaveBy.id])
        XCTAssertFalse(router.isPresentingCards, "the last card gone, the stack closes")
    }

    func testTheStackGoesOverATaskCardAndGivesItBack() async {
        let display = makeDisplay()
        let router = makeRouter(display, Feed(three))
        let task = LensTaskSource()
        router.startTask(task)
        XCTAssertEqual(router.currentScreen?.title, "Step one")
        router.openCards()
        XCTAssertEqual(router.currentScreen?.title, "Leave by 18:15")
        do { let said = await router.handleVoiceCommand("next"); XCTAssertTrue(said, "next is the next card while the stack is up") }
        XCTAssertEqual(task.completed, 0)
        router.closeCards()
        XCTAssertEqual(router.currentScreen?.title, "Step one")
        XCTAssertTrue(router.isPresentingTask)

        // A task stopped from the phone while the cards are over it leaves the cards up.
        router.openCards()
        router.stopTask()
        XCTAssertTrue(router.isPresentingCards)
        XCTAssertTrue(display.isInteractive)
        XCTAssertEqual(router.currentScreen?.title, "Leave by 18:15")
        router.closeCards()
        XCTAssertFalse(display.isInteractive)
    }

    // MARK: - Pushed glances (§6.2)

    private func makeGlances(_ display: GlassesDisplayService, _ router: HUDRouter, _ feed: Feed)
        -> (PreparedCardGlances, expire: () -> Void, opened: () -> [PreparedCardID]) {
        let defaults = UserDefaults(suiteName: "kt-p3-\(UUID().uuidString)")!
        let glances = PreparedCardGlances(display: display, router: router, defaults: defaults)
        var timers: [@MainActor () -> Void] = []
        var opened: [PreparedCardID] = []
        glances.cards = { feed.cards }
        glances.worn = { true }
        glances.geometry = { .raybanDisplay }
        glances.scheduleExpiry = { _, fire in timers.append(fire) }
        glances.open = { id in
            opened.append(id)
            router.openCards(at: id)
        }
        return (glances, { timers.forEach { $0() } }, { opened })
    }

    func testAnImmediateCardIsPushedOnceAsAGlanceThatCloses() async {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.leaveBy, LensCardFixtures.meetingFollowUp])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        rig.0.evaluate()
        XCTAssertTrue(rig.0.isShowing)
        XCTAssertEqual(rig.0.screenOnLens?.title, "Leave by 18:15")
        XCTAssertEqual(rig.0.screenOnLens?.items.map(\.label), ["Open", "Close"])
        rig.expire()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertFalse(display.isInteractive)
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing, "each card pushes once; the follow-up is never pushed")
    }

    func testOpenOnAGlanceOpensTheStackAtItsCard() async {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.fitItIn, LensCardFixtures.runningLate])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        rig.0.evaluate()
        XCTAssertEqual(rig.0.screenOnLens?.title, LensCardFixtures.runningLate.headline)
        guard let screen = rig.0.screenOnLens else { return XCTFail() }
        display.testInteractiveButtonActions(for: screen)[0]()
        await drain()
        XCTAssertEqual(rig.opened(), [LensCardFixtures.runningLate.id])
        XCTAssertEqual(router.shownCardID, LensCardFixtures.runningLate.id)
    }

    func testAPushNeverCoversATaskCardAndWaitsForItToClose() {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.jobOnMyWay])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        router.startTask(LensTaskSource())
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertEqual(router.currentScreen?.title, "Step one")
        router.stopTask()
        rig.0.evaluate()
        XCTAssertTrue(rig.0.isShowing, "it goes up once the task card has closed")
    }

    func testAPushNeverCoversAnAnswerCardAndIsDroppedIfNoLongerImmediate() {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.leaveBy])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        XCTAssertTrue(display.presentAnswerCard(HUDScreen(title: "Answer", items: [
            HUDItem(id: "kp.close", label: "Close", style: .outline) {},
        ])) { _ in })
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertTrue(display.showsAnswerCard)
        // The card is no longer immediate by the time the answer closes (the event started).
        feed.cards = []
        display.endInteractive()
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertFalse(display.isInteractive)
    }

    func testNothingIsPushedOrQueuedWhileAnotherAppHasTheDisplay() {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.runningLate])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        display.applySessionReading(.init(state: .paused))
        XCTAssertEqual(display.displayAvailability, .inUse)
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing)
        XCTAssertFalse(display.isInteractive)
        display.applySessionReading(.init(state: .started))
        XCTAssertEqual(display.displayAvailability, .ours)
        rig.0.evaluate()
        XCTAssertFalse(rig.0.isShowing, "nothing queued while in use comes up afterwards")
    }

    func testAPushIsAStalePressSafeRaisedCard() {
        let display = makeDisplay()
        let feed = Feed([LensCardFixtures.leaveBy])
        let router = makeRouter(display, feed)
        let rig = makeGlances(display, router, feed)
        rig.0.evaluate()
        display.flash("A notification", duration: 30)
        rig.0.handle(PreparedCardLensPress(action: .open, cardID: LensCardFixtures.leaveBy.id))
        XCTAssertTrue(rig.opened().isEmpty, "a press under a notification is dropped")
    }
}

/// A one-step task for the precedence tests.
@MainActor
private final class LensTaskSource: HUDTaskSource {
    var title: String { "Example task" }
    var current: HUDStep? { HUDStep(index: 0, total: 1, title: "Step one") }
    var next: HUDStep? { nil }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    private(set) var completed = 0
    func complete() async { completed += 1 }
    func skip() async {}
    func back() async {}
}
#endif
