import Foundation
@testable import OpenGlasses

/// Invented people, places and numbers for the prepared-card tests (Plan KT P0). Nothing here is
/// anyone real: `example.com` addresses, `555-01xx` numbers, "Example Street".
enum CardFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 24-hour times ("18:15"), so expectations read plainly.
    static let locale = Locale(identifier: "en_GB")

    /// 2026-11-12 at `hour:minute:second`, UTC.
    static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, day: Int = 12) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: day,
                       hour: hour, minute: minute, second: second).date!
    }

    static let me = CalendarPerson(name: "Sam Example", email: "sam@example.com", isSelf: true,
                                   response: .accepted)
    static let ana = CalendarPerson(name: "Ana Example", email: "ana@example.com", response: .accepted)
    static let tom = CalendarPerson(name: "Tom Example", email: "tom@example.com", isOrganizer: true,
                                    response: .accepted)
    static let lee = CalendarPerson(name: "Lee Example", email: "lee@example.com")
    static let kim = CalendarPerson(name: "Kim Example", email: "kim@example.com")

    static func event(_ id: String, _ title: String, start: Date, minutes: Double = 60,
                      location: String? = nil, attendees: [CalendarPerson] = []) -> MyDayCalendarEvent {
        MyDayCalendarEvent(id: id, title: title, startDate: start,
                           endDate: start.addingTimeInterval(minutes * 60), isAllDay: false,
                           location: location, attendees: attendees)
    }

    /// The gig: 19:00–21:00 at the hall, with Ana. Leave by 18:15 (30 min driving + 15 buffer).
    static let gig = event("gig-1", "Gig at the Example Hall", start: at(19), minutes: 120,
                           location: "1 Example Street", attendees: [me, ana])

    static func travel(for event: MyDayCalendarEvent, travelMinutes: Double = 30,
                       bufferMinutes: Double = 15, mode: MyDayTransportMode = .driving) -> MyDayTravelEstimate {
        let travel = travelMinutes * 60
        let buffer = bufferMinutes * 60
        return MyDayTravelEstimate(eventID: event.id, eventTitle: event.title,
                                   destination: event.location ?? "Somewhere", eventStart: event.startDate,
                                   travelDuration: travel, bufferDuration: buffer,
                                   leaveAt: event.startDate.addingTimeInterval(-(travel + buffer)), mode: mode)
    }

    static func myDay(events: [MyDayCalendarEvent] = [], reminders: [MyDayReminder] = [],
                      weather: MyDayWeather? = nil, travel: MyDayTravelEstimate? = nil) -> MyDayInputs {
        MyDayInputs(events: events, reminders: reminders, weather: weather, travel: travel,
                    sourceStates: MyDaySource.allCases.map(MyDaySourceState.available))
    }

    static func gigInputs(distance: Double? = 5_000, contacts: [String: CardContact] = [:],
                          attendees: [CalendarPerson]? = nil) -> CardInputs {
        var event = gig
        if let attendees { event.attendees = attendees }
        return CardInputs(myDay: myDay(events: [event], travel: travel(for: event)),
                          travelDistanceMeters: distance, contacts: contacts)
    }

    static var settings: PreparedCardSettings {
        var settings = PreparedCardSettings()
        settings.draftLanguage = "en-GB"
        return settings
    }

    static var rules: PreparedCardRules {
        PreparedCardRules(calendar: calendar, locale: locale, templates: CatalogDraftTemplates())
    }

    static var joiner: PreparedCardJoiner { PreparedCardJoiner(calendar: calendar, locale: locale) }

    // MARK: Jobs

    static let job = CardJob(id: "job-a", jobReference: "1005", customer: "Hana Example",
                             address: "14 Example Street", phone: "555-0199", scheduledFor: at(10))

    static func jobTravel(distance: Double? = 5_000) -> CardJobTravel {
        CardJobTravel(jobID: job.id, travelDuration: 25 * 60, leaveAt: at(9, 30), mode: .driving,
                      distanceMeters: distance)
    }

    static func session(_ id: String, ended: Date?, reportSent: Bool = false, signedOff: Bool = false,
                        unsentParts: Int = 0, cancelled: Bool = false) -> JobDaySession {
        JobDaySession(id: id, jobReference: "100\(id.suffix(1))", customer: "Example Customer",
                      siteHeadline: nil, startedAt: at(8), endedAt: ended, isPaused: false,
                      cancelled: cancelled, reportSent: reportSent, signedOff: signedOff,
                      openPartsRequests: unsentParts, unsentPartsRequests: unsentParts)
    }

    static func jobInputs(job: CardJob = job, travel: CardJobTravel? = jobTravel(),
                          sessions: [JobDaySession] = [], signOffRequired: Bool = false,
                          wearer: CardWearer = CardWearer(name: "Sam Example", company: "Example Plumbing")) -> CardInputs {
        CardInputs(myDay: myDay(),
                   jobs: CardJobFacts(upcoming: [job], sessions: sessions, signOffRequired: signOffRequired,
                                      travel: travel),
                   wearer: wearer)
    }

    /// A finished card for joiner tests, built without a rule.
    static func card(_ kind: PreparedCardKind, _ occurrence: String, urgency: MyDayUrgency = .upcoming,
                     dueAt: Date? = nil, validUntil: Date = at(23), absorbs: [CardRowID] = [],
                     draft: PreparedDraft? = nil) -> RuledCard {
        RuledCard(card: PreparedCard(
            id: PreparedCardID(kind: kind, occurrence: occurrence), headline: "Card \(occurrence)",
            subject: nil, signals: [CardSignal(source: .calendar, text: "10:00")], facts: [],
            primary: .dismiss, draft: draft, urgency: urgency, dueAt: dueAt, validUntil: validUntil,
            absorbs: absorbs))
    }

    static func item(_ source: MyDaySource, _ raw: String) -> MyDayItem {
        MyDayItem(id: MyDayItemID(source: source, rawValue: raw), kind: .event, title: raw, detail: nil,
                  dueAt: nil, urgency: .upcoming, actions: [.open])
    }
}
