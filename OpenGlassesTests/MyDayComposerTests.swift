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
        digestUpdates: [MyDayDigestUpdate] = [],
        states: [MyDaySourceState] = MyDaySource.allCases.map(MyDaySourceState.available),
        dismissals: [String: String] = [:]
    ) -> MyDayInputs {
        .init(events: events, reminders: reminders, weather: weather, travel: travel,
              digestUpdates: digestUpdates,
              sourceStates: states,
              dismissals: dismissals)
    }

    private func allDayEvent(_ id: String = "holiday", title: String = "Holiday") -> MyDayCalendarEvent {
        MyDayCalendarEvent(id: id, title: title, startDate: date(0),
                           endDate: date(0, day: 31), isAllDay: true, location: nil)
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

    func testEveningIncludesFirstTomorrowCommitmentAndOnePreparationCue() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [event("second", at: 11, day: 31), event("first", at: 8, day: 31)]),
            now: date(20)
        )
        XCTAssertEqual(snapshot.period, .evening)
        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["first", "prepare:first"])
        XCTAssertTrue(snapshot.items[0].detail?.contains("Tomorrow") == true)
        XCTAssertEqual(snapshot.items[1].kind, .preparation)
        XCTAssertTrue(snapshot.headline.contains("Tomorrow starts with Event first"))
        XCTAssertTrue(snapshot.headline.first?.isUppercase == true,
                      "headline is a sentence and must start capitalized")
    }

    /// "X's birthday, all day" reads as parody — an all-day event's headline names the event and
    /// lets the missing time say the rest. The card detail row keeps the qualifier.
    func testEveningHeadlineForAllDayEventOmitsAllDay() {
        let birthday = MyDayCalendarEvent(
            id: "bday", title: "Mike's birthday",
            startDate: date(0, day: 31), endDate: date(23, day: 31, minute: 59),
            isAllDay: true, location: nil)
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [birthday]),
            now: date(20)
        )
        XCTAssertTrue(snapshot.headline.contains("Tomorrow includes Mike's birthday"))
        XCTAssertFalse(snapshot.headline.contains("all day"))
        XCTAssertTrue(snapshot.items[0].detail?.contains("all day") == true,
                      "the detail row keeps the schedule qualifier")
    }

    func testDigestUpdatesAreCappedAtTwoAndOnlyFillRemainingCapacity() {
        let updates = (1...3).map {
            MyDayDigestUpdate(
                id: "update-\($0)",
                title: "Update \($0)",
                detail: "Agent",
                createdAt: date(8, minute: $0),
                urgency: .important
            )
        }
        let snapshot = MyDayComposer(calendar: calendar, maxItems: 3).compose(
            inputs: inputs(
                reminders: [reminder("due", due: date(10))],
                digestUpdates: updates
            ),
            now: date(9)
        )

        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["due", "update-1", "update-2"])
        XCTAssertEqual(snapshot.items.filter { $0.kind == .update }.count, 2)
        XCTAssertEqual(snapshot.items.last?.actions, [.dismiss])
    }

    func testAllDayEventIsUpcomingRatherThanImmediate() {
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [allDayEvent()]), now: date(9))
        XCTAssertEqual(snapshot.items.first?.urgency, .upcoming)
        XCTAssertEqual(snapshot.items.first?.detail, "All day")
    }

    /// "I know it's this bloke's birthday, but I don't need to know it all day." An all-day event
    /// today is briefing information: worth a slot over breakfast, noise by lunchtime, because
    /// there is nothing to do about it and nothing that changes.
    func testATodayAllDayEventHoldsASlotInTheMorningOnly() {
        let composer = MyDayComposer(calendar: calendar)

        let morning = composer.compose(inputs: inputs(events: [allDayEvent()]), now: date(9))
        XCTAssertEqual(morning.period, .morning)
        XCTAssertEqual(morning.items.map(\.id.rawValue), ["holiday"])

        for hour in [14, 20] {
            let later = composer.compose(inputs: inputs(events: [allDayEvent()]), now: date(hour))
            XCTAssertFalse(later.items.contains { $0.id.rawValue == "holiday" },
                           "The all-day row is still holding a slot at \(hour):00")
        }
    }

    /// The headline counts what the card is willing to show, so the sentence and the rows tell the
    /// same story rather than the headline insisting on a commitment with no row behind it.
    func testTheHeadlineCountsATodayAllDayEventOnlyWhileItHasASlot() {
        let composer = MyDayComposer(calendar: calendar)

        let morning = composer.compose(inputs: inputs(events: [allDayEvent()]), now: date(9))
        XCTAssertFalse(morning.headline.contains("clear"),
                       "A morning with an all-day event is not a clear day")

        let afternoon = composer.compose(inputs: inputs(events: [allDayEvent()]), now: date(14))
        XCTAssertTrue(afternoon.items.isEmpty)
        XCTAssertTrue(afternoon.headline.contains("clear"),
                      "The headline still counts a commitment the card refuses to show")
    }

    /// Tomorrow's all-day events are a different question — the evening preview is forward-looking,
    /// and this is the guard that the morning-only rule did not reach into it.
    func testTomorrowsAllDayEventStillPreviewsInTheEvening() {
        let tomorrow = MyDayCalendarEvent(id: "trip", title: "Trip", startDate: date(0, day: 31),
                                          endDate: date(0, day: 32), isAllDay: true, location: nil)
        let snapshot = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [tomorrow]), now: date(20))
        XCTAssertEqual(snapshot.period, .evening)
        XCTAssertEqual(snapshot.items.map(\.id.rawValue), ["trip", "prepare:trip"])
        XCTAssertTrue(snapshot.items[0].detail?.contains("all day") == true)
    }

    // MARK: - Cleared rows

    /// The invariant the whole dismissal design is for: clearing a row hides it from the card and
    /// destroys nothing. The event is still in the compose inputs — still gathered, still there for
    /// the headline and for travel — and only the ranked rows lose it.
    func testDismissingAnEventHidesTheRowAndKeepsTheEvent() {
        let meeting = event("standup", at: 10)
        let composed = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [meeting]), now: date(9))
        guard let row = composed.items.first(where: { $0.id.rawValue == "standup" }) else {
            return XCTFail("The event did not compose into a row to begin with")
        }

        let dismissals = [row.id.dismissalKey: row.dismissalFingerprint]
        let after = MyDayComposer(calendar: calendar).compose(
            inputs: inputs(events: [meeting], dismissals: dismissals), now: date(9))

        XCTAssertFalse(after.items.contains { $0.id.rawValue == "standup" },
                       "The cleared row is still on the card")
        // The event itself never left: the same inputs still carry it, and the headline still
        // counts the commitment, because clearing a row is a statement about a card.
        XCTAssertTrue(after.headline.contains("1"), "The event was erased, not just un-shown")
    }

    /// A cleared row frees its slot rather than leaving a hole — which is what a wearer clearing
    /// clutter is actually asking for.
    func testAClearedRowFreesItsSlotForTheNextOne() {
        let events = (0..<7).map { event("e\($0)", at: 9 + $0) }
        let composer = MyDayComposer(calendar: calendar)
        let full = composer.compose(inputs: inputs(events: events), now: date(8))
        XCTAssertEqual(full.items.count, 6, "The fixture should be at the item cap")

        guard let first = full.items.first else { return XCTFail("No rows") }
        let after = composer.compose(
            inputs: inputs(events: events,
                           dismissals: [first.id.dismissalKey: first.dismissalFingerprint]),
            now: date(8))
        XCTAssertEqual(after.items.count, 6)
        XCTAssertFalse(after.items.contains { $0.id == first.id })
    }

    /// A dismissal is pinned to the row's content as well as its id, so a rescheduled meeting is
    /// new news and comes back rather than staying cleared under the same EventKit identifier.
    func testARescheduledEventComesBackAfterBeingCleared() {
        let original = event("standup", at: 10)
        let composer = MyDayComposer(calendar: calendar)
        guard let row = composer.compose(inputs: inputs(events: [original]), now: date(9))
            .items.first else { return XCTFail("No row") }
        let dismissals = [row.id.dismissalKey: row.dismissalFingerprint]

        let moved = event("standup", at: 15)
        let after = composer.compose(inputs: inputs(events: [moved], dismissals: dismissals),
                                     now: date(9))
        XCTAssertTrue(after.items.contains { $0.id.rawValue == "standup" },
                      "A rescheduled event stayed hidden under a stale dismissal")
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
