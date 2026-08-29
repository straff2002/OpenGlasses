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
    private let composer: MyDayComposer
    private let spokenFormatter: MyDaySpokenFormatter
    private let calendar: Calendar

    init(
        calendarSource: any CalendarDaySource,
        remindersSource: any RemindersDaySource,
        weatherSource: any WeatherDaySource,
        composer: MyDayComposer = MyDayComposer(),
        spokenFormatter: MyDaySpokenFormatter = MyDaySpokenFormatter(),
        calendar: Calendar = .current
    ) {
        self.calendarSource = calendarSource
        self.remindersSource = remindersSource
        self.weatherSource = weatherSource
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
        let reminders = await remindersSource.loadReminders()
        let weather = await weatherLoad
        let snapshot = composer.compose(
            inputs: MyDayInputs(
                events: events.value,
                reminders: reminders.value,
                weather: weather.value,
                sourceStates: [events.state, reminders.state, weather.state]
            ),
            now: now
        )
        state = .loaded(snapshot)
        return snapshot
    }

    func spokenBriefing(now: Date = Date()) async -> String {
        spokenFormatter.format(await refresh(now: now))
    }

    @discardableResult
    func completeReminder(id: String, now: Date = Date()) async throws -> String? {
        let title = try await remindersSource.completeReminder(id: id)
        _ = await refresh(now: now)
        return title
    }
}
