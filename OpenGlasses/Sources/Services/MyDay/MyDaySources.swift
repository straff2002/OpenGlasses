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
                    priority: $0.priority
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

    init(weatherTool: WeatherTool) {
        self.weatherTool = weatherTool
    }

    func loadWeather() async -> MyDaySourceLoad<MyDayWeather?> {
        do {
            let summary = try await weatherTool.execute(args: [:])
            guard !Self.looksUnavailable(summary) else {
                return .init(
                    value: nil,
                    state: .unavailable(.weather, message: "Weather is unavailable.")
                )
            }
            return .init(
                value: MyDayWeather(
                    summary: summary,
                    isDecisionRelevant: Self.isDecisionRelevant(summary)
                ),
                state: .available(.weather)
            )
        } catch {
            return .init(
                value: nil,
                state: .unavailable(.weather, message: "Weather is unavailable.")
            )
        }
    }

    static func isDecisionRelevant(_ summary: String) -> Bool {
        let text = summary.lowercased()
        let decisionWords = [
            "drizzle", "rain", "snow", "sleet", "hail", "thunderstorm", "storm",
            "freezing", "fog", "warning", "hazard", "high wind", "strong wind"
        ]
        return decisionWords.contains { text.contains($0) }
    }

    private static func looksUnavailable(_ summary: String) -> Bool {
        let text = summary.lowercased()
        return text.contains("can't get the weather")
            || text.contains("weather service is temporarily unavailable")
            || text.contains("failed to build weather")
            || text.contains("couldn't parse weather")
            || text.contains("couldn't read weather")
    }
}
