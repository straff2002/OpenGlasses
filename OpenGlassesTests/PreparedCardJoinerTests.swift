import XCTest
@testable import OpenGlasses

/// Plan KT P0 — joining (§3): absorbing rows, chips, state, expiry, ranking, caps, and ids that
/// survive a rebuild.
final class PreparedCardJoinerTests: XCTestCase {
    private typealias F = CardFixtures
    private let joiner = F.joiner

    // MARK: - Absorbing

    func testALeaveByCardReplacesTheEventAndLeaveByRowsMyDayComposed() {
        let lunch = F.event("lunch", "Lunch", start: F.at(13))
        let inputs = F.gigInputs(distance: nil)
        var myDay = inputs.myDay
        myDay = F.myDay(events: [lunch, F.gig], travel: myDay.travel)
        let snapshot = MyDayComposer(calendar: F.calendar, locale: F.locale).compose(inputs: myDay, now: F.at(12))
        XCTAssertTrue(snapshot.allItems.contains { $0.id == MyDayItemID(source: .travel, rawValue: "leave-by:gig-1") })

        var cardInputs = inputs
        cardInputs.myDay = myDay
        let feed = F.rules.todayFeed(from: cardInputs, items: snapshot.allItems, settings: F.settings, now: F.at(17))
        XCTAssertEqual(feed.cards.map(\.kind), [.leaveBy])
        XCTAssertFalse(feed.rows.contains { $0.id.rawValue == "gig-1" })
        XCTAssertFalse(feed.rows.contains { $0.id.rawValue == "leave-by:gig-1" })
        XCTAssertTrue(feed.rows.contains { $0.id.rawValue == "lunch" })
        XCTAssertTrue(feed.absorbed.contains(CardRowID(source: "calendar", rawValue: "gig-1")))
    }

    func testOnlyShownCardsAbsorbRows() {
        let row = F.item(.calendar, "e1")
        let hidden = F.card(.fitItIn, "a", absorbs: [CardRowID(row.id)])
        let memory = [hidden.card.id: PreparedCardMemory(state: .dismissed, changedAt: F.at(9))]
        let feed = joiner.join([hidden], items: [row], memory: memory, now: F.at(10))
        XCTAssertTrue(feed.cards.isEmpty)
        XCTAssertEqual(feed.rows, [row])
    }

    func testJobDayRowsAreReportedAsAbsorbedForTheJobDayToDrop() {
        let card = F.card(.jobReportOwed, "s1", absorbs: [.jobDay("unsent-s1")])
        let feed = joiner.join([card], items: [], now: F.at(10))
        XCTAssertEqual(feed.absorbed, [.jobDay("unsent-s1")])
    }

    // MARK: - Caps

    func testTheMyDayPageShowsSixCardsAndTheHomeCardOneWithACountOfTheRest() {
        let cards = (0..<8).map { F.card(.fitItIn, "c\($0)", dueAt: F.at(10, $0)) }
        let feed = joiner.join(cards, items: [], now: F.at(9))
        XCTAssertEqual(feed.cards.count, PreparedCardJoiner.pageCardLimit)
        XCTAssertEqual(feed.topCard?.id.occurrence, "c0")
        XCTAssertEqual(feed.moreReadyCount, 5)
        XCTAssertEqual(TodayFeed.empty.moreReadyCount, 0)
    }

    func testOnlyOneShortNightADay() {
        let cards = [F.card(.shortNight, "a", dueAt: F.at(8)), F.card(.shortNight, "b", dueAt: F.at(9))]
        XCTAssertEqual(joiner.join(cards, items: [], now: F.at(7)).cards.map(\.id.occurrence), ["a"])
    }

    func testRowsKeepMyDaysCapWithTheRestInOverflow() {
        let items = (0..<8).map { F.item(.calendar, "e\($0)") }
        let feed = joiner.join([], items: items, now: F.at(9))
        XCTAssertEqual(feed.rows.map(\.id.rawValue), ["e0", "e1", "e2", "e3", "e4", "e5"])
        XCTAssertEqual(feed.overflow.map(\.id.rawValue), ["e6", "e7"])
    }

    // MARK: - Ranking

    func testCardsRankByUrgencyThenDueTimeThenKindThenID() {
        let cards = [
            F.card(.fitItIn, "late", urgency: .upcoming, dueAt: F.at(15)),
            F.card(.fitItIn, "none", urgency: .upcoming, dueAt: nil),
            F.card(.leaveBy, "now", urgency: .immediate, dueAt: F.at(10)),
            F.card(.fitItIn, "soon", urgency: .important, dueAt: F.at(10, 30)),
            F.card(.leaveBy, "tie", urgency: .upcoming, dueAt: F.at(15)),
        ]
        let order = joiner.join(cards, items: [], now: F.at(9)).cards.map(\.id.occurrence)
        XCTAssertEqual(order, ["now", "soon", "tie", "late", "none"])
    }

    func testJobKindsComeFirstOnAFieldAssistDay() {
        let cards = [F.card(.meetingFollowUp, "m"), F.card(.jobReportOwed, "j")]
        XCTAssertEqual(joiner.join(cards, items: [], now: F.at(9), isFieldAssistDay: true).cards.map(\.kind),
                       [.jobReportOwed, .meetingFollowUp])
        XCTAssertEqual(joiner.join(cards, items: [], now: F.at(9), isFieldAssistDay: false).cards.map(\.kind),
                       [.meetingFollowUp, .jobReportOwed])
    }

    // MARK: - Expiry and state

    func testAnExpiredCardIsGoneNotGreyed() {
        let card = F.card(.fitItIn, "a", validUntil: F.at(10))
        XCTAssertEqual(joiner.join([card], items: [], now: F.at(9, 59, 59)).cards.count, 1)
        XCTAssertTrue(joiner.join([card], items: [], now: F.at(10)).cards.isEmpty)
    }

    func testStateDecidesWhatIsShown() {
        let card = F.card(.fitItIn, "a")
        let table: [(PreparedCardState, Bool)] = [
            (.fresh, true),
            (.seen, true),
            (.later(until: F.at(11)), false),
            (.later(until: F.at(10)), true),
            (.handedOff(at: F.at(9), result: .sent), false),
            (.handedOff(at: F.at(9), result: .cancelled), true),
            (.handedOff(at: F.at(9), result: .unknown), true),
            (.done, false),
            (.dismissed, false),
            (.notUseful, false),
        ]
        for (state, shown) in table {
            let memory = [card.card.id: PreparedCardMemory(state: state, changedAt: F.at(9))]
            XCTAssertEqual(joiner.join([card], items: [], memory: memory, now: F.at(10)).cards.isEmpty, !shown,
                           "\(state)")
        }
    }

    func testAnEditedDraftSurvivesARebuildWithNewFacts() throws {
        let contacts = ["ana@example.com": CardContact(name: "Ana Example", phone: "555-0142")]
        let inputs = F.gigInputs(distance: nil, contacts: contacts)
        let first = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(16, 50))
            .cards.first)
        let memory = [first.id: PreparedCardMemory(state: .seen, editedText: "Leaving soon, see you inside",
                                                   changedAt: F.at(16, 55))]
        let rebuilt = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings,
                                                      memory: memory, now: F.at(18, 20)).cards.first)
        XCTAssertEqual(rebuilt.id, first.id)
        XCTAssertNotEqual(rebuilt.headline, first.headline)  // "Leave now" by then
        XCTAssertEqual(rebuilt.draft?.text, "Leaving soon, see you inside")
    }

    // MARK: - Ids stay put across rebuilds

    func testIDsAreStableAcrossRebuildsAndDistinctAcrossDaysAndKinds() {
        let rules = F.rules
        let early = rules.cards(from: F.gigInputs(distance: nil), now: F.at(16, 50), settings: F.settings)
        let later = rules.cards(from: F.gigInputs(distance: nil), now: F.at(18, 10), settings: F.settings)
        XCTAssertEqual(early.map(\.card.id), later.map(\.card.id))
        XCTAssertEqual(early.first?.card.id.rawValue, "leaveBy:gig-1:2026-11-12")

        let late = rules.cards(from: F.gigInputs(distance: 5_000), now: F.at(18, 40), settings: F.settings)
        XCTAssertEqual(late.first?.card.id.rawValue, "runningLate:gig-1:2026-11-12")

        var tomorrow = F.gig
        tomorrow = F.event("gig-1", tomorrow.title, start: F.at(19, day: 13), minutes: 120,
                           location: tomorrow.location, attendees: tomorrow.attendees)
        let next = rules.cards(from: CardInputs(myDay: F.myDay(events: [tomorrow], travel: F.travel(for: tomorrow))),
                               now: F.at(18, day: 13), settings: F.settings)
        XCTAssertEqual(next.first?.card.id.rawValue, "leaveBy:gig-1:2026-11-13")

        let jobs = rules.cards(from: F.jobInputs(), now: F.at(9, 10), settings: F.settings)
        let jobsAgain = rules.cards(from: F.jobInputs(), now: F.at(9, 20), settings: F.settings)
        XCTAssertEqual(jobs.map(\.card.id), jobsAgain.map(\.card.id))
    }

    // MARK: - Weather and location chips

    private func hour(_ start: Date, rain: Double = 0, celsius: Double = 15) -> CardWeatherHour {
        CardWeatherHour(start: start, precipitationChance: rain, temperatureCelsius: celsius)
    }

    func testRainAtTheDestinationDuringTheEventAddsAChipAFactAndTakesTheWeatherRow() throws {
        var inputs = F.gigInputs(distance: nil)
        inputs.destinationWeather = [hour(F.at(17), rain: 0.9), hour(F.at(19), rain: 0.2), hour(F.at(20), rain: 0.4)]
        let weatherRow = MyDayItem(id: MyDayItemID(source: .weather, rawValue: "current"), kind: .weather,
                                   title: "Weather", detail: "Showers", dueAt: nil, urgency: .important, actions: [])
        let feed = F.rules.todayFeed(from: inputs, items: [weatherRow], settings: F.settings, now: F.at(17))
        let card = try XCTUnwrap(feed.cards.first)
        XCTAssertEqual(card.signals.last, CardSignal(source: .weather, text: "Rain from 20:00"))
        XCTAssertEqual(card.facts.last, CardFact(label: "Weather", value: "Rain from 20:00 · take a coat"))
        XCTAssertTrue(feed.rows.isEmpty)
    }

    func testRainBelowFortyPercentOrOutsideTheEventAddsNothing() throws {
        var inputs = F.gigInputs(distance: nil)
        inputs.destinationWeather = [hour(F.at(16), rain: 0.9), hour(F.at(19), rain: 0.39), hour(F.at(21), rain: 0.9)]
        let card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertFalse(card.signals.contains { $0.source == .weather })
        XCTAssertFalse(card.absorbs.contains(PreparedCardJoiner.weatherRow))
    }

    func testColdBelowFiveDegreesAddsAChip() throws {
        var inputs = F.gigInputs(distance: nil)
        inputs.destinationWeather = [hour(F.at(19), celsius: 5), hour(F.at(20), celsius: 3)]
        let card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        let chip = try XCTUnwrap(card.signals.first { $0.source == .weather })
        XCTAssertTrue(chip.text.hasPrefix("Cold, 3"), chip.text)

        inputs.destinationWeather = [hour(F.at(19), celsius: 5)]
        let mild = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertFalse(mild.signals.contains { $0.source == .weather })
    }

    func testTheLocationChipSaysTheNeighbourhoodElseTheStreetAndNeverMakesACard() throws {
        var inputs = F.gigInputs(distance: nil)
        inputs.here = CardPlace(subLocality: "Example Vale", street: "2 Sample Road")
        var card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertEqual(card.signals.map(\.text), ["19:00", "You're in Example Vale"])

        inputs.here = CardPlace(subLocality: nil, street: "2 Sample Road")
        card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertEqual(card.signals.last?.text, "Near 2 Sample Road")

        inputs.here = CardPlace(subLocality: "A Neighbourhood With A Very Long Name", street: nil)
        card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertEqual(card.signals.count, 1)

        var nowhere = CardInputs(myDay: F.myDay())
        nowhere.here = CardPlace(subLocality: "Example Vale", street: nil)
        XCTAssertTrue(F.rules.todayFeed(from: nowhere, items: [], settings: F.settings, now: F.at(17)).cards.isEmpty)
    }

    func testChipsStopAtThreeWithLocationBeforeWeather() throws {
        var inputs = F.gigInputs(distance: nil)
        inputs.here = CardPlace(subLocality: "Example Vale", street: nil)
        inputs.destinationWeather = [hour(F.at(19), rain: 0.8)]
        let card = try XCTUnwrap(F.rules.todayFeed(from: inputs, items: [], settings: F.settings, now: F.at(17)).cards.first)
        XCTAssertEqual(card.signals.map(\.source), [.calendar, .location, .weather])
    }

    func testAPlaceFromGeocodingPrefersTheSubLocalityAndFallsBackToTheShortAddressStreet() {
        let place = GeocodingHelper.PlaceInfo(locality: nil, administrativeArea: nil, isoCountryCode: nil,
                                              thoroughfare: nil, subThoroughfare: nil, fullAddress: nil,
                                              location: nil, shortAddress: "2 Sample Road, Example Town",
                                              cityName: "Example Town", subLocality: "Example Vale")
        XCTAssertEqual(CardPlace(place), CardPlace(subLocality: "Example Vale", street: "2 Sample Road"))
        XCTAssertEqual(place.streetFromShortAddress, "2 Sample Road")
    }
}
