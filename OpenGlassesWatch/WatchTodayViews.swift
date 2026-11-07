import SwiftUI
import WatchKit

// Plan KS — Today on the wrist: Now Playing, today's calendar, today's weather, as three vertical
// pages. The phone resolves the calendar and the weather and sends them in the `today` context
// value; the watch reads no calendar, weather or location of its own. Now Playing is the system's
// own view and controls whatever is playing, on the iPhone or the watch, with no phone code at all.
// Every page that has nothing to show says why.

/// "Today" in the main list.
struct WatchTodayRow: View {
    @ObservedObject var connectivity: WatchConnectivityService

    var body: some View {
        NavigationLink {
            WatchTodayPages(connectivity: connectivity)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(AccentColors.aiCoral)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today")
                        .font(.body)
                    TimelineView(.everyMinute) { context in
                        Text(Self.subtitle(connectivity.today, now: context.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The first item still to come, or what the pages hold.
    static func subtitle(_ payload: WatchTodayPayload?, now: Date) -> String {
        if case .current(let today) = WatchTodayFreshness.evaluate(payload, now: now, calendar: .autoupdatingCurrent),
           let row = WatchTodayTimeline.rows(today.events, now: now).first(where: { $0.mark != .allDay }) {
            let time = row.event.start.formatted(date: .omitted, time: .shortened)
            if row.mark == .now { return String(localized: "Now: \(row.event.title ?? time)") }
            return [time, row.event.title].compactMap { $0 }.joined(separator: " ")
        }
        return String(localized: "Now Playing, calendar, weather")
    }
}

/// The three pages, swiped vertically.
struct WatchTodayPages: View {
    @ObservedObject var connectivity: WatchConnectivityService

    var body: some View {
        TabView {
            NowPlayingView()
                .navigationTitle("Now Playing")
            WatchTodayCalendarPage(payload: connectivity.today)
                .navigationTitle("Calendar")
            WatchTodayWeatherPage(payload: connectivity.today)
                .navigationTitle("Weather")
        }
        .tabViewStyle(.verticalPage)
    }
}

// MARK: - Calendar

struct WatchTodayCalendarPage: View {
    let payload: WatchTodayPayload?

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch WatchTodayFreshness.evaluate(payload, now: context.date, calendar: .autoupdatingCurrent) {
                    case .current(let today):
                        content(today, now: context.date)
                    case let other:
                        WatchTodayReason(text: WatchTodayReasons.unavailable(other))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func content(_ today: WatchTodayPayload, now: Date) -> some View {
        if today.calendarStatus == .shown {
            let rows = WatchTodayTimeline.rows(today.events, now: now)
            if rows.isEmpty {
                WatchTodayReason(text: today.moreEvents > 0
                                 ? WatchTodayReasons.moreOnPhone(today.moreEvents)
                                 : String(localized: "Nothing else on your calendar today."))
            } else {
                ForEach(rows) { row in
                    WatchTodayEventRow(row: row)
                }
                if today.moreEvents > 0 {
                    Text(WatchTodayReasons.moreOnPhone(today.moreEvents))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if today.redacted {
                    Text("Event names and places are hidden while Medical Compliance is on.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            WatchTodayReason(text: WatchTodayReasons.calendar(today.calendarStatus))
        }
        WatchTodayUpdated(generatedAt: today.generatedAt)
    }
}

struct WatchTodayEventRow: View {
    let row: WatchTodayTimeline.Row

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(row.mark == .now ? AccentColors.aiCoral : Color.secondary.opacity(0.5))
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let mark = markText {
                        Text(mark)
                            .font(.caption2.bold())
                            .foregroundStyle(AccentColors.aiCoral)
                    }
                }
                Text(row.event.title ?? String(localized: "Event"))
                    .font(.caption)
                    .lineLimit(2)
                if let location = row.event.location {
                    Text(location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if row.event.isAllDay { return String(localized: "All day") }
        let start = row.event.start.formatted(date: .omitted, time: .shortened)
        let end = row.event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) \u{2013} \(end)"
    }

    private var markText: String? {
        switch row.mark {
        case .now: return String(localized: "Now")
        case .next: return String(localized: "Next")
        case .allDay, .later: return nil
        }
    }
}

// MARK: - Weather

struct WatchTodayWeatherPage: View {
    let payload: WatchTodayPayload?

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch WatchTodayFreshness.evaluate(payload, now: context.date, calendar: .autoupdatingCurrent) {
                    case .current(let today):
                        if let weather = today.weather {
                            WatchTodayWeatherSummary(weather: weather)
                            if let attribution = today.attribution {
                                WatchTodayWeatherCredit(attribution: attribution)
                            }
                        } else {
                            WatchTodayReason(text: WatchTodayReasons.weather(today.weatherStatus))
                        }
                        WatchTodayUpdated(generatedAt: today.generatedAt)
                    case let other:
                        WatchTodayReason(text: WatchTodayReasons.unavailable(other))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct WatchTodayWeatherSummary: View {
    let weather: WatchTodayWeather

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: weather.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(degrees(weather.temperature))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
            }
            Text(weather.condition)
                .font(.caption)
            HStack(spacing: 8) {
                if let high = weather.high, let low = weather.low {
                    Text("H \(degrees(high))  L \(degrees(low))")
                }
                if let chance = weather.precipitationChance, chance > 0 {
                    Label {
                        Text(Double(chance) / 100, format: .percent)
                    } icon: {
                        Image(systemName: "umbrella.fill")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func degrees(_ value: Int) -> String {
        "\(value)\u{00B0}"
    }
}

/// The credit Apple requires wherever WeatherKit data is shown: the service's name and its legal
/// attribution page (the other data sources). The phone sends both; the watch fetches nothing. On
/// a watch that cannot open the page, the same page is a tap away under My Day on the iPhone.
struct WatchTodayWeatherCredit: View {
    let attribution: WatchTodayAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: attribution.serviceName)
                .font(.caption2.weight(.semibold))
            if let url = URL(string: attribution.legalPageURL) {
                Link(destination: url) {
                    Text("Legal attribution")
                        .font(.caption2)
                        .underline()
                }
            }
            Text("Weather data sources are listed there and under My Day in Avenkin on your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

// MARK: - Shared pieces

struct WatchTodayReason: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WatchTodayUpdated: View {
    let generatedAt: Date

    var body: some View {
        Text("Updated \(generatedAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }
}

/// Every stated reason the Today pages give.
enum WatchTodayReasons {

    static func unavailable(_ freshness: WatchTodayFreshness) -> String {
        switch freshness {
        case .settingOff:
            return String(localized: "Today on Your Watch is off. Turn it on in Avenkin on your iPhone, under Apple Watch.")
        case .absent, .stale, .current:
            return String(localized: "Open Avenkin on your iPhone to update today.")
        }
    }

    static func calendar(_ status: WatchTodaySectionStatus) -> String {
        switch status {
        case .notIncluded: return String(localized: "Calendar is off in My Day on your iPhone.")
        case .noAccess: return String(localized: "Avenkin can\u{2019}t read your calendar. Allow access on your iPhone.")
        case .locked: return String(localized: "Unlock your iPhone to update today.")
        case .settingOff: return unavailable(.settingOff)
        case .shown, .medicalOff, .unavailable: return String(localized: "Your calendar couldn\u{2019}t be read.")
        }
    }

    static func weather(_ status: WatchTodaySectionStatus) -> String {
        switch status {
        case .notIncluded: return String(localized: "Weather is off in My Day on your iPhone.")
        case .medicalOff: return String(localized: "Weather is off while Medical Local Only is on.")
        case .noAccess: return String(localized: "Weather needs your location on your iPhone.")
        case .locked: return String(localized: "Unlock your iPhone to update today.")
        case .settingOff: return unavailable(.settingOff)
        case .shown, .unavailable: return String(localized: "Weather isn\u{2019}t available right now.")
        }
    }

    static func moreOnPhone(_ count: Int) -> String {
        String(localized: "\(count) more today on your iPhone.")
    }
}
