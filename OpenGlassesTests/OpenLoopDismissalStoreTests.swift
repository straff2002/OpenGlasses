import XCTest
@testable import OpenGlasses

/// Plan LE P1 — the check-in's dismissal and said-today records: `UserDefaults` + JSON, day-scoped,
/// pinned to each loop's fingerprint, and holding no title. Invented titles only.
final class OpenLoopDismissalStoreTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OpenLoopDismissalStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> OpenLoopDismissalStore {
        OpenLoopDismissalStore(defaults: defaults, calendar: { F.calendar })
    }

    func testADismissalRoundTripsThroughANewStore() {
        let loop = F.reminder("r1", "Renew the registration", due: F.at(9))
        store().dismiss(loop, on: F.now)
        let reread = store().dismissed(on: F.at(22))
        XCTAssertEqual(reread, [loop.id: loop.fingerprint])
        XCTAssertTrue(OpenLoopDismissals.isDismissed(loop, in: reread))
    }

    func testADismissalLapsesWithTheDay() {
        let loop = F.reminder("r1", "Renew the registration", due: F.at(9))
        store().dismiss(loop, on: F.now)
        XCTAssertTrue(store().dismissed(on: F.at(8, day: 15)).isEmpty, "tomorrow is a new question")

        // The next write rolls the record over rather than carrying yesterday's.
        let other = F.reminder("r2", "Call the plumber", due: F.at(9, day: 15))
        store().dismiss(other, on: F.at(8, day: 15))
        XCTAssertEqual(Array(store().dismissed(on: F.at(9, day: 15)).keys), ["reminder:r2"])
    }

    func testAChangedLoopComesBackTheSameNight() {
        let loop = F.reminder("r1", "Renew the registration", due: F.at(9))
        store().dismiss(loop, on: F.now)
        let moved = F.reminder("r1", "Renew the registration", due: F.at(20))
        let collected = OpenLoopCollector.collect([moved], dismissed: store().dismissed(on: F.now),
                                                  now: F.now, calendar: F.calendar)
        XCTAssertEqual(collected.loops.map(\.id), ["reminder:r1"], "moved to another time is new news")
    }

    func testSaidLoopsAreKeptApartFromDismissedOnes() {
        let said = F.reminder("r1", "Renew", due: F.at(9))
        store().markSaid([said], on: F.now)
        XCTAssertTrue(store().dismissed(on: F.now).isEmpty)
        XCTAssertEqual(store().said(on: F.now), [said.id: said.fingerprint])

        let collected = OpenLoopCollector.collect([said], dismissed: [:], said: store().said(on: F.now),
                                                  now: F.now, calendar: F.calendar)
        XCTAssertTrue(collected.isEmpty, "said once today is not said again")
    }

    func testNothingOfALoopsWordsIsKept() throws {
        let loop = OpenLoop(id: "report:q1", source: .jobReport, title: "Work order", job: .customer("Smith"),
                            since: F.at(13), action: .open(.job(.send(queuedId: "q1"))))
        let named = F.reminder("r1", "Ring Aroha about the deposit", due: F.at(9))
        store().dismiss(loop, on: F.now)
        store().markSaid([named], on: F.now)
        for key in [OpenLoopDismissalStore.dismissedKey, OpenLoopDismissalStore.saidKey] {
            let data = try XCTUnwrap(defaults.data(forKey: key))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("Smith"))
            XCTAssertFalse(text.contains("Aroha"))
            XCTAssertFalse(text.contains("Work order"))
        }
    }

    func testDeleteAllClearsBoth() {
        let loop = F.reminder("r1", "Renew", due: F.at(9))
        store().dismiss(loop, on: F.now)
        store().markSaid([loop], on: F.now)
        store().deleteAll()
        XCTAssertTrue(store().dismissed(on: F.now).isEmpty)
        XCTAssertTrue(store().said(on: F.now).isEmpty)
    }

    func testTheStoreIsRegistered() {
        let record = SensitiveStore.checkInDismissals.record
        XCTAssertEqual(record.owner, "OpenLoopDismissalStore")
        XCTAssertEqual(record.deleteSubject, .notSubjectLinked)
    }
}
