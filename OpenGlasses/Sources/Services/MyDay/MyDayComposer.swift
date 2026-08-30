import Foundation

struct MyDayComposer: Sendable {
    let calendar: Calendar
    let locale: Locale
    let maxItems: Int

    init(calendar: Calendar = .current, locale: Locale = .current, maxItems: Int = 6) {
        self.calendar = calendar
        self.locale = locale
        self.maxItems = max(1, maxItems)
    }

    func compose(inputs: MyDayInputs, now: Date) -> MyDaySnapshot {
        let period = period(at: now)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow

        let todayEvents = inputs.events
            .filter { $0.endDate > now && $0.startDate < startOfTomorrow }
            .sorted(by: eventOrder)
        let tomorrowEvents = inputs.events
            .filter { $0.startDate >= startOfTomorrow && $0.startDate < endOfTomorrow }
            .sorted(by: eventOrder)

        var ranked: [RankedItem] = []
        for event in todayEvents {
            ranked.append(eventItem(event, now: now))
        }
        if let travel = inputs.travel,
           travel.eventStart > now,
           travel.eventStart < endOfTomorrow {
            ranked.append(leaveByItem(travel, now: now))
        }
        if period == .evening, let firstTomorrow = tomorrowEvents.first {
            ranked.append(tomorrowItem(firstTomorrow))
        }

        for reminder in inputs.reminders {
            ranked.append(reminderItem(
                reminder,
                now: now,
                startOfToday: startOfToday,
                startOfTomorrow: startOfTomorrow
            ))
        }

        if let weather = inputs.weather {
            let includeRoutineWeather = period == .morning
            if weather.isDecisionRelevant || includeRoutineWeather {
                ranked.append(weatherItem(weather))
            }
        }

        let items = ranked
            .sorted(by: rankedOrder)
            .prefix(maxItems)
            .map(\.item)

        return MyDaySnapshot(
            generatedAt: now,
            period: period,
            headline: headline(
                todayCommitments: inputs.events.filter {
                    $0.startDate >= startOfToday && $0.startDate < startOfTomorrow
                }.count,
                overdueReminders: inputs.reminders.filter {
                    guard let due = $0.dueDate else { return false }
                    return $0.hasTime ? due < now : due < startOfToday
                }.count,
                travel: inputs.travel,
                items: items
            ),
            items: items,
            sourceStates: inputs.sourceStates.sorted { $0.source.rawValue < $1.source.rawValue },
            nextRefreshAt: calendar.date(byAdding: .minute, value: 15, to: now)
        )
    }

    private func period(at date: Date) -> MyDayPeriod {
        let hour = calendar.component(.hour, from: date)
        if hour < 12 { return .morning }
        if hour < 18 { return .daytime }
        return .evening
    }

    private func eventOrder(_ lhs: MyDayCalendarEvent, _ rhs: MyDayCalendarEvent) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return lhs.id < rhs.id
    }

    private func eventItem(_ event: MyDayCalendarEvent, now: Date) -> RankedItem {
        let startsIn = event.startDate.timeIntervalSince(now)
        let isInProgress = !event.isAllDay && event.startDate <= now && event.endDate > now
        let urgency: MyDayUrgency
        let rank: Int
        if event.isAllDay {
            urgency = .upcoming
            rank = 4
        } else if isInProgress || startsIn <= 30 * 60 {
            urgency = .immediate
            rank = 0
        } else if startsIn <= 2 * 60 * 60 {
            urgency = .important
            rank = 2
        } else {
            urgency = .upcoming
            rank = 4
        }

        let detail: String
        if event.isAllDay {
            detail = "All day" + locationSuffix(event.location)
        } else if isInProgress {
            detail = "In progress until \(formatTime(event.endDate))" + locationSuffix(event.location)
        } else {
            detail = formatTime(event.startDate) + locationSuffix(event.location)
        }

        return RankedItem(
            rank: rank,
            item: MyDayItem(
                id: .init(source: .calendar, rawValue: event.id),
                kind: .event,
                title: event.title,
                detail: detail,
                dueAt: event.startDate,
                urgency: urgency,
                actions: [.open]
            )
        )
    }

    private func tomorrowItem(_ event: MyDayCalendarEvent) -> RankedItem {
        RankedItem(
            rank: 5,
            item: MyDayItem(
                id: .init(source: .calendar, rawValue: event.id),
                kind: .event,
                title: event.title,
                detail: "Tomorrow, \(event.isAllDay ? "all day" : formatTime(event.startDate))" + locationSuffix(event.location),
                dueAt: event.startDate,
                urgency: .upcoming,
                actions: [.open]
            )
        )
    }

    private func reminderItem(
        _ reminder: MyDayReminder,
        now: Date,
        startOfToday: Date,
        startOfTomorrow: Date
    ) -> RankedItem {
        let isOverdue = reminder.dueDate.map { due in
            reminder.hasTime ? due < now : due < startOfToday
        } ?? false
        let isDueToday = reminder.dueDate.map { $0 >= startOfToday && $0 < startOfTomorrow } ?? false
        let rank = isOverdue ? 2 : (isDueToday ? 3 : 6)
        let urgency: MyDayUrgency = isOverdue ? .important : (isDueToday ? .upcoming : .routine)

        let detail: String?
        if isOverdue {
            detail = "Overdue"
        } else if let due = reminder.dueDate, isDueToday {
            detail = reminder.hasTime ? "Due \(formatTime(due))" : "Due today"
        } else {
            detail = nil
        }

        return RankedItem(
            rank: rank,
            secondaryRank: -reminder.priority,
            item: MyDayItem(
                id: .init(source: .reminders, rawValue: reminder.id),
                kind: .reminder,
                title: reminder.title,
                detail: detail,
                dueAt: reminder.dueDate,
                urgency: urgency,
                actions: [.complete, .open]
            )
        )
    }

    private func leaveByItem(_ estimate: MyDayTravelEstimate, now: Date) -> RankedItem {
        let secondsUntilLeave = estimate.leaveAt.timeIntervalSince(now)
        let urgency: MyDayUrgency
        if secondsUntilLeave <= 0 {
            urgency = .immediate
        } else if secondsUntilLeave <= 30 * 60 {
            urgency = .important
        } else {
            urgency = .upcoming
        }

        let title = secondsUntilLeave <= 0
            ? "Leave now for \(estimate.eventTitle)"
            : "Leave by \(formatTime(estimate.leaveAt)) for \(estimate.eventTitle)"
        let routeMinutes = max(1, Int((estimate.travelDuration / 60).rounded()))
        let bufferMinutes = max(0, Int((estimate.bufferDuration / 60).rounded()))
        var detail = "\(routeMinutes) min \(estimate.mode.displayName.lowercased()) to \(estimate.destination)"
        if bufferMinutes > 0 {
            detail += " + \(bufferMinutes) min buffer"
        }

        return RankedItem(
            rank: 1,
            item: MyDayItem(
                id: .init(source: .travel, rawValue: "leave-by:\(estimate.eventID)"),
                kind: .leaveBy,
                title: title,
                detail: detail,
                dueAt: estimate.leaveAt,
                urgency: urgency,
                actions: [.directions]
            )
        )
    }

    private func weatherItem(_ weather: MyDayWeather) -> RankedItem {
        RankedItem(
            rank: weather.isDecisionRelevant ? 3 : 7,
            item: MyDayItem(
                id: .init(source: .weather, rawValue: "current"),
                kind: .weather,
                title: "Weather",
                detail: weather.summary,
                dueAt: nil,
                urgency: weather.isDecisionRelevant ? .important : .routine,
                actions: []
            )
        )
    }

    private func rankedOrder(_ lhs: RankedItem, _ rhs: RankedItem) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.item.dueAt != rhs.item.dueAt {
            return (lhs.item.dueAt ?? .distantFuture) < (rhs.item.dueAt ?? .distantFuture)
        }
        if lhs.secondaryRank != rhs.secondaryRank { return lhs.secondaryRank < rhs.secondaryRank }
        return lhs.item.id < rhs.item.id
    }

    private func headline(
        todayCommitments: Int,
        overdueReminders: Int,
        travel: MyDayTravelEstimate?,
        items: [MyDayItem]
    ) -> String {
        var parts: [String] = []
        if todayCommitments > 0 {
            parts.append("\(todayCommitments) commitment\(todayCommitments == 1 ? "" : "s") today")
        }
        if overdueReminders > 0 {
            parts.append("\(overdueReminders) overdue reminder\(overdueReminders == 1 ? "" : "s")")
        }
        if let travel, items.contains(where: { $0.kind == .leaveBy }) {
            parts.append("leave by \(formatTime(travel.leaveAt)) for \(travel.eventTitle)")
        }
        if parts.isEmpty {
            return items.isEmpty ? "Your day is clear." : "Here is what matters today."
        }
        return parts.joined(separator: "; ") + "."
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func locationSuffix(_ location: String?) -> String {
        guard let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return " at \(location)"
    }

    private struct RankedItem {
        let rank: Int
        var secondaryRank: Int = 0
        let item: MyDayItem
    }
}

struct MyDaySpokenFormatter: Sendable {
    func format(_ snapshot: MyDaySnapshot) -> String {
        var sentences = [snapshot.headline]
        sentences.append(contentsOf: snapshot.items.map { item in
            if let detail = item.detail, !detail.isEmpty {
                return "\(item.title): \(detail)."
            }
            return "\(item.title)."
        })

        let unavailable = snapshot.sourceStates.filter { $0.availability != .available }
        if !unavailable.isEmpty {
            let names = unavailable.map { $0.source.displayName }.joined(separator: " and ")
            sentences.append("\(names) \(unavailable.count == 1 ? "is" : "are") unavailable.")
        }
        return sentences.joined(separator: " ")
    }
}
