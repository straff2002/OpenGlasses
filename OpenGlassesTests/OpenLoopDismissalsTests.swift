import XCTest
@testable import OpenGlasses

/// Plan LE P0 — `OpenLoopDismissals`: a loop cleared from tonight's check-in stays cleared for
/// every read tonight, comes back when it changes, and lapses with the day.
final class OpenLoopDismissalsTests: XCTestCase {
    private typealias F = OpenLoopFixture

    func testADismissalHoldsAllEveningAndLapsesWithTheDay() {
        let report = F.report("q1", job: .customer("Smith"))
        let record = OpenLoopDismissals.empty.adding(report, on: F.at(21), calendar: F.calendar)
        XCTAssertEqual(record.dayKey, "2026-11-14")

        for minute in stride(from: 0, through: 170, by: 10) {
            let active = record.active(on: F.at(21).addingTimeInterval(TimeInterval(minute * 60)), calendar: F.calendar)
            XCTAssertTrue(OpenLoopDismissals.isDismissed(report, in: active), "minute \(minute)")
        }
        XCTAssertEqual(record.active(on: F.at(0, 1, day: 15), calendar: F.calendar), [:])
    }

    func testAChangedLoopIsNewNews() {
        let staged = F.report("q1", job: .customer("Smith"))
        let active = OpenLoopDismissals.empty.adding(staged, on: F.at(21), calendar: F.calendar)
            .active(on: F.at(21, 30), calendar: F.calendar)
        let failedSince = F.report("q1", job: .customer("Smith"), failed: true)
        XCTAssertFalse(OpenLoopDismissals.isDismissed(failedSince, in: active),
                       "a staged report that has since failed to send comes back")
    }

    func testAddingOnANewDayStartsAFreshRecord() {
        let first = OpenLoopDismissals.empty.adding(F.reminder("r1", "Book the skip", due: nil), on: F.at(21),
                                                    calendar: F.calendar)
        let next = first.adding(F.reminder("r2", "Lock the shed", due: nil), on: F.at(21, day: 15),
                                calendar: F.calendar)
        XCTAssertEqual(next.dayKey, "2026-11-15")
        XCTAssertEqual(Array(next.fingerprints.keys), ["reminder:r2"])
    }

    func testTheRecordRoundTrips() throws {
        let record = OpenLoopDismissals.empty.adding(F.approval(1, "Your OK", since: F.at(9)), on: F.at(21),
                                                     calendar: F.calendar)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(OpenLoopDismissals.self, from: data), record)
    }
}
