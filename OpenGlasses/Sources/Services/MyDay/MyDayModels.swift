import Foundation

enum MyDayPeriod: String, Equatable, Sendable {
    case morning
    case daytime
    case evening
}

enum MyDayKind: String, Equatable, Sendable {
    case event
    case leaveBy
    case preparation
    case reminder
    case update
    case weather
}

enum MyDayUrgency: Int, Comparable, Equatable, Sendable {
    case routine = 0
    case upcoming = 1
    case important = 2
    case immediate = 3

    static func < (lhs: MyDayUrgency, rhs: MyDayUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MyDaySource: String, CaseIterable, Equatable, Sendable {
    case calendar
    case digest
    case reminders
    case travel
    case weather

    var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .digest: "Actionable Updates"
        case .reminders: "Reminders"
        case .travel: "Travel Time"
        case .weather: "Weather"
        }
    }
}

enum MyDaySourceAvailability: Equatable, Sendable {
    case available
    case denied
    case unavailable
}

struct MyDaySourceState: Identifiable, Equatable, Sendable {
    let source: MyDaySource
    let availability: MyDaySourceAvailability
    let message: String?

    var id: MyDaySource { source }
}

struct MyDayItemID: Hashable, Comparable, Sendable {
    let source: MyDaySource
    let rawValue: String

    static func < (lhs: MyDayItemID, rhs: MyDayItemID) -> Bool {
        if lhs.source.rawValue != rhs.source.rawValue {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        return lhs.rawValue < rhs.rawValue
    }
}

enum MyDayAction: Hashable, Sendable {
    case open
    case complete
    case directions
    case dismiss
}

struct MyDayItem: Identifiable, Equatable, Sendable {
    let id: MyDayItemID
    let kind: MyDayKind
    let title: String
    let detail: String?
    let dueAt: Date?
    let urgency: MyDayUrgency
    let actions: Set<MyDayAction>
}

struct MyDaySnapshot: Equatable, Sendable {
    let generatedAt: Date
    let period: MyDayPeriod
    let headline: String
    /// What the card and every budgeted consumer (the spoken briefing, the digest, the HUD) draw
    /// from: ranked, cleared rows removed, capped.
    let items: [MyDayItem]
    /// What the cap left out, still ranked and still the wearer's day.
    ///
    /// It exists because the cap used to be *invisible*: clearing a row let the next-ranked one
    /// appear, which reads as items materialising out of nowhere rather than as a list that was
    /// always longer than the card. The full-day surface shows these; nothing that speaks or
    /// summarises does, because that is what the cap is for.
    let overflowItems: [MyDayItem]
    let sourceStates: [MyDaySourceState]
    let nextRefreshAt: Date?

    /// Everything the day actually holds, in rank order — what "See all N" must count and open.
    var allItems: [MyDayItem] { items + overflowItems }

    init(generatedAt: Date, period: MyDayPeriod, headline: String, items: [MyDayItem],
         overflowItems: [MyDayItem] = [], sourceStates: [MyDaySourceState],
         nextRefreshAt: Date?) {
        self.generatedAt = generatedAt
        self.period = period
        self.headline = headline
        self.items = items
        self.overflowItems = overflowItems
        self.sourceStates = sourceStates
        self.nextRefreshAt = nextRefreshAt
    }
}

struct MyDayCalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
}

struct MyDayReminder: Equatable, Sendable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
    let priority: Int
    /// The Reminders list this came from ("Shopping", "Work").
    ///
    /// Carried because a day's reminders arrive from every list at once and, without it, a row is
    /// just a title with no way to tell which part of your life it belongs to. It is the wearer's
    /// own words: it belongs on the row and in what VoiceOver reads, and in no log line.
    let listName: String?

    init(id: String, title: String, dueDate: Date?, hasTime: Bool, priority: Int,
         listName: String? = nil) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.hasTime = hasTime
        self.priority = priority
        self.listName = listName
    }
}

struct MyDayWeather: Equatable, Sendable {
    let summary: String
    let isDecisionRelevant: Bool
}

enum MyDayTransportMode: String, CaseIterable, Codable, Equatable, Sendable {
    case walking
    case driving
    case transit

    var displayName: String {
        switch self {
        case .walking: "Walking"
        case .driving: "Driving"
        case .transit: "Transit"
        }
    }
}

enum MyDayTravelOrigin: String, CaseIterable, Codable, Equatable, Sendable {
    case currentLocation
    case home
    case work

    var displayName: String {
        switch self {
        case .currentLocation: "Current Location"
        case .home: "Home"
        case .work: "Work"
        }
    }
}

struct MyDayTravelEstimate: Equatable, Sendable {
    let eventID: String
    let eventTitle: String
    let destination: String
    let eventStart: Date
    let travelDuration: TimeInterval
    let bufferDuration: TimeInterval
    let leaveAt: Date
    let mode: MyDayTransportMode
}

struct MyDayDigestUpdate: Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let createdAt: Date
    let urgency: MyDayUrgency
}

struct MyDaySourceSelection: Equatable, Sendable {
    let calendar: Bool
    let reminders: Bool
    let weather: Bool
    let travel: Bool
    let digest: Bool

    static var current: Self {
        let calendar = Config.myDayCalendarIncluded
        return .init(
            calendar: calendar,
            reminders: Config.myDayRemindersIncluded,
            weather: Config.myDayWeatherIncluded,
            travel: calendar && Config.myDayTravelIncluded,
            digest: Config.myDayDigestIncluded
        )
    }

    static let all = Self(
        calendar: true,
        reminders: true,
        weather: true,
        travel: true,
        digest: true
    )
}

struct MyDayInputs: Equatable, Sendable {
    let events: [MyDayCalendarEvent]
    let reminders: [MyDayReminder]
    let weather: MyDayWeather?
    let travel: MyDayTravelEstimate?
    let digestUpdates: [MyDayDigestUpdate]
    let sourceStates: [MyDaySourceState]
    /// Rows the wearer cleared from today's card, as storage key → fingerprint. Note what this is
    /// *not*: it never reaches a source, so a cleared row is still gathered, still counted where
    /// counting is honest, and still in `events`/`reminders` here. Only the ranking drops it.
    let dismissals: [String: String]

    init(
        events: [MyDayCalendarEvent],
        reminders: [MyDayReminder],
        weather: MyDayWeather?,
        travel: MyDayTravelEstimate? = nil,
        digestUpdates: [MyDayDigestUpdate] = [],
        sourceStates: [MyDaySourceState],
        dismissals: [String: String] = [:]
    ) {
        self.events = events
        self.reminders = reminders
        self.weather = weather
        self.travel = travel
        self.digestUpdates = digestUpdates
        self.sourceStates = sourceStates
        self.dismissals = dismissals
    }
}

struct MyDaySourceLoad<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let state: MyDaySourceState
}

extension MyDaySourceState {
    static func available(_ source: MyDaySource) -> Self {
        .init(source: source, availability: .available, message: nil)
    }

    static func denied(_ source: MyDaySource, message: String? = nil) -> Self {
        .init(source: source, availability: .denied, message: message)
    }

    static func unavailable(_ source: MyDaySource, message: String? = nil) -> Self {
        .init(source: source, availability: .unavailable, message: message)
    }
}
