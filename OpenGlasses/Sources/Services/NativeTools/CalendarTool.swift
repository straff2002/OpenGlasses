import Foundation

/// Provides calendar access: view today's events, upcoming meetings, and create new events.
final class CalendarTool: NativeTool, @unchecked Sendable {
    let name = "calendar"
    let description = "View today's calendar events, check upcoming meetings, or create new events. Can answer 'what's my next meeting?', 'what's on my schedule today?', or 'add a meeting at 3pm tomorrow'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'today' for today's events, 'next' for next upcoming event, 'upcoming' for next 7 days, 'create' to add a new event."
            ],
            "title": [
                "type": "string",
                "description": "Event title (required for 'create')"
            ],
            "date": [
                "type": "string",
                "description": "Date string for create, e.g. '2025-03-18' or 'tomorrow'. Defaults to today."
            ],
            "start_time": [
                "type": "string",
                "description": "Start time for create, e.g. '15:00' or '3pm'"
            ],
            "duration_minutes": [
                "type": "integer",
                "description": "Duration in minutes for create. Defaults to 60."
            ],
            "location": [
                "type": "string",
                "description": "Location for the event (optional, for create)"
            ]
        ],
        "required": ["action"]
    ]

    private let eventStore: EventKitDayStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    @MainActor
    convenience init() {
        self.init(eventStore: EventKitDayStore())
    }

    @MainActor
    init(eventStore: EventKitDayStore, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.eventStore = eventStore
        self.calendar = calendar
        self.now = now
    }

    func execute(args: [String: Any]) async throws -> String {
        // Request calendar access
        let granted: Bool
        granted = try await eventStore.requestCalendarAccess()

        guard granted else {
            return "Calendar access denied. Please enable calendar access in iPhone Settings > Privacy & Security > Calendars."
        }

        let action = (args["action"] as? String ?? "today").lowercased()

        switch action {
        case "today", "schedule":
            return getTodayEvents()
        case "next":
            return getNextEvent()
        case "upcoming", "week", "this_week":
            return getUpcomingEvents(days: 7)
        case "tomorrow":
            return getTomorrowEvents()
        case "create", "add":
            return createEvent(args: args)
        default:
            return "Unknown action '\(action)'. Use: today, next, upcoming, tomorrow, or create."
        }
    }

    private func getTodayEvents() -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let events = eventStore.calendarEvents(from: startOfDay, to: endOfDay)

        guard !events.isEmpty else {
            return "Your calendar is clear today. No events scheduled."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let descriptions = events.map { event -> String in
            var desc = "\(formatter.string(from: event.startDate)): \(event.title)"
            if event.isAllDay {
                desc = "All day: \(event.title)"
            }
            if let location = event.location, !location.isEmpty {
                desc += " at \(location)"
            }
            return desc
        }

        return "Today's schedule (\(events.count) event\(events.count == 1 ? "" : "s")): \(descriptions.joined(separator: ". "))."
    }

    private func getTomorrowEvents() -> String {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: tomorrow)!

        let events = eventStore.calendarEvents(from: tomorrow, to: endOfTomorrow)

        guard !events.isEmpty else {
            return "No events scheduled for tomorrow."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        let descriptions = events.map { event -> String in
            var desc = "\(formatter.string(from: event.startDate)): \(event.title)"
            if event.isAllDay {
                desc = "All day: \(event.title)"
            }
            if let location = event.location, !location.isEmpty {
                desc += " at \(location)"
            }
            return desc
        }

        return "Tomorrow's schedule (\(events.count) event\(events.count == 1 ? "" : "s")): \(descriptions.joined(separator: ". "))."
    }

    private func getNextEvent() -> String {
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        let events = eventStore.calendarEvents(from: now, to: endDate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        guard let next = events.first else {
            return "No upcoming events in the next 7 days."
        }

        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(next.startDate) {
            formatter.dateFormat = "h:mm a"
            let timeStr = formatter.string(from: next.startDate)
            let minsUntil = Int(next.startDate.timeIntervalSince(now) / 60)

            var desc = "Next up: \(next.title) at \(timeStr)"
            if minsUntil > 0 {
                if minsUntil < 60 {
                    desc += " (in \(minsUntil) minute\(minsUntil == 1 ? "" : "s"))"
                } else {
                    let hours = minsUntil / 60
                    let mins = minsUntil % 60
                    desc += " (in \(hours)h\(mins > 0 ? " \(mins)m" : ""))"
                }
            }
            if let location = next.location, !location.isEmpty {
                desc += " at \(location)"
            }
            return desc + "."
        } else {
            formatter.dateFormat = "EEEE 'at' h:mm a"
            var desc = "Next up: \(next.title) on \(formatter.string(from: next.startDate))"
            if let location = next.location, !location.isEmpty {
                desc += " at \(location)"
            }
            return desc + "."
        }
    }

    private func getUpcomingEvents(days: Int) -> String {
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!

        let events = eventStore.calendarEvents(from: start, to: end)

        guard !events.isEmpty else {
            return "No events in the next \(days) days."
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let descriptions = events.prefix(10).map { event -> String in
            let day = Calendar.current.isDateInToday(event.startDate) ? "Today" :
                      Calendar.current.isDateInTomorrow(event.startDate) ? "Tomorrow" :
                      dayFormatter.string(from: event.startDate)
            if event.isAllDay {
                return "\(day): \(event.title) (all day)"
            }
            return "\(day) \(timeFormatter.string(from: event.startDate)): \(event.title)"
        }

        var result = "Upcoming (\(events.count) event\(events.count == 1 ? "" : "s")): \(descriptions.joined(separator: ". "))."
        if events.count > 10 {
            result += " Plus \(events.count - 10) more."
        }
        return result
    }

    private func createEvent(args: [String: Any]) -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return "No event title provided."
        }

        let dateStr = (args["date"] as? String ?? "").lowercased()
        let day: Date?
        if dateStr == "tomorrow" {
            day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now()))
        } else {
            day = parseDate(dateStr)
        }
        let time = (args["start_time"] as? String).flatMap(parseTime)
        let startDate = Self.resolveStart(day: day, time: time, now: now(), calendar: calendar)

        let durationMinutes = (args["duration_minutes"] as? Int) ?? 60
        let endDate = calendar.date(byAdding: .minute, value: durationMinutes, to: startDate)
            ?? startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))

        do {
            try eventStore.saveCalendarEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: args["location"] as? String
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d 'at' h:mm a"
            var result = "Created: '\(title)' on \(formatter.string(from: startDate)) (\(durationMinutes) min)"
            if let location = args["location"] as? String {
                result += " at \(location)"
            }
            result += ". You'll get a reminder 15 minutes before."
            return result
        } catch {
            return "Couldn't create event: \(error.localizedDescription)"
        }
    }

    /// The new event's start: `day` (today when nil) at `time`.
    ///
    /// With no time it is the next full hour after `now`. Today that can be tomorrow's midnight:
    /// asked at 23:22, the next hour is 00:00, and setting hour 24 on today used to return nil and
    /// crash. On another day it is the same clock hour, capped at 23:00 so it stays on that day.
    nonisolated static func resolveStart(
        day: Date?,
        time: (hour: Int, minute: Int)?,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let day = day.map { calendar.startOfDay(for: $0) } ?? today

        if let time {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
                ?? calendar.date(byAdding: DateComponents(hour: time.hour, minute: time.minute), to: day)
                ?? day
        }

        let nextHour = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        if day == today {
            return nextHour
        }
        let hour = min(calendar.component(.hour, from: now) + 1, 23)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
            ?? calendar.date(byAdding: .hour, value: hour, to: day)
            ?? day
    }

    private func parseDate(_ str: String) -> Date? {
        Self.resolveDate(str, now: now(), calendar: calendar)
    }

    /// Resolves a typed or spoken date to the start of that day in `calendar`'s time zone.
    ///
    /// An explicit year ("2027-01-15", "01/15/2027") is kept as given. A month and day alone
    /// ("Jan 15", "January 15") resolve to their next occurrence on or after `now`'s day, so a
    /// January date asked for in December lands in the coming year rather than the one just
    /// ending. 29 February resolves to the next year that has one.
    nonisolated static func resolveDate(_ str: String, now: Date, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let locale = calendar.locale {
            formatter.locale = locale
        }

        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "MM-dd-yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: str) {
                return calendar.startOfDay(for: date)
            }
        }

        let today = calendar.startOfDay(for: now)
        for format in ["MMM d", "MMMM d"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: str) {
                let monthDay = calendar.dateComponents([.month, .day], from: date)
                // `nextDate(after:)` is exclusive, so step back a second to include today.
                guard let justBeforeToday = calendar.date(byAdding: .second, value: -1, to: today) else {
                    return nil
                }
                return calendar.nextDate(
                    after: justBeforeToday,
                    matching: monthDay,
                    matchingPolicy: .strict,
                    direction: .forward
                )
            }
        }
        return nil
    }

    private func parseTime(_ str: String) -> (hour: Int, minute: Int)? {
        let cleaned = str.lowercased().trimmingCharacters(in: .whitespaces)

        // Try "3pm", "3:30pm", "15:00"
        let formatter = DateFormatter()
        for format in ["h:mm a", "ha", "h a", "HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                let cal = Calendar.current
                return (cal.component(.hour, from: date), cal.component(.minute, from: date))
            }
        }
        return nil
    }
}
