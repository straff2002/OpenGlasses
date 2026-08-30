import XCTest
@testable import OpenGlasses

final class MyDayComposerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, day: Int = 30, minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 8, day: day, hour: hour, minute: minute).date!
    }

    private func event(_ id: String, at hour: Int, minute: Int = 0, day: Int = 30) -> MyDayCalendarEvent {
        let start = date(hour, day: day, minute: minute)
        return .init(id: id, title: "Event \(id)", startDate: start,
                     endDate: start.addingTimeInterval(3600), isAllDay: false, location: nil)
    }

    private func reminder(_ id: String, due: Date?, priority: Int = 0) -> MyDayReminder {
        .init(id: id, title: "Reminder \(id)", dueDate: due, hasTime: due != nil, priority: priority)
    }

    private func inputs(
        events: [MyDayCalendarEvent] = [],
        reminders: [MyDayReminder] = [],
        weather: MyDayWeather? = nil,
        travel: MyDayTravelEstimate? = nil,
        states: [MyDaySourceState] = MyDaySource.allCases.map(MyDaySourceState.available)
    ) -> MyDayInputs {
        .init(events: events, reminders: reminders, weather: weather, travel: travel,
              sourceStates: states)
    }

    func testPriorityPolicyPutsImmediateCommitmentThenOverdueAndDueItems() {
        let now = date(9)
        let snapshot = MyDayComposer(calendar: calendar, locale: Locale(identifier: "en_NZ"))
            .compose(inputs: inputs(
                events: [event("later", at: 14), event("imminent", at: 9, minute: 15)],
                reminders: [
                    reminder("someday", due: nil),
                    reminder("due", due: date(10)),
                    reminder("overdue", due: date(8))
                ],
                weather: .init(summary: "Rain this afternoon.", isDecisionRelevant: true)
            ), now: now)

        XCTAssertEqual(snapshot.items.map(\.id.rawValue),
                       ["imminent", "overdue", "due", "current", "later", "someday"])
        XCTAssertEqual(snapshot.items.first?.urgency, .immediate)
        XCTAssertEqual(snapshot.items.count, 6)
    }

    func testRoutineWeatherNeverDisplacesHigherPriorityItems() {
        let snapshot = MyDayComposer(calendar: calendar, maxItems: 2).compose(
            inputs: inputs(
                events: [event("soon", at: 9, minute: 10)],
                reminders: [reminder("late", due: date(8))],
                weather: .init(summary: "Clear sky.", isDecisionRelevant: false)
            ),
            now: date(9)
        )
        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["soon", "late"])
    }

    func testLeaveByRanksAfterImminentEventAndBeforeOverdueReminder() {
        let now = date(9)
        let later = event("dentist", at: 10)
        let travel = MyDayTravelEstimate(
            eventID: later.id,
            eventTitle: "Dentist",
            destination: "Queen Street Dental",
            eventStart: later.startDate,
            travelDuration: 20 * 60,
            bufferDuration: 10 * 60,
            leaveAt: date(9, minute: 30),
            mode: .walking
        )
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(
                events: [event("standup", at: 9, minute: 15), later],
                reminders: [reminder("overdue", due: date(8))],
                travel: travel
            ),
            now: now
        )

        XCTAssertEqual(snapshot.items.prefix(3).map(\.id.rawValue),
                       ["standup", "leave-by:dentist", "overdue"])
        XCTAssertEqual(snapshot.items[1].kind, .leaveBy)
        XCTAssertEqual(snapshot.items[1].actions, [.directions])
        XCTAssertTrue(snapshot.headline.contains("leave by"))
    }

    func testStableIdentityKeepsSimilarlyNamedEventAndReminder() {
        let sharedTitle = "Dentist"
        let start = date(11)
        let event = MyDayCalendarEvent(id: "event-1", title: sharedTitle, startDate: start,
                                       endDate: start.addingTimeInterval(3600), isAllDay: false, location: nil)
        let reminder = MyDayReminder(id: "reminder-1", title: sharedTitle, dueDate: date(10),
                                     hasTime: true, priority: 0)
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [event], reminders: [reminder]), now: date(9))

        XCTAssertEqual(snapshot.items.filter { $0.title == sharedTitle }.count, 2)
        XCTAssertEqual(Set(snapshot.items.map(\.id.source)), [.calendar, .reminders])
    }

    func testTiesUseStableID() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(reminders: [
                reminder("z", due: date(10)),
                reminder("a", due: date(10))
            ]),
            now: date(9)
        )
        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["a", "z"])
    }

    func testPartialAvailabilityIsPreservedAndSorted() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(states: [
                .unavailable(.weather, message: "Offline"),
                .denied(.calendar, message: "Calendar access is off"),
                .available(.reminders)
            ]),
            now: date(9)
        )
        XCTAssertEqual(snapshot.sourceStates.map(\.source), [.calendar, .reminders, .weather])
        XCTAssertEqual(snapshot.sourceStates.first?.availability, .denied)
    }

    func testEveningIncludesFirstTomorrowCommitment() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [event("second", at: 11, day: 31), event("first", at: 8, day: 31)]),
            now: date(20)
        )
        XCTAssertEqual(snapshot.period, .evening)
        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["first"])
        XCTAssertTrue(snapshot.items[0].detail?.contains("Tomorrow") == true)
    }

    func testAllDayEventIsUpcomingRatherThanImmediate() {
        let start = date(0)
        let allDay = MyDayCalendarEvent(id: "holiday", title: "Holiday", startDate: start,
                                        endDate: date(0, day: 31), isAllDay: true, location: nil)
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [allDay]), now: date(9))
        XCTAssertEqual(snapshot.items.first?.urgency, .upcoming)
        XCTAssertEqual(snapshot.items.first?.detail, "All day")
    }

    func testDateOnlyReminderDueTodayIsNotOverdue() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(reminders: [
                .init(id: "today", title: "Water plants", dueDate: date(0), hasTime: false, priority: 0)
            ]),
            now: date(9)
        )
        XCTAssertEqual(snapshot.items.first?.detail, "Due today")
        XCTAssertEqual(snapshot.items.first?.urgency, .upcoming)
    }

    func testSpokenFormatterUsesBoundedSnapshotAndNamesUnavailableSource() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(
                reminders: [reminder("one", due: date(10))],
                states: [.available(.reminders), .denied(.calendar), .unavailable(.weather)]
            ),
            now: date(9)
        )
        let spoken = MyDaySpokenFormatter().format(snapshot)
        XCTAssertTrue(spoken.contains("Reminder one"))
        XCTAssertTrue(spoken.contains("Calendar and Weather are unavailable."))
        XCTAssertLessThan(spoken.count, 500)
    }
}
