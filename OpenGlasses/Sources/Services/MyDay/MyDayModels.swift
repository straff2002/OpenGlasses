import Foundation

enum MyDayPeriod: String, Equatable, Sendable {
    case morning
    case daytime
    case evening
}

enum MyDayKind: String, Equatable, Sendable {
    case event
    case reminder
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
    case reminders
    case weather

    var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
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
    let items: [MyDayItem]
    let sourceStates: [MyDaySourceState]
    let nextRefreshAt: Date?
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
}

struct MyDayWeather: Equatable, Sendable {
    let summary: String
    let isDecisionRelevant: Bool
}

struct MyDayInputs: Equatable, Sendable {
    let events: [MyDayCalendarEvent]
    let reminders: [MyDayReminder]
    let weather: MyDayWeather?
    let sourceStates: [MyDaySourceState]
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
