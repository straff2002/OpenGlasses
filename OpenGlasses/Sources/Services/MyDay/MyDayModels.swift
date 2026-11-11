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

// `MyDayUrgency` lives in `Shared/PreparedCard.swift` (Plan KT): a prepared card carries it, and
// the watch decodes prepared cards.

enum MyDaySource: String, CaseIterable, Equatable, Sendable {
    case calendar
    case digest
    case reminders
    case travel
    case weather
    /// The wearer's goals (Plan IW P2): at most one row, the open step due soonest.
    case goals

    var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .digest: "Actionable Updates"
        case .reminders: "Reminders"
        case .travel: "Travel Time"
        case .weather: "Weather"
        case .goals: "Goals"
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
    /// The event's people, organiser included, from EventKit (Plan KT §9.3). The same for Google,
    /// iCloud and Exchange calendars. Empty for an event with nobody else on it, and from every
    /// source that does not read attendees — defaulted, so those callers are unchanged.
    var attendees: [CalendarPerson] = []
}

/// One person on a calendar event (Plan KT §9.3), mapped from `EKParticipant` by
/// `CalendarAttendeeMapper`. Rooms and resources are not people and never become one.
struct CalendarPerson: Codable, Equatable, Hashable, Sendable {
    enum Response: String, Codable, Equatable, Sendable {
        case accepted
        case declined
        case tentative
        case pending
        case unknown
    }

    /// As the calendar gives it; nil when it gives none.
    let name: String?
    /// Lower-cased, from the participant's `mailto:` URL; nil when it has none.
    let email: String?
    let isOrganizer: Bool
    /// The wearer (`EKParticipant.isCurrentUser`).
    let isSelf: Bool
    let response: Response

    init(name: String?, email: String?, isOrganizer: Bool = false, isSelf: Bool = false,
         response: Response = .unknown) {
        self.name = name
        self.email = email
        self.isOrganizer = isOrganizer
        self.isSelf = isSelf
        self.response = response
    }
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
    /// The report the summary was phrased from, for surfaces that draw numbers rather than speak a
    /// sentence (the watch's Today weather, Plan KS). Nil from sources that have no report.
    var report: WeatherReport? = nil
}

/// What one My Day refresh gathered, before the composer ranked and capped it (Plan KS). The
/// watch's Today screens need the calendar as a calendar — start, end, all-day, place — which the
/// composed card rows no longer carry.
struct MyDayGathered: Equatable, Sendable {
    let generatedAt: Date
    /// The phone was locked, so nothing content-bearing was read.
    let locked: Bool
    let calendarIncluded: Bool
    let events: [MyDayCalendarEvent]
    let calendarState: MyDaySourceState?
    let weatherIncluded: Bool
    let weather: MyDayWeather?
    let weatherState: MyDaySourceState?
}

enum MyDayTransportMode: String, CaseIterable, Codable, Equatable, Sendable {
    case walking
    case driving
    case transit

    var displayName: String {
        switch self {
        case .walking: String(localized: "Walking")
        case .driving: String(localized: "Driving")
        case .transit: String(localized: "Transit")
        }
    }

    /// English name for the composed, spoken My Day lines; `displayName` is the localized
    /// settings label.
    var spokenName: String {
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
        case .currentLocation: String(localized: "Current Location")
        case .home: String(localized: "Home")
        case .work: String(localized: "Work")
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
    /// Plan IW P2. On by default; with no goals the source simply has nothing to add.
    let goals: Bool

    init(calendar: Bool, reminders: Bool, weather: Bool, travel: Bool, digest: Bool,
         goals: Bool = true) {
        self.calendar = calendar
        self.reminders = reminders
        self.weather = weather
        self.travel = travel
        self.digest = digest
        self.goals = goals
    }

    static var current: Self {
        let calendar = Config.myDayCalendarIncluded
        return .init(
            calendar: calendar,
            reminders: Config.myDayRemindersIncluded,
            weather: Config.myDayWeatherIncluded,
            travel: calendar && Config.myDayTravelIncluded,
            digest: Config.myDayDigestIncluded,
            goals: Config.myDayGoalsIncluded
        )
    }

    static let all = Self(
        calendar: true,
        reminders: true,
        weather: true,
        travel: true,
        digest: true,
        goals: true
    )
}

/// One goal's next step, as My Day needs it (Plan IW P2). Only steps with a date reach the card —
/// the step's own, else the goal's — because the card is a day, and an undated step is not part
/// of one (the same rule the card keeps for undated reminders).
struct MyDayGoalStep: Equatable, Sendable {
    let goalID: UUID
    let stepID: UUID
    let goalTitle: String
    let stepTitle: String
    let dueAt: Date
}

struct MyDayInputs: Equatable, Sendable {
    let events: [MyDayCalendarEvent]
    let reminders: [MyDayReminder]
    let weather: MyDayWeather?
    let travel: MyDayTravelEstimate?
    let digestUpdates: [MyDayDigestUpdate]
    /// Each active goal's next dated step; the composer shows the soonest due, at most one.
    let goalSteps: [MyDayGoalStep]
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
        goalSteps: [MyDayGoalStep] = [],
        sourceStates: [MyDaySourceState],
        dismissals: [String: String] = [:]
    ) {
        self.events = events
        self.reminders = reminders
        self.weather = weather
        self.travel = travel
        self.digestUpdates = digestUpdates
        self.goalSteps = goalSteps
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
