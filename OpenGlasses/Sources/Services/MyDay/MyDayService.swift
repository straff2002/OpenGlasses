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
    private var digestSource: (any DigestDaySource)?
    private let sourceSelection: () -> MyDaySourceSelection
    private let composer: MyDayComposer
    private let spokenFormatter: MyDaySpokenFormatter
    private let calendar: Calendar

    init(
        calendarSource: any CalendarDaySource,
        remindersSource: any RemindersDaySource,
        weatherSource: any WeatherDaySource,
        travelSource: (any TravelTimeDaySource)? = nil,
        digestSource: (any DigestDaySource)? = nil,
        sourceSelection: @escaping () -> MyDaySourceSelection = { .current },
        composer: MyDayComposer = MyDayComposer(),
        spokenFormatter: MyDaySpokenFormatter = MyDaySpokenFormatter(),
        calendar: Calendar = .current
    ) {
        self.calendarSource = calendarSource
        self.remindersSource = remindersSource
        self.weatherSource = weatherSource
        self.travelSource = travelSource
        self.digestSource = digestSource
        self.sourceSelection = sourceSelection
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
        // Calendar and Reminders can each show a first-use system permission sheet. Keep those in
        // sequence; weather and the first-party digest have no permission prompt and can run beside
        // them. Travel starts after Calendar because it consumes that authoritative event set.
        let selection = sourceSelection()
        async let weatherLoad = loadWeather(enabled: selection.weather)
        async let digestLoad = loadDigest(enabled: selection.digest, now: now)
        let events = await loadEvents(enabled: selection.calendar, from: start, to: end)
        async let travelLoad = loadTravel(
            enabled: selection.travel,
            for: events?.value ?? [],
            now: now
        )
        let reminders = await loadReminders(enabled: selection.reminders)
        let weather = await weatherLoad
        let travel = await travelLoad
        let digest = await digestLoad
        let sourceStates = [events?.state, reminders?.state, weather?.state, travel?.state, digest?.state]
            .compactMap { $0 }
        let snapshot = composer.compose(
            inputs: MyDayInputs(
                events: events?.value ?? [],
                reminders: reminders?.value ?? [],
                weather: weather?.value,
                travel: travel?.value,
                digestUpdates: digest?.value ?? [],
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

    func setDigestSource(_ source: any DigestDaySource) {
        digestSource = source
    }

    @discardableResult
    func dismissDigestItem(id: String, now: Date = Date()) async -> MyDaySnapshot {
        digestSource?.dismissDigestItem(id: id)
        return await refresh(now: now)
    }

    @discardableResult
    func completeReminder(id: String, now: Date = Date()) async throws -> String? {
        let title = try await remindersSource.completeReminder(id: id)
        _ = await refresh(now: now)
        return title
    }

    private func loadEvents(
        enabled: Bool,
        from start: Date,
        to end: Date
    ) async -> MyDaySourceLoad<[MyDayCalendarEvent]>? {
        guard enabled else { return nil }
        return await calendarSource.loadEvents(from: start, to: end)
    }

    private func loadReminders(enabled: Bool) async -> MyDaySourceLoad<[MyDayReminder]>? {
        guard enabled else { return nil }
        return await remindersSource.loadReminders()
    }

    private func loadWeather(enabled: Bool) async -> MyDaySourceLoad<MyDayWeather?>? {
        guard enabled else { return nil }
        return await weatherSource.loadWeather()
    }

    private func loadTravel(
        enabled: Bool,
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?>? {
        guard enabled, let travelSource else { return nil }
        return await travelSource.loadTravel(for: events, now: now)
    }

    private func loadDigest(
        enabled: Bool,
        now: Date
    ) async -> MyDaySourceLoad<[MyDayDigestUpdate]>? {
        guard enabled, let digestSource else { return nil }
        return await digestSource.loadDigest(now: now)
    }
}
