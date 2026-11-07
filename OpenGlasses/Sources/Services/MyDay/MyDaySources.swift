import Foundation

@MainActor
protocol CalendarDaySource: AnyObject {
    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]>
}

@MainActor
protocol RemindersDaySource: AnyObject {
    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]>
    func completeReminder(id: String) async throws -> String?
}

@MainActor
protocol WeatherDaySource: AnyObject {
    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?>
}

@MainActor
protocol TravelTimeDaySource: AnyObject {
    func loadTravel(
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?>
    func directionsURL(for eventID: String) -> URL?
}

@MainActor
protocol DigestDaySource: AnyObject {
    func loadDigest(now: Date) async -> MyDaySourceLoad<[MyDayDigestUpdate]>
    func dismissDigestItem(id: String)
}

/// The goals row's source (Plan IW P2).
@MainActor
protocol GoalsDaySource: AnyObject {
    func loadGoalSteps() async -> MyDaySourceLoad<[MyDayGoalStep]>
    /// Mark one step done, as the Goals screen's Done does. Returns the step's title, or nil when
    /// the goal or the step is gone (or the goals cannot be opened).
    func completeGoalStep(goalID: UUID, stepID: UUID, now: Date) -> String?
}

/// Reads the wearer's goals from `GoalStore`. Goals are the wearer's own list on this phone, so
/// there is no permission to ask for; the only way to be unavailable is a file that cannot be read.
@MainActor
final class GoalStoreDaySource: GoalsDaySource {
    private let store: @MainActor () -> GoalStore

    init(store: @escaping @MainActor () -> GoalStore = { GoalStore.shared }) {
        self.store = store
    }

    func loadGoalSteps() async -> MyDaySourceLoad<[MyDayGoalStep]> {
        let store = store()
        guard !store.isUnreadable else {
            return .init(value: [], state: .unavailable(.goals, message: "Goals could not be opened."))
        }
        return .init(value: Self.nextSteps(store.goals), state: .available(.goals))
    }

    func completeGoalStep(goalID: UUID, stepID: UUID, now: Date) -> String? {
        let store = store()
        guard let goal = store.goal(id: goalID),
              let index = goal.steps.firstIndex(where: { $0.id == stepID }) else { return nil }
        let title = goal.steps[index].title
        let updated = store.update(goalID) { changed in
            changed.steps[index].state = .done
            changed.steps[index].doneAt = now
        }
        return updated == nil ? nil : title
    }

    /// Each active goal's next step (`GoalAdvancePolicy.nextStep`) that has a date — its own, else
    /// the goal's. Pure.
    static func nextSteps(_ goals: [Goal]) -> [MyDayGoalStep] {
        goals.compactMap { goal in
            guard let step = GoalAdvancePolicy.nextStep(in: goal),
                  let due = step.dueAt ?? goal.dueAt else { return nil }
            return MyDayGoalStep(goalID: goal.id, stepID: step.id, goalTitle: goal.title,
                                 stepTitle: step.title, dueAt: due)
        }
    }
}

extension EventKitDayStore: CalendarDaySource {
    func loadEvents(from start: Date, to end: Date) async -> MyDaySourceLoad<[MyDayCalendarEvent]> {
        do {
            guard try await requestCalendarAccess() else {
                return .init(
                    value: [],
                    state: .denied(.calendar, message: "Calendar access is off.")
                )
            }
            let events = calendarEvents(from: start, to: end).map {
                MyDayCalendarEvent(
                    id: $0.id,
                    title: $0.title,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location
                )
            }
            return .init(value: events, state: .available(.calendar))
        } catch {
            return .init(
                value: [],
                state: .unavailable(.calendar, message: "Calendar could not be loaded.")
            )
        }
    }
}

extension EventKitDayStore: RemindersDaySource {
    func loadReminders() async -> MyDaySourceLoad<[MyDayReminder]> {
        do {
            guard try await requestRemindersAccess() else {
                return .init(
                    value: [],
                    state: .denied(.reminders, message: "Reminders access is off.")
                )
            }
            let reminders = await incompleteReminders().map {
                MyDayReminder(
                    id: $0.id,
                    title: $0.title,
                    dueDate: $0.dueDate,
                    hasTime: $0.hasTime,
                    priority: $0.priority,
                    listName: $0.listName
                )
            }
            return .init(value: reminders, state: .available(.reminders))
        } catch {
            return .init(
                value: [],
                state: .unavailable(.reminders, message: "Reminders could not be loaded.")
            )
        }
    }
}

@MainActor
final class NativeWeatherDaySource: WeatherDaySource {
    private let weatherTool: WeatherTool
    private let now: () -> Date

    init(weatherTool: WeatherTool, now: @escaping () -> Date = Date.init) {
        self.weatherTool = weatherTool
        self.now = now
    }

    /// Reads the report itself rather than matching words in the spoken sentence: decision
    /// relevance comes from the data (alerts, rain in the next hour, the condition), and a failure
    /// is a failure whatever its wording.
    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> {
        switch await weatherTool.lookUp(args: [:]) {
        case .answered(let summary, let report):
            return .init(
                value: MyDayWeather(
                    summary: summary,
                    isDecisionRelevant: WeatherPhraser.isDecisionRelevant(report, now: now()),
                    report: report
                ),
                state: .available(.weather)
            )
        case .refused:
            return .init(
                value: nil,
                state: .unavailable(.weather, message: "Weather is off while Medical Local Only is on.")
            )
        case .failed(let failure):
            return .init(
                value: nil,
                state: .unavailable(.weather, message: Self.unavailableMessage(failure))
            )
        }
    }

    static func unavailableMessage(_ failure: WeatherFetchFailure) -> String {
        switch failure {
        case .noLocation, .placeNotFound:
            return "Weather needs your location."
        case .offline:
            return "Weather needs a connection."
        case .serviceUnavailable:
            return "Apple Weather is unavailable right now."
        }
    }
}
