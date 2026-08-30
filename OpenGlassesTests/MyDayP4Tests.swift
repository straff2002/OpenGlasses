import XCTest
@testable import OpenGlasses

final class MyDayP4CalendarHardeningTests: XCTestCase {
    private func calendar(timeZone identifier: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: identifier)!
        return value
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testOverlappingAndAllDayEventsRemainDistinctAndDeterministic() {
        let calendar = calendar(timeZone: "Pacific/Auckland")
        let now = date("2026-08-30T22:15:00Z")
        let events = [
            MyDayCalendarEvent(
                id: "all-day", title: "Conference", startDate: date("2026-08-30T12:00:00Z"),
                endDate: date("2026-08-31T12:00:00Z"), isAllDay: true, location: nil
            ),
            MyDayCalendarEvent(
                id: "first", title: "First", startDate: date("2026-08-30T22:00:00Z"),
                endDate: date("2026-08-30T23:00:00Z"), isAllDay: false, location: nil
            ),
            MyDayCalendarEvent(
                id: "overlap", title: "Overlap", startDate: date("2026-08-30T22:30:00Z"),
                endDate: date("2026-08-30T23:30:00Z"), isAllDay: false, location: nil
            ),
        ]

        let snapshot = MyDayComposer(calendar: calendar, locale: Locale(identifier: "en_NZ"))
            .compose(inputs: .init(events: events, reminders: [], weather: nil, sourceStates: []), now: now)

        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["first", "overlap", "all-day"])
        XCTAssertEqual(snapshot.items.last?.detail, "All day")
        XCTAssertEqual(Set(snapshot.items.map(\.id.rawValue)).count, 3)
    }

    func testDeliveryUsesLocalCivilTimeAcrossDSTGapAndRepeatedHour() {
        let calendar = calendar(timeZone: "America/Los_Angeles")
        let settings = MyDayDeliverySettings(
            myDayEnabled: true,
            morningEnabled: true,
            morningMinutes: 2 * 60 + 30,
            eveningEnabled: false,
            eveningMinutes: 19 * 60,
            scheduledSpeechEnabled: true,
            quietHoursEnabled: false,
            quietStartMinutes: 22 * 60,
            quietEndMinutes: 7 * 60
        )
        let context = MyDayDeliveryContext(
            presence: .active,
            power: .normal,
            isOnline: true,
            isBusy: false,
            sourceAccessReady: true,
            isProtectedDataAvailable: true
        )

        // 02:30 does not exist on the spring-forward day. The first civil time after it remains
        // inside the bounded delivery window instead of losing the briefing.
        XCTAssertEqual(
            MyDayDeliveryPolicy.decide(
                now: date("2026-03-08T10:05:00Z"),
                calendar: calendar,
                settings: settings,
                context: context,
                lastMorningDayKey: "",
                lastEveningDayKey: ""
            ),
            .deliver(slot: .morning, dayKey: "2026-03-08", speak: true)
        )

        let firstRepeatedHour = date("2026-11-01T08:40:00Z")
        let secondRepeatedHour = date("2026-11-01T09:40:00Z")
        XCTAssertEqual(MyDayDeliveryPolicy.dayKey(for: firstRepeatedHour, calendar: calendar), "2026-11-01")
        XCTAssertEqual(MyDayDeliveryPolicy.dayKey(for: secondRepeatedHour, calendar: calendar), "2026-11-01")
        XCTAssertEqual(
            MyDayDeliveryPolicy.decide(
                now: secondRepeatedHour,
                calendar: calendar,
                settings: settings,
                context: context,
                lastMorningDayKey: "2026-11-01",
                lastEveningDayKey: ""
            ),
            .notDue
        )
    }
}

@MainActor
final class MyDayP4ServiceHardeningTests: XCTestCase {
    func testRefreshAdoptsChangedTimezoneWithoutRecreatingService() async {
        let now = iso("2026-08-30T00:00:00Z")
        let event = MyDayCalendarEvent(
            id: "timezone-event",
            title: "Appointment",
            startDate: iso("2026-08-30T10:00:00Z"),
            endDate: iso("2026-08-30T11:00:00Z"),
            isAllDay: false,
            location: nil
        )
        let sources = P4FakeDaySources(events: [event])
        let calendarBox = P4CalendarBox(calendar: fixedCalendar("UTC"))
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            sourceSelection: { .init(calendar: true, reminders: false, weather: false, travel: false, digest: false) },
            composer: MyDayComposer(calendar: fixedCalendar("UTC"), locale: Locale(identifier: "en_US")),
            calendarProvider: { calendarBox.calendar }
        )

        let utc = await service.refresh(now: now)
        calendarBox.calendar = fixedCalendar("Pacific/Auckland")
        let auckland = await service.refresh(now: now)

        XCTAssertNotEqual(utc.items.first?.detail, auckland.items.first?.detail)
        XCTAssertNotEqual(sources.requestedRanges[0].start, sources.requestedRanges[1].start)
    }

    func testPermissionDenialThenRegrantRestoresOnlyAffectedSources() async {
        let now = iso("2026-08-30T00:00:00Z")
        let sources = P4FakeDaySources()
        sources.calendarState = .denied(.calendar, message: "Calendar access is off.")
        sources.remindersState = .denied(.reminders, message: "Reminders access is off.")
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            sourceSelection: { .init(calendar: true, reminders: true, weather: false, travel: false, digest: false) }
        )

        let denied = await service.refresh(now: now)
        XCTAssertTrue(denied.sourceStates.allSatisfy { $0.availability == .denied })
        XCTAssertTrue(denied.items.isEmpty)

        sources.calendarState = .available(.calendar)
        sources.remindersState = .available(.reminders)
        sources.events = [
            .init(id: "regranted-event", title: "Event", startDate: now.addingTimeInterval(3600),
                  endDate: now.addingTimeInterval(7200), isAllDay: false, location: nil)
        ]
        sources.reminders = [
            .init(id: "regranted-reminder", title: "Reminder", dueDate: now, hasTime: true, priority: 0)
        ]

        let regranted = await service.refresh(now: now)
        XCTAssertTrue(regranted.sourceStates.allSatisfy { $0.availability == .available })
        XCTAssertEqual(Set(regranted.items.map(\.id.rawValue)), ["regranted-event", "regranted-reminder"])
    }

    func testRouteFailureAndOfflineWeatherRemainHonestPartialSnapshot() async {
        let now = iso("2026-08-30T00:00:00Z")
        let sources = P4FakeDaySources(events: [
            .init(id: "event", title: "Event", startDate: now.addingTimeInterval(3600),
                  endDate: now.addingTimeInterval(7200), isAllDay: false, location: "22 Queen Street")
        ])
        sources.weatherState = .unavailable(.weather, message: "Weather is unavailable offline.")
        sources.travelState = .unavailable(.travel, message: "Travel time could not be estimated.")
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            travelSource: sources,
            sourceSelection: { .init(calendar: true, reminders: false, weather: true, travel: true, digest: false) }
        )

        let snapshot = await service.refresh(now: now)

        XCTAssertTrue(snapshot.items.contains { $0.id.rawValue == "event" })
        XCTAssertFalse(snapshot.items.contains { $0.kind == .leaveBy || $0.kind == .weather })
        XCTAssertEqual(snapshot.sourceStates.first { $0.source == .travel }?.availability, .unavailable)
        XCTAssertEqual(snapshot.sourceStates.first { $0.source == .weather }?.availability, .unavailable)
        XCTAssertTrue(NativeWeatherDaySource.looksUnavailable("I can't get the weather right now."))
    }

    func testMissingLocationDoesNotAttemptRoutingOrMarkTravelUnavailable() async {
        let now = iso("2026-08-30T00:00:00Z")
        let events = [
            MyDayCalendarEvent(id: "blank", title: "Blank", startDate: now.addingTimeInterval(600),
                               endDate: now.addingTimeInterval(1200), isAllDay: false, location: "  "),
            MyDayCalendarEvent(id: "virtual", title: "Virtual", startDate: now.addingTimeInterval(1200),
                               endDate: now.addingTimeInterval(1800), isAllDay: false, location: "Zoom"),
        ]

        XCTAssertNil(MyDayTravelPlanner.nextLocatableEvent(in: events, now: now))
        XCTAssertNil(MyDayTravelPlanner.usableDestination(nil))
        XCTAssertNil(MyDayTravelPlanner.usableDestination("  "))
    }

    func testLockedPhoneDoesNotLoadContentAndUnlockCanRefresh() async {
        let now = iso("2026-08-30T00:00:00Z")
        let sources = P4FakeDaySources(events: [
            .init(id: "private-event", title: "Private", startDate: now.addingTimeInterval(3600),
                  endDate: now.addingTimeInterval(7200), isAllDay: false, location: "Private place")
        ])
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            travelSource: sources,
            digestSource: sources,
            sourceSelection: { .all }
        )
        var unlocked = false
        service.protectedDataAvailable = { unlocked }

        let locked = await service.refresh(now: now)
        XCTAssertTrue(locked.items.isEmpty)
        XCTAssertTrue(locked.sourceStates.allSatisfy { $0.message == "Unlock iPhone to refresh My Day." })
        XCTAssertEqual(sources.totalLoadCount, 0)

        unlocked = true
        let refreshed = await service.refresh(now: now)
        XCTAssertTrue(refreshed.items.contains { $0.id.rawValue == "private-event" })
        XCTAssertGreaterThan(sources.totalLoadCount, 0)
    }

    func testLockedScheduledDeliveryDefersWithoutConsumingOccurrence() {
        let calendar = fixedCalendar("UTC")
        let now = iso("2026-08-30T08:05:00Z")
        let decision = MyDayDeliveryPolicy.decide(
            now: now,
            calendar: calendar,
            settings: .init(
                myDayEnabled: true, morningEnabled: true, morningMinutes: 8 * 60,
                eveningEnabled: false, eveningMinutes: 19 * 60, scheduledSpeechEnabled: true,
                quietHoursEnabled: false, quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60
            ),
            context: .init(
                presence: .active, power: .normal, isOnline: true, isBusy: false,
                sourceAccessReady: true, isProtectedDataAvailable: false
            ),
            lastMorningDayKey: "",
            lastEveningDayKey: ""
        )

        XCTAssertEqual(decision, .deferred(.protectedData))
    }

    func testSnapshotLatencyRecordsOnlyABoundedBucket() async throws {
        let suiteName = "MyDayP4Latency-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let metrics = MyDayMetricsStore(defaults: defaults, calendar: fixedCalendar("UTC"))
        let clock = P4MonotonicClock(values: [100, 100.7])
        let sources = P4FakeDaySources()
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            sourceSelection: { .init(calendar: true, reminders: false, weather: false, travel: false, digest: false) },
            metrics: metrics,
            monotonicNow: { clock.next() }
        )

        _ = await service.refresh(now: iso("2026-08-30T00:00:00Z"))

        XCTAssertEqual(metrics.snapshot().snapshotLatencies[.underOneSecond], 1)
        let persisted = String(describing: defaults.persistentDomain(forName: suiteName) ?? [:])
        XCTAssertFalse(persisted.contains("title"))
        XCTAssertFalse(persisted.contains("location"))
    }

    private func fixedCalendar(_ identifier: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: identifier)!
        return value
    }

    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

final class MyDayP4SpeechAndMetricsTests: XCTestCase {
    func testSpokenBriefingHasHardDurationLimitAndPreservesAvailabilityWarning() {
        let long = Array(repeating: "confidential", count: 120).joined(separator: " ")
        let snapshot = MyDaySnapshot(
            generatedAt: Date(),
            period: .morning,
            headline: "Here is what matters today.",
            items: (0..<6).map { index in
                .init(
                    id: .init(source: .calendar, rawValue: "event-\(index)"),
                    kind: .event,
                    title: "Item \(index) \(long)",
                    detail: long,
                    dueAt: nil,
                    urgency: .upcoming,
                    actions: [.open]
                )
            },
            sourceStates: [.denied(.calendar)],
            nextRefreshAt: nil
        )

        let spoken = MyDaySpokenFormatter().format(snapshot)

        XCTAssertLessThanOrEqual(
            MyDaySpeechPolicy.estimatedDuration(for: spoken),
            MyDaySpeechPolicy.maximumDuration
        )
        XCTAssertLessThanOrEqual(spoken.count, MyDaySpeechPolicy.maximumCharacters)
        XCTAssertTrue(spoken.contains("Calendar is unavailable."))
    }

    func testLocalMetricsAggregateFixedVocabularyAndSevenDayReturn() throws {
        let suiteName = "MyDayP4Metrics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = MyDayMetricsStore(defaults: defaults, calendar: calendar)
        let first = Date(timeIntervalSince1970: 1_788_065_600)

        store.record(.optedIn, at: first)
        store.record(.briefingRequested(.phone), at: first)
        store.record(.briefingRequested(.voice), at: first.addingTimeInterval(6 * 86_400))
        store.record(.briefingRequested(.scheduled), at: first.addingTimeInterval(7 * 86_400))
        store.record(.briefingRequested(.phone), at: first.addingTimeInterval(8 * 86_400))
        store.record(.action(.openEvent), at: first)
        store.record(.action(.completeReminder), at: first)
        store.record(.action(.startDirections), at: first)
        store.record(.dismissal, at: first)
        store.record(.snapshotLatency(.under500Milliseconds), at: first)
        store.record(.spokenDuration(.target20Through35Seconds), at: first)

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.optIns, 1)
        XCTAssertEqual(snapshot.briefingRequests[.phone], 2)
        XCTAssertEqual(snapshot.briefingRequests[.voice], 1)
        XCTAssertEqual(snapshot.briefingRequests[.scheduled], 1)
        XCTAssertEqual(snapshot.actions.values.reduce(0, +), 3)
        XCTAssertEqual(snapshot.dismissals, 1)
        XCTAssertEqual(snapshot.sevenDayReturns, 1)
        XCTAssertEqual(snapshot.snapshotLatencies[.under500Milliseconds], 1)
        XCTAssertEqual(snapshot.spokenDurations[.target20Through35Seconds], 1)

        let persisted = String(describing: defaults.persistentDomain(forName: suiteName) ?? [:])
        for forbidden in ["Dental appointment", "22 Queen Street", "Buy medicine", "Private body", "Generated speech"] {
            XCTAssertFalse(persisted.contains(forbidden))
        }
    }
}

@MainActor
private final class P4FakeDaySources: CalendarDaySource, RemindersDaySource, WeatherDaySource,
                                      TravelTimeDaySource, DigestDaySource {
    var events: [MyDayCalendarEvent]
    var reminders: [MyDayReminder] = []
    var weather: MyDayWeather?
    var travel: MyDayTravelEstimate?
    var digestUpdates: [MyDayDigestUpdate] = []
    var calendarState = MyDaySourceState.available(.calendar)
    var remindersState = MyDaySourceState.available(.reminders)
    var weatherState = MyDaySourceState.available(.weather)
    var travelState = MyDaySourceState.available(.travel)
    var digestState = MyDaySourceState.available(.digest)
    var requestedRanges: [(start: Date, end: Date)] = []
    private(set) var totalLoadCount = 0

    init(events: [MyDayCalendarEvent] = [], weather: MyDayWeather? = nil) {
        self.events = events
        self.weather = weather
    }

    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        totalLoadCount += 1
        requestedRanges.append((start, end))
        return .init(value: events, state: calendarState)
    }

    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> {
        totalLoadCount += 1
        return .init(value: reminders, state: remindersState)
    }

    func completeReminder(id: String) async throws -> String? {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return nil }
        return reminders.remove(at: index).title
    }

    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> {
        totalLoadCount += 1
        return .init(value: weather, state: weatherState)
    }

    func loadTravel(
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?> {
        totalLoadCount += 1
        return .init(value: travel, state: travelState)
    }

    func directionsURL(for eventID: String) -> URL? { nil }

    func loadDigest(now: Date) async -> MyDaySourceLoad<[MyDayDigestUpdate]> {
        totalLoadCount += 1
        return .init(value: digestUpdates, state: digestState)
    }

    func dismissDigestItem(id: String) {
        digestUpdates.removeAll { $0.id == id }
    }
}

private final class P4CalendarBox: @unchecked Sendable {
    var calendar: Calendar

    init(calendar: Calendar) {
        self.calendar = calendar
    }
}

private final class P4MonotonicClock: @unchecked Sendable {
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func next() -> TimeInterval {
        values.removeFirst()
    }
}
