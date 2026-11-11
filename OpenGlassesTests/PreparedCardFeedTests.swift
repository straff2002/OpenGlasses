import XCTest
@testable import OpenGlasses

/// Plan KT P1 — My Day publishes the joined day (§3.1): the builder turns a gathering into cards
/// then rows, applies what the wearer did through the store, keeps an edit across a rebuild and
/// says when the times under it changed (§5.4), and turns a kind off on the third "not useful"
/// (§3.5). Then `MyDayService` itself: the feed is published with the snapshot, rows only when
/// locked, and the Google calendar hint (§9.2). Invented people and places only.
@MainActor
final class PreparedCardFeedTests: XCTestCase {

    private var directory: URL!
    private var savedKindSetting: Any?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCardFeed_\(UUID().uuidString)", isDirectory: true)
        savedKindSetting = UserDefaults.standard.object(forKey: Config.preparedCardKindKey(.leaveBy))
    }

    override func tearDown() {
        if let savedKindSetting {
            UserDefaults.standard.set(savedKindSetting, forKey: Config.preparedCardKindKey(.leaveBy))
        } else {
            UserDefaults.standard.removeObject(forKey: Config.preparedCardKindKey(.leaveBy))
        }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Fixtures

    private let ana = CardContact(name: "Ana Example", phone: "555-0142")

    private func gigInputs() -> MyDayInputs { CardFixtures.gigInputs().myDay }

    private func snapshot(_ inputs: MyDayInputs, now: Date) -> MyDaySnapshot {
        MyDayComposer(calendar: CardFixtures.calendar, locale: CardFixtures.locale).compose(inputs: inputs, now: now)
    }

    private func makeBuilder(enabled: Bool = true, metrics: RecordingCardMetrics = RecordingCardMetrics(),
                             context: FakeCardContext? = nil) -> (PreparedCardFeedBuilder, FakeCardContext) {
        let source = context ?? FakeCardContext(context: PreparedCardContext(
            travelDistanceMeters: 5_000, contacts: ["ana@example.com": ana]))
        let builder = PreparedCardFeedBuilder(
            store: PreparedCardStore(directory: directory), metrics: metrics, contextSource: source,
            calendar: { CardFixtures.calendar }, locale: CardFixtures.locale, isEnabled: { enabled },
            settings: { _, _ in CardFixtures.settings })
        return (builder, source)
    }

    private func built(_ builder: PreparedCardFeedBuilder, now: Date = CardFixtures.at(17)) async -> PreparedCardFeed {
        let inputs = gigInputs()
        return await builder.build(inputs: inputs, snapshot: snapshot(inputs, now: now), now: now)
    }

    // MARK: - Cards then rows

    func testAGatheringBecomesCardsThenRows() async throws {
        let (builder, _) = makeBuilder()
        let result = await built(builder)
        let card = try XCTUnwrap(result.feed.cards.first)
        XCTAssertEqual(card.kind, .leaveBy)
        XCTAssertNotNil(card.draft, "Ana is in Contacts, so the card has a draft")
        XCTAssertFalse(result.feed.rows.contains { $0.id == MyDayItemID(source: .calendar, rawValue: "gig-1") },
                       "the card replaces the event's row")
        XCTAssertTrue(result.feed.absorbed.contains(CardRowID(MyDayItemID(source: .calendar, rawValue: "gig-1"))))
    }

    func testCardsOffIsMyDaysRowsAsTheyWere() async {
        let (builder, _) = makeBuilder(enabled: false)
        let inputs = gigInputs()
        let day = snapshot(inputs, now: CardFixtures.at(17))
        let result = await builder.build(inputs: inputs, snapshot: day, now: CardFixtures.at(17))
        XCTAssertTrue(result.feed.cards.isEmpty)
        XCTAssertEqual(result.feed.rows, day.items)
        XCTAssertEqual(result.feed.overflow, day.overflowItems)
    }

    // MARK: - What the wearer did

    func testDismissLaterAndUndo() async throws {
        let (builder, _) = makeBuilder()
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        let now = CardFixtures.at(17, 1)

        builder.dismiss(card, now: now)
        XCTAssertTrue(builder.rejoin(now: now)?.feed.cards.isEmpty ?? false)
        builder.undo(card.id, now: now)
        XCTAssertEqual(builder.rejoin(now: now)?.feed.cards.first?.id, card.id)

        builder.later(card, until: CardFixtures.at(18), now: now)
        XCTAssertTrue(builder.rejoin(now: CardFixtures.at(17, 30))?.feed.cards.isEmpty ?? false)
        XCTAssertEqual(builder.rejoin(now: CardFixtures.at(18))?.feed.cards.first?.id, card.id, "back when it said")
    }

    func testAnEditIsKeptAcrossARebuildAndACancelledHandOff() async throws {
        let (builder, _) = makeBuilder()
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        builder.edit(card, text: "Leaving now, Ana", now: CardFixtures.at(17, 1))

        let rebuiltFeed = await built(builder, now: CardFixtures.at(17, 2))
        let rebuilt = try XCTUnwrap(rebuiltFeed.feed.cards.first)
        XCTAssertEqual(rebuilt.draft?.text, "Leaving now, Ana")

        builder.handedOff(rebuilt, result: .cancelled, now: CardFixtures.at(17, 3))
        let after = try XCTUnwrap(builder.rejoin(now: CardFixtures.at(17, 3))?.feed.cards.first)
        XCTAssertEqual(after.id, card.id, "a cancelled composer leaves the card")
        XCTAssertEqual(after.draft?.text, "Leaving now, Ana", "…and the edit")
    }

    func testASendClosesTheCardAndAnUnknownResultLeavesItOpenedIn() async throws {
        let (builder, _) = makeBuilder()
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        builder.handedOff(card, result: .unknown, now: CardFixtures.at(17, 1))
        XCTAssertEqual(builder.rejoin(now: CardFixtures.at(17, 1))?.feed.cards.first?.id, card.id)
        XCTAssertEqual(builder.store.memory[card.id]?.state, .handedOff(at: CardFixtures.at(17, 1), result: .unknown))

        builder.handedOff(card, result: .sent, now: CardFixtures.at(17, 2))
        XCTAssertTrue(builder.rejoin(now: CardFixtures.at(17, 2))?.feed.cards.isEmpty ?? false)
    }

    func testTimesChangingUnderAnEditAsksRatherThanOverwrites() async throws {
        let (builder, _) = makeBuilder()
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        let original = try XCTUnwrap(card.draft?.text)
        builder.edit(card, text: "Leaving now, Ana", now: CardFixtures.at(17, 1))

        // Past leave-by the arrival moves on, so the rule writes a different draft.
        let later = try XCTUnwrap(builder.rejoin(now: CardFixtures.at(18, 20)))
        let newDraft = try XCTUnwrap(later.changedDrafts[card.id])
        XCTAssertNotEqual(newDraft, original)
        XCTAssertEqual(later.feed.cards.first?.draft?.text, "Leaving now, Ana", "the edit is not overwritten")

        builder.keepEdit(card.id, newBase: newDraft, now: CardFixtures.at(18, 20))
        XCTAssertNil(builder.rejoin(now: CardFixtures.at(18, 20))?.changedDrafts[card.id], "Keep mine settles it")

        builder.updateDraft(card.id, now: CardFixtures.at(18, 20))
        XCTAssertEqual(builder.rejoin(now: CardFixtures.at(18, 20))?.feed.cards.first?.draft?.text, newDraft, "Update")
    }

    func testTheThirdNotUsefulTurnsTheKindOffAndUndoTurnsItBack() async throws {
        let (builder, _) = makeBuilder()
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        builder.notUseful(card, now: CardFixtures.at(17, 1))
        builder.notUseful(card, now: CardFixtures.at(17, 2))
        XCTAssertTrue(Config.preparedCardKindEnabled(.leaveBy))
        builder.notUseful(card, now: CardFixtures.at(17, 3))
        XCTAssertFalse(Config.preparedCardKindEnabled(.leaveBy))
        XCTAssertEqual(builder.rejoin(now: CardFixtures.at(17, 3))?.turnedOffKind, .leaveBy, "said once on the page")

        builder.undoTurnOff(.leaveBy)
        XCTAssertTrue(Config.preparedCardKindEnabled(.leaveBy))
        XCTAssertNil(builder.rejoin(now: CardFixtures.at(17, 4))?.turnedOffKind)
    }

    func testMetricsCountWithoutContent() async throws {
        let metrics = RecordingCardMetrics()
        let (builder, _) = makeBuilder(metrics: metrics)
        let cardFeed = await built(builder)
        let card = try XCTUnwrap(cardFeed.feed.cards.first)
        _ = await built(builder)
        builder.noteShown([card], now: CardFixtures.at(17))
        builder.noteShown([card], now: CardFixtures.at(17, 1))
        builder.edit(card, text: "Mine", now: CardFixtures.at(17, 2))
        builder.edit(card, text: "Mine again", now: CardFixtures.at(17, 3))
        builder.handedOff(card, result: .sent, now: CardFixtures.at(17, 4))
        XCTAssertEqual(metrics.events, [.card(.leaveBy, .built), .card(.leaveBy, .shown), .draftOrigin(.template),
                                        .card(.leaveBy, .draftEdited), .card(.leaveBy, .handedOff),
                                        .card(.leaveBy, .sent)],
                       "built once, shown once, edited once however many keystrokes")
    }

    // MARK: - The job day

    func testTheJobDayIsReadFreshOnEveryJoin() async throws {
        let context = FakeCardContext(context: PreparedCardContext())
        let (builder, _) = makeBuilder(context: context)
        let inputs = CardFixtures.myDay()
        _ = await builder.build(inputs: inputs, snapshot: snapshot(inputs, now: CardFixtures.at(15)), now: CardFixtures.at(15))
        context.jobs = CardJobFacts(sessions: [CardFixtures.session("s1", ended: CardFixtures.at(14))])
        let feed = try XCTUnwrap(builder.rejoin(now: CardFixtures.at(15)))
        XCTAssertEqual(feed.feed.cards.map(\.kind), [.jobReportOwed])
        XCTAssertTrue(feed.feed.absorbed.contains(.jobDay("unsent-s1")))
    }

    func testTheJobDaysOwnRowGivesWayToTheCard() {
        var inputs = JobDayInputs(now: CardFixtures.at(15), calendar: CardFixtures.calendar,
                                  sessions: [CardFixtures.session("s1", ended: CardFixtures.at(14))])
        XCTAssertTrue(JobDayComposer.compose(inputs).todos.contains { $0.id == "unsent-s1" })
        inputs.absorbedTodoIDs = ["unsent-s1"]
        XCTAssertFalse(JobDayComposer.compose(inputs).todos.contains { $0.id == "unsent-s1" })
    }

    // MARK: - MyDayService

    private func service(sources: CardTestDaySources, builder: PreparedCardFeedBuilder?) -> MyDayService {
        let service = MyDayService(calendarSource: sources, remindersSource: sources, weatherSource: sources,
                                   travelSource: sources, sourceSelection: { .all },
                                   calendarProvider: { CardFixtures.calendar }, metrics: NullMyDayMetrics())
        service.cardBuilder = builder
        return service
    }

    func testTheServicePublishesTheFeedWithTheSnapshot() async throws {
        let sources = CardTestDaySources()
        let (builder, _) = makeBuilder()
        let myDay = service(sources: sources, builder: builder)
        var published: [TodayFeed] = []
        myDay.onFeedChanged = { feed, _ in published.append(feed) }

        _ = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertEqual(myDay.todayFeed.cards.map(\.kind), [.leaveBy])
        XCTAssertEqual(published.last, myDay.todayFeed)

        let card = try XCTUnwrap(myDay.card(myDay.todayFeed.cards[0].id))
        myDay.changeCards(now: CardFixtures.at(17, 1)) { $0.dismiss(card, now: CardFixtures.at(17, 1)) }
        XCTAssertTrue(myDay.todayFeed.cards.isEmpty, "acting on a card re-joins without a refresh")
        XCTAssertEqual(sources.calendarLoads, 1)
    }

    func testWithoutABuilderTheFeedIsTheRows() async {
        let sources = CardTestDaySources()
        let myDay = service(sources: sources, builder: nil)
        let snapshot = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertTrue(myDay.todayFeed.cards.isEmpty)
        XCTAssertEqual(myDay.todayFeed.rows, snapshot.items)
    }

    func testLockedTheFeedHasNoCards() async {
        let sources = CardTestDaySources()
        let (builder, _) = makeBuilder()
        let myDay = service(sources: sources, builder: builder)
        myDay.protectedDataAvailable = { false }
        _ = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertTrue(myDay.todayFeed.cards.isEmpty)
    }

    func testTheGoogleCalendarHint() async {
        let sources = CardTestDaySources()
        let myDay = service(sources: sources, builder: nil)
        myDay.calendarSources = { [CalendarSourceRecord(title: "iCloud", kind: .calDAV)] }
        _ = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertTrue(myDay.googleCalendarMissing)

        myDay.calendarSources = { [CalendarSourceRecord(title: "Gmail", kind: .calDAV)] }
        _ = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertFalse(myDay.googleCalendarMissing)

        sources.calendarState = .denied(.calendar)
        myDay.calendarSources = { [] }
        _ = await myDay.refresh(now: CardFixtures.at(17), channel: nil)
        XCTAssertFalse(myDay.googleCalendarMissing, "no hint while Calendar itself is off")
    }

    // MARK: - The support report

    func testTheCardsSectionIsCountsOnly() {
        let snapshot = PreparedCardMetricsSnapshot(
            counts: [.leaveBy: [.built: 3, .shown: 2, .sent: 1]], draftOrigins: [.template: 2],
            fallbacks: [.tooLong: 1])
        let lines = PreparedCardReport.lines(enabled: true, disabledKinds: [.fitItIn], customerTextsAllowed: false,
                                             shownNow: 2, snapshot: snapshot)
        XCTAssertEqual(lines, [
            "Cards: on, 2 on the page now",
            "Cards off: fitItIn",
            "Cards: customer texts off",
            "Cards leaveBy: built 3, shown 2, sent 1",
            "Card drafts: template 2",
            "Card draft fallbacks: tooLong 1",
        ])
    }

    func testTheMetricsStoreRoundTrips() {
        let suite = "PreparedCardMetrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreparedCardMetricsStore(defaults: defaults)
        store.record(.card(.jobOnMyWay, .handedOff))
        store.record(.card(.jobOnMyWay, .handedOff))
        store.record(.validatorFallback(.url))
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count(.jobOnMyWay, .handedOff), 2)
        XCTAssertEqual(snapshot.total(.handedOff), 2)
        XCTAssertEqual(snapshot.fallbacks, [.url: 1])
        store.reset()
        XCTAssertTrue(store.snapshot().counts.isEmpty)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeCardContext: PreparedCardContextSource {
    var context: PreparedCardContext
    var jobs: CardJobFacts?
    var isFieldAssistDay = false
    var healthAvailable = false

    init(context: PreparedCardContext) { self.context = context }

    func context(for inputs: MyDayInputs, settings: PreparedCardSettings, now: Date) async -> PreparedCardContext {
        context
    }

    func jobFacts(now: Date) -> CardJobFacts? { jobs }
}

private final class RecordingCardMetrics: PreparedCardMetricsRecording {
    var events: [PreparedCardMetricEvent] = []
    func record(_ event: PreparedCardMetricEvent) { events.append(event) }
}

private final class NullMyDayMetrics: MyDayMetricsRecording {
    func record(_ event: MyDayMetricEvent, at date: Date) {}
}

/// The gig day: one event with a place and Ana, and its travel estimate.
@MainActor
private final class CardTestDaySources: CalendarDaySource, RemindersDaySource, WeatherDaySource, TravelTimeDaySource {
    var calendarState = MyDaySourceState.available(.calendar)
    var calendarLoads = 0
    private let inputs = CardFixtures.gigInputs().myDay

    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        calendarLoads += 1
        return .init(value: calendarState.availability == .available ? inputs.events : [], state: calendarState)
    }

    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> { .init(value: [], state: .available(.reminders)) }
    func completeReminder(id: String) async throws -> String? { nil }
    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> { .init(value: nil, state: .available(.weather)) }

    func loadTravel(for events: [MyDayCalendarEvent], now: Date) async -> MyDaySourceLoad<MyDayTravelEstimate?> {
        .init(value: events.isEmpty ? nil : inputs.travel, state: .available(.travel))
    }

    func directionsURL(for eventID: String) -> URL? { nil }
}
