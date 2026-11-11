import Foundation
import WeatherKit

/// Plan KS — builds the watch's `today` value from what My Day gathered. Pure: the clock, the
/// calendar, the Medical Compliance mode, the units and the weather credit are all inputs.
enum WatchTodayBuilder {

    struct Inputs {
        var now: Date
        var calendar: Calendar
        var medical: MedicalEgressGuard.Mode
        var temperatureUnit: WatchTodayTemperatureUnit
        var attribution: WatchTodayAttribution
        /// Localised short text for a condition. WeatherKit's own description by default.
        var conditionText: (WeatherCondition) -> String = { $0.description }
        /// Plan KT §6.7: the feed's prepared cards, ranked (`MyDayService.todayFeed.cards`).
        var cards: [PreparedCard] = []
    }

    static let titleLimit = 60
    static let locationLimit = 40

    static func payload(from gathered: MyDayGathered, _ inputs: Inputs) -> WatchTodayPayload {
        let calendar = inputs.calendar
        let dayStart = calendar.startOfDay(for: gathered.generatedAt)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        // Any Medical Compliance mode, Local Only or not: the wrist gets times and counts, never
        // what an appointment is or where.
        let redacted = inputs.medical.hipaaMode

        let calendarStatus = Self.calendarStatus(gathered)
        var events: [WatchTodayEvent] = []
        var more = 0
        if calendarStatus == .shown {
            let upcoming = gathered.events
                .filter { $0.startDate < dayEnd && $0.endDate > dayStart }
                .filter { $0.isAllDay || $0.endDate > inputs.now }
                .sorted { lhs, rhs in
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                    return lhs.id < rhs.id
                }
            events = upcoming.prefix(WatchTodayPayload.maxEvents).map { event in
                WatchTodayEvent(id: event.id, start: event.startDate, end: event.endDate,
                                isAllDay: event.isAllDay,
                                title: redacted ? nil : shortened(event.title, limit: titleLimit),
                                location: redacted ? nil : event.location.flatMap {
                                    shortened(firstLine($0), limit: locationLimit)
                                })
            }
            more = max(0, upcoming.count - events.count)
        }

        var weatherStatus = Self.weatherStatus(gathered, medical: inputs.medical)
        var weather: WatchTodayWeather?
        if weatherStatus == .shown {
            if let report = gathered.weather?.report {
                weather = Self.weather(from: report, inputs)
            } else {
                weatherStatus = .unavailable
            }
        }

        return WatchTodayPayload(day: WatchTodayDay(gathered.generatedAt, calendar: calendar),
                                 generatedAt: gathered.generatedAt, calendarStatus: calendarStatus,
                                 events: events, moreEvents: more,
                                 redacted: redacted,
                                 weatherStatus: weatherStatus, weather: weather,
                                 attribution: weather == nil ? nil : inputs.attribution,
                                 // The same Medical Compliance reading as the titles above.
                                 cards: WatchPreparedCardBuilder.cards(from: inputs.cards, now: inputs.now,
                                                                       withholding: redacted))
    }

    static func calendarStatus(_ gathered: MyDayGathered) -> WatchTodaySectionStatus {
        guard gathered.calendarIncluded else { return .notIncluded }
        guard !gathered.locked else { return .locked }
        switch gathered.calendarState?.availability {
        case .available: return .shown
        case .denied: return .noAccess
        case .unavailable, nil: return .unavailable
        }
    }

    static func weatherStatus(_ gathered: MyDayGathered,
                              medical: MedicalEgressGuard.Mode) -> WatchTodaySectionStatus {
        guard gathered.weatherIncluded else { return .notIncluded }
        if medical.isEnforcing { return .medicalOff }
        guard !gathered.locked else { return .locked }
        switch gathered.weatherState?.availability {
        case .available: return .shown
        case .denied: return .noAccess
        case .unavailable, nil: return .unavailable
        }
    }

    static func weather(from report: WeatherReport, _ inputs: Inputs) -> WatchTodayWeather {
        let today = report.days.first { inputs.calendar.isDate($0.date, inSameDayAs: inputs.now) }
            ?? report.days.first
        let degrees: (Double) -> Int = { celsius in
            let value = inputs.temperatureUnit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
            let rounded = Int(value.rounded())
            return rounded == 0 ? 0 : rounded
        }
        return WatchTodayWeather(
            symbolName: report.current.symbolName ?? fallbackSymbol(report.current.condition),
            temperature: degrees(report.current.temperatureC),
            high: today.map { degrees($0.highC) },
            low: today.map { degrees($0.lowC) },
            precipitationChance: today.map { Int(($0.precipitationChance * 100).rounded()) },
            condition: inputs.conditionText(report.current.condition),
            unit: inputs.temperatureUnit)
    }

    /// The symbol when WeatherKit's own is missing (a report built without one).
    static func fallbackSymbol(_ condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .mostlyClear, .hot: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .mostlyCloudy, .cloudy: return "cloud.fill"
        case .foggy, .haze, .smoky, .blowingDust: return "cloud.fog.fill"
        case .breezy, .windy: return "wind"
        case .drizzle, .sunShowers: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms:
            return "cloud.bolt.rain.fill"
        case .flurries, .snow, .heavySnow, .sunFlurries, .blowingSnow, .blizzard: return "cloud.snow.fill"
        case .sleet, .freezingDrizzle, .freezingRain, .wintryMix, .hail: return "cloud.sleet.fill"
        case .frigid: return "thermometer.snowflake"
        case .hurricane, .tropicalStorm: return "hurricane"
        @unknown default: return "thermometer.medium"
        }
    }

    static func shortened(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// Whether a new gathering replaces the one held. A refresh made while the phone was locked read
/// nothing, so it never overwrites a good gathering of the same day; a new day always replaces.
enum WatchTodayHoldPolicy {
    static func shouldReplace(held: MyDayGathered?, with new: MyDayGathered, calendar: Calendar) -> Bool {
        guard let held, new.locked, !held.locked else { return true }
        return !calendar.isDate(held.generatedAt, inSameDayAs: new.generatedAt)
    }
}
