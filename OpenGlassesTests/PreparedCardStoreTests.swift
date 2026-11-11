import XCTest
@testable import OpenGlasses

/// Plan KT P1 — the card store (§3.5): state and edits survive a relaunch, entries end a day after
/// their card, "not useful" turns a kind off on the third press in 14 days, and erasure reaches
/// an edited draft. Invented names only.
@MainActor
final class PreparedCardStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedCardStore_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func card(_ occurrence: String = "gig", kind: PreparedCardKind = .leaveBy,
                      validUntil: Date = CardFixtures.at(19)) -> PreparedCard {
        CardFixtures.card(kind, occurrence, validUntil: validUntil).card
    }

    func testStateAndEditSurviveARelaunch() {
        let now = CardFixtures.at(17)
        let store = PreparedCardStore(directory: directory)
        let gig = card()
        store.setEdit("Leaving now, Ana", base: "On my way — there about 18:45.", for: gig, now: now)
        store.record(.later(until: CardFixtures.at(18)), for: gig, now: now)

        let reopened = PreparedCardStore(directory: directory)
        let memory = reopened.memory[gig.id]
        XCTAssertEqual(memory?.state, .later(until: CardFixtures.at(18)))
        XCTAssertEqual(memory?.editedText, "Leaving now, Ana")
        XCTAssertEqual(reopened.entry(for: gig.id)?.editedFrom, "On my way — there about 18:45.")
        XCTAssertEqual(reopened.entry(for: gig.id)?.expiresAt, CardFixtures.at(19).addingTimeInterval(24 * 3600))
    }

    func testAnEditBackToTheDraftIsNoEdit() {
        let store = PreparedCardStore(directory: directory)
        let gig = card()
        store.setEdit("Changed", base: "Original", for: gig, now: CardFixtures.at(17))
        store.setEdit("Original", base: "Original", for: gig, now: CardFixtures.at(17))
        XCTAssertNil(store.memory[gig.id]?.editedText)
        XCTAssertNil(store.entry(for: gig.id)?.editedFrom)
    }

    func testACancelledHandOffKeepsTheEdit() {
        let store = PreparedCardStore(directory: directory)
        let gig = card()
        store.setEdit("Leaving now, Ana", base: "On my way", for: gig, now: CardFixtures.at(17))
        store.record(.fresh, for: gig, now: CardFixtures.at(17, 5))
        XCTAssertEqual(store.memory[gig.id]?.state, .fresh)
        XCTAssertEqual(store.memory[gig.id]?.editedText, "Leaving now, Ana")
    }

    func testMarkSeenMovesOnlyFreshCards() {
        let store = PreparedCardStore(directory: directory)
        let dismissed = card("a")
        let fresh = card("b")
        store.record(.dismissed, for: dismissed, now: CardFixtures.at(9))
        store.markSeen([dismissed, fresh], now: CardFixtures.at(10))
        XCTAssertEqual(store.memory[dismissed.id]?.state, .dismissed)
        XCTAssertEqual(store.memory[fresh.id]?.state, .seen)
    }

    func testEntriesGoADayAfterTheirCardEnds() {
        let store = PreparedCardStore(directory: directory)
        let gig = card(validUntil: CardFixtures.at(19))
        store.record(.dismissed, for: gig, now: CardFixtures.at(17))
        store.prune(now: CardFixtures.at(18, day: 13))
        XCTAssertNotNil(store.entry(for: gig.id), "still inside the day after")
        store.prune(now: CardFixtures.at(19, 1, day: 13))
        XCTAssertNil(store.entry(for: gig.id))
        XCTAssertNil(PreparedCardStore(directory: directory).entry(for: gig.id), "and gone from the file")
    }

    func testTheThirdNotUsefulInFourteenDaysTurnsTheKindOff() {
        let store = PreparedCardStore(directory: directory)
        XCTAssertFalse(store.notUseful(card("1", kind: .fitItIn), now: CardFixtures.at(9, day: 1)))
        XCTAssertFalse(store.notUseful(card("2", kind: .fitItIn), now: CardFixtures.at(9, day: 5)))
        XCTAssertTrue(store.notUseful(card("3", kind: .fitItIn), now: CardFixtures.at(9, day: 14)))
    }

    func testNotUsefulOutsideTheWindowDoesNotCount() {
        let store = PreparedCardStore(directory: directory)
        store.notUseful(card("1", kind: .fitItIn), now: CardFixtures.at(9, day: 1))
        store.notUseful(card("2", kind: .fitItIn), now: CardFixtures.at(9, day: 2))
        XCTAssertFalse(store.notUseful(card("3", kind: .fitItIn), now: CardFixtures.at(10, day: 16)),
                       "the first two are more than 14 days old by now")
        XCTAssertFalse(store.notUseful(card("4", kind: .leaveBy), now: CardFixtures.at(10, day: 16)),
                       "another kind's presses are its own")
    }

    func testUndoForgetsTheKindsPresses() {
        let store = PreparedCardStore(directory: directory)
        for day in 1...3 { store.notUseful(card("\(day)", kind: .fitItIn), now: CardFixtures.at(9, day: day)) }
        store.clearNotUseful(.fitItIn)
        XCTAssertFalse(store.notUseful(card("4", kind: .fitItIn), now: CardFixtures.at(9, day: 4)))
    }

    func testRestoreBringsACardBackWithItsEdit() {
        let store = PreparedCardStore(directory: directory)
        let gig = card()
        store.setEdit("Mine", base: "Theirs", for: gig, now: CardFixtures.at(17))
        store.record(.dismissed, for: gig, now: CardFixtures.at(17))
        store.restore(gig.id, now: CardFixtures.at(17, 1))
        XCTAssertEqual(store.memory[gig.id]?.state, .fresh)
        XCTAssertEqual(store.memory[gig.id]?.editedText, "Mine")
    }

    // MARK: - Erasure

    func testForgetRemovesEveryEntryWhoseDraftNamesThePerson() {
        let store = PreparedCardStore(directory: directory)
        store.setEdit("Hi Hana, on my way", base: "On my way", for: card("a"), now: CardFixtures.at(9))
        store.setEdit("Running late", base: "On my way", for: card("b"), now: CardFixtures.at(9))
        store.record(.dismissed, for: card("c"), now: CardFixtures.at(9))
        XCTAssertEqual(store.forget(matching: "hana"), 1)
        XCTAssertEqual(Set(PreparedCardStore(directory: directory).entries.keys),
                       [card("b").id.rawValue, card("c").id.rawValue])
    }

    func testForgetReachesTheDraftAnEditStartedFrom() {
        let store = PreparedCardStore(directory: directory)
        store.setEdit("See you soon", base: "Hi Hana, on my way", for: card("a"), now: CardFixtures.at(9))
        XCTAssertEqual(store.forget(matching: "Hana"), 1)
    }

    func testDeleteAllRemovesTheFile() {
        let store = PreparedCardStore(directory: directory)
        store.record(.dismissed, for: card(), now: CardFixtures.at(9))
        store.deleteAll()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cards.json").path))
    }

    func testTheErasureWalkReachesTheStore() async {
        let store = PreparedCardStore(directory: directory)
        store.setEdit("Hi Hana, on my way", base: "On my way", for: card("a"), now: CardFixtures.at(9))
        var stores = SubjectErasureCoordinator.Stores()
        stores.preparedCards = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("Hana"))
        XCTAssertTrue(receipts.contains { $0.store == .preparedCards })
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Later

    func testLaterOffersOnlyWhatTheCardOutlives() {
        let calendar = CardFixtures.calendar
        XCTAssertEqual(PreparedCardLaterOption.available(validUntil: CardFixtures.at(19), now: CardFixtures.at(17),
                                                         calendar: calendar), [.inAnHour, .thisEvening])
        XCTAssertEqual(PreparedCardLaterOption.available(validUntil: CardFixtures.at(17, 30), now: CardFixtures.at(17),
                                                         calendar: calendar), [])
        XCTAssertEqual(PreparedCardLaterOption.available(validUntil: CardFixtures.at(12, day: 13), now: CardFixtures.at(10),
                                                         calendar: calendar), [.inAnHour, .thisEvening, .tomorrowMorning])
        XCTAssertNil(PreparedCardLaterOption.thisEvening.until(now: CardFixtures.at(18, 30), calendar: calendar),
                     "this evening, once it is the evening, is not an offer")
    }
}
