import XCTest
@testable import OpenGlasses

/// Plan KT §5.3 — a card's one notification: only when it becomes immediate, only for the kinds
/// that may push, once, held back in quiet hours, and generic on the lock screen unless the wearer
/// asked for the headline — and never the draft, a recipient or a health or personal card's text.
final class PreparedCardNotificationTests: XCTestCase {

    private func card(_ kind: PreparedCardKind = .leaveBy, urgency: MyDayUrgency = .immediate,
                      sensitivity: CardSensitivity = .ordinary, occurrence: String = "gig") -> PreparedCard {
        PreparedCard(
            id: PreparedCardID(kind: kind, occurrence: occurrence), headline: "Leave by 18:15",
            subject: "Gig at the Example Hall", signals: [CardSignal(source: .calendar, text: "19:00")],
            facts: [CardFact(label: "Travel", value: "30 min")],
            primary: .directions(destination: "1 Example Street", mode: .driving),
            draft: PreparedDraft(channel: .messages,
                                 recipient: DraftRecipient(name: "Ana Example", addresses: ["555-0142"],
                                                           source: .calendarAttendee),
                                 text: "On my way — there about 18:45.", language: "en-GB"),
            urgency: urgency, dueAt: CardFixtures.at(18, 15), validUntil: CardFixtures.at(19),
            sensitivity: sensitivity)
    }

    func testTheTextIsGenericByDefault() {
        let due = PreparedCardNotificationPolicy.due(cards: [card()], alreadyPosted: [], showsHeadline: false, quiet: false)
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due[0].title, "My Day")
        XCTAssertEqual(due[0].body, "Something's ready in My Day")
        for leaked in ["Leave by", "Ana", "555-0142", "On my way", "Example Hall", "Example Street"] {
            XCTAssertFalse(due[0].title.contains(leaked) || due[0].body.contains(leaked), leaked)
        }
    }

    func testTheHeadlineOnlyWhenAskedAndOnlyForAnOrdinaryCard() {
        let ordinary = PreparedCardNotificationPolicy.content(for: card(), showsHeadline: true)
        XCTAssertEqual(ordinary.body, "Leave by 18:15")
        XCTAssertFalse(ordinary.body.contains("On my way"), "never the draft")

        let personal = PreparedCardNotificationPolicy.content(for: card(sensitivity: .personal), showsHeadline: true)
        XCTAssertEqual(personal.body, PreparedCardNotificationPolicy.genericBody)
        let health = PreparedCardNotificationPolicy.content(for: card(sensitivity: .health), showsHeadline: true)
        XCTAssertEqual(health.body, PreparedCardNotificationPolicy.genericBody)
    }

    func testOnlyImmediateCardsOfPushingKindsNotify() {
        let cards = [card(urgency: .important, occurrence: "a"), card(.fitItIn, occurrence: "b"),
                     card(.jobReportOwed, occurrence: "c"), card(.runningLate, occurrence: "d"),
                     card(.jobOnMyWay, occurrence: "e"), card(.jobRunningLate, occurrence: "f")]
        let due = PreparedCardNotificationPolicy.due(cards: cards, alreadyPosted: [], showsHeadline: false, quiet: false)
        XCTAssertEqual(due.map(\.cardID.kind), [.runningLate, .jobOnMyWay, .jobRunningLate])
    }

    func testOncePerCardAndNotInQuietHours() {
        let gig = card()
        XCTAssertTrue(PreparedCardNotificationPolicy.due(cards: [gig], alreadyPosted: [gig.id.rawValue],
                                                         showsHeadline: false, quiet: false).isEmpty)
        XCTAssertTrue(PreparedCardNotificationPolicy.due(cards: [gig], alreadyPosted: [],
                                                         showsHeadline: false, quiet: true).isEmpty)
    }

    func testQuietHoursAreMyDays() {
        let settings = MyDayDeliverySettings(myDayEnabled: true, morningEnabled: false, morningMinutes: 480,
                                             eveningEnabled: false, eveningMinutes: 1140, scheduledSpeechEnabled: false,
                                             quietHoursEnabled: true, quietStartMinutes: 22 * 60, quietEndMinutes: 7 * 60)
        XCTAssertTrue(MyDayDeliveryPolicy.isQuiet(at: CardFixtures.at(23), calendar: CardFixtures.calendar, settings: settings))
        XCTAssertFalse(MyDayDeliveryPolicy.isQuiet(at: CardFixtures.at(18), calendar: CardFixtures.calendar, settings: settings))
    }

    func testATapNamesTheCard() {
        let gig = card()
        XCTAssertEqual(PreparedCardNotificationPolicy.cardID(from: [PreparedCardNotificationPolicy.cardKey: gig.id.rawValue]),
                       gig.id)
        XCTAssertNil(PreparedCardNotificationPolicy.cardID(from: ["og_open_tab": "job"]))
    }

    @MainActor
    func testTheNotifierPostsACardOnceEvenAcrossALockedRefresh() {
        let suite = "PreparedCardNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifier = PreparedCardNotifier(defaults: defaults, center: { nil })
        let quietOff = MyDayDeliverySettings(myDayEnabled: true, morningEnabled: false, morningMinutes: 0,
                                             eveningEnabled: false, eveningMinutes: 0, scheduledSpeechEnabled: false,
                                             quietHoursEnabled: false, quietStartMinutes: 0, quietEndMinutes: 0)
        let gig = card()
        notifier.notify(feed: TodayFeed(cards: [gig], rows: [], overflow: [], absorbed: []), now: CardFixtures.at(18, 10),
                        calendar: CardFixtures.calendar, delivery: quietOff, showsHeadline: false)
        XCTAssertEqual(notifier.posted, [gig.id.rawValue])
        // Locked: no cards. Unlocked: the same card again — still posted once.
        notifier.notify(feed: .empty, now: CardFixtures.at(18, 11), calendar: CardFixtures.calendar,
                        delivery: quietOff, showsHeadline: false)
        notifier.notify(feed: TodayFeed(cards: [gig], rows: [], overflow: [], absorbed: []), now: CardFixtures.at(18, 12),
                        calendar: CardFixtures.calendar, delivery: quietOff, showsHeadline: false)
        XCTAssertEqual(defaults.stringArray(forKey: "preparedCardNotifiedIDs"), [gig.id.rawValue])
    }
}
