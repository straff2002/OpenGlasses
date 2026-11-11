import Foundation
@testable import OpenGlasses

/// One invented card of every kind, as the rules would build them, for the Display tests (Plan KT
/// P3). Nobody here is real: "Example" names, `example.com` addresses, `555-01xx` numbers.
enum LensCardFixtures {
    static let ana = DraftRecipient(name: "Ana Example", addresses: ["555-0123"], source: .calendarAttendee)
    static let tom = DraftRecipient(name: "Tom Example", addresses: ["tom@example.com"], source: .calendarOrganiser)
    static let team = DraftRecipient(name: "Tom Example and 2 others", addresses: ["tom@example.com"],
                                     source: .meetingAttendees)
    static let hana = DraftRecipient(name: "Hana Example", addresses: ["555-0199"], source: .jobCustomer)

    static let validUntil = CardFixtures.at(23)

    static func id(_ kind: PreparedCardKind) -> PreparedCardID {
        PreparedCardID(kind: kind, occurrence: "example:2026-11-12")
    }

    static func draft(_ recipient: DraftRecipient, _ text: String, channel: DraftChannel = .messages) -> PreparedDraft {
        PreparedDraft(channel: channel, recipient: recipient, subject: channel == .email ? "Example" : nil,
                      text: text, language: "en-GB")
    }

    static let longEmail = """
        Hi Tom,

        Could we move the Example review to 10:00? It would suit me better today. If that time \
        doesn't work for you, any slot after lunch is fine as well, and I can send round the notes \
        beforehand so we can keep it short.

        Thanks,
        Sam
        """

    static let recap = """
        Hi all,

        Thanks for this morning. What we agreed:
        - Example Co sends the revised quote by Friday
        - Sam books the site visit for next week
        - Lee shares the drawings with the team

        Best,
        Sam
        """

    static var leaveBy: PreparedCard {
        PreparedCard(id: id(.leaveBy), headline: "Leave by 18:15", subject: "Gig at the Example Hall",
                     signals: [CardSignal(source: .calendar, text: "19:00"),
                               CardSignal(source: .location, text: "You're in Example Bay"),
                               CardSignal(source: .weather, text: "Rain from 18:00")],
                     facts: [CardFact(label: "Leave by", value: "18:15"),
                             CardFact(label: "Travel", value: "30 min · Driving"),
                             CardFact(label: "Arrive by", value: "18:45")],
                     primary: .directions(destination: "1 Example Street", mode: .driving),
                     secondary: [.handOff(.init(channel: .messages)), .later],
                     draft: draft(ana, "On my way — there about 18:45."),
                     urgency: .immediate, dueAt: CardFixtures.at(18, 15), validUntil: CardFixtures.at(19))
    }

    static var runningLate: PreparedCard {
        PreparedCard(id: id(.runningLate), headline: "Running about 10 min late", subject: "Gig at the Example Hall",
                     signals: [CardSignal(source: .calendar, text: "Starts 19:00"),
                               CardSignal(source: .travel, text: "25 min away")],
                     facts: [CardFact(label: "Starts", value: "19:00"),
                             CardFact(label: "Arrive about", value: "19:10"),
                             CardFact(label: "Late by", value: "10 min")],
                     primary: .handOff(.init(channel: .messages)),
                     secondary: [.directions(destination: "1 Example Street", mode: .driving), .dismiss],
                     draft: draft(ana, "Running about 10 minutes late, sorry — there about 19:10."),
                     urgency: .immediate, dueAt: CardFixtures.at(19), validUntil: CardFixtures.at(19))
    }

    static var shortNight: PreparedCard {
        PreparedCard(id: id(.shortNight), headline: "Ask to move Example review", subject: "Example review · 08:30",
                     signals: [CardSignal(source: .sleep, text: "Slept 5h 10m", sensitivity: .health),
                               CardSignal(source: .calendar, text: "Free from 10:00")],
                     facts: [CardFact(label: "Meeting", value: "08:30"),
                             CardFact(label: "Proposed", value: "10:00")],
                     primary: .handOff(.init(channel: .email)),
                     secondary: [.openEvent(id: "review-1"), .dismiss],
                     draft: draft(tom, longEmail, channel: .email),
                     urgency: .important, dueAt: CardFixtures.at(8, 30), validUntil: CardFixtures.at(8, 30),
                     sensitivity: .health)
    }

    static var meetingFollowUp: PreparedCard {
        PreparedCard(id: id(.meetingFollowUp), headline: "Send a recap", subject: "Example planning",
                     signals: [CardSignal(source: .meeting, text: "3 things agreed", sensitivity: .personal),
                               CardSignal(source: .calendar, text: "09:00")],
                     facts: [CardFact(label: "Agreed", value: "Example Co sends the revised quote"),
                             CardFact(label: "Agreed", value: "Sam books the site visit"),
                             CardFact(label: "Agreed", value: "Lee shares the drawings")],
                     primary: .handOff(.init(channel: .email)),
                     secondary: [.openEvent(id: "planning-1"), .dismiss],
                     draft: draft(team, recap, channel: .email),
                     urgency: .upcoming, dueAt: nil, validUntil: validUntil, sensitivity: .personal)
    }

    static var fitItIn: PreparedCard {
        PreparedCard(id: id(.fitItIn), headline: "Fit it in: Post the parcel", subject: nil,
                     signals: [CardSignal(source: .reminders, text: "Post the parcel"),
                               CardSignal(source: .calendar, text: "Free till 15:00")],
                     facts: [CardFact(label: "Reminder", value: "Post the parcel"),
                             CardFact(label: "Free", value: "14:00–15:00")],
                     primary: .complete(reminderId: "reminder-1"),
                     secondary: [.later],
                     urgency: .important, dueAt: CardFixtures.at(14), validUntil: CardFixtures.at(15))
    }

    static var jobOnMyWay: PreparedCard {
        PreparedCard(id: id(.jobOnMyWay), headline: "Leave by 09:30 for job 1005", subject: "14 Example Street",
                     signals: [CardSignal(source: .job, text: "Job 1005"),
                               CardSignal(source: .location, text: "14 Example Street"),
                               CardSignal(source: .travel, text: "25 min")],
                     facts: [CardFact(label: "Customer", value: "Hana Example"),
                             CardFact(label: "Scheduled", value: "10:00"),
                             CardFact(label: "Arrive about", value: "09:55")],
                     primary: .directions(destination: "14 Example Street", mode: .driving),
                     secondary: [.handOff(.init(channel: .messages)), .later],
                     draft: draft(hana, "Hi Hana, it's Sam from Example Plumbing. On my way, there about 09:55."),
                     urgency: .immediate, dueAt: CardFixtures.at(9, 30), validUntil: CardFixtures.at(10))
    }

    static var jobRunningLate: PreparedCard {
        PreparedCard(id: id(.jobRunningLate), headline: "Running late to job 1005", subject: "14 Example Street",
                     signals: [CardSignal(source: .job, text: "Job 1005"),
                               CardSignal(source: .travel, text: "20 min away")],
                     facts: [CardFact(label: "Scheduled", value: "10:00"),
                             CardFact(label: "Arrive about", value: "10:15")],
                     primary: .handOff(.init(channel: .messages)),
                     secondary: [.directions(destination: "14 Example Street", mode: .driving)],
                     draft: draft(hana, "Hi Hana, running about 15 minutes behind — there about 10:15. Sorry for the wait."),
                     urgency: .immediate, dueAt: CardFixtures.at(10), validUntil: CardFixtures.at(10, 45))
    }

    static var jobReportOwed: PreparedCard {
        PreparedCard(id: id(.jobReportOwed), headline: "Report not sent", subject: "Job 1003",
                     signals: [CardSignal(source: .job, text: "Job 1003"),
                               CardSignal(source: .job, text: "Report not sent")],
                     facts: [CardFact(label: "Customer", value: "Example Customer"),
                             CardFact(label: "Ended", value: "11:40")],
                     primary: .openReport(sessionId: "s3"), secondary: [.openJob(id: "s3")],
                     urgency: .upcoming, dueAt: nil, validUntil: validUntil)
    }

    static var jobPartsOwed: PreparedCard {
        PreparedCard(id: id(.jobPartsOwed), headline: "Parts not ordered", subject: "Job 1004",
                     signals: [CardSignal(source: .job, text: "Job 1004"),
                               CardSignal(source: .job, text: "2 parts")],
                     facts: [CardFact(label: "Parts", value: "2")],
                     primary: .openPartsOrder(sessionId: "s4"), secondary: [.openJob(id: "s4")],
                     urgency: .upcoming, dueAt: nil, validUntil: validUntil)
    }

    static var jobSignOffOwed: PreparedCard {
        PreparedCard(id: id(.jobSignOffOwed), headline: "Sign-off owed", subject: "Job 1002",
                     signals: [CardSignal(source: .job, text: "Job 1002")],
                     facts: [CardFact(label: "Customer", value: "Example Customer")],
                     primary: .getSignOff(sessionId: "s2"), secondary: [.openJob(id: "s2")],
                     urgency: .upcoming, dueAt: nil, validUntil: validUntil)
    }

    /// One card of every kind, in the catalogue's order.
    static var all: [PreparedCard] {
        PreparedCardKind.allCases.map(card)
    }

    static func card(_ kind: PreparedCardKind) -> PreparedCard {
        switch kind {
        case .jobRunningLate: jobRunningLate
        case .jobOnMyWay: jobOnMyWay
        case .jobReportOwed: jobReportOwed
        case .jobPartsOwed: jobPartsOwed
        case .jobSignOffOwed: jobSignOffOwed
        case .runningLate: runningLate
        case .leaveBy: leaveBy
        case .shortNight: shortNight
        case .meetingFollowUp: meetingFollowUp
        case .fitItIn: fitItIn
        }
    }
}
