import XCTest
@testable import OpenGlasses

/// Plan KT P4 — the day's cards on the wrist: what `WatchTodayPayload.cards` carries, its version
/// bump (an older payload still reads), the application-context budget, and each
/// `preparedCardAction` command. Invented data only.
@MainActor
final class WatchPreparedCardTests: XCTestCase {

    private let now = CardFixtures.at(9)

    private var utc: Calendar { CardFixtures.calendar }

    private func payload(cards: [WatchPreparedCard], events: Int = 0) -> WatchTodayPayload {
        WatchTodayPayload(day: WatchTodayDay(now, calendar: utc), generatedAt: now, calendarStatus: .shown,
                          events: (0..<events).map {
                              WatchTodayEvent(id: "e\($0)", start: now.addingTimeInterval(Double($0) * 3600),
                                              end: now.addingTimeInterval(Double($0) * 3600 + 1800), isAllDay: false,
                                              title: "Example \($0) " + String(repeating: "t", count: 50),
                                              location: "Example Street \($0)")
                          },
                          moreEvents: 0, redacted: false, weatherStatus: .notIncluded, weather: nil, attribution: nil,
                          cards: cards)
    }

    // MARK: - What goes to the wrist

    func testAtMostThreeCardsNoHealthNoneExpired() {
        let feed = [LensCardFixtures.shortNight, LensCardFixtures.runningLate, LensCardFixtures.leaveBy,
                    LensCardFixtures.meetingFollowUp, LensCardFixtures.fitItIn]
        let cards = WatchPreparedCardBuilder.cards(from: feed, now: now, withholding: false)
        XCTAssertEqual(cards.map(\.id), [LensCardFixtures.runningLate, LensCardFixtures.leaveBy,
                                         LensCardFixtures.meetingFollowUp].map(\.id.rawValue))
        XCTAssertFalse(cards.contains { $0.id == LensCardFixtures.shortNight.id.rawValue }, "health never goes to the watch")
        let late = WatchPreparedCardBuilder.cards(from: feed, now: CardFixtures.at(19, 30), withholding: false)
        XCTAssertFalse(late.contains { $0.id == LensCardFixtures.leaveBy.id.rawValue }, "past validUntil, gone")
    }

    func testACardCarriesItsHeadlineChipsTwoFactsPrimaryDraftAndID() {
        let card = WatchPreparedCardBuilder.card(for: LensCardFixtures.leaveBy, withholding: false)
        XCTAssertEqual(card.id, LensCardFixtures.leaveBy.id.rawValue)
        XCTAssertEqual(card.headline, "Leave by 18:15")
        XCTAssertEqual(card.chips.map(\.text), ["19:00", "You're in Example Bay", "Rain from 18:00"])
        XCTAssertEqual(card.facts.map(\.label), ["Travel", "Arrive by"], "two facts, not the headline's own")
        XCTAssertEqual(card.primaryLabel, "Directions")
        XCTAssertEqual(card.buttons, [WatchPreparedCardButton(action: .directions, label: "Directions"),
                                      WatchPreparedCardButton(action: .stage, label: "Text Ana")])
        XCTAssertEqual(card.draftTo, "To Ana Example · Messages")
        XCTAssertEqual(card.draftText, "On my way — there about 18:45.")
        XCTAssertFalse(card.draftWithheld)

        let followUp = WatchPreparedCardBuilder.card(for: LensCardFixtures.meetingFollowUp, withholding: false)
        XCTAssertEqual(followUp.draftText, LensCardFixtures.recap, "personal drafts show on the watch (§6.6)")
        let report = WatchPreparedCardBuilder.card(for: LensCardFixtures.jobReportOwed, withholding: false)
        XCTAssertEqual(report.primaryLabel, "Send report")
        XCTAssertTrue(report.buttons.isEmpty, "a report opens on the phone, not from the wrist")
        XCTAssertNil(report.draftTo)
    }

    // MARK: - The payload: version, old decode, budget

    func testTheVersionIsBumpedAndAVersionOnePayloadStillReads() throws {
        XCTAssertEqual(WatchTodayWire.version, 2)
        // A phone not yet updated sends version 1, with no `cards` key at all.
        struct VersionOne: Encodable {
            let version = 1
            let day: WatchTodayDay
            let generatedAt: Date
            let calendarStatus = WatchTodaySectionStatus.shown
            let events: [WatchTodayEvent] = []
            let moreEvents = 0
            let redacted = false
            let weatherStatus = WatchTodaySectionStatus.notIncluded
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(VersionOne(day: WatchTodayDay(now, calendar: utc), generatedAt: now))
        let decoded = try XCTUnwrap(WatchTodayCodec.decode(data))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.cards, [])
        XCTAssertEqual(decoded.calendarStatus, .shown)
    }

    func testCardsRoundTripWellInsideTheBudget() throws {
        let cards = WatchPreparedCardBuilder.cards(from: [LensCardFixtures.runningLate, LensCardFixtures.leaveBy,
                                                          LensCardFixtures.meetingFollowUp], now: now, withholding: false)
        let full = payload(cards: cards, events: 6)
        let encoded = try WatchTodayCodec.encode(full).get()
        XCTAssertEqual(encoded.payload, full, "three cards and six items fit untouched")
        XCTAssertLessThan(encoded.data.count, WatchTodayCodec.budgetBytes)
        XCTAssertEqual(WatchTodayCodec.decode(encoded.data), full)
    }

    func testOverBudgetDropsDraftTextsThenCardsBeforeAnyEvent() throws {
        func big(_ i: Int) -> WatchPreparedCard {
            WatchPreparedCard(id: "leaveBy:example-\(i)", headline: "Leave by 18:1\(i)", chips: [], facts: [],
                              primaryLabel: "Directions", buttons: [], draftTo: "To Ana Example · Messages",
                              // Distinct: a binary property list stores a repeated string once.
                              draftText: "\(i)" + String(repeating: "x", count: 1_500),
                              draftWithheld: false, validUntil: CardFixtures.at(19))
        }
        let full = payload(cards: [big(0), big(1), big(2)], events: 6)
        func size(_ value: WatchTodayPayload) throws -> Int { try WatchTodayCodec.encode(value).get().data.count }

        var lastStripped = full
        lastStripped.cards[2] = lastStripped.cards[2].withoutDraftText()
        let trimmed = try WatchTodayCodec.encode(full, budget: try size(lastStripped)).get().payload
        XCTAssertEqual(trimmed.events.count, 6, "the calendar is kept whole")
        XCTAssertEqual(trimmed.cards.count, 3, "the cards are kept")
        XCTAssertNil(trimmed.cards.last?.draftText, "the last card's draft text goes first")
        XCTAssertEqual(trimmed.cards.last?.draftWithheld, true, "and the wrist says to read it on the phone")
        XCTAssertNotNil(trimmed.cards.first?.draftText, "the top card's text goes last")

        var allStripped = full
        allStripped.cards = allStripped.cards.map { $0.withoutDraftText() }
        let tighter = try WatchTodayCodec.encode(full, budget: try size(allStripped) - 1).get().payload
        XCTAssertEqual(tighter.cards.count, 2, "then trailing cards")
        XCTAssertTrue(tighter.cards.allSatisfy { $0.draftText == nil })
        XCTAssertEqual(tighter.events.count, 6, "before any event")
    }

    func testTheBuilderPutsTheCardsInTodayUnderTheSameMedicalReading() {
        let gathered = MyDayGathered(generatedAt: now, locked: false, calendarIncluded: false, events: [],
                                     calendarState: nil, weatherIncluded: false, weather: nil, weatherState: nil)
        var inputs = WatchTodayBuilder.Inputs(now: now, calendar: utc, medical: .off, temperatureUnit: .celsius,
                                              attribution: WatchTodayAttribution(serviceName: "Example Weather",
                                                                                 legalPageURL: "https://example.com"))
        inputs.cards = [LensCardFixtures.leaveBy, LensCardFixtures.shortNight]
        let open = WatchTodayBuilder.payload(from: gathered, inputs)
        XCTAssertEqual(open.cards.map(\.id), [LensCardFixtures.leaveBy.id.rawValue])
        inputs.medical = MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false)
        let medical = WatchTodayBuilder.payload(from: gathered, inputs)
        XCTAssertTrue(medical.redacted)
        XCTAssertEqual(medical.cards.first?.headline, "Leave by 18:15")
        XCTAssertFalse(medical.cards.contains { card in
            card.facts.contains { $0.value.contains("Gig") } || card.headline.contains("Gig")
        })
    }

    // MARK: - Commands

    private final class Calls {
        var staged: [PreparedCardID] = []
        var ran: [PreparedAction] = []
        var later: [PreparedCardID] = []
        var dismissed: [PreparedCardID] = []
        var outcome: PreparedCardStager.Outcome = .notified
        var runsNow = true
    }

    private func handler(_ cards: [PreparedCard], _ calls: Calls, at date: Date? = nil) -> WatchPreparedCardHandler {
        let handler = WatchPreparedCardHandler()
        handler.cards = { cards }
        handler.stage = { card in calls.staged.append(card.id); return calls.outcome }
        handler.run = { action, _ in calls.ran.append(action); return calls.runsNow }
        handler.later = { calls.later.append($0.id) }
        handler.dismiss = { calls.dismissed.append($0.id) }
        handler.now = { date ?? self.now }
        handler.calendar = utc
        return handler
    }

    private func message(_ card: PreparedCard, _ action: String) -> [String: Any] {
        ["command": WatchPreparedCardWire.command, WatchPreparedCardWire.cardIDKey: card.id.rawValue,
         WatchPreparedCardWire.actionKey: action]
    }

    func testStageDoesWhatTheDisplaysSendOnPhoneDoes() async {
        let calls = Calls()
        let handler = handler([LensCardFixtures.leaveBy], calls)
        let reply = await handler.handle(message(LensCardFixtures.leaveBy, "stage"))
        XCTAssertEqual(calls.staged, [LensCardFixtures.leaveBy.id], "through the stager, the card from the feed")
        XCTAssertEqual(reply, .done(PreparedCardHUDBuilder.stagedLine))
        XCTAssertTrue(calls.ran.isEmpty && calls.later.isEmpty && calls.dismissed.isEmpty)
        calls.outcome = .openedComposer
        let open = await handler.handle(message(LensCardFixtures.leaveBy, "stage"))
        XCTAssertEqual(open, .done(PreparedCardHUDBuilder.stagedOpenLine))
        XCTAssertEqual(WatchPreparedCardCommand.dictionary(open)["response"] as? String, PreparedCardHUDBuilder.stagedOpenLine)
    }

    func testStageWithoutADraftIsRefused() async {
        let calls = Calls()
        let reply = await handler([LensCardFixtures.fitItIn], calls).handle(message(LensCardFixtures.fitItIn, "stage"))
        XCTAssertEqual(reply, .refused(WatchPreparedCardCommand.nothingToDoMessage))
        XCTAssertTrue(calls.staged.isEmpty)
    }

    func testDirectionsRunsTheCardsOwnDirections() async {
        let calls = Calls()
        let handler = handler([LensCardFixtures.leaveBy, LensCardFixtures.jobReportOwed], calls)
        let reply = await handler.handle(message(LensCardFixtures.leaveBy, "directions"))
        XCTAssertEqual(calls.ran, [.directions(destination: "1 Example Street", mode: .driving)])
        XCTAssertEqual(reply, .done(WatchPreparedCardCommand.directionsMessage))
        calls.runsNow = false
        let away = await handler.handle(message(LensCardFixtures.leaveBy, "directions"))
        XCTAssertEqual(away, .done(PreparedCardHUDBuilder.openOnPhoneLine), "a locked phone opens it when unlocked")
        let none = await handler.handle(message(LensCardFixtures.jobReportOwed, "directions"))
        XCTAssertEqual(none, .refused(WatchPreparedCardCommand.nothingToDoMessage))
    }

    func testLaterAndDismiss() async {
        let calls = Calls()
        let both = handler([LensCardFixtures.meetingFollowUp, LensCardFixtures.leaveBy], calls)
        let later = await both.handle(message(LensCardFixtures.meetingFollowUp, "later"))
        XCTAssertEqual(later, .done(WatchPreparedCardCommand.laterMessage))
        XCTAssertEqual(calls.later, [LensCardFixtures.meetingFollowUp.id])
        let dismissed = await both.handle(message(LensCardFixtures.leaveBy, "dismiss"))
        XCTAssertEqual(dismissed, .done(WatchPreparedCardCommand.dismissedMessage))
        XCTAssertEqual(calls.dismissed, [LensCardFixtures.leaveBy.id])

        // Due before any "later" option: it stays.
        let soon = handler([LensCardFixtures.leaveBy], calls, at: CardFixtures.at(18, 50))
        let refused = await soon.handle(message(LensCardFixtures.leaveBy, "later"))
        XCTAssertEqual(refused, .refused(WatchPreparedCardCommand.cannotWaitMessage))
        XCTAssertEqual(calls.later.count, 1)
    }

    func testAGoneHealthOrUnknownCommandIsRefused() {
        let cards = [LensCardFixtures.leaveBy, LensCardFixtures.shortNight]
        XCTAssertEqual(WatchPreparedCardCommand.resolve(message(LensCardFixtures.runningLate, "dismiss"), cards: cards),
                       .refuse(WatchPreparedCardCommand.goneMessage))
        XCTAssertEqual(WatchPreparedCardCommand.resolve(message(LensCardFixtures.shortNight, "stage"), cards: cards),
                       .refuse(WatchPreparedCardCommand.goneMessage), "a health card is never on the wrist")
        XCTAssertEqual(WatchPreparedCardCommand.resolve(message(LensCardFixtures.leaveBy, "send"), cards: cards),
                       .refuse(WatchPreparedCardCommand.nothingToDoMessage), "there is no send")
        XCTAssertEqual(WatchPreparedCardCommand.resolve([WatchPreparedCardWire.actionKey: "stage"], cards: cards),
                       .refuse(WatchPreparedCardCommand.goneMessage))
        XCTAssertEqual(WatchPreparedCardCommand.dictionary(.refused("x"))["error"] as? String, "x")
        XCTAssertEqual(Set(WatchPreparedCardAction.allCases.map(\.rawValue)), ["stage", "directions", "later", "dismiss"])
    }

    func testTheCommandIsAKnownWatchToken() {
        XCTAssertNotNil(WatchConnectivityManager.commandToken(WatchPreparedCardWire.command))
        XCTAssertEqual(WatchPreparedCardWire.command, "preparedCardAction")
        XCTAssertEqual(WatchPreparedCardWire.cardIDKey, "card_id")
        XCTAssertEqual(WatchPreparedCardWire.actionKey, "action")
    }
}
