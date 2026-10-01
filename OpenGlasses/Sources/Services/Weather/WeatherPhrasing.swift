import Foundation
import WeatherKit

// The deterministic half of a weather answer: everything here is a pure function of a
// `WeatherReport`, a clock and the wearer's units, so every sentence the wearer can hear is
// covered by a headless test.

// MARK: - Conditions

enum WeatherConditionPhrase {

    /// A short, lowercase phrase that reads naturally after "Currently 14°C,". Fixed English
    /// rather than WeatherKit's localised `description`, so the sentence is stable in tests and
    /// the model — which answers in the wearer's language — gets the same input everywhere.
    static func phrase(_ condition: WeatherCondition) -> String {
        switch condition {
        case .blizzard: return "blizzard"
        case .blowingDust: return "blowing dust"
        case .blowingSnow: return "blowing snow"
        case .breezy: return "breezy"
        case .clear: return "clear"
        case .cloudy: return "cloudy"
        case .drizzle: return "drizzle"
        case .flurries: return "snow flurries"
        case .foggy: return "foggy"
        case .freezingDrizzle: return "freezing drizzle"
        case .freezingRain: return "freezing rain"
        case .frigid: return "bitterly cold"
        case .hail: return "hail"
        case .haze: return "hazy"
        case .heavyRain: return "heavy rain"
        case .heavySnow: return "heavy snow"
        case .hot: return "very hot"
        case .hurricane: return "hurricane conditions"
        case .isolatedThunderstorms: return "isolated thunderstorms"
        case .mostlyClear: return "mostly clear"
        case .mostlyCloudy: return "mostly cloudy"
        case .partlyCloudy: return "partly cloudy"
        case .rain: return "rain"
        case .scatteredThunderstorms: return "scattered thunderstorms"
        case .sleet: return "sleet"
        case .smoky: return "smoky"
        case .snow: return "snow"
        case .strongStorms: return "strong storms"
        case .sunFlurries: return "sun and flurries"
        case .sunShowers: return "sun showers"
        case .thunderstorms: return "thunderstorms"
        case .tropicalStorm: return "tropical storm conditions"
        case .windy: return "windy"
        case .wintryMix: return "a wintry mix"
        @unknown default: return "mixed conditions"
        }
    }

    /// Conditions a person would change a plan for — take a coat, leave earlier, stay in.
    static func isDecisionRelevant(_ condition: WeatherCondition) -> Bool {
        switch condition {
        case .clear, .mostlyClear, .partlyCloudy, .mostlyCloudy, .cloudy, .breezy, .haze:
            return false
        case .blizzard, .blowingDust, .blowingSnow, .drizzle, .flurries, .foggy,
             .freezingDrizzle, .freezingRain, .frigid, .hail, .heavyRain, .heavySnow, .hot,
             .hurricane, .isolatedThunderstorms, .rain, .scatteredThunderstorms, .sleet, .smoky,
             .snow, .strongStorms, .sunFlurries, .sunShowers, .thunderstorms, .tropicalStorm,
             .windy, .wintryMix:
            return true
        @unknown default:
            return false
        }
    }
}

// MARK: - Rain in the next hour

/// What the minute forecast says about the next hour. Only ever computed from WeatherKit's minute
/// forecast; where the region has none the answer is `.unknown` and nothing is said — "no rain"
/// would be a claim the data cannot support.
enum RainOutlook: Equatable, Sendable {
    case unknown
    case dryForTheHour
    case starting(inMinutes: Int, kind: Precipitation)
    case stopping(inMinutes: Int, kind: Precipitation)
    case continuing(kind: Precipitation)

    /// A minute counts as wet at this chance or more…
    static let wetChance = 0.5
    /// …and at least this intensity (light drizzle is about 0.1–0.5 mm/h).
    static let wetIntensity = 0.1
    /// A change has to last this many minutes, so one wet minute is not "rain starting".
    static let minimumRun = 3
    /// The horizon the answer speaks for.
    static let horizonMinutes = 60

    static func isWet(_ minute: WeatherReport.Minute) -> Bool {
        minute.precipitation != .none
            && minute.precipitationChance >= wetChance
            && minute.intensityMillimetresPerHour >= wetIntensity
    }

    static func evaluate(minutes: [WeatherReport.Minute]?, now: Date) -> RainOutlook {
        guard let minutes else { return .unknown }
        // The minute that contains `now` onwards, an hour of them.
        let window = minutes
            .filter { $0.date.addingTimeInterval(60) > now }
            .sorted { $0.date < $1.date }
            .prefix(horizonMinutes)
        guard let first = window.first, window.count >= minimumRun else { return .unknown }

        let wet = window.map(isWet)
        let startsWet = wet[0]
        // The first index where the state flips and then holds for `minimumRun` minutes.
        var flip: Int?
        var index = 1
        while index + minimumRun <= wet.count {
            if wet[index] != startsWet, wet[index..<(index + minimumRun)].allSatisfy({ $0 == wet[index] }) {
                flip = index
                break
            }
            index += 1
        }

        func minutesUntil(_ i: Int) -> Int {
            max(1, Int((window[window.startIndex + i].date.timeIntervalSince(now) / 60).rounded()))
        }

        if startsWet {
            let kind = first.precipitation
            if let flip { return .stopping(inMinutes: minutesUntil(flip), kind: kind) }
            return .continuing(kind: kind)
        }
        if let flip {
            return .starting(inMinutes: minutesUntil(flip), kind: window[window.startIndex + flip].precipitation)
        }
        return .dryForTheHour
    }

    /// The sentence, or nil when there is nothing to say.
    var sentence: String? {
        switch self {
        case .unknown:
            return nil
        case .dryForTheHour:
            return "No rain expected in the next hour."
        case .starting(let minutes, let kind):
            return "\(Self.capitalisedNoun(kind)) starting in \(Self.aboutMinutes(minutes))."
        case .stopping(let minutes, let kind):
            return "\(Self.capitalisedNoun(kind)) stopping in \(Self.aboutMinutes(minutes))."
        case .continuing(let kind):
            return "\(Self.capitalisedNoun(kind)) for at least the next hour."
        }
    }

    static func noun(_ kind: Precipitation) -> String {
        switch kind {
        case .snow: return "snow"
        case .sleet: return "sleet"
        case .hail: return "hail"
        case .mixed: return "rain and snow"
        case .rain, .none: return "rain"
        @unknown default: return "rain"
        }
    }

    private static func capitalisedNoun(_ kind: Precipitation) -> String {
        let word = noun(kind)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private static func aboutMinutes(_ minutes: Int) -> String {
        if minutes <= 1 { return "about a minute" }
        if minutes < 10 { return "about \(minutes) minutes" }
        // Minute forecasts are not precise to the minute; five-minute steps say so.
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        return "about \(rounded) minutes"
    }
}

// MARK: - Severe-weather alerts

enum WeatherAlertDigest {

    /// At most this many alerts are read out; the rest are counted.
    static let spokenLimit = 2

    static func rank(_ severity: WeatherSeverity) -> Int {
        switch severity {
        case .extreme: return 4
        case .severe: return 3
        case .moderate: return 2
        case .minor: return 1
        case .unknown: return 0
        @unknown default: return 0
        }
    }

    /// Most severe first, duplicates (same summary and source) removed, blank summaries dropped.
    static func ordered(_ alerts: [WeatherReport.Alert]) -> [WeatherReport.Alert] {
        var seen = Set<String>()
        let unique = alerts.filter { alert in
            let summary = alert.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return false }
            let key = summary.lowercased() + "|" + alert.source.lowercased()
            return seen.insert(key).inserted
        }
        // Stable: equal severities keep WeatherKit's order.
        return unique.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element.severity), r = rank(rhs.element.severity)
                return l != r ? l > r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// "Weather alert: Flood Warning, from the National Weather Service." — or nil when none.
    static func sentence(_ alerts: [WeatherReport.Alert]?) -> String? {
        guard let alerts else { return nil }
        let ordered = ordered(alerts)
        guard !ordered.isEmpty else { return nil }
        let spoken = ordered.prefix(spokenLimit).map(describe)
        let label = ordered.count == 1 ? "Weather alert" : "Weather alerts"
        var text = "\(label): \(spoken.joined(separator: "; "))"
        let remaining = ordered.count - spoken.count
        if remaining > 0 { text += "; and \(remaining) more" }
        return text + "."
    }

    private static func describe(_ alert: WeatherReport.Alert) -> String {
        let summary = alert.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let source = alert.source.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? summary : "\(summary), from \(source)"
    }
}

// MARK: - The whole answer

enum WeatherPhraser {

    /// The tool's answer: current conditions, today's high and low, rain in the next hour, any
    /// alerts, then tomorrow and the day after. Sentences are dropped, never guessed, when the
    /// data for them is missing.
    static func answer(
        _ report: WeatherReport,
        placeName: String?,
        units: WeatherUnits,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        var sentences: [String] = []
        let current = report.current
        let place = placeName.map { " in \($0)" } ?? ""
        sentences.append(
            "Currently \(units.temperature(current.temperatureC)) (feels like \(units.temperature(current.apparentTemperatureC))), "
            + "\(WeatherConditionPhrase.phrase(current.condition))\(place). "
            + "Wind \(units.speed(current.windKmh)), humidity \(Int((current.humidity * 100).rounded()))%."
        )

        let days = upcomingDays(report.days, now: now)
        if let today = days.first {
            var line = "Today's high \(units.temperature(today.highC)), low \(units.temperature(today.lowC))"
            if let chance = rainChance(today) { line += ", \(chance)" }
            sentences.append(line + ".")
        }

        if let rain = RainOutlook.evaluate(minutes: report.minutes, now: now).sentence {
            sentences.append(rain)
        }
        if let alerts = WeatherAlertDigest.sentence(report.alerts) {
            sentences.append(alerts)
        }

        if days.count >= 2 {
            let tomorrow = days[1]
            sentences.append("Tomorrow: \(WeatherConditionPhrase.phrase(tomorrow.condition)), "
                             + "\(units.temperature(tomorrow.highC))/\(units.temperature(tomorrow.lowC)).")
        }
        if days.count >= 3 {
            let after = days[2]
            let name = weekdayName(after.date, calendar: calendar)
            sentences.append("\(name): \(WeatherConditionPhrase.phrase(after.condition)), "
                             + "\(units.temperature(after.highC))/\(units.temperature(after.lowC)).")
        }
        return sentences.joined(separator: " ")
    }

    /// Whether My Day should lift the weather above routine: an active alert, rain in the next
    /// hour, or a condition now or today that changes plans. Read from the data, not from words
    /// in a sentence.
    static func isDecisionRelevant(_ report: WeatherReport, now: Date) -> Bool {
        if let alerts = report.alerts, !WeatherAlertDigest.ordered(alerts).isEmpty { return true }
        switch RainOutlook.evaluate(minutes: report.minutes, now: now) {
        case .starting, .continuing, .stopping: return true
        case .unknown, .dryForTheHour: break
        }
        if WeatherConditionPhrase.isDecisionRelevant(report.current.condition) { return true }
        if let today = upcomingDays(report.days, now: now).first {
            if WeatherConditionPhrase.isDecisionRelevant(today.condition) { return true }
            if today.precipitationChance >= 0.5 { return true }
        }
        return false
    }

    /// Today onwards: a day whose 24 hours have fully passed is dropped, so a forecast fetched
    /// just before midnight does not call yesterday "today".
    static func upcomingDays(_ days: [WeatherReport.Day], now: Date) -> [WeatherReport.Day] {
        days.sorted { $0.date < $1.date }
            .filter { $0.date.addingTimeInterval(24 * 3600) > now }
    }

    private static func rainChance(_ day: WeatherReport.Day) -> String? {
        let percent = Int((day.precipitationChance * 100 / 10).rounded()) * 10
        guard percent >= 30 else { return nil }
        return "\(percent)% chance of precipitation"
    }

    private static func weekdayName(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}

// MARK: - Coordinates

enum WeatherLocationPrecision {
    /// Two decimal places is about 1.1 km of latitude — fine for a minute forecast, and less than
    /// a GPS fix reveals about where the wearer is standing.
    static let decimalPlaces = 2

    static func coarsen(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let scale = pow(10, Double(decimalPlaces))
        return ((latitude * scale).rounded() / scale, (longitude * scale).rounded() / scale)
    }
}
