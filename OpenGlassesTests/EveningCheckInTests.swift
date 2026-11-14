import XCTest
@testable import OpenGlasses

/// Day sources for a My Day service the scheduled delivery can call for the evening's part.
@MainActor
private final class QuietDaySources: CalendarDaySource, RemindersDaySource, WeatherDaySource {
    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        .init(value: [], state: .available(.calendar))
    }
    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> { .init(value: [], state: .available(.reminders)) }
    func completeReminder(id: String) async throws -> String? { nil }
    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> { .init(value: nil, state: .available(.weather)) }
}

/// Plan LE P1 — the check-in delivered at its time, asked for with `activity waiting`, and shown as
/// My Day's Waiting on you section. Invented titles and names only.
@MainActor
final class EveningCheckInTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var savedDays: (String, String, String) = ("", "", "")

    override func setUp() {
        super.setUp()
        suiteName = "EveningCheckInTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedDays = (Config.myDayLastMorningDeliveryDay, Config.myDayLastEveningDeliveryDay,
                     Config.myDayLastCheckInDeliveryDay)
        Config.myDayLastMorningDeliveryDay = ""
        Config.myDayLastEveningDeliveryDay = ""
        Config.myDayLastCheckInDeliveryDay = ""
    }

    override func tearDown() {
        Config.myDayLastMorningDeliveryDay = savedDays.0
        Config.myDayLastEveningDeliveryDay = savedDays.1
        Config.myDayLastCheckInDeliveryDay = savedDays.2
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Fixtures

    private func settings(checkIn: Bool = true, checkInMinutes: Int? = 21 * 60, evening: Bool = false,
                          eveningMinutes: Int = 19 * 60) -> MyDayDeliverySettings {
        MyDayDeliverySettings(myDayEnabled: true, morningEnabled: false, morningMinutes: 8 * 60,
                              eveningEnabled: evening, eveningMinutes: eveningMinutes,
                              scheduledSpeechEnabled: true, quietHoursEnabled: false,
                              quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60,
                              checkInEnabled: checkIn, checkInMinutes: checkInMinutes, fieldAssistOn: false)
    }

    private func checkIn(_ readers: [OpenLoopSourceReading],
                         settings: MyDayDeliverySettings? = nil) -> EveningCheckInService {
        let service = EveningCheckInService(readers: readers,
                                            store: OpenLoopDismissalStore(defaults: defaults, calendar: { F.calendar }))
        service.calendar = { F.calendar }
        service.fieldAssistOn = { false }
        let chosen = settings ?? self.settings()
        service.settings = { chosen }
        return service
    }

    private struct Delivered {
        let slot: MyDayDeliverySlot
        let text: String
        let speak: Bool
    }

    private func delivery(_ checkIn: EveningCheckInService, settings: MyDayDeliverySettings,
                          motion: MotionSample.Kind? = nil) -> (MyDayScheduledDeliveryService, () -> [Delivered]) {
        let sources = QuietDaySources()
        let myDay = MyDayService(calendarSource: sources, remindersSource: sources, weatherSource: sources,
                                 sourceSelection: { .init(calendar: true, reminders: true, weather: false,
                                                          travel: false, digest: false, goals: false) },
                                 calendarProvider: { F.calendar })
        let service = MyDayScheduledDeliveryService(myDayService: myDay, calendarProvider: { F.calendar })
        service.settings = { settings }
        service.presence = { .active }
        service.power = { .normal }
        service.isOnline = { true }
        service.isBusy = { false }
        service.sourceAccessReady = { true }
        service.protectedDataAvailable = { true }
        service.motion = { motion }
        service.checkIn = checkIn
        var delivered: [Delivered] = []
        service.onDelivery = { slot, text, speak, _ in delivered.append(Delivered(slot: slot, text: text, speak: speak)) }
        return (service, { delivered })
    }

    private let twoLoops: [OpenLoop] = [
        OpenLoopFixture.reminder("r1", "Renew the registration", due: OpenLoopFixture.at(9, day: 12)),
        OpenLoopFixture.step(1, "Book a skip", goal: "Clear the garage", due: OpenLoopFixture.at(12)),
    ]

    // MARK: Delivery

    func testTheCheckInDeliversItsListAtItsTime() async {
        let checkIn = checkIn([FakeLoopReader([.reminder, .goalStep], .read(twoLoops))])
        let (service, delivered) = delivery(checkIn, settings: settings())
        await service.evaluate(now: F.at(20, 59))
        XCTAssertTrue(delivered().isEmpty, "not before its time")

        await service.evaluate(now: F.at(21, 1))
        XCTAssertEqual(delivered().count, 1)
        XCTAssertEqual(delivered().first?.slot, .checkIn)
        XCTAssertEqual(delivered().first?.speak, true)
        XCTAssertEqual(delivered().first?.text,
                       "Two things are still waiting on you: the 'Renew the registration' reminder and the next step of 'Clear the garage'.")
        XCTAssertEqual(Config.myDayLastCheckInDeliveryDay, "2026-11-14")
        XCTAssertEqual(Set(checkIn.store.said(on: F.now).keys), Set(twoLoops.map(\.id)),
                       "each delivered loop is marked said today")
    }

    func testItIsNeverDeliveredTwiceInADay() async {
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([twoLoops[0]]))])
        let (service, delivered) = delivery(checkIn, settings: settings())
        await service.evaluate(now: F.at(21, 1))
        await service.evaluate(now: F.at(21, 2))
        await service.evaluate(now: F.at(22, 30))
        XCTAssertEqual(delivered().count, 1)
    }

    func testAnEmptyCheckInSaysNothingAndIsNotSaidLaterInTheWindow() async {
        let reader = FakeLoopReader([.reminder], .read([]))
        let checkIn = checkIn([reader])
        let (service, delivered) = delivery(checkIn, settings: settings())
        await service.evaluate(now: F.at(21, 1))
        XCTAssertTrue(delivered().isEmpty, "silent when empty (decision 4)")
        XCTAssertEqual(Config.myDayLastCheckInDeliveryDay, "2026-11-14", "and today's turn is spent")

        reader.reading = .read([twoLoops[0]])
        await service.evaluate(now: F.at(21, 40))
        XCTAssertTrue(delivered().isEmpty, "never later in the window")
    }

    func testMergedWithTheEveningTheListComesFirstAndBothDaysAreSpent() async {
        let chosen = settings(evening: true, eveningMinutes: 20 * 60 + 45)
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([twoLoops[0]]))], settings: chosen)
        let (service, delivered) = delivery(checkIn, settings: chosen)
        await service.evaluate(now: F.at(20, 50))
        XCTAssertEqual(delivered().count, 1)
        let text = delivered().first?.text ?? ""
        XCTAssertTrue(text.hasPrefix("One thing is still waiting on you: the 'Renew the registration' reminder. "), text)
        XCTAssertGreaterThan(text.count, "One thing is still waiting on you: the 'Renew the registration' reminder. ".count,
                             "then the evening's look at tomorrow")
        XCTAssertEqual(Config.myDayLastCheckInDeliveryDay, "2026-11-14")
        XCTAssertEqual(Config.myDayLastEveningDeliveryDay, "2026-11-14")

        await service.evaluate(now: F.at(21, 5))
        XCTAssertEqual(delivered().count, 1, "neither comes again")
    }

    func testAnEmptyCheckInMergedWithTheEveningLeavesTheEveningToSpeak() async {
        let chosen = settings(evening: true, eveningMinutes: 20 * 60 + 45)
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([]))], settings: chosen)
        let (service, delivered) = delivery(checkIn, settings: chosen)
        await service.evaluate(now: F.at(20, 50))
        XCTAssertEqual(delivered().count, 1)
        XCTAssertFalse(delivered().first?.text.contains("waiting on you") ?? true)
    }

    func testWhileDrivingItIsShownNotSpoken() async {
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([twoLoops[0]]))])
        let (service, delivered) = delivery(checkIn, settings: settings(), motion: .automotive)
        await service.evaluate(now: F.at(21, 1))
        XCTAssertEqual(delivered().count, 1)
        XCTAssertEqual(delivered().first?.speak, false, "on the phone, said when asked (decision 10)")
    }

    func testAnOldMotionReadingSaysNothingAboutNow() {
        let sample = MotionSample(.automotive, at: F.at(20))
        XCTAssertEqual(MyDayDeliveryMotion.kind(of: sample, now: F.at(20, 5)), .automotive)
        XCTAssertNil(MyDayDeliveryMotion.kind(of: sample, now: F.at(21)))
        XCTAssertNil(MyDayDeliveryMotion.kind(of: nil, now: F.at(21)))
    }

    func testWhatWasAskedForAfterTheTimeIsNotSaidAgainAtTheTime() async {
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([twoLoops[0]]))],
                              settings: settings(checkInMinutes: 20 * 60))
        _ = await checkIn.askedText(now: F.at(20, 10))
        let (service, delivered) = delivery(checkIn, settings: settings(checkInMinutes: 20 * 60))
        await service.evaluate(now: F.at(20, 20))
        XCTAssertTrue(delivered().isEmpty, "each item is said once a day")
        XCTAssertEqual(Config.myDayLastCheckInDeliveryDay, "2026-11-14")
    }

    func testTheSettingsRowShowsTheDefaultUntilTheWearerChooses() {
        XCTAssertEqual(MyDayCheckInDefaults.shown(stored: nil, fieldAssistOn: false), 21 * 60)
        XCTAssertEqual(MyDayCheckInDefaults.shown(stored: nil, fieldAssistOn: true), 17 * 60)
        XCTAssertEqual(MyDayCheckInDefaults.shown(stored: 19 * 60 + 30, fieldAssistOn: true), 19 * 60 + 30)
    }

    // MARK: activity waiting

    private func tool(_ checkIn: EveningCheckInService?) -> ActivityTool {
        let tool = ActivityTool()
        tool.checkIn = { checkIn }
        return tool
    }

    func testWaitingSaysNothingIsWaitingWhenEmpty() async throws {
        let checkIn = checkIn([FakeLoopReader([.reminder], .read([]))])
        let said = try await tool(checkIn).execute(args: ["action": "waiting"])
        XCTAssertEqual(said, "Nothing is waiting on you.")
    }

    func testWaitingListsWhatIsWaiting() async throws {
        let checkIn = checkIn([FakeLoopReader([.reminder, .goalStep], .read(twoLoops))])
        let tool = tool(checkIn)
        tool.clock = { F.at(16) }
        let said = try await tool.execute(args: ["action": "waiting"])
        XCTAssertTrue(said.hasPrefix("Two things are still waiting on you:"), said)
        XCTAssertFalse(said.contains("Want to deal with the first one now?"))
        XCTAssertTrue(checkIn.store.said(on: F.at(16)).isEmpty, "asked before the check-in time: nothing marked")
    }

    func testWaitingAfterTheCheckInTimeMarksTheDaysItemsSaid() async throws {
        let checkIn = checkIn([FakeLoopReader([.reminder, .goalStep], .read(twoLoops))])
        let tool = tool(checkIn)
        tool.clock = { F.at(21, 30) }
        _ = try await tool.execute(args: ["action": "waiting"])
        XCTAssertEqual(Set(checkIn.store.said(on: F.at(21, 30)).keys), Set(twoLoops.map(\.id)))
    }

    func testWaitingSaysWhenItCouldNotCheckEverything() async throws {
        let checkIn = checkIn([FakeLoopReader([.reminder], .unavailable), FakeLoopReader([.goalStep], .read([]))])
        let said = try await tool(checkIn).execute(args: ["action": "waiting"])
        XCTAssertEqual(said, "I couldn't check everything, and nothing I could check is waiting on you.")
    }

    func testTheToolDescribesTheQuestionsItAnswers() {
        let tool = ActivityTool()
        XCTAssertTrue(tool.description.contains("what's waiting on me?"))
        XCTAssertTrue(tool.description.contains("what do I still need to do today?"))
        XCTAssertTrue(tool.description.contains("anything I haven't answered?"))
        let schema = tool.parametersSchema["properties"] as? [String: Any]
        let action = schema?["action"] as? [String: Any]
        XCTAssertTrue((action?["enum"] as? [String])?.contains("waiting") ?? false)
    }

    // MARK: My Day's section

    func testTheSectionShowsInTheEveningAndAfterTheTimeWhenThereIsSomething() {
        func visible(_ enabled: Bool, empty: Bool, at now: Date, minutes: Int = 17 * 60) -> Bool {
            WaitingOnYouSection.isVisible(checkInEnabled: enabled, isEmpty: empty, now: now,
                                          calendar: F.calendar, checkInMinutes: minutes)
        }
        XCTAssertFalse(visible(false, empty: false, at: F.at(21)), "only while the check-in is on")
        XCTAssertTrue(visible(true, empty: true, at: F.at(18, 30)), "all evening, even when empty")
        XCTAssertTrue(visible(true, empty: false, at: F.at(17, 30)), "after the time, with something in it")
        XCTAssertFalse(visible(true, empty: true, at: F.at(17, 30)))
        XCTAssertFalse(visible(true, empty: false, at: F.at(16)), "not before the time")
    }

    private final class Calls {
        var reviewed: [UUID] = []
        var declined: [UUID] = []
        var completed: [String] = []
        var steps: [UUID] = []
        var opened: [OpenLoopPlace] = []
        var heard: [OpenLoopPlace] = []
    }

    private func model(_ loops: [OpenLoop], canReview: Bool = true, reviewWorks: Bool = true) -> (WaitingOnYouScreenModel, Calls) {
        let calls = Calls()
        var handlers = WaitingOnYouHandlers()
        handlers.canReview = { _ in canReview }
        handlers.review = { id in calls.reviewed.append(id); return reviewWorks }
        handlers.decline = { calls.declined.append($0) }
        handlers.completeReminder = { calls.completed.append($0) }
        handlers.completeStep = { _, step in calls.steps.append(step) }
        handlers.open = { calls.opened.append($0) }
        handlers.markHeard = { calls.heard.append($0) }
        let service = checkIn([FakeLoopReader([.approval, .reminder, .goalStep, .digest, .jobReport], .read(loops))])
        let model = WaitingOnYouScreenModel(checkIn: service, handlers: handlers)
        let chosen = settings(checkInMinutes: 17 * 60)
        model.settings = { chosen }
        model.calendar = { F.calendar }
        return (model, calls)
    }

    func testEachRowRoutesToItsOwnAction() async {
        let approval = F.approval(1, "Your OK to use the send message tool", since: F.at(20))
        let reminder = twoLoops[0]
        let step = twoLoops[1]
        let digest = OpenLoop(id: "digest:d1", source: .digest, title: "The parcel arrived", since: F.at(20),
                              action: .open(.digestItem(id: "d1")))
        let report = F.report("q1", job: .customer("Smith"))
        let (model, calls) = model([approval, reminder, step, digest, report])
        await model.refresh(now: F.now)
        XCTAssertTrue(model.isVisible)

        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows[approval.id]?.primary, .review(entryID: F.uuid(501)))
        XCTAssertEqual(rows[approval.id]?.secondary, .decline(entryID: F.uuid(501)))
        XCTAssertEqual(rows[reminder.id]?.primary, .complete(reminderID: "r1"))
        XCTAssertEqual(rows[step.id]?.primary, .stepDone(goalID: F.uuid(1), stepID: F.uuid(101)))
        XCTAssertEqual(rows[digest.id]?.primary, .heard(.digestItem(id: "d1")))
        XCTAssertEqual(rows[report.id]?.primary, .open(.job(.send(queuedId: "q1"))))
        XCTAssertEqual(rows[report.id]?.title, "Report not sent")
        XCTAssertEqual(rows[report.id]?.detail, "Smith")

        for row in model.rows {
            if let primary = row.primary { await model.perform(primary, now: F.now) }
            if let secondary = row.secondary { await model.perform(secondary, now: F.now) }
        }
        XCTAssertEqual(calls.reviewed, [F.uuid(501)], "approving runs the item's own confirmation")
        XCTAssertEqual(calls.declined, [F.uuid(501)])
        XCTAssertEqual(calls.completed, ["r1"])
        XCTAssertEqual(calls.steps, [F.uuid(101)])
        XCTAssertEqual(calls.heard, [.digestItem(id: "d1")])
        XCTAssertEqual(calls.opened, [.job(.send(queuedId: "q1"))])
        XCTAssertTrue(WaitingOnYouAction.review(entryID: F.uuid(501)).leavesPage)
        XCTAssertFalse(WaitingOnYouAction.decline(entryID: F.uuid(501)).leavesPage)
    }

    func testAnApprovalThatCanNoLongerBePutBackOffersOnlyDecline() async {
        let approval = F.approval(1, "Your OK to use the send message tool", since: F.at(20))
        let (model, _) = model([approval], canReview: false)
        await model.refresh(now: F.now)
        XCTAssertNil(model.rows.first?.primary)
        XCTAssertEqual(model.rows.first?.secondary, .decline(entryID: F.uuid(501)))
    }

    func testAReviewThatFailsSaysSo() async {
        let approval = F.approval(1, "Your OK to use the send message tool", since: F.at(20))
        let (model, _) = model([approval], reviewWorks: false)
        await model.refresh(now: F.now)
        await model.perform(.review(entryID: F.uuid(501)), now: F.now)
        XCTAssertNotNil(model.notice)
    }

    func testSwipingARowAwayWritesTheDismissalStoreOnly() async {
        let (model, calls) = model([twoLoops[0], twoLoops[1]])
        await model.refresh(now: F.now)
        let row = model.rows[0]
        model.dismiss(row, now: F.now)
        XCTAssertFalse(model.rows.contains { $0.id == row.id })
        XCTAssertEqual(model.checkIn.store.dismissed(on: F.now), [row.loop.id: row.loop.fingerprint])
        XCTAssertTrue(calls.completed.isEmpty && calls.steps.isEmpty, "clearing completes nothing")

        await model.refresh(now: F.now)
        XCTAssertFalse(model.rows.contains { $0.id == row.id }, "and it stays out tonight")
    }
}
