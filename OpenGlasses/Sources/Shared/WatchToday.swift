import Foundation

// Plan KS — today on the wrist: the next few of today's calendar items and today's weather, as
// the phone resolved them. Foundation only and compiled into both targets (listed in
// `project.watch.yml`), so the phone that builds the payload and the watch that draws it read the
// same types. The watch reads no calendar, weather or location of its own.

/// The application-context key and the payload's version.
enum WatchTodayWire {
    /// The application-context key holding the encoded `WatchTodayPayload`.
    static let contextKey = "today"
    /// Bumped when a field changes meaning. A watch that reads a newer version shows nothing
    /// rather than a misreading.
    ///
    /// 2 (Plan KT P4): adds `cards`, the day's prepared cards. A payload of version 1 (from a phone
    /// not yet updated) still reads, with no cards.
    static let version = 2
    /// Every version this build reads.
    static let readableVersions: ClosedRange<Int> = 1...version
}

/// A calendar day as the phone saw it — year, month, day in the phone's calendar and time zone.
/// Compared field by field, so the watch's own clock decides "is this today?" without either side
/// sending a time zone.
struct WatchTodayDay: Codable, Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }
}

/// Why a section shows what it shows. Every state but `shown` is drawn as a stated reason.
enum WatchTodaySectionStatus: String, Codable, Equatable, Sendable {
    /// The data is in the payload (an empty calendar is still `shown`: "Nothing else today").
    case shown
    /// The source is not included in My Day on the phone.
    case notIncluded
    /// The phone has no access (calendar permission off).
    case noAccess
    /// The phone was locked when it last looked, so it could not read the calendar.
    case locked
    /// Off while Medical Local Only is on (weather only).
    case medicalOff
    /// The source failed (no location, no connection, the service refused).
    case unavailable
    /// "Today on Your Watch" is off on the phone.
    case settingOff
}

/// One calendar item. `title` and `location` are nil under any Medical Compliance mode: the wrist
/// then shows the time only.
struct WatchTodayEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let title: String?
    let location: String?
}

enum WatchTodayTemperatureUnit: String, Codable, Equatable, Sendable {
    case celsius
    case fahrenheit
}

/// Today's weather, already in the wearer's unit and whole degrees.
struct WatchTodayWeather: Codable, Equatable, Sendable {
    /// An SF Symbol name (WeatherKit's own, or the phone's fallback).
    let symbolName: String
    let temperature: Int
    let high: Int?
    let low: Int?
    /// 0...100.
    let precipitationChance: Int?
    /// Short, localised condition text from the phone ("Partly Cloudy").
    let condition: String
    let unit: WatchTodayTemperatureUnit
}

/// The weather credit the watch must draw beside any weather (Apple's WeatherKit attribution).
struct WatchTodayAttribution: Codable, Equatable, Sendable {
    /// The service name WeatherKit gives ("Apple Weather" when it has not answered).
    let serviceName: String
    /// The legal attribution page — the other data sources.
    let legalPageURL: String
}

/// The whole `today` value.
struct WatchTodayPayload: Codable, Equatable, Sendable {
    var version: Int = WatchTodayWire.version
    /// The day the calendar and weather belong to.
    var day: WatchTodayDay
    var generatedAt: Date
    var calendarStatus: WatchTodaySectionStatus
    /// The next of today's items, not yet over, all-day first, at most `maxEvents`.
    var events: [WatchTodayEvent]
    /// Today's items past the cap — counted, never named.
    var moreEvents: Int
    /// Titles and locations were withheld (Medical Compliance).
    var redacted: Bool
    var weatherStatus: WatchTodaySectionStatus
    var weather: WatchTodayWeather?
    /// Present whenever `weather` is.
    var attribution: WatchTodayAttribution?
    /// The day's prepared cards (Plan KT §6.7), at most `WatchPreparedCard.maxCards`, ranked.
    /// Drawn above the calendar. Empty in a version 1 payload.
    var cards: [WatchPreparedCard] = []

    static let maxEvents = 6

    init(version: Int = WatchTodayWire.version, day: WatchTodayDay, generatedAt: Date,
         calendarStatus: WatchTodaySectionStatus, events: [WatchTodayEvent], moreEvents: Int, redacted: Bool,
         weatherStatus: WatchTodaySectionStatus, weather: WatchTodayWeather?, attribution: WatchTodayAttribution?,
         cards: [WatchPreparedCard] = []) {
        self.version = version
        self.day = day
        self.generatedAt = generatedAt
        self.calendarStatus = calendarStatus
        self.events = events
        self.moreEvents = moreEvents
        self.redacted = redacted
        self.weatherStatus = weatherStatus
        self.weather = weather
        self.attribution = attribution
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey {
        case version, day, generatedAt, calendarStatus, events, moreEvents, redacted, weatherStatus, weather,
             attribution, cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        day = try container.decode(WatchTodayDay.self, forKey: .day)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        calendarStatus = try container.decode(WatchTodaySectionStatus.self, forKey: .calendarStatus)
        events = try container.decode([WatchTodayEvent].self, forKey: .events)
        moreEvents = try container.decode(Int.self, forKey: .moreEvents)
        redacted = try container.decode(Bool.self, forKey: .redacted)
        weatherStatus = try container.decode(WatchTodaySectionStatus.self, forKey: .weatherStatus)
        weather = try container.decodeIfPresent(WatchTodayWeather.self, forKey: .weather)
        attribution = try container.decodeIfPresent(WatchTodayAttribution.self, forKey: .attribution)
        // Version 1 has no cards.
        cards = try container.decodeIfPresent([WatchPreparedCard].self, forKey: .cards) ?? []
    }

    /// What the phone sends while "Today on Your Watch" is off, so the watch can say so rather
    /// than ask the wearer to open the app.
    static func settingOff(at now: Date, calendar: Calendar) -> WatchTodayPayload {
        WatchTodayPayload(day: WatchTodayDay(now, calendar: calendar), generatedAt: now,
                          calendarStatus: .settingOff, events: [], moreEvents: 0, redacted: false,
                          weatherStatus: .settingOff, weather: nil, attribution: nil)
    }

    var isSettingOff: Bool { calendarStatus == .settingOff && weatherStatus == .settingOff }
}

// MARK: - Prepared cards (Plan KT §6.7)

/// The command the watch sends for a card, and its fields.
enum WatchPreparedCardWire {
    static let command = "preparedCardAction"
    static let cardIDKey = "card_id"
    static let actionKey = "action"
}

/// What a press on the wrist asks the phone to do with a card.
enum WatchPreparedCardAction: String, Codable, CaseIterable, Sendable {
    /// §6.4: put the draft on the phone, ready to send there — exactly the Display's Send on phone.
    case stage
    case directions
    case later
    case dismiss
}

/// A button on a wrist card: what it does, and the phone's own label for it ("Text Ana").
struct WatchPreparedCardButton: Codable, Equatable, Hashable, Sendable {
    let action: WatchPreparedCardAction
    let label: String
}

/// One prepared card as the wrist shows it. Health cards never come here, and a draft's text only
/// when the card's sensitivity and Medical Compliance allow it.
struct WatchPreparedCard: Codable, Equatable, Identifiable, Sendable {
    static let maxCards = 3
    static let maxFacts = 2

    /// The card's id (`PreparedCardID.rawValue`), sent back with a command.
    let id: String
    let headline: String
    /// The chips, as the lens words them.
    let chips: [CardSignal]
    /// Up to `maxFacts`.
    let facts: [CardFact]
    /// The primary action's label, as the phone names it ("Directions", "Text Ana", "Send report").
    let primaryLabel: String
    /// What the wrist can press, primary first: stage and directions. Later and Dismiss are always
    /// offered beside them.
    let buttons: [WatchPreparedCardButton]
    /// "To Ana · Messages", when there is a draft.
    let draftTo: String?
    /// The draft's text, when it may show on the wrist.
    let draftText: String?
    /// The card has a draft whose text is withheld on the wrist (Medical Compliance, or the budget).
    let draftWithheld: Bool
    /// After this the card is gone.
    let validUntil: Date

    func isLive(at now: Date) -> Bool { validUntil > now }

    /// The same card without its draft's text.
    func withoutDraftText() -> WatchPreparedCard {
        WatchPreparedCard(id: id, headline: headline, chips: chips, facts: facts, primaryLabel: primaryLabel,
                          buttons: buttons, draftTo: draftTo, draftText: nil,
                          draftWithheld: draftWithheld || draftText != nil, validUntil: validUntil)
    }
}

// MARK: - Codec

/// Property-list encoding with a hard byte budget. Over budget drops the cards' draft texts (the
/// phone still has them), then trailing cards, then trailing events (counted in `moreEvents`), and
/// is otherwise refused with a reason, never cut silently.
enum WatchTodayCodec {

    /// 8 KB: six items with titles and places and the weather come to well under 2 KB. Apple
    /// documents no limit for the application context; this is self-imposed, as GM's are.
    static let budgetBytes = 8 * 1024

    enum Refusal: Error, Equatable {
        case overBudget(bytes: Int, limit: Int)
        case encodingFailed
    }

    struct Encoded: Equatable {
        let data: Data
        let payload: WatchTodayPayload
    }

    static func encode(_ payload: WatchTodayPayload, budget: Int = budgetBytes) -> Result<Encoded, Refusal> {
        guard let data = plist(payload) else { return .failure(.encodingFailed) }
        if data.count <= budget { return .success(Encoded(data: data, payload: payload)) }
        var trimmed = payload
        var smallest = data.count
        // Draft texts first, from the last card up: the wrist still shows the card, and the phone
        // the message.
        for index in trimmed.cards.indices.reversed() where trimmed.cards[index].draftText != nil {
            trimmed.cards[index] = trimmed.cards[index].withoutDraftText()
            guard let attempt = plist(trimmed) else { return .failure(.encodingFailed) }
            smallest = attempt.count
            if attempt.count <= budget { return .success(Encoded(data: attempt, payload: trimmed)) }
        }
        while !trimmed.cards.isEmpty {
            trimmed.cards.removeLast()
            guard let attempt = plist(trimmed) else { return .failure(.encodingFailed) }
            smallest = attempt.count
            if attempt.count <= budget { return .success(Encoded(data: attempt, payload: trimmed)) }
        }
        while !trimmed.events.isEmpty {
            trimmed.events.removeLast()
            trimmed.moreEvents += 1
            guard let attempt = plist(trimmed) else { return .failure(.encodingFailed) }
            smallest = attempt.count
            if attempt.count <= budget { return .success(Encoded(data: attempt, payload: trimmed)) }
        }
        return .failure(.overBudget(bytes: smallest, limit: budget))
    }

    /// Nil for anything unreadable, and for a version this build does not know. An older version
    /// reads (Plan KT P4: version 1 has no cards).
    static func decode(_ data: Data) -> WatchTodayPayload? {
        guard let payload = try? PropertyListDecoder().decode(WatchTodayPayload.self, from: data),
              WatchTodayWire.readableVersions.contains(payload.version) else { return nil }
        return payload
    }

    private static func plist<T: Encodable>(_ value: T) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(value)
    }
}

// MARK: - Is it today?

/// What the watch can show from what it holds. Pure: the watch's clock and calendar are inputs.
enum WatchTodayFreshness: Equatable {
    /// Nothing from the phone yet.
    case absent
    /// "Today on Your Watch" is off on the phone.
    case settingOff
    /// The payload is for another day (yesterday's, usually).
    case stale
    case current(WatchTodayPayload)

    static func evaluate(_ payload: WatchTodayPayload?, now: Date, calendar: Calendar) -> WatchTodayFreshness {
        guard let payload else { return .absent }
        if payload.isSettingOff { return .settingOff }
        guard payload.day == WatchTodayDay(now, calendar: calendar) else { return .stale }
        return .current(payload)
    }
}

// MARK: - Which item is now

/// The items still to come at `now`, each marked. Pure, so the watch re-marks every minute without
/// asking the phone.
enum WatchTodayTimeline {

    enum Mark: Equatable {
        /// All day.
        case allDay
        /// Under way.
        case now
        /// The first timed item still to start.
        case next
        case later
    }

    struct Row: Equatable, Identifiable {
        let event: WatchTodayEvent
        let mark: Mark
        var id: String { event.id }
    }

    static func rows(_ events: [WatchTodayEvent], now: Date) -> [Row] {
        var nextMarked = false
        return events.compactMap { event in
            if event.isAllDay { return Row(event: event, mark: .allDay) }
            guard event.end > now else { return nil }
            if event.start <= now { return Row(event: event, mark: .now) }
            if !nextMarked {
                nextMarked = true
                return Row(event: event, mark: .next)
            }
            return Row(event: event, mark: .later)
        }
    }
}

// MARK: - When to look again

enum WatchTodaySchedule {

    /// The phone looks again on foreground no more often than this.
    static let foregroundInterval: TimeInterval = 15 * 60

    /// A few seconds past the next local midnight, so the new day has begun when the phone looks.
    static func nextMidnight(after now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        return tomorrow.addingTimeInterval(5)
    }

    /// Whether a refresh is due: nothing held, the held day is not today, or the last look is
    /// older than `interval`.
    static func isRefreshDue(lastGeneratedAt: Date?, now: Date, calendar: Calendar,
                             interval: TimeInterval = foregroundInterval) -> Bool {
        guard let last = lastGeneratedAt else { return true }
        guard calendar.isDate(last, inSameDayAs: now) else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }
}
