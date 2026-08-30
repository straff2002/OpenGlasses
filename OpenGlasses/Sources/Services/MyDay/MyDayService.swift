import Foundation

enum MyDayLoadState: Equatable {
    case idle
    case loading(previous: MyDaySnapshot?)
    case loaded(MyDaySnapshot)
}

@MainActor
final class MyDayService: ObservableObject {
    @Published private(set) var state: MyDayLoadState = .idle

    private let calendarSource: any CalendarDaySource
    private let remindersSource: any RemindersDaySource
    private let weatherSource: any WeatherDaySource
    private let travelSource: (any TravelTimeDaySource)?
    private let composer: MyDayComposer
    private let spokenFormatter: MyDaySpokenFormatter
    private let calendar: Calendar

    init(
        calendarSource: any CalendarDaySource,
        remindersSource: any RemindersDaySource,
        weatherSource: any WeatherDaySource,
        travelSource: (any TravelTimeDaySource)? = nil,
        composer: MyDayComposer = MyDayComposer(),
        spokenFormatter: MyDaySpokenFormatter = MyDaySpokenFormatter(),
        calendar: Calendar = .current
    ) {
        self.calendarSource = calendarSource
        self.remindersSource = remindersSource
        self.weatherSource = weatherSource
        self.travelSource = travelSource
        self.composer = composer
        self.spokenFormatter = spokenFormatter
        self.calendar = calendar
    }

    @discardableResult
    func refresh(now: Date = Date()) async -> MyDaySnapshot {
        let previous: MyDaySnapshot?
        if case .loaded(let snapshot) = state { previous = snapshot } else { previous = nil }
        state = .loading(previous: previous)

        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? now
        // Calendar and Reminders can each show a first-use system permission sheet. Load them in
        // sequence so iOS never has to arbitrate two permission prompts at once; weather can run
        // alongside both because it has no prompt of its own.
        async let weatherLoad = weatherSource.loadWeather()
        let events = await calendarSource.loadEvents(from: start, to: end)
        async let travelLoad = loadTravel(for: events.value, now: now)
        let reminders = await remindersSource.loadReminders()
        let weather = await weatherLoad
        let travel = await travelLoad
        var sourceStates = [events.state, reminders.state, weather.state]
        if let travel { sourceStates.append(travel.state) }
        let snapshot = composer.compose(
            inputs: MyDayInputs(
                events: events.value,
                reminders: reminders.value,
                weather: weather.value,
                travel: travel?.value,
                sourceStates: sourceStates
            ),
            now: now
        )
        state = .loaded(snapshot)
        return snapshot
    }

    func spokenBriefing(now: Date = Date()) async -> String {
        spokenFormatter.format(await refresh(now: now))
    }

    func directionsURL(for itemID: MyDayItemID) -> URL? {
        guard itemID.source == .travel,
              itemID.rawValue.hasPrefix("leave-by:") else { return nil }
        let eventID = String(itemID.rawValue.dropFirst("leave-by:".count))
        return travelSource?.directionsURL(for: eventID)
    }

    @discardableResult
    func completeReminder(id: String, now: Date = Date()) async throws -> String? {
        let title = try await remindersSource.completeReminder(id: id)
        _ = await refresh(now: now)
        return title
    }

    private func loadTravel(
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?>? {
        guard let travelSource else { return nil }
        return await travelSource.loadTravel(for: events, now: now)
    }
}
