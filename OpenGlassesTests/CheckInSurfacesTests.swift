import XCTest
@testable import OpenGlasses

// Plan LE P2 — the Evening Check-in's notification, its "Want to deal with the first one now?", the
// card on the lens, the line on the wrist and the things-to-try scenarios. Invented titles only.

// MARK: - Fixtures

private enum P2 {
    typealias F = OpenLoopFixture

    static func settings(myDay: Bool = true, checkIn: Bool = true, checkInMinutes: Int? = 21 * 60,
                         fieldAssist: Bool = false, evening: Bool = false, eveningMinutes: Int = 19 * 60,
                         quiet: Bool = false, quietStart: Int = 22 * 60, quietEnd: Int = 7 * 60) -> MyDayDeliverySettings {
        MyDayDeliverySettings(myDayEnabled: myDay, morningEnabled: false, morningMinutes: 8 * 60,
                              eveningEnabled: evening, eveningMinutes: eveningMinutes,
                              scheduledSpeechEnabled: true, quietHoursEnabled: quiet,
                              quietStartMinutes: quietStart, quietEndMinutes: quietEnd,
                              checkInEnabled: checkIn, checkInMinutes: checkInMinutes, fieldAssistOn: fieldAssist)
    }

    static let heldTitle = "Your OK to use the send message tool"
    static let approval = F.approval(1, heldTitle, since: F.at(19))
    static let reminder = F.reminder("r1", "Renew the registration", due: F.at(9))
    static let step = F.step(1, "Book a skip", goal: "Clear the garage", due: F.at(12))
}

/// The notification centre, faked: what is pending and delivered, and whether the phone allows it.
@MainActor
private final class FakeCheckInCenter: CheckInNotificationCentering {
    var pending: [String: CheckInNotificationRequest] = [:]
    var otherPending: [String] = []
    var delivered: [String] = []
    var allowed = true
    private(set) var askedWith: [Bool] = []
    private(set) var postedNow: [CheckInNotificationRequest] = []

    func pendingIdentifiers() async -> [String] { Array(pending.keys).sorted() + otherPending }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ request: CheckInNotificationRequest, immediately: Bool) async {
        if immediately {
            postedNow.append(request)
            pending[request.identifier] = nil
            if !delivered.contains(request.identifier) { delivered.append(request.identifier) }
        } else {
            pending[request.identifier] = request
        }
    }
    func remove(pending ids: [String], delivered shown: [String]) {
        for id in ids { pending[id] = nil }
        otherPending.removeAll { ids.contains($0) }
        delivered.removeAll { shown.contains($0) }
    }
    func mayNotify(askIfNeeded: Bool) async -> Bool {
        askedWith.append(askIfNeeded)
        return allowed
    }
}

// MARK: - The notification's rules

final class CheckInNotificationPolicyTests: XCTestCase {
    private typealias F = OpenLoopFixture

    func testOffOrMyDayOffWantsNothing() {
        XCTAssertEqual(CheckInNotificationPolicy.wanted(now: F.at(16), calendar: F.calendar,
                                                        settings: P2.settings(checkIn: false), lastCheckInDayKey: ""), [])
        XCTAssertEqual(CheckInNotificationPolicy.wanted(now: F.at(16), calendar: F.calendar,
                                                        settings: P2.settings(myDay: false), lastCheckInDayKey: ""), [])
    }

    func testOnItWantsOneNotificationAnEveningForAWeek() {
        let wanted = CheckInNotificationPolicy.wanted(now: F.at(16), calendar: F.calendar,
                                                      settings: P2.settings(), lastCheckInDayKey: "")
        XCTAssertEqual(wanted.count, CheckInNotificationPolicy.daysAhead)
        XCTAssertEqual(wanted.first?.dayKey, "2026-11-14")
        XCTAssertEqual(wanted.first?.identifier, "my-day.check-in.2026-11-14.1260")
        XCTAssertEqual(wanted.last?.dayKey, "2026-11-20")
        XCTAssertEqual(wanted.first?.fireAt.hour, 21)
        XCTAssertEqual(wanted.first?.fireAt.minute, CheckInNotificationPolicy.delayMinutes,
                       "a little after the time, so a live process delivers first and takes it away")
        XCTAssertEqual(Set(wanted.map(\.identifier)).count, wanted.count)
    }

    func testTonightIsLeftOutOnceItsTimeHasGoneOrTheCheckInHasRun() {
        let late = CheckInNotificationPolicy.wanted(now: F.at(21, 5), calendar: F.calendar,
                                                    settings: P2.settings(), lastCheckInDayKey: "")
        XCTAssertEqual(late.first?.dayKey, "2026-11-15")
        let ran = CheckInNotificationPolicy.wanted(now: F.at(20), calendar: F.calendar,
                                                   settings: P2.settings(), lastCheckInDayKey: "2026-11-14")
        XCTAssertEqual(ran.first?.dayKey, "2026-11-15", "the check-in already ran tonight while the app was alive")
    }

    func testWithFieldAssistTheDefaultIsFivePmAndAChosenTimeIsKept() {
        let field = CheckInNotificationPolicy.wanted(now: F.at(9), calendar: F.calendar,
                                                     settings: P2.settings(checkInMinutes: nil, fieldAssist: true),
                                                     lastCheckInDayKey: "")
        XCTAssertEqual(field.first?.fireAt.hour, 17)
        XCTAssertEqual(field.first?.identifier, "my-day.check-in.2026-11-14.1020")
        let chosen = CheckInNotificationPolicy.wanted(now: F.at(9), calendar: F.calendar,
                                                      settings: P2.settings(checkInMinutes: 20 * 60, fieldAssist: true),
                                                      lastCheckInDayKey: "")
        XCTAssertEqual(chosen.first?.fireAt.hour, 20)
    }

    func testNothingIsScheduledInsideQuietHours() {
        let wanted = CheckInNotificationPolicy.wanted(now: F.at(9), calendar: F.calendar,
                                                      settings: P2.settings(quiet: true, quietStart: 20 * 60),
                                                      lastCheckInDayKey: "")
        XCTAssertEqual(wanted, [])
    }

    func testReconcileAddsWhatIsMissingAndRemovesOnlyItsOwnStaleOnes() {
        let wanted = CheckInNotificationPolicy.wanted(now: F.at(16), calendar: F.calendar,
                                                      settings: P2.settings(), lastCheckInDayKey: "")
        let stale = "my-day.check-in.2026-11-13.1260"
        let (add, remove) = CheckInNotificationPolicy.reconcile(
            wanted: wanted, pending: [stale, "field-assist.staged-sends", wanted[0].identifier])
        XCTAssertEqual(add.map(\.identifier), wanted.dropFirst().map(\.identifier))
        XCTAssertEqual(remove, [stale], "another plan's notification is never touched")
    }

    func testAChangedTimeReplacesEveryEvening() {
        let before = CheckInNotificationPolicy.wanted(now: F.at(9), calendar: F.calendar,
                                                      settings: P2.settings(), lastCheckInDayKey: "")
        let after = CheckInNotificationPolicy.wanted(now: F.at(9), calendar: F.calendar,
                                                     settings: P2.settings(checkInMinutes: 20 * 60), lastCheckInDayKey: "")
        let (add, remove) = CheckInNotificationPolicy.reconcile(wanted: after, pending: before.map(\.identifier))
        XCTAssertEqual(add, after)
        XCTAssertEqual(Set(remove), Set(before.map(\.identifier)))
    }

    func testAfterARunTonightsGoesUnlessItWasShownAndNotSpoken() {
        let tonight = "my-day.check-in.2026-11-14.1260"
        let tomorrow = "my-day.check-in.2026-11-15.1260"
        XCTAssertEqual(CheckInNotificationPolicy.afterRun(dayKey: "2026-11-14", minutes: 1260, delivered: true,
                                                          spoke: true, known: [tonight, tomorrow]),
                       .remove(identifiers: [tonight]))
        XCTAssertEqual(CheckInNotificationPolicy.afterRun(dayKey: "2026-11-14", minutes: 1260, delivered: false,
                                                          spoke: false, known: [tonight, tomorrow]),
                       .remove(identifiers: [tonight]), "silent when empty: nothing left on the phone")
        XCTAssertEqual(CheckInNotificationPolicy.afterRun(dayKey: "2026-11-14", minutes: 1260, delivered: true,
                                                          spoke: false, known: [tomorrow, tonight]),
                       .postNow(identifier: tonight, dayKey: "2026-11-14"))
        XCTAssertEqual(CheckInNotificationPolicy.afterRun(dayKey: "2026-11-14", minutes: 1260, delivered: true,
                                                          spoke: false, known: []),
                       .postNow(identifier: tonight, dayKey: "2026-11-14"))
    }

    func testIdentifiersCarryOnlyTheDayAndTheTime() {
        XCTAssertEqual(CheckInNotificationPolicy.dayKey(of: "my-day.check-in.2026-11-14.1260"), "2026-11-14")
        XCTAssertNil(CheckInNotificationPolicy.dayKey(of: "my-day.card.abc"))
        XCTAssertEqual(CheckInNotificationPolicy.dayKey(from: [CheckInNotificationPolicy.dayKeyInfoKey: "2026-11-14"]),
                       "2026-11-14")
    }

    @MainActor
    func testTheWordsNameNothing() {
        XCTAssertEqual(CheckInNotificationPolicy.body, "Your evening check-in is ready.")
        XCTAssertEqual(CheckInNotificationPolicy.title, "My Day")
        XCTAssertEqual(AppState.myDayDeliveryNotificationBody(.checkIn), CheckInNotificationPolicy.body)
    }

    @MainActor
    func testATapOnTheCheckInsNotificationOpensTheCheckIn() {
        var opened: [String] = []
        var tabs: [MainTab] = []
        let router = JobSendNotificationRouter(openTab: { tabs.append($0) }, routeAction: { _ in })
        router.openCheckIn = { opened.append($0) }
        router.handle(.tap, userInfo: [CheckInNotificationPolicy.dayKeyInfoKey: "2026-11-14"])
        XCTAssertEqual(opened, ["2026-11-14"])
        XCTAssertEqual(tabs, [])
    }
}

// MARK: - The scheduler over the centre

@MainActor
final class CheckInNotificationSchedulerTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private func scheduler(_ center: FakeCheckInCenter, settings: MyDayDeliverySettings = P2.settings(),
                           lastDay: String = "", at now: Date = OpenLoopFixture.at(16),
                           mayAsk: Bool = false) -> CheckInNotificationScheduler {
        let scheduler = CheckInNotificationScheduler(center: center)
        scheduler.settings = { settings }
        scheduler.lastCheckInDayKey = { lastDay }
        scheduler.calendar = { F.calendar }
        scheduler.now = { now }
        scheduler.mayAsk = { mayAsk }
        return scheduler
    }

    func testTurnedOnItSchedulesTheWeekOnceAndAgainChangesNothing() async {
        let center = FakeCheckInCenter()
        let scheduler = scheduler(center)
        let changed = await scheduler.reconcile()
        XCTAssertTrue(changed)
        XCTAssertEqual(center.pending.count, CheckInNotificationPolicy.daysAhead)
        let again = await scheduler.reconcile()
        XCTAssertFalse(again)
        XCTAssertEqual(center.pending.count, CheckInNotificationPolicy.daysAhead)
    }

    func testTurnedOffItLeavesNoneOfItsOwnPendingOrDelivered() async {
        let center = FakeCheckInCenter()
        _ = await scheduler(center).reconcile()
        center.delivered = ["my-day.check-in.2026-11-13.1260", "my-day.card.x"]
        center.otherPending = ["field-assist.staged-sends"]
        _ = await scheduler(center, settings: P2.settings(checkIn: false)).reconcile()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.otherPending, ["field-assist.staged-sends"])
        XCTAssertEqual(center.delivered, ["my-day.card.x"])
    }

    func testWithoutPermissionNothingIsAddedAndItAsksOnlyWhenSwitchedOnInTheForeground() async {
        let center = FakeCheckInCenter()
        center.allowed = false
        _ = await scheduler(center, mayAsk: true).reconcile()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.askedWith, [false], "already on at launch: not asked out of the blue")

        var on = false
        let switched = scheduler(center, mayAsk: true)
        switched.settings = { P2.settings(checkIn: on) }
        _ = await switched.reconcile()
        on = true
        _ = await switched.reconcile()
        XCTAssertEqual(center.askedWith, [false, true], "asked once, right after the wearer switched it on")

        var later = false
        let background = scheduler(center, mayAsk: false)
        background.settings = { P2.settings(checkIn: later) }
        _ = await background.reconcile()
        later = true
        _ = await background.reconcile()
        XCTAssertEqual(center.askedWith.last, false, "never from the background")
    }

    func testARunThatWasSpokenTakesTonightsAway() async {
        let center = FakeCheckInCenter()
        let scheduler = scheduler(center)
        _ = await scheduler.reconcile()
        center.delivered = ["my-day.check-in.2026-11-14.1260"]
        await scheduler.checkInRan(dayKey: "2026-11-14", delivered: true, spoke: true)
        XCTAssertNil(center.pending["my-day.check-in.2026-11-14.1260"])
        XCTAssertNotNil(center.pending["my-day.check-in.2026-11-15.1260"], "tomorrow's stays")
        XCTAssertEqual(center.delivered, [])
        XCTAssertTrue(center.postedNow.isEmpty)
    }

    func testARunShownButNotSpokenLeavesOneNotificationInTonightsPlace() async {
        let center = FakeCheckInCenter()
        let scheduler = scheduler(center)
        _ = await scheduler.reconcile()
        await scheduler.checkInRan(dayKey: "2026-11-14", delivered: true, spoke: false)
        XCTAssertEqual(center.postedNow.map(\.identifier), ["my-day.check-in.2026-11-14.1260"])
        XCTAssertNil(center.pending["my-day.check-in.2026-11-14.1260"], "replaced, not added beside")
        XCTAssertEqual(center.askedWith.last, false, "never asks for permission after a run")
    }

    func testTheBackgroundWakeTopsTheWindowUpOnlyWhileTheCheckInIsOn() async {
        let off = scheduler(FakeCheckInCenter(), settings: P2.settings(checkIn: false))
        XCTAssertNil(off.nextBackgroundWake(now: F.at(16)))
        let offOutcome = await off.backgroundParticipant().run(F.at(17))
        XCTAssertEqual(offOutcome, .notDue)

        let center = FakeCheckInCenter()
        let on = scheduler(center)
        XCTAssertEqual(on.nextBackgroundWake(now: F.at(16)), F.at(16), "never looked: due now")
        let first = await on.backgroundParticipant().run(F.at(17))
        XCTAssertEqual(first, .didWork)
        XCTAssertEqual(on.nextBackgroundWake(now: F.at(16)), F.at(16).addingTimeInterval(24 * 3600))
        let second = await on.backgroundParticipant().run(F.at(17))
        XCTAssertEqual(second, .nothingToDo)
        XCTAssertEqual(CheckInNotificationScheduler.backgroundID, "check-in-notifications")
    }
}

// MARK: - The delivery settles the notification

/// Day sources for a My Day service the scheduled delivery can call for the evening's part.
@MainActor
private final class SilentDaySources: CalendarDaySource, RemindersDaySource, WeatherDaySource {
    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        .init(value: [], state: .available(.calendar))
    }
    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> { .init(value: [], state: .available(.reminders)) }
    func completeReminder(id: String) async throws -> String? { nil }
    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> { .init(value: nil, state: .available(.weather)) }
}

// MARK: - The offer

@MainActor
final class CheckInOfferTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var savedDays: (String, String, String) = ("", "", "")

    override func setUp() {
        super.setUp()
        suiteName = "CheckInOfferTests.\(UUID().uuidString)"
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

    private final class Replays {
        var keys: [String] = []
    }

    private func checkIn(_ loops: [OpenLoop], replayable: Bool = true, direct: Bool = true,
                         settings: MyDayDeliverySettings = P2.settings()) -> (EveningCheckInService, Replays) {
        let service = EveningCheckInService(readers: [FakeLoopReader([.approval, .reminder, .goalStep], .read(loops))],
                                            store: OpenLoopDismissalStore(defaults: defaults, calendar: { F.calendar }))
        service.calendar = { F.calendar }
        service.fieldAssistOn = { false }
        service.settings = { settings }
        let replays = Replays()
        service.holdKey = { $0 == F.uuid(501) ? "hold-1" : nil }
        service.canReplay = { _ in replayable }
        service.replay = { key in
            replays.keys.append(key)
            return "Sent."
        }
        service.offersAfterScheduled = { direct }
        return (service, replays)
    }

    private let offer = "Want to deal with the first one now?"

    func testTheScheduledCheckInOffersAReplayableApprovalAndAYesPutsItBackOnce() async {
        let (service, replays) = checkIn([P2.approval, P2.reminder])
        let text = await service.scheduledText(now: F.at(21, 1), mayOffer: true)
        XCTAssertTrue(text?.hasSuffix(offer) ?? false, text ?? "")
        XCTAssertEqual(service.pendingOffer?.holdKey, "hold-1")

        let first = await service.dealWithFirst(now: F.at(21, 2))
        XCTAssertEqual(first, "Sent.", "the replayed call's own outcome")
        XCTAssertEqual(replays.keys, ["hold-1"])
        let again = await service.dealWithFirst(now: F.at(21, 2))
        XCTAssertEqual(again, CheckInOfferPolicy.nothingOffered, "single use")
        XCTAssertEqual(replays.keys, ["hold-1"])
    }

    func testAnApprovalThatCanNoLongerBePutBackIsNotOffered() async {
        let (service, _) = checkIn([P2.approval], replayable: false)
        let text = await service.scheduledText(now: F.at(21, 1), mayOffer: true)
        XCTAssertFalse(text?.contains(offer) ?? true)
        XCTAssertNil(service.pendingOffer)
    }

    func testNothingIsOfferedWhenTheFirstItemIsNotAnApproval() async {
        let (service, _) = checkIn([P2.reminder, P2.step])
        let text = await service.scheduledText(now: F.at(21, 1), mayOffer: true)
        XCTAssertFalse(text?.contains(offer) ?? true)
        XCTAssertNil(service.pendingOffer)
    }

    func testTheScheduledCheckInOffersOnlyWhereTheYesCanLand() async {
        let (live, _) = checkIn([P2.approval], direct: false)
        let liveText = await live.scheduledText(now: F.at(21, 1), mayOffer: true)
        XCTAssertFalse(liveText?.contains(offer) ?? true, "a live session never hears the scheduled check-in")

        defaults.removePersistentDomain(forName: suiteName)      // the first one marked the item said today
        let (unspoken, _) = checkIn([P2.approval])
        let shownText = await unspoken.scheduledText(now: F.at(21, 1), mayOffer: false)
        XCTAssertNotNil(shownText)
        XCTAssertFalse(shownText?.contains(offer) ?? true)
        XCTAssertNil(unspoken.pendingOffer)
    }

    func testAnOfferLapsesAfterAFewMinutes() async {
        let (service, replays) = checkIn([P2.approval])
        _ = await service.scheduledText(now: F.at(21, 1), mayOffer: true)
        XCTAssertNotNil(service.offerTurnNote(now: F.at(21, 3)))
        XCTAssertNil(service.offerTurnNote(now: F.at(21, 7)))
        let late = await service.dealWithFirst(now: F.at(21, 7))
        XCTAssertEqual(late, CheckInOfferPolicy.nothingOffered)
        XCTAssertTrue(replays.keys.isEmpty)
    }

    func testTheTurnNoteNamesNothing() async {
        let (service, _) = checkIn([P2.approval])
        _ = await service.scheduledText(now: F.at(21, 1), mayOffer: true)
        let note = service.offerTurnNote(now: F.at(21, 2)) ?? ""
        XCTAssertTrue(note.contains("deal_with_first"))
        XCTAssertFalse(note.lowercased().contains("send message"))
        XCTAssertFalse(note.contains(P2.heldTitle))
    }

    func testAskedForItOffersTooAndTheToolTakesTheYes() async throws {
        let (service, replays) = checkIn([P2.approval, P2.reminder])
        let tool = ActivityTool()
        tool.checkIn = { service }
        tool.clock = { F.at(16) }
        let said = try await tool.execute(args: ["action": "waiting"])
        XCTAssertTrue(said.hasSuffix(offer), said)
        let yes = try await tool.execute(args: ["action": "deal_with_first"])
        XCTAssertEqual(yes, "Sent.")
        XCTAssertEqual(replays.keys, ["hold-1"])
    }

    func testDealWithFirstWithNoOfferDoesNothing() async throws {
        let (service, replays) = checkIn([P2.approval])
        let tool = ActivityTool()
        tool.checkIn = { service }
        let said = try await tool.execute(args: ["action": "deal_with_first"])
        XCTAssertEqual(said, CheckInOfferPolicy.nothingOffered)
        XCTAssertTrue(replays.keys.isEmpty)
        let noService = ActivityTool()
        let none = try await noService.execute(args: ["action": "deal_with_first"])
        XCTAssertEqual(none, CheckInOfferPolicy.nothingOffered)
    }

    func testTheToolDeclaresTheAction() {
        let tool = ActivityTool()
        XCTAssertTrue(tool.description.contains("deal_with_first"))
        let schema = tool.parametersSchema["properties"] as? [String: Any]
        let action = schema?["action"] as? [String: Any]
        XCTAssertTrue((action?["enum"] as? [String])?.contains("deal_with_first") ?? false)
    }

    // MARK: Through the delivery

    private struct Run: Equatable {
        let dayKey: String
        let delivered: Bool
        let spoke: Bool
    }

    private func delivery(_ checkIn: EveningCheckInService, settings: MyDayDeliverySettings,
                          motion: MotionSample.Kind? = nil)
        -> (MyDayScheduledDeliveryService, () -> [String], () -> [Run], () -> [MyDayDeliverySlot]) {
        let sources = SilentDaySources()
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
        var texts: [String] = []
        var slots: [MyDayDeliverySlot] = []
        var runs: [Run] = []
        service.onDelivery = { slot, text, _, _ in
            texts.append(text)
            slots.append(slot)
        }
        service.onCheckInRan = { day, delivered, spoke in runs.append(Run(dayKey: day, delivered: delivered, spoke: spoke)) }
        return (service, { texts }, { runs }, { slots })
    }

    func testTheDeliveryOffersWhenSpokenAndSettlesTonightsNotification() async {
        let (checkIn, _) = checkIn([P2.approval])
        let (service, texts, runs, _) = delivery(checkIn, settings: P2.settings())
        await service.evaluate(now: F.at(21, 1))
        XCTAssertTrue(texts().first?.hasSuffix(offer) ?? false)
        XCTAssertEqual(runs(), [Run(dayKey: "2026-11-14", delivered: true, spoke: true)])
    }

    func testWhileDrivingNothingIsOfferedAndTheRunIsShownNotSpoken() async {
        let (checkIn, _) = checkIn([P2.approval])
        let (service, texts, runs, _) = delivery(checkIn, settings: P2.settings(), motion: .automotive)
        await service.evaluate(now: F.at(21, 1))
        XCTAssertFalse(texts().first?.contains(offer) ?? true)
        XCTAssertNil(checkIn.pendingOffer)
        XCTAssertEqual(runs(), [Run(dayKey: "2026-11-14", delivered: true, spoke: false)])
    }

    func testMergedWithTheEveningTheQuestionIsNotAsked() async {
        let chosen = P2.settings(evening: true, eveningMinutes: 20 * 60 + 45)
        let (checkIn, _) = checkIn([P2.approval], settings: chosen)
        let (service, texts, _, slots) = delivery(checkIn, settings: chosen)
        await service.evaluate(now: F.at(21, 1))
        XCTAssertFalse(texts().first?.contains(offer) ?? true)
        XCTAssertEqual(slots(), [.checkIn])
    }

    func testAnEmptyCheckInIsARunWithNothingDeliveredAndAnEmptyMergeIsTheEvenings() async {
        let (empty, _) = checkIn([])
        let (service, texts, runs, _) = delivery(empty, settings: P2.settings())
        await service.evaluate(now: F.at(21, 1))
        XCTAssertTrue(texts().isEmpty)
        XCTAssertEqual(runs(), [Run(dayKey: "2026-11-14", delivered: false, spoke: true)])

        Config.myDayLastCheckInDeliveryDay = ""
        let chosen = P2.settings(evening: true, eveningMinutes: 20 * 60 + 45)
        let (mergedEmpty, _) = checkIn([], settings: chosen)
        let (merged, _, _, slots) = delivery(mergedEmpty, settings: chosen)
        await merged.evaluate(now: F.at(21, 1))
        XCTAssertEqual(slots(), [.evening], "the evening's words, delivered as the evening")
    }
}

// MARK: - The lens and the wrist

final class CheckInLensCardTests: XCTestCase {
    private typealias F = OpenLoopFixture

    func testNothingWaitingIsNoCard() {
        XCTAssertNil(CheckInLensCard.text(.empty, fieldAssist: false))
    }

    func testTheCountComesFirstThenOneItemALine() {
        let text = CheckInLensCard.text(OpenLoopCollection(loops: [P2.reminder, P2.step], unavailable: []),
                                        fieldAssist: false)
        XCTAssertEqual(text, "2 waiting on you\nRenew the registration\nBook a skip")
        let field = CheckInLensCard.text(OpenLoopCollection(loops: [P2.reminder], unavailable: []), fieldAssist: true)
        XCTAssertEqual(field?.split(separator: "\n").first, "1 before you finish")
    }

    func testPastSixItemsTheRestAreCounted() {
        let loops = (1...8).map { F.reminder("r\($0)", "Item \($0)", due: F.at(9)) }
        let text = CheckInLensCard.text(OpenLoopCollection(loops: loops, unavailable: []), fieldAssist: false) ?? ""
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.first, "8 waiting on you")
        XCTAssertEqual(lines.count, 1 + CheckInLensCard.maximumItems + 1)
        XCTAssertEqual(lines.last, "2 more on your phone")
    }

    func testTheFirstPageIsTheCountAndTheFirstItemAndTheRestTurn() {
        let loops = [P2.reminder, P2.step,
                     F.reminder("r2", "Call the garage", due: F.at(10)),
                     F.reminder("r3", "Pay the water bill", due: F.at(11))]
        let text = CheckInLensCard.text(OpenLoopCollection(loops: loops, unavailable: []), fieldAssist: false) ?? ""
        let pages = HUDAnswerPager.pages(for: text, geometry: .raybanDisplay)
        XCTAssertGreaterThan(pages.count, 1, "the rest are behind the page turn")
        XCTAssertEqual(pages.first?.lines.first, "4 waiting on you")
        XCTAssertEqual(pages.first?.lines.dropFirst().first, "Renew the registration")
    }

    func testItGoesOnTheLensOnlyWhenSpokenAndNoTurnIsOpen() {
        XCTAssertTrue(CheckInLensCard.shows(spoke: true, turnOpen: false))
        XCTAssertFalse(CheckInLensCard.shows(spoke: false, turnOpen: false), "driving or the glasses off")
        XCTAssertFalse(CheckInLensCard.shows(spoke: true, turnOpen: true))
    }
}

final class WatchTodayWaitingTests: XCTestCase {
    private typealias F = OpenLoopFixture
    private let two = OpenLoopCollection(loops: [P2.reminder, P2.step], unavailable: [])

    func testInTheEveningItIsTheCountAndTheFirstItem() {
        let line = WatchTodayWaitingBuilder.line(two, readAt: F.at(21), now: F.at(21, 5), calendar: F.calendar,
                                                 settings: P2.settings(), redacted: false)
        XCTAssertEqual(line, WatchTodayWaiting(count: 2, heading: "2 waiting on you", first: "Renew the registration"))
    }

    func testMedicalComplianceLeavesTheCountAlone() {
        let line = WatchTodayWaitingBuilder.line(two, readAt: F.at(21), now: F.at(21, 5), calendar: F.calendar,
                                                 settings: P2.settings(), redacted: true)
        XCTAssertEqual(line?.count, 2)
        XCTAssertNil(line?.first)
    }

    func testNoLineWhenOffEmptyEarlyOrReadOnAnotherDay() {
        XCTAssertNil(WatchTodayWaitingBuilder.line(two, readAt: F.at(21), now: F.at(21, 5), calendar: F.calendar,
                                                   settings: P2.settings(checkIn: false), redacted: false))
        XCTAssertNil(WatchTodayWaitingBuilder.line(.empty, readAt: F.at(21), now: F.at(21, 5), calendar: F.calendar,
                                                   settings: P2.settings(), redacted: false))
        XCTAssertNil(WatchTodayWaitingBuilder.line(two, readAt: F.at(15), now: F.at(16), calendar: F.calendar,
                                                   settings: P2.settings(), redacted: false),
                     "before the evening and before the check-in's time")
        XCTAssertNil(WatchTodayWaitingBuilder.line(two, readAt: F.at(21, day: 13), now: F.at(21, 5),
                                                   calendar: F.calendar, settings: P2.settings(), redacted: false),
                     "yesterday's read is not tonight's list")
        XCTAssertNil(WatchTodayWaitingBuilder.line(two, readAt: nil, now: F.at(21, 5), calendar: F.calendar,
                                                   settings: P2.settings(), redacted: false))
    }

    func testThePayloadCarriesTheLineAndAnOlderPayloadReadsWithout() throws {
        let line = WatchTodayWaiting(count: 2, heading: "2 waiting on you", first: "Renew the registration")
        let payload = WatchTodayPayload(day: WatchTodayDay(year: 2026, month: 11, day: 14), generatedAt: F.at(21),
                                        calendarStatus: .shown, events: [], moreEvents: 0, redacted: false,
                                        weatherStatus: .notIncluded, weather: nil, attribution: nil, waiting: line)
        guard case .success(let encoded) = WatchTodayCodec.encode(payload) else { return XCTFail("encode") }
        XCTAssertEqual(WatchTodayCodec.decode(encoded.data)?.waiting, line)
        XCTAssertEqual(WatchTodayCodec.decode(encoded.data)?.version, 3)

        var older = payload
        older.version = 2
        older.waiting = nil
        guard case .success(let olderData) = WatchTodayCodec.encode(older) else { return XCTFail("encode") }
        XCTAssertNil(WatchTodayCodec.decode(olderData.data)?.waiting)
        XCTAssertEqual(WatchTodayCodec.decode(olderData.data)?.version, 2)
    }
}

// MARK: - Things to try

final class CheckInScenarioTests: XCTestCase {

    func testTheCheckInIsOfferedFromThingsToTry() throws {
        let everyday = try XCTUnwrap(ScenarioCatalog.scenario(id: "still-waiting"))
        XCTAssertEqual(everyday.intent, .everyday)
        XCTAssertEqual(everyday.toolNames, ["activity"])
        XCTAssertEqual(everyday.kind, .prompt)
        let field = try XCTUnwrap(ScenarioCatalog.scenario(id: "field-before-you-finish"))
        XCTAssertEqual(field.intent, .field)
        XCTAssertTrue(field.needs.contains(.fieldAssist))
        XCTAssertTrue(field.needs.contains(.tool("activity")))
    }
}
