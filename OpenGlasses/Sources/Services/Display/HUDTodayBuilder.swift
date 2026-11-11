import Foundation

/// What the Today glance shows (Plan LC §4), as plain data: the launcher's root screen is built from
/// this by `HUDTodayBuilder`, and nothing in it fetches. A row with no data is nil and is left off
/// the screen.
///
/// The calendar and the weather come from what My Day last gathered, through the Watch's Today
/// value (`WatchTodayBuilder.payload`, Plan KS) — so the lens reads the same day the wrist does,
/// with the same Medical Compliance rules: any Medical Compliance mode withholds what an
/// appointment is (the lens shows its time only), and Local Only withholds the weather.
struct HUDTodayGlance: Equatable {
    /// The next calendar item.
    struct Event: Equatable {
        /// The start time as the wearer reads it; nil for an all-day item.
        var time: String?
        /// Nil when withheld (Medical Compliance) or untitled.
        var title: String?
        /// Under way now.
        var isNow: Bool
        var isAllDay: Bool
    }

    /// Today's weather, in the wearer's unit and whole degrees.
    struct Weather: Equatable {
        var temperature: Int
        var condition: String
        var high: Int?
        var low: Int?
        /// The weather service's name (WeatherKit's attribution), drawn beside the weather.
        var credit: String?
    }

    /// The time now, as the wearer reads it.
    var time: String
    /// The glasses' battery, only while they are connected (`GlassesConnectionService.batteryLevel`).
    var batteryPercent: Int?
    var event: Event?
    var weather: Weather?
    /// The active walking route's line (Plan CA), while guiding.
    var route: String?
    /// The digest's top item (Plan BZ), as its deterministic line.
    var digestTop: String?

    /// The glance from the app's state at `now`. `today` is the Watch's Today value built from My
    /// Day's last gathering; one for another day, or a section My Day could not read, adds nothing.
    static func make(now: Date, calendar: Calendar, locale: Locale, batteryPercent: Int?,
                     today: WatchTodayPayload?, route: String?, digestTop: String?) -> HUDTodayGlance {
        let clock: (Date) -> String = { timeText($0, calendar: calendar, locale: locale) }
        var glance = HUDTodayGlance(time: clock(now), batteryPercent: batteryPercent,
                                    route: nonEmpty(route), digestTop: nonEmpty(digestTop))
        guard case .current(let payload) = WatchTodayFreshness.evaluate(today, now: now, calendar: calendar) else {
            return glance
        }
        if payload.calendarStatus == .shown {
            let rows = WatchTodayTimeline.rows(payload.events, now: now)
            // Under way first, then the next to start, then an all-day item.
            if let row = rows.first(where: { $0.mark == .now }) ?? rows.first(where: { $0.mark == .next })
                ?? rows.first(where: { $0.mark == .allDay }) {
                glance.event = Event(time: row.event.isAllDay ? nil : clock(row.event.start),
                                     title: nonEmpty(row.event.title), isNow: row.mark == .now,
                                     isAllDay: row.event.isAllDay)
            }
        }
        if payload.weatherStatus == .shown, let weather = payload.weather {
            glance.weather = Weather(temperature: weather.temperature, condition: weather.condition,
                                     high: weather.high, low: weather.low,
                                     credit: nonEmpty(payload.attribution?.serviceName))
        }
        return glance
    }

    /// A short time ("09:41", "9:41 AM") in the wearer's locale.
    static func timeText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Builds the launcher's root, the Today glance (Plan LC §4). Pure: the glance is plain data and
/// the items' effects are injected closures, so every row and item is unit-testable headlessly.
///
/// | Row | Icon | When |
/// |---|---|---|
/// | time · glasses battery (meta) | clock | always (the battery only while connected) |
/// | the next event ("Now: …", "10:30 …", "Today: …") | calendar | an event still to come today |
/// | the weather ("18° Partly Cloudy · H 21° L 12° · Apple Weather") | weather | My Day read it |
/// | the route | navigation | while walking navigation guides |
/// | the digest's top item | info | the digest has something |
///
/// Then **Ready** (Plan KT §6.2, the day's prepared cards; primary and focused when there are any) ·
/// **What's new** (primary, focused without cards) · **Resume** · **Navigate** · **Menu** · **Close**, each
/// only when it has something to do — What's new with a digest to show, Resume with a task card to
/// go back to, Navigate with a recent destination, Menu with a branch in it. Focus is What's new,
/// else Resume, else Menu. Today is the launcher's root, so Close is its own way out and Back (the
/// band) ending the session is the intended exit (§2.3).
///
/// Item ids are the launcher's branch ids where the action is the same, so a voice label or a test
/// that knows the branch finds it on Today too.
enum HUDTodayBuilder {

    enum ItemID {
        /// Plan KT §6.2: the day's prepared cards.
        static let ready = "branch:cards"
        static let whatsNew = "branch:digest"
        static let resume = "branch:resume"
        static let navigate = "branch:navigate"
        static let menu = "today:menu"
        static let close = "close"
    }

    /// The items' effects. A nil closure leaves its item off.
    struct Actions {
        /// Plan KT §6.2: open the day's prepared cards; first, and focused, when there are any.
        var ready: (() -> Void)?
        var whatsNew: (() -> Void)?
        var resume: (() -> Void)?
        var navigate: (() -> Void)?
        var menu: (() -> Void)?
        var close: () -> Void
    }

    /// Plan KT decision 9: the cards' own word, "Ready", rather than a second "Today" on Today.
    static var readyLabel: String {
        String(localized: "Ready", comment: "Glasses: Today glance button that opens the day's prepared cards.")
    }

    static var title: String {
        String(localized: "Today", comment: "Glasses: heading of the Today glance, the launcher's first screen.")
    }

    static func screen(_ glance: HUDTodayGlance, actions: Actions) -> HUDScreen {
        HUDScreen(title: title, lines: lines(glance), items: items(actions),
                  focusItemID: focus(actions))
    }

    static func lines(_ glance: HUDTodayGlance) -> [HUDLine] {
        var lines = [HUDLine(metaLine(glance), icon: .clock, emphasis: .meta)]
        if let event = glance.event { lines.append(HUDLine(eventLine(event), icon: .calendar)) }
        if let weather = glance.weather { lines.append(HUDLine(weatherLine(weather), icon: .weather)) }
        if let route = glance.route {
            lines.append(HUDLine(HUDTextShaper.condense(route), icon: .navigation))
        }
        if let digest = glance.digestTop {
            lines.append(HUDLine(HUDTextShaper.condense(digest), icon: .info, emphasis: .secondary))
        }
        return lines
    }

    /// "09:41 · Glasses 80%", or the time alone.
    static func metaLine(_ glance: HUDTodayGlance) -> String {
        guard let percent = glance.batteryPercent else { return glance.time }
        let battery = String(localized: "Glasses \(percent)%",
                             comment: "Glasses: the glasses' battery on the Today glance, e.g. 'Glasses 80%'.")
        return "\(glance.time) · \(battery)"
    }

    static func eventLine(_ event: HUDTodayGlance.Event) -> String {
        let name = event.title ?? String(localized: "Event",
                                         comment: "Glasses: Today glance, a calendar item whose title is withheld or empty.")
        let line: String
        if event.isNow {
            line = String(localized: "Now: \(name)", comment: "Glasses: Today glance, the calendar item under way.")
        } else if event.isAllDay || event.time == nil {
            line = String(localized: "Today: \(name)", comment: "Glasses: Today glance, an all-day calendar item.")
        } else {
            line = "\(event.time ?? "") \(name)"
        }
        return HUDTextShaper.condense(line)
    }

    static func weatherLine(_ weather: HUDTodayGlance.Weather) -> String {
        var parts = ["\(weather.temperature)° \(weather.condition)"]
        if let high = weather.high, let low = weather.low {
            parts.append(String(localized: "H \(high)° L \(low)°",
                                comment: "Glasses: Today glance, today's high and low temperature."))
        }
        if let credit = weather.credit { parts.append(credit) }
        return HUDTextShaper.condense(parts.joined(separator: " · "))
    }

    static func items(_ actions: Actions) -> [HUDItem] {
        var items: [HUDItem] = []
        if let ready = actions.ready {
            items.append(HUDItem(id: ItemID.ready, label: readyLabel, icon: .reminder, style: .primary, action: ready))
        }
        if let whatsNew = actions.whatsNew {
            items.append(HUDItem(id: ItemID.whatsNew,
                                 label: String(localized: "What's new", comment: "Glasses: Today glance button that opens the digest."),
                                 icon: .info, style: .primary, action: whatsNew))
        }
        if let resume = actions.resume {
            items.append(HUDItem(id: ItemID.resume,
                                 label: String(localized: "Resume", comment: "Glasses: Today glance button back to the running task card."),
                                 icon: .navigation, style: .secondary, action: resume))
        }
        if let navigate = actions.navigate {
            items.append(HUDItem(id: ItemID.navigate,
                                 label: String(localized: "Navigate", comment: "Glasses: Today glance button that lists recent destinations."),
                                 icon: .navigation, style: .secondary, action: navigate))
        }
        if let menu = actions.menu {
            items.append(HUDItem(id: ItemID.menu,
                                 label: String(localized: "Menu", comment: "Glasses: Today glance button that opens the launcher's full list."),
                                 style: .secondary, action: menu))
        }
        items.append(HUDItem(id: ItemID.close,
                             label: String(localized: "Close", comment: "Glasses: Today glance button that closes the launcher."),
                             style: .outline, action: actions.close))
        return items
    }

    /// What's new, else Resume, else Menu; nil (the default rule) with none of them.
    static func focus(_ actions: Actions) -> String? {
        if actions.ready != nil { return ItemID.ready }
        if actions.whatsNew != nil { return ItemID.whatsNew }
        if actions.resume != nil { return ItemID.resume }
        if actions.menu != nil { return ItemID.menu }
        return nil
    }
}
