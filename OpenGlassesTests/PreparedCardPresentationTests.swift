import XCTest
@testable import OpenGlasses

/// Plan KT P1 — what the My Day page and the home cards draw (§5.1, §5.2, §5.5): buttons name the
/// effect and the person, the draft says who it is to and where it came from, a hand-off with no
/// result says where it went, VoiceOver reads the card in the plan's order, and the home card shows
/// one card with "N more ready". Invented people and numbers only.
final class PreparedCardPresentationTests: XCTestCase {

    private let calendar = CardFixtures.calendar

    private func draft(_ channel: DraftChannel, to name: String = "Ana Example",
                       origin: DraftOrigin = .template) -> PreparedDraft {
        PreparedDraft(channel: channel,
                      recipient: DraftRecipient(name: name, addresses: [channel == .email ? "ana@example.com" : "555-0142"],
                                                source: .calendarAttendee),
                      subject: channel == .email ? "Today" : nil, text: "On my way — there about 18:45.",
                      origin: origin, language: "en-GB")
    }

    private func leaveBy(draft: PreparedDraft? = nil) -> PreparedCard {
        PreparedCard(
            id: PreparedCardID(kind: .leaveBy, occurrence: "gig-1:2026-11-12"),
            headline: "Leave by 18:15", subject: "Gig at the Example Hall",
            signals: [CardSignal(source: .calendar, text: "19:00"), CardSignal(source: .weather, text: "Rain from 18:00")],
            facts: [CardFact(label: "Leave by", value: "18:15"), CardFact(label: "Travel", value: "30 min · Driving")],
            primary: .directions(destination: "1 Example Street", mode: .driving),
            secondary: (draft.map { [PreparedAction.handOff(.init(channel: $0.channel))] } ?? []) + [.later],
            draft: draft, urgency: .important, dueAt: CardFixtures.at(18, 15), validUntil: CardFixtures.at(19))
    }

    private func model(_ card: PreparedCard, memory: PreparedCardMemory? = nil,
                       now: Date = CardFixtures.at(17)) -> PreparedCardModel {
        PreparedCardPresentation.model(card, memory: memory, changedDraft: nil, now: now, calendar: calendar)
    }

    // MARK: - Buttons

    func testTheButtonsNameTheEffectAndThePerson() {
        let texted = model(leaveBy(draft: draft(.messages)))
        XCTAssertEqual(texted.primary.label, "Directions")
        XCTAssertEqual(texted.secondary.map(\.label), ["Text Ana"], "Later is in the menu, not a button")

        let emailed = model(leaveBy(draft: draft(.email, to: "Tom Example")))
        XCTAssertEqual(emailed.secondary.map(\.label), ["Email Tom"])
        XCTAssertTrue(emailed.secondary[0].isHandOff)
    }

    func testNoButtonIsSendAlone() {
        let actions: [PreparedAction] = [
            .handOff(.init(channel: .messages)), .handOff(.init(channel: .email)), .directions(destination: "x", mode: .walking),
            .openEvent(id: "e"), .openJob(id: "j"), .openReport(sessionId: "s"), .openPartsOrder(sessionId: "s"),
            .getSignOff(sessionId: "s"), .call(ContactRef(name: "Ana Example", phone: "555-0142")),
            .complete(reminderId: "r"), .later, .dismiss,
        ]
        let card = leaveBy(draft: draft(.messages))
        for action in actions {
            let label = PreparedCardPresentation.button(action, card: card).label
            XCTAssertNotEqual(label, "Send", "\(action)")
            XCTAssertFalse(label.isEmpty)
        }
        XCTAssertEqual(PreparedCardPresentation.button(.openReport(sessionId: "s"), card: card).label, "Send report")
        XCTAssertEqual(PreparedCardPresentation.button(.call(ContactRef(name: "Ana Example", phone: "555-0142")), card: card).label,
                       "Call Ana")
    }

    func testAMeetingFollowUpOffersTheRecap() {
        let followUp = PreparedCard(
            id: PreparedCardID(kind: .meetingFollowUp, occurrence: "m"), headline: "Send the recap", subject: nil,
            signals: [CardSignal(source: .meeting, text: "3 things agreed")], facts: [],
            primary: .handOff(.init(channel: .email)), draft: draft(.email), urgency: .upcoming, dueAt: nil,
            validUntil: CardFixtures.at(23), sensitivity: .personal)
        XCTAssertEqual(model(followUp).primary.label, "Email recap")
    }

    // MARK: - The draft

    func testTheDraftSaysWhoItIsToAndWhereItCameFrom() {
        let shown = model(leaveBy(draft: draft(.messages)))
        XCTAssertEqual(shown.draft?.recipientLine, "To Ana Example · Messages")
        XCTAssertEqual(shown.draft?.footer, "Simple draft")
        XCTAssertEqual(PreparedCardPresentation.draftModel(draft(.messages, origin: .onDevice)).footer, "Drafted on this iPhone")
        XCTAssertEqual(PreparedCardPresentation.draftModel(draft(.messages, origin: .cloud(provider: "Example AI"))).footer,
                       "Drafted by Example AI")
    }

    func testAHandOffWithNoResultSaysWhereItWent() {
        let card = leaveBy(draft: draft(.whatsapp))
        let opened = model(card, memory: PreparedCardMemory(state: .handedOff(at: CardFixtures.at(17), result: .unknown),
                                                            changedAt: CardFixtures.at(17)))
        XCTAssertEqual(opened.handedOffNote, "Opened in WhatsApp")
        XCTAssertNil(model(card, memory: PreparedCardMemory(state: .seen, changedAt: CardFixtures.at(17))).handedOffNote)
    }

    func testLaterOptionsFollowTheCardsEnd() {
        XCTAssertEqual(model(leaveBy()).laterOptions, [.inAnHour, .thisEvening])
        XCTAssertEqual(model(leaveBy(), now: CardFixtures.at(18, 30)).laterOptions, [])
    }

    // MARK: - VoiceOver (§5.5)

    func testVoiceOverReadsHeadlineThenReasonsThenFactsThenDraft() {
        let spoken = model(leaveBy(draft: draft(.messages))).accessibilityLabel
        let order = ["Leave by 18:15", "because: 19:00; Rain from 18:00", "Travel 30 min · Driving",
                     "Draft To Ana Example · Messages: On my way"]
        var cursor = spoken.startIndex
        for part in order {
            guard let range = spoken.range(of: part, range: cursor..<spoken.endIndex) else {
                return XCTFail("\"\(part)\" missing or out of order in: \(spoken)")
            }
            cursor = range.upperBound
        }
    }

    func testTheChipsAreOneReading() {
        XCTAssertEqual(PreparedCardModel.because([CardSignal(source: .sleep, text: "Slept 5h 10m", sensitivity: .health),
                                                  CardSignal(source: .calendar, text: "Free from 10")]),
                       "because: Slept 5h 10m; Free from 10")
        XCTAssertNil(PreparedCardModel.because([]))
        XCTAssertEqual(PreparedCardModel.readyLabel, "Ready", "a small label, not a feature name")
    }

    // MARK: - The page and the home card

    private func feed(_ cards: [PreparedCard]) -> PreparedCardFeed {
        PreparedCardFeed(feed: TodayFeed(cards: cards, rows: [], overflow: [], absorbed: []))
    }

    func testThePageDrawsEveryCardInOrder() {
        let cards = [leaveBy(), CardFixtures.card(.fitItIn, "r").card]
        let page = PreparedCardPresentation.page(feed(cards), memory: [:], now: CardFixtures.at(17), calendar: calendar)
        XCTAssertEqual(page.map(\.id), cards.map(\.id))
    }

    func testTheHomeCardShowsTheTopCardAndHowManyMore() {
        let cards = [leaveBy(), CardFixtures.card(.fitItIn, "r").card, CardFixtures.card(.jobReportOwed, "s").card]
        let home = PreparedCardHomeModel.make(feed(cards), memory: [:], now: CardFixtures.at(17), calendar: calendar)
        XCTAssertEqual(home.top?.id, cards[0].id)
        XCTAssertEqual(home.moreReadyText, "2 more ready")

        let single = PreparedCardHomeModel.make(feed([leaveBy()]), memory: [:], now: CardFixtures.at(17), calendar: calendar)
        XCTAssertNil(single.moreReadyText)
        let none = PreparedCardHomeModel.make(feed([]), memory: [:], now: CardFixtures.at(17), calendar: calendar)
        XCTAssertNil(none.top, "no cards: the home card is My Day's card as it was")
    }

    func testTheJobDaysCardShowsJobCardsUnlessMyDayIsFoldedIn() {
        let cards = [leaveBy(), CardFixtures.card(.jobReportOwed, "s").card]
        let jobsOnly = PreparedCardHomeModel.make(feed(cards), memory: [:], now: CardFixtures.at(17), calendar: calendar,
                                                  includes: { $0.isJobKind })
        XCTAssertEqual(jobsOnly.top?.kind, .jobReportOwed)
        XCTAssertEqual(jobsOnly.moreReadyCount, 0)
    }
}
