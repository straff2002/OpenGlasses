import Foundation

struct MyDayComposer: Sendable {
    let calendar: Calendar
    let locale: Locale
    let maxItems: Int

    init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent, maxItems: Int = 6) {
        self.calendar = calendar
        self.locale = locale
        self.maxItems = max(1, maxItems)
    }

    func compose(inputs: MyDayInputs, now: Date) -> MyDaySnapshot {
        let period = period(at: now)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow

        // An all-day event today is briefing information, not a commitment: "today is someone's
        // birthday" is worth a slot over breakfast and is noise by lunchtime, because there is
        // nothing to do about it and nothing that changes. It holds a slot in the morning only.
        // Tomorrow's all-day events are untouched — the evening preview below is forward-looking,
        // which is a different question.
        let todayEvents = inputs.events
            .filter { $0.endDate > now && $0.startDate < startOfTomorrow }
            .filter { period == .morning || !$0.isAllDay }
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
        let firstTomorrow = tomorrowEvents.first
        if period == .evening, let firstTomorrow {
            ranked.append(tomorrowItem(firstTomorrow))
            ranked.append(preparationItem(firstTomorrow))
        }

        for reminder in inputs.reminders {
            guard let item = reminderItem(
                reminder,
                now: now,
                startOfToday: startOfToday,
                startOfTomorrow: startOfTomorrow
            ) else { continue }
            ranked.append(item)
        }

        if let weather = inputs.weather {
            let includeRoutineWeather = period == .morning
            if weather.isDecisionRelevant || includeRoutineWeather {
                ranked.append(weatherItem(weather))
            }
        }

        for update in inputs.digestUpdates.prefix(MyDayDigestPolicy.limit) {
            ranked.append(digestItem(update))
        }

        // Cleared rows drop out *here* — after ranking, before the cap. Filtering the inputs would
        // have hidden the row from the headline's counts as well and left travel selection looking
        // at events the card no longer shows; filtering the finished snapshot would have left the
        // headline describing rows that are gone. Here, a cleared row also frees its slot for the
        // next-ranked one, which is what a wearer clearing clutter is asking for.
        let dismissed = inputs.dismissals
        let surviving = ranked
            .sorted(by: rankedOrder)
            .filter { !MyDayDismissalPolicy.isDismissed($0.item, in: dismissed) }
            .map(\.item)
        // The cap still decides what the card and the spoken briefing carry — but what it left
        // out travels with the snapshot now instead of vanishing. A row appearing the moment
        // another was cleared is the same list all along; it only looked like conjuring because
        // nothing on screen could say how long the list was.
        let items = Array(surviving.prefix(maxItems))
        let overflowItems = Array(surviving.dropFirst(maxItems))

        return MyDaySnapshot(
            generatedAt: now,
            period: period,
            headline: headline(
                // The headline counts what the card is willing to show: an all-day event is part
                // of the morning's count and no part of the afternoon's, which keeps the sentence
                // and the rows telling the same story.
                todayCommitments: inputs.events.filter {
                    $0.startDate >= startOfToday && $0.startDate < startOfTomorrow
                        && (period == .morning || !$0.isAllDay)
                }.count,
                overdueReminders: inputs.reminders.filter {
                    guard let due = $0.dueDate else { return false }
                    return $0.hasTime ? due < now : due < startOfToday
                }.count,
                period: period,
                firstTomorrow: firstTomorrow,
                travel: inputs.travel,
                items: items
            ),
            items: items,
            overflowItems: overflowItems,
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

    private func preparationItem(_ event: MyDayCalendarEvent) -> RankedItem {
        let timing = event.isAllDay
            ? "Tomorrow, all day"
            : "Tomorrow at \(formatTime(event.startDate))"
        return RankedItem(
            rank: 5,
            secondaryRank: 1,
            item: MyDayItem(
                id: .init(source: .calendar, rawValue: "prepare:\(event.id)"),
                kind: .preparation,
                title: "Prepare for \(event.title)",
                detail: timing + locationSuffix(event.location) + ". Check what you need before then.",
                dueAt: event.startDate,
                urgency: .upcoming,
                actions: [.open]
            )
        )
    }

    /// A reminder's row, or nil if it is not part of *today*.
    ///
    /// My Day carried every incomplete reminder, ranking the undated ones last. On a real list
    /// that is most of them: a "someday" pile with no date attached is not a day's work, and it
    /// crowded out the things that were. So the card takes exactly two kinds — overdue, and due
    /// today — and everything else stays in Reminders, which is the app for it. Future-dated items
    /// were already ranked last for the same reason and are now excluded outright, so tomorrow's
    /// task cannot displace today's.
    ///
    /// This is the same contract the morning-only all-day rule set: the card curates, the source
    /// app keeps everything.
    private func reminderItem(
        _ reminder: MyDayReminder,
        now: Date,
        startOfToday: Date,
        startOfTomorrow: Date
    ) -> RankedItem? {
        guard let dueDate = reminder.dueDate else { return nil }
        let isOverdue = reminder.hasTime ? dueDate < now : dueDate < startOfToday
        let isDueToday = dueDate >= startOfToday && dueDate < startOfTomorrow
        guard isOverdue || isDueToday else { return nil }

        let rank = isOverdue ? 2 : 3
        let urgency: MyDayUrgency = isOverdue ? .important : .upcoming

        let timing: String
        if isOverdue {
            timing = "Overdue"
        } else {
            timing = reminder.hasTime ? "Due \(formatTime(dueDate))" : "Due today"
        }
        // The list is the answer to "which part of my life is this?", which a bare title cannot
        // give when the day's reminders arrive from every list at once.
        let detail = [timing, reminder.listName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

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

    private func digestItem(_ update: MyDayDigestUpdate) -> RankedItem {
        RankedItem(
            rank: 8,
            item: MyDayItem(
                id: .init(source: .digest, rawValue: update.id),
                kind: .update,
                title: update.title,
                detail: update.detail,
                dueAt: update.createdAt,
                urgency: update.urgency,
                actions: [.dismiss]
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
        period: MyDayPeriod,
        firstTomorrow: MyDayCalendarEvent?,
        travel: MyDayTravelEstimate?,
        items: [MyDayItem]
    ) -> String {
        var parts: [String] = []
        if period == .evening, let firstTomorrow {
            if firstTomorrow.isAllDay {
                // No "all day" here: an event named "X's birthday" already is, and the absence
                // of a time says the rest. The card's detail row still carries the qualifier.
                parts.append("tomorrow includes \(firstTomorrow.title)")
            } else {
                parts.append("tomorrow starts with \(firstTomorrow.title) at \(formatTime(firstTomorrow.startDate))")
            }
        } else if todayCommitments > 0 {
            parts.append("\(todayCommitments) commitment\(todayCommitments == 1 ? "" : "s") today")
        }
        if overdueReminders > 0 {
            parts.append("\(overdueReminders) overdue reminder\(overdueReminders == 1 ? "" : "s")")
        }
        if let travel, items.contains(where: { $0.kind == .leaveBy }) {
            parts.append("leave by \(formatTime(travel.leaveAt)) for \(travel.eventTitle)")
        }
        if parts.isEmpty {
            if period == .evening {
                return items.isEmpty ? "Your evening is clear." : "Here is what matters before tomorrow."
            }
            return items.isEmpty ? "Your day is clear." : "Here is what matters today."
        }
        return Self.sentenceCased(parts.joined(separator: "; ")) + "."
    }

    /// Capitalize only the leading character — the parts are written mid-sentence ("tomorrow
    /// includes…") and event titles keep their own casing.
    static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
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

enum MyDaySpeechPolicy {
    /// A conservative deterministic ceiling for the normal iOS speech rate. Actual device timing
    /// remains a physical-device release check because installed voices and accessibility speech
    /// settings vary.
    static let maximumDuration: TimeInterval = 35
    static let wordsPerSecond = 2.4
    static let charactersPerSecond = 15.0
    static let maximumWords = Int(maximumDuration * wordsPerSecond)
    static let maximumCharacters = Int(maximumDuration * charactersPerSecond)

    static func estimatedDuration(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(
            Double(words) / wordsPerSecond,
            Double(text.count) / charactersPerSecond
        )
    }

    static func bounded(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var result = words.prefix(maximumWords).joined(separator: " ")
        if result.count > maximumCharacters - 1 {
            result = String(result.prefix(maximumCharacters - 1))
            if let lastSpace = result.lastIndex(of: " ") {
                result = String(result[..<lastSpace])
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count < text.trimmingCharacters(in: .whitespacesAndNewlines).count else {
            return result
        }
        return result.trimmingCharacters(in: .punctuationCharacters) + "…"
    }
}

struct MyDaySpokenFormatter: Sendable {
    func format(_ snapshot: MyDaySnapshot) -> String {
        var candidates = [snapshot.headline]

        let unavailable = snapshot.sourceStates.filter { $0.availability != .available }
        if !unavailable.isEmpty {
            let names = unavailable.map { $0.source.displayName }.joined(separator: " and ")
            candidates.append("\(names) \(unavailable.count == 1 ? "is" : "are") unavailable.")
        }

        candidates.append(contentsOf: snapshot.items.map { item in
            if let detail = item.detail, !detail.isEmpty {
                return "\(item.title): \(detail)."
            }
            return "\(item.title)."
        })

        var result = ""
        for candidate in candidates {
            let proposed = result.isEmpty ? candidate : result + " " + candidate
            if MyDaySpeechPolicy.estimatedDuration(for: proposed) <= MyDaySpeechPolicy.maximumDuration {
                result = proposed
            } else if result.isEmpty {
                result = MyDaySpeechPolicy.bounded(candidate)
            } else {
                break
            }
        }
        return MyDaySpeechPolicy.bounded(result)
    }
}
