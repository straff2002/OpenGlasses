import XCTest
@testable import OpenGlasses

/// Plan KT P0 — the personal kinds, a table per rule: each boundary the plan names, on both sides.
final class PreparedCardRulesTests: XCTestCase {
    private typealias F = CardFixtures
    private let rules = F.rules
    private let settings = F.settings

    // MARK: - Leave by: from 90 min before leave-by until the event starts

    func testLeaveByAppearsFromNinetyMinutesBeforeLeaveByUntilTheStart() {
        // Leave-by is 18:15, so the window opens at 16:45 and closes at 19:00.
        let table: [(Date, Bool)] = [
            (F.at(16, 44, 59), false),
            (F.at(16, 45), true),
            (F.at(18, 15), true),
            (F.at(18, 59, 59), true),
            (F.at(19), false),
        ]
        for (now, appears) in table {
            let card = rules.leaveBy(F.gigInputs(distance: nil), now: now, settings: settings)
            XCTAssertEqual(card != nil, appears, "at \(now)")
        }
    }

    func testLeaveByCardCarriesTheRuleFactsAndAbsorbsTheEventAndLeaveByRows() throws {
        let ruled = try XCTUnwrap(rules.leaveBy(F.gigInputs(distance: nil), now: F.at(17), settings: settings))
        let card = ruled.card
        XCTAssertEqual(card.id.rawValue, "leaveBy:gig-1:2026-11-12")
        XCTAssertEqual(card.headline, "Leave by 18:15")
        XCTAssertEqual(card.subject, "Gig at the Example Hall")
        XCTAssertEqual(card.facts.map(\.value).first, "18:15")
        XCTAssertEqual(card.facts.last?.value, "18:45")
        XCTAssertEqual(card.primary, .directions(destination: "1 Example Street", mode: .driving))
        XCTAssertEqual(card.validUntil, F.at(19))
        XCTAssertEqual(card.urgency, .upcoming)
        XCTAssertEqual(Set(card.absorbs), [CardRowID(source: "calendar", rawValue: "gig-1"),
                                           CardRowID(source: "travel", rawValue: "leave-by:gig-1")])
        XCTAssertEqual(ruled.weatherWindow, DateInterval(start: F.at(19), end: F.at(21)))
    }

    func testLeaveByUrgencyClimbsAsLeaveByNears() {
        let table: [(Date, MyDayUrgency)] = [
            (F.at(17), .upcoming),       // 75 min out
            (F.at(17, 15), .important),  // 60 min
            (F.at(18, 5), .immediate),   // 10 min
            (F.at(18, 30), .immediate),  // past leave-by: "Leave now"
        ]
        for (now, urgency) in table {
            XCTAssertEqual(rules.leaveBy(F.gigInputs(distance: nil), now: now, settings: settings)?.card.urgency,
                           urgency, "at \(now)")
        }
        XCTAssertEqual(rules.leaveBy(F.gigInputs(distance: nil), now: F.at(18, 30), settings: settings)?.card.headline,
                       "Leave now")
    }

    func testLeaveByDraftsATextWhenTheOneOtherPersonHasANumber() throws {
        let contacts = ["ana@example.com": CardContact(name: "Ana Example", phone: "555-0142")]
        let card = try XCTUnwrap(rules.leaveBy(F.gigInputs(distance: nil, contacts: contacts), now: F.at(18),
                                               settings: settings)?.card)
        let draft = try XCTUnwrap(card.draft)
        XCTAssertEqual(draft.channel, .messages)
        XCTAssertEqual(draft.recipient, DraftRecipient(name: "Ana Example", addresses: ["555-0142"],
                                                      source: .calendarAttendee))
        // Leaving at 18:15 (later than now), 30 min on the road.
        XCTAssertEqual(draft.text, "On my way — there about 18:45.")
        XCTAssertEqual(draft.origin, .template)
        XCTAssertEqual(card.secondary, [.handOff(.init(channel: .messages)), .later])
    }

    func testLeaveByDraftsAnEmailWhenContactsHasNoNumber() throws {
        let draft = try XCTUnwrap(rules.leaveBy(F.gigInputs(distance: nil), now: F.at(18), settings: settings)?.card.draft)
        XCTAssertEqual(draft.channel, .email)
        XCTAssertEqual(draft.recipient.addresses, ["ana@example.com"])
        XCTAssertEqual(draft.subject, "Gig at the Example Hall")
    }

    func testLeaveByHasNoDraftWithTwoOtherPeopleOrNobody() throws {
        for attendees in [[F.me, F.ana, F.lee], [F.me], []] {
            let card = try XCTUnwrap(rules.leaveBy(F.gigInputs(distance: nil, attendees: attendees), now: F.at(18),
                                                   settings: settings)?.card)
            XCTAssertNil(card.draft)
            XCTAssertEqual(card.secondary, [.later])
        }
    }

    func testLeaveByNeedsAnEventWithATimeAndATravelEstimate() {
        var inputs = F.gigInputs(distance: nil)
        inputs.myDay = F.myDay(events: [F.gig], travel: nil)
        XCTAssertNil(rules.leaveBy(inputs, now: F.at(18), settings: settings))
        var allDay = F.gig
        allDay = MyDayCalendarEvent(id: allDay.id, title: allDay.title, startDate: allDay.startDate,
                                    endDate: allDay.endDate, isAllDay: true, location: allDay.location)
        inputs.myDay = F.myDay(events: [allDay], travel: F.travel(for: allDay))
        XCTAssertNil(rules.leaveBy(inputs, now: F.at(18), settings: settings))
    }

    // MARK: - Running late: now + travel > start − 2 min, and more than 300 m away

    func testRunningLateAppearsTwoMinutesBeforeTheStartWouldBeMissed() {
        // 30 min away from a 19:00 start: arriving at 18:58 is on time, a second later is not.
        let table: [(Date, Bool)] = [
            (F.at(18, 28), false),
            (F.at(18, 28, 1), true),
            (F.at(19, 30), true),
            (F.at(21), false),  // the event is over
        ]
        for (now, appears) in table {
            XCTAssertEqual(rules.runningLate(F.gigInputs(distance: 5_000), now: now, settings: settings) != nil,
                           appears, "at \(now)")
        }
    }

    func testRunningLateNeedsTheWearerMoreThanThreeHundredMetresAway() {
        let table: [(Double?, Bool)] = [(nil, false), (0, false), (300, false), (300.5, true), (5_000, true)]
        for (distance, appears) in table {
            XCTAssertEqual(rules.runningLate(F.gigInputs(distance: distance), now: F.at(18, 40),
                                             settings: settings) != nil,
                           appears, "at \(String(describing: distance)) m")
        }
    }

    func testRunningLateReplacesLeaveByForTheSameEvent() {
        let inputs = F.gigInputs(distance: 5_000)
        XCTAssertNil(rules.leaveBy(inputs, now: F.at(18, 40), settings: settings))
        XCTAssertNotNil(rules.runningLate(inputs, now: F.at(18, 40), settings: settings))
        let kinds = rules.cards(from: inputs, now: F.at(18, 40), settings: settings).map(\.card.kind)
        XCTAssertEqual(kinds, [.runningLate])
    }

    func testRunningLateTextsWithMinutesRoundedUpToFive() throws {
        let contacts = ["ana@example.com": CardContact(name: "Ana Example", phone: "555-0142")]
        let card = try XCTUnwrap(rules.runningLate(F.gigInputs(distance: 5_000, contacts: contacts),
                                                   now: F.at(18, 41), settings: settings)?.card)
        // Arriving 19:11: 11 minutes late, said as 15.
        XCTAssertEqual(card.headline, "Running about 15 min late")
        XCTAssertEqual(card.draft?.text, "Running about 15 minutes late, sorry — there about 19:11.")
        XCTAssertEqual(card.primary, .handOff(.init(channel: .messages)))
        XCTAssertEqual(card.urgency, .immediate)
        XCTAssertEqual(card.validUntil, F.at(21))
    }

    func testRunningLateWithoutADraftLeadsWithDirections() throws {
        let card = try XCTUnwrap(rules.runningLate(F.gigInputs(distance: 5_000, attendees: [F.me]),
                                                   now: F.at(18, 41), settings: settings)?.card)
        XCTAssertNil(card.draft)
        XCTAssertEqual(card.primary, .directions(destination: "1 Example Street", mode: .driving))
        XCTAssertEqual(card.secondary, [.dismiss])
    }

    func testLateMinutesRoundUpToFiveAndNeverBelowFive() {
        let start = F.at(19)
        let table: [(TimeInterval, Int)] = [(-60, 5), (0, 5), (60, 5), (5 * 60, 5), (5 * 60 + 1, 10),
                                            (11 * 60, 15), (20 * 60, 20)]
        for (lateBy, said) in table {
            XCTAssertEqual(PreparedCardRules.lateMinutes(arrival: start.addingTimeInterval(lateBy), start: start),
                           said, "\(lateBy) s late")
        }
    }

    // MARK: - Short night: opt-in, < 6 h, a meeting before 09:30 someone else organised

    private func shortNightInputs(asleep: TimeInterval? = 5 * 3600 + 10 * 60, meetingAt: Date = F.at(8),
                                  attendees: [CalendarPerson] = [F.me, F.tom],
                                  morning: Date = F.calendar.startOfDay(for: F.at(8))) -> CardInputs {
        let review = F.event("review-1", "Review", start: meetingAt, minutes: 30, attendees: attendees)
        let standUp = F.event("standup", "Stand-up", start: F.at(9, 45), minutes: 30)
        let sleep = SleepNight(morning: morning, windowEnd: morning.addingTimeInterval(14 * 3600),
                               asleep: asleep, inBed: nil, stages: nil, awakenings: 0, asOf: F.at(7))
        return CardInputs(myDay: F.myDay(events: [review, standUp]), sleep: sleep,
                          wearer: CardWearer(name: "Sam Example"))
    }

    private var shortNightOn: PreparedCardSettings {
        var settings = F.settings
        settings.enabledKinds.insert(.shortNight)
        return settings
    }

    func testShortNightIsOffUntilTheWearerTurnsItOn() {
        XCTAssertFalse(PreparedCardSettings().isEnabled(.shortNight))
        let kinds = rules.cards(from: shortNightInputs(), now: F.at(7), settings: settings).map(\.card.kind)
        XCTAssertFalse(kinds.contains(.shortNight))
        XCTAssertTrue(rules.cards(from: shortNightInputs(), now: F.at(7), settings: shortNightOn)
            .map(\.card.kind).contains(.shortNight))
    }

    func testShortNightAppearsBelowSixHoursOnly() {
        let table: [(TimeInterval?, Bool)] = [(nil, false), (6 * 3600, false), (6 * 3600 - 60, true),
                                              (4 * 3600, true), (7 * 3600, false)]
        for (asleep, appears) in table {
            XCTAssertEqual(rules.shortNight(shortNightInputs(asleep: asleep), now: F.at(7), settings: shortNightOn) != nil,
                           appears, "asleep \(String(describing: asleep))")
        }
    }

    func testShortNightNeedsAMeetingBeforeHalfPastNine() {
        let table: [(Date, Bool)] = [(F.at(9, 29), true), (F.at(9, 29, 59), true), (F.at(9, 30), false),
                                     (F.at(11), false)]
        for (meetingAt, appears) in table {
            XCTAssertEqual(rules.shortNight(shortNightInputs(meetingAt: meetingAt), now: F.at(7),
                                            settings: shortNightOn) != nil,
                           appears, "meeting at \(meetingAt)")
        }
    }

    func testShortNightNeedsSomeoneElseOrganisingWithOneToThreeOthers() {
        let mine = CalendarPerson(name: "Sam Example", email: "sam@example.com", isOrganizer: true, isSelf: true)
        let table: [([CalendarPerson], Bool)] = [
            ([F.me, F.tom], true),
            ([F.me, F.tom, F.ana, F.lee], true),
            ([F.me, F.tom, F.ana, F.lee, F.kim], false),  // four others
            ([mine, F.ana], false),                         // the wearer organised it
            ([F.me, F.ana], false),                         // nobody organised it
        ]
        for (attendees, appears) in table {
            XCTAssertEqual(rules.shortNight(shortNightInputs(attendees: attendees), now: F.at(7),
                                            settings: shortNightOn) != nil,
                           appears, "\(attendees.map { $0.name ?? "" })")
        }
    }

    func testShortNightReadsOnlyLastNight() {
        let yesterday = F.calendar.startOfDay(for: F.at(8, day: 11))
        XCTAssertNil(rules.shortNight(shortNightInputs(morning: yesterday), now: F.at(7), settings: shortNightOn))
    }

    func testShortNightProposesTheFirstFreeSlotAndNeverMentionsSleep() throws {
        let card = try XCTUnwrap(rules.shortNight(shortNightInputs(), now: F.at(7), settings: shortNightOn)?.card)
        // Review 08:00–08:30; stand-up 09:45–10:15. Free from 08:30.
        XCTAssertEqual(card.facts.map(\.value), ["08:00", "08:30"])
        XCTAssertEqual(card.signals.first?.text, "Slept 5h 10m")
        XCTAssertEqual(card.signals.first?.sensitivity, .health)
        XCTAssertEqual(card.sensitivity, .health)
        let draft = try XCTUnwrap(card.draft)
        XCTAssertEqual(draft.channel, .email)
        XCTAssertEqual(draft.recipient, DraftRecipient(name: "Tom Example", addresses: ["tom@example.com"],
                                                      source: .calendarOrganiser))
        XCTAssertEqual(draft.text, "Hi Tom,\n\nCould we move Review to 08:30? It would suit me better today.\n\nSam Example")
        for word in ["sleep", "slept", "tired", "night"] {
            XCTAssertFalse(draft.text.lowercased().contains(word), word)
        }
        XCTAssertEqual(card.validUntil, F.at(8))
    }

    func testShortNightSkipsBusyTimeWhenLookingForASlot() {
        let review = F.event("review-1", "Review", start: F.at(8), minutes: 60, attendees: [F.me, F.tom])
        let busy = F.event("busy", "Busy", start: F.at(9), minutes: 90)
        let slot = rules.freeSlot(lasting: 3600, from: review.endDate, until: F.at(18),
                                  events: [review, busy], ignoring: review.id)
        XCTAssertEqual(slot, F.at(10, 30))
        XCTAssertNil(rules.freeSlot(lasting: 3600, from: F.at(17, 30), until: F.at(18), events: []))
    }

    // MARK: - Meeting follow-up

    private func followUpInputs(savedAt: Date = F.at(11, 30), items: [String]? = nil,
                                attendees: [CalendarPerson] = [F.me, F.ana, F.lee]) -> CardInputs {
        let planning = F.event("plan-1", "Planning", start: F.at(10), attendees: attendees)
        let actionItems = items ?? ["Ana will send the draft plan", "Lee to book the room for Friday",
                                    "Check the figures again", "A fourth thing"]
        let meeting = MeetingSummaryFacts(actionItems: actionItems, decisions: [], topics: [],
                                          startedAt: F.at(10, 5), endedAt: F.at(10, 55), savedAt: savedAt,
                                          transcript: actionItems.joined(separator: ". "))
        return CardInputs(myDay: F.myDay(events: [planning]), meeting: meeting,
                          wearer: CardWearer(name: "Sam Example"))
    }

    func testMeetingFollowUpNeedsTheSummarySavedWithinTwoHoursOfTheEvent() {
        let table: [(Date, Bool)] = [(F.at(11, 30), true), (F.at(13), true), (F.at(13, 0, 1), false)]
        for (savedAt, appears) in table {
            XCTAssertEqual(rules.meetingFollowUp(followUpInputs(savedAt: savedAt), now: F.at(14),
                                                 settings: settings) != nil,
                           appears, "saved \(savedAt)")
        }
    }

    func testMeetingFollowUpNeedsActionItemsAndOtherPeopleWithAddresses() {
        XCTAssertNil(rules.meetingFollowUp(followUpInputs(items: []), now: F.at(12), settings: settings))
        XCTAssertNil(rules.meetingFollowUp(followUpInputs(attendees: [F.me]), now: F.at(12), settings: settings))
        let noAddress = CalendarPerson(name: "Room guest", email: nil)
        XCTAssertNil(rules.meetingFollowUp(followUpInputs(attendees: [F.me, noAddress]), now: F.at(12),
                                           settings: settings))
    }

    func testMeetingFollowUpLastsTheDayAndEmailsTheAttendeesTheFirstThreeItems() throws {
        XCTAssertNil(rules.meetingFollowUp(followUpInputs(), now: F.at(0, day: 13), settings: settings))
        let card = try XCTUnwrap(rules.meetingFollowUp(followUpInputs(), now: F.at(12), settings: settings)?.card)
        XCTAssertEqual(card.facts.count, 3)
        XCTAssertEqual(card.signals.first?.text, "4 things agreed")
        XCTAssertEqual(card.sensitivity, .personal)
        let draft = try XCTUnwrap(card.draft)
        XCTAssertEqual(draft.recipient.addresses, ["ana@example.com", "lee@example.com"])
        XCTAssertEqual(draft.recipient.source, .meetingAttendees)
        XCTAssertEqual(draft.subject, "Recap: Planning")
        XCTAssertTrue(draft.text.hasPrefix("Hi all,"))
        XCTAssertTrue(draft.text.contains("• Ana will send the draft plan\n• Lee to book the room for Friday\n• Check the figures again"))
        XCTAssertFalse(draft.text.contains("A fourth thing"))
        XCTAssertTrue(draft.text.hasSuffix("Sam Example"))
        XCTAssertEqual(card.validUntil, F.at(0, day: 13))
    }

    // MARK: - Fit it in

    private func fitInputs(hasTime: Bool = false, due: Date = F.at(0)) -> CardInputs {
        let reminder = MyDayReminder(id: "r1", title: "Post the parcel", dueDate: due, hasTime: hasTime, priority: 0)
        return CardInputs(myDay: F.myDay(events: [F.event("e1", "Busy", start: F.at(10))], reminders: [reminder]))
    }

    func testFitItInNeedsThirtyFreeMinutesStartingWithinTheHour() {
        let table: [(Date, Bool)] = [
            (F.at(9), true),          // 09:00–10:00 free
            (F.at(9, 30), true),      // exactly 30 min
            (F.at(9, 30, 1), false),  // 29:59 now; the next gap starts at 11:00, more than an hour away
            (F.at(10, 1), true),      // in the event; 11:00 is within the hour
            (F.at(17, 31), false),    // the day ends at 18:00
        ]
        for (now, appears) in table {
            XCTAssertEqual(rules.fitItIn(fitInputs(), now: now, settings: settings) != nil, appears, "at \(now)")
        }
    }

    func testFitItInTakesOnlyUntimedRemindersDueToday() throws {
        XCTAssertNil(rules.fitItIn(fitInputs(hasTime: true, due: F.at(15)), now: F.at(9), settings: settings))
        XCTAssertNil(rules.fitItIn(fitInputs(due: F.at(0, day: 13)), now: F.at(9), settings: settings))
        let card = try XCTUnwrap(rules.fitItIn(fitInputs(), now: F.at(9), settings: settings)?.card)
        XCTAssertEqual(card.primary, .complete(reminderId: "r1"))
        XCTAssertEqual(card.subject, "Free till 10:00")
        XCTAssertNil(card.draft)
        XCTAssertEqual(card.absorbs, [CardRowID(source: "reminders", rawValue: "r1")])
    }

    // MARK: - Urgency (§3.2)

    func testUrgencyLadder() {
        let now = F.at(12)
        let table: [(Date?, MyDayUrgency)] = [
            (nil, .upcoming),
            (F.at(11), .immediate),
            (F.at(12, 10), .immediate),
            (F.at(12, 10, 1), .important),
            (F.at(13), .important),
            (F.at(13, 0, 1), .upcoming),
            (F.at(23, 59), .upcoming),
            (F.at(9, day: 13), .routine),
        ]
        for (due, urgency) in table {
            XCTAssertEqual(rules.urgency(dueAt: due, now: now), urgency, "\(String(describing: due))")
        }
    }

    func testADisabledKindMakesNoCard() {
        var settings = F.settings
        settings.enabledKinds.remove(.leaveBy)
        XCTAssertTrue(rules.cards(from: F.gigInputs(distance: nil), now: F.at(18), settings: settings).isEmpty)
    }
}
