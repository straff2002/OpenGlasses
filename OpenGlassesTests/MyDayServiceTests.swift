import XCTest
@testable import OpenGlasses

@MainActor
final class MyDayServiceTests: XCTestCase {
    func testRefreshComposesAvailableSourcesAndPublishesLoadedState() async {
        let now = Date(timeIntervalSince1970: 1_788_065_600)
        let event = MyDayCalendarEvent(id: "event", title: "Stand-up", startDate: now.addingTimeInterval(900),
                                       endDate: now.addingTimeInterval(1800), isAllDay: false, location: nil)
        let reminder = MyDayReminder(id: "reminder", title: "Send notes", dueDate: now.addingTimeInterval(-60),
                                     hasTime: true, priority: 0)
        let sources = FakeDaySources(events: [event], reminders: [reminder],
                                     weather: .init(summary: "Rain.", isDecisionRelevant: true))
        let service = MyDayService(calendarSource: sources, remindersSource: sources, weatherSource: sources)

        let snapshot = await service.refresh(now: now)

        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["event", "reminder", "current"])
        XCTAssertEqual(service.state, .loaded(snapshot))
    }

    func testRefreshIsHonestWhenCalendarDenied() async {
        let sources = FakeDaySources()
        sources.calendarState = .denied(.calendar, message: "Calendar access is off.")
        let service = MyDayService(calendarSource: sources, remindersSource: sources, weatherSource: sources)

        let snapshot = await service.refresh()

        XCTAssertEqual(snapshot.sourceStates.first { $0.source == .calendar }?.availability, .denied)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testRefreshLoadsTravelFromCalendarEventsAndExposesDirections() async {
        let now = Date(timeIntervalSince1970: 1_788_065_600)
        let start = now.addingTimeInterval(3600)
        let event = MyDayCalendarEvent(
            id: "event-with-location",
            title: "Dentist",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            isAllDay: false,
            location: "Queen Street Dental"
        )
        let sources = FakeDaySources(events: [event])
        sources.travel = .init(
            eventID: event.id,
            eventTitle: event.title,
            destination: "Queen Street Dental",
            eventStart: start,
            travelDuration: 20 * 60,
            bufferDuration: 10 * 60,
            leaveAt: now.addingTimeInterval(1800),
            mode: .walking
        )
        let service = MyDayService(
            calendarSource: sources,
            remindersSource: sources,
            weatherSource: sources,
            travelSource: sources
        )

        let snapshot = await service.refresh(now: now)

        XCTAssertEqual(sources.travelEventIDs, [event.id])
        let leaveBy = snapshot.items.first { $0.kind == .leaveBy }
        XCTAssertEqual(leaveBy?.id.rawValue, "leave-by:event-with-location")
        XCTAssertEqual(service.directionsURL(for: leaveBy!.id)?.absoluteString,
                       "https://maps.apple.com/?daddr=Queen%20Street%20Dental")
    }

    func testStableReminderCompletionRefreshesSnapshot() async throws {
        let now = Date()
        let sources = FakeDaySources(reminders: [
            .init(id: "exact-id", title: "Call Ana", dueDate: now, hasTime: true, priority: 0)
        ])
        let service = MyDayService(calendarSource: sources, remindersSource: sources, weatherSource: sources)
        _ = await service.refresh(now: now)

        let title = try await service.completeReminder(id: "exact-id", now: now)

        XCTAssertEqual(title, "Call Ana")
        XCTAssertEqual(sources.completedIDs, ["exact-id"])
        guard case .loaded(let snapshot) = service.state else { return XCTFail("Expected loaded state") }
        XCTAssertFalse(snapshot.items.contains { $0.id.rawValue == "exact-id" })
    }

    func testReminderMatchPolicyRejectsAmbiguousSubstring() {
        let reminders = [
            EventKitReminderRecord(id: "1", title: "Call Alex", dueDate: nil, hasTime: false, priority: 0),
            EventKitReminderRecord(id: "2", title: "Call Ana", dueDate: nil, hasTime: false, priority: 0)
        ]
        XCTAssertEqual(
            ReminderMatchPolicy.resolve(search: "Call", reminders: reminders),
            .ambiguous(titles: ["Call Alex", "Call Ana"])
        )
        XCTAssertEqual(
            ReminderMatchPolicy.resolve(search: "Call Ana", reminders: reminders),
            .match(id: "2", title: "Call Ana")
        )
    }

    func testReminderDuePolicyRequiresAbsoluteFutureISO8601() {
        let now = Date(timeIntervalSince1970: 1_788_065_600)
        XCTAssertEqual(ReminderDuePolicy.validate(nil, now: now), .valid(nil))
        XCTAssertEqual(ReminderDuePolicy.validate("tomorrow at five", now: now), .invalidISO8601)
        XCTAssertEqual(ReminderDuePolicy.validate("2020-01-01T17:00:00Z", now: now), .past)

        guard case .valid(let date) = ReminderDuePolicy.validate("2030-01-01T17:00:00Z", now: now) else {
            return XCTFail("Expected a valid future ISO-8601 date")
        }
        XCTAssertNotNil(date)
    }
}

@MainActor
private final class FakeDaySources: CalendarDaySource, RemindersDaySource, WeatherDaySource,
                                    TravelTimeDaySource {
    var events: [MyDayCalendarEvent]
    var reminders: [MyDayReminder]
    var weather: MyDayWeather?
    var travel: MyDayTravelEstimate?
    var calendarState = MyDaySourceState.available(.calendar)
    var remindersState = MyDaySourceState.available(.reminders)
    var weatherState = MyDaySourceState.available(.weather)
    var completedIDs: [String] = []
    var travelEventIDs: [String] = []

    init(events: [MyDayCalendarEvent] = [], reminders: [MyDayReminder] = [], weather: MyDayWeather? = nil) {
        self.events = events
        self.reminders = reminders
        self.weather = weather
    }

    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        .init(value: events, state: calendarState)
    }

    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> {
        .init(value: reminders, state: remindersState)
    }

    func completeReminder(id: String) async throws -> String? {
        completedIDs.append(id)
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return nil }
        return reminders.remove(at: index).title
    }

    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> {
        .init(value: weather, state: weatherState)
    }

    func loadTravel(
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?> {
        travelEventIDs = events.map(\.id)
        return .init(value: travel, state: .available(.travel))
    }

    func directionsURL(for eventID: String) -> URL? {
        guard travel?.eventID == eventID else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: travel?.destination)]
        return components?.url
    }
}
