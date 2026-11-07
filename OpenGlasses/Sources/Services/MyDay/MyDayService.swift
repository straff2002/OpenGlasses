import Foundation

enum MyDayLoadState: Equatable {
    case idle
    case loading(previous: MyDaySnapshot?)
    case loaded(MyDaySnapshot)
}

@MainActor
final class MyDayService: ObservableObject {
    @Published private(set) var state: MyDayLoadState = .idle
    /// The last refresh's inputs as gathered, before composing (Plan KS: the watch's Today
    /// screens). Set before `state`, on every refresh.
    @Published private(set) var gathered: MyDayGathered?

    private let calendarSource: any CalendarDaySource
    private let remindersSource: any RemindersDaySource
    private let weatherSource: any WeatherDaySource
    private let travelSource: (any TravelTimeDaySource)?
    private var digestSource: (any DigestDaySource)?
    /// Plan IW P2: the goals row. Wired by AppState, like the digest.
    private var goalsSource: (any GoalsDaySource)?
    private let sourceSelection: () -> MyDaySourceSelection
    private let composer: MyDayComposer
    private let spokenFormatter: MyDaySpokenFormatter
    private let calendarProvider: () -> Calendar
    private let metrics: any MyDayMetricsRecording
    private let monotonicNow: () -> TimeInterval
    /// Rows the wearer cleared from today's card. Read on every compose so a dismissal survives
    /// the frequent refreshes, and day-scoped so it lapses on its own.
    private let dismissals: MyDayDismissalStore

    /// EventKit and the content-bearing snapshot are not touched while iOS protected data is
    /// unavailable. AppState replaces this default with UIApplication's live lock-state signal.
    var protectedDataAvailable: () -> Bool = { true }

    init(
        calendarSource: any CalendarDaySource,
        remindersSource: any RemindersDaySource,
        weatherSource: any WeatherDaySource,
        travelSource: (any TravelTimeDaySource)? = nil,
        digestSource: (any DigestDaySource)? = nil,
        goalsSource: (any GoalsDaySource)? = nil,
        sourceSelection: @escaping () -> MyDaySourceSelection = { .current },
        composer: MyDayComposer = MyDayComposer(),
        spokenFormatter: MyDaySpokenFormatter = MyDaySpokenFormatter(),
        calendarProvider: @escaping () -> Calendar = { .autoupdatingCurrent },
        metrics: any MyDayMetricsRecording = MyDayMetricsStore.shared,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dismissals: MyDayDismissalStore = MyDayDismissalStore()
    ) {
        self.dismissals = dismissals
        self.calendarSource = calendarSource
        self.remindersSource = remindersSource
        self.weatherSource = weatherSource
        self.travelSource = travelSource
        self.digestSource = digestSource
        self.goalsSource = goalsSource
        self.sourceSelection = sourceSelection
        self.composer = composer
        self.spokenFormatter = spokenFormatter
        self.calendarProvider = calendarProvider
        self.metrics = metrics
        self.monotonicNow = monotonicNow
    }

    @discardableResult
    func refresh(
        now: Date = Date(),
        channel: MyDayBriefingChannel? = .phone
    ) async -> MyDaySnapshot {
        let refreshStartedAt = monotonicNow()
        if let channel {
            metrics.record(.briefingRequested(channel), at: now)
        }
        let previous: MyDaySnapshot?
        if case .loaded(let snapshot) = state { previous = snapshot } else { previous = nil }
        state = .loading(previous: previous)

        let calendar = calendarProvider()
        let refreshComposer = MyDayComposer(
            calendar: calendar,
            locale: composer.locale,
            maxItems: composer.maxItems
        )
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? now
        // Calendar and Reminders can each show a first-use system permission sheet. Keep those in
        // sequence; weather and the first-party digest have no permission prompt and can run beside
        // them. Travel starts after Calendar because it consumes that authoritative event set.
        let selection = sourceSelection()
        guard protectedDataAvailable() else {
            let snapshot = refreshComposer.compose(
                inputs: .init(
                    events: [],
                    reminders: [],
                    weather: nil,
                    sourceStates: lockedSourceStates(for: selection)
                ),
                now: now
            )
            gathered = MyDayGathered(generatedAt: now, locked: true,
                                     calendarIncluded: selection.calendar, events: [],
                                     calendarState: nil, weatherIncluded: selection.weather,
                                     weather: nil, weatherState: nil)
            state = .loaded(snapshot)
            recordLatency(since: refreshStartedAt, at: now)
            return snapshot
        }
        async let weatherLoad = loadWeather(enabled: selection.weather)
        async let digestLoad = loadDigest(enabled: selection.digest, now: now)
        async let goalsLoad = loadGoals(enabled: selection.goals)
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
        let goals = await goalsLoad
        let sourceStates = [events?.state, reminders?.state, weather?.state, travel?.state, digest?.state,
                            goals?.state]
            .compactMap { $0 }
        let snapshot = refreshComposer.compose(
            inputs: MyDayInputs(
                events: events?.value ?? [],
                reminders: reminders?.value ?? [],
                weather: weather?.value,
                travel: travel?.value,
                digestUpdates: digest?.value ?? [],
                goalSteps: goals?.value ?? [],
                sourceStates: sourceStates,
                dismissals: dismissals.active(on: now)
            ),
            now: now
        )
        gathered = MyDayGathered(generatedAt: now, locked: false,
                                 calendarIncluded: selection.calendar, events: events?.value ?? [],
                                 calendarState: events?.state, weatherIncluded: selection.weather,
                                 weather: weather?.value ?? nil, weatherState: weather?.state)
        state = .loaded(snapshot)
        recordLatency(since: refreshStartedAt, at: now)
        return snapshot
    }

    func spokenBriefing(
        now: Date = Date(),
        channel: MyDayBriefingChannel = .voice
    ) async -> String {
        let text = spokenFormatter.format(await refresh(now: now, channel: channel))
        metrics.record(
            .spokenDuration(.init(seconds: MyDaySpeechPolicy.estimatedDuration(for: text))),
            at: now
        )
        return text
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

    func setGoalsSource(_ source: any GoalsDaySource) {
        goalsSource = source
    }

    /// Clear one row from today's card — the one entry point, whichever source the row came from.
    ///
    /// A digest update owns its own record and is retired inside the digest, which is the shipped
    /// behaviour and the reason `.dismiss` existed at all. Everything else — an event, a reminder,
    /// a leave-by, the weather — belongs to a source this app does not own and must not edit, so
    /// the dismissal is recorded against the *card* instead. Neither branch deletes or completes
    /// anything the wearer would miss.
    @discardableResult
    func dismiss(_ item: MyDayItem, now: Date = Date()) async -> MyDaySnapshot {
        metrics.record(.dismissal, at: now)
        if item.id.source == .digest {
            digestSource?.dismissDigestItem(id: item.id.rawValue)
        } else {
            dismissals.dismiss(item, on: now)
        }
        return await refresh(now: now, channel: nil)
    }

    @discardableResult
    func dismissDigestItem(id: String, now: Date = Date()) async -> MyDaySnapshot {
        metrics.record(.dismissal, at: now)
        digestSource?.dismissDigestItem(id: id)
        return await refresh(now: now, channel: nil)
    }

    @discardableResult
    func completeReminder(id: String, now: Date = Date()) async throws -> String? {
        metrics.record(.action(.completeReminder), at: now)
        let title = try await remindersSource.completeReminder(id: id)
        _ = await refresh(now: now, channel: nil)
        return title
    }

    /// Complete a row's item: a reminder in Reminders, a goal step in the wearer's goals (Plan IW
    /// P2). Returns the title of what was completed, or nil when it is no longer there.
    @discardableResult
    func complete(_ item: MyDayItem, now: Date = Date()) async throws -> String? {
        switch item.id.source {
        case .goals:
            return await completeGoalStep(id: item.id.rawValue, now: now)
        default:
            return try await completeReminder(id: item.id.rawValue, now: now)
        }
    }

    /// Mark the goal step a goals row names done. `id` is `<goal uuid>|<step uuid>`.
    @discardableResult
    func completeGoalStep(id: String, now: Date = Date()) async -> String? {
        let parts = id.split(separator: Character(MyDayComposer.goalItemSeparator)).map(String.init)
        guard parts.count == 2, let goalID = UUID(uuidString: parts[0]),
              let stepID = UUID(uuidString: parts[1]) else { return nil }
        metrics.record(.action(.completeGoalStep), at: now)
        let title = goalsSource?.completeGoalStep(goalID: goalID, stepID: stepID, now: now)
        _ = await refresh(now: now, channel: nil)
        return title
    }

    /// The goal a goals row belongs to, for its "open" action.
    static func goalID(of item: MyDayItem) -> UUID? {
        guard item.id.source == .goals,
              let first = item.id.rawValue.split(separator: Character(MyDayComposer.goalItemSeparator)).first
        else { return nil }
        return UUID(uuidString: String(first))
    }

    func recordAction(_ action: MyDayActionMetric, at date: Date = Date()) {
        metrics.record(.action(action), at: date)
    }

#if DEBUG
    /// UI-test seeding only — see `UITestSupport`, and the note at the top of that file about what
    /// seeding is and is not. It sets the state a real refresh would have produced, so the card can
    /// be audited with rows in it without a calendar, a permission grant, or a device. Nothing
    /// branches on it; a seeded snapshot is an ordinary one.
    func seedForUITest(_ snapshot: MyDaySnapshot) {
        state = .loaded(snapshot)
    }
#endif

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

    private func loadGoals(enabled: Bool) async -> MyDaySourceLoad<[MyDayGoalStep]>? {
        guard enabled, let goalsSource else { return nil }
        return await goalsSource.loadGoalSteps()
    }

    private func loadDigest(
        enabled: Bool,
        now: Date
    ) async -> MyDaySourceLoad<[MyDayDigestUpdate]>? {
        guard enabled, let digestSource else { return nil }
        return await digestSource.loadDigest(now: now)
    }

    private func lockedSourceStates(for selection: MyDaySourceSelection) -> [MyDaySourceState] {
        let message = "Unlock iPhone to refresh My Day."
        return [
            selection.calendar ? .unavailable(.calendar, message: message) : nil,
            selection.reminders ? .unavailable(.reminders, message: message) : nil,
            selection.weather ? .unavailable(.weather, message: message) : nil,
            selection.travel ? .unavailable(.travel, message: message) : nil,
            selection.digest ? .unavailable(.digest, message: message) : nil,
        ].compactMap { $0 }
    }

    private func recordLatency(since start: TimeInterval, at date: Date) {
        metrics.record(
            .snapshotLatency(.init(seconds: max(0, monotonicNow() - start))),
            at: date
        )
    }
}
