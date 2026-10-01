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
                    isDecisionRelevant: WeatherPhraser.isDecisionRelevant(report, now: now())
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
