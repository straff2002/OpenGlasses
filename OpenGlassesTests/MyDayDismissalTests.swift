import XCTest
@testable import OpenGlasses

/// Clearing a row from today's card: what it survives, when it lapses, and the line it never
/// crosses.
final class MyDayDismissalTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ hour: Int, day: Int = 30) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                       year: 2026, month: 8, day: day, hour: hour).date!
    }

    private func item(_ raw: String, source: MyDaySource = .calendar,
                      title: String = "Birthday", dueAt: Date? = nil) -> MyDayItem {
        MyDayItem(id: .init(source: source, rawValue: raw), kind: .event, title: title,
                  detail: nil, dueAt: dueAt, urgency: .upcoming, actions: [.open])
    }

    // MARK: - Surviving the day

    /// The card recomposes on every foreground and every calendar change. A dismissal that did not
    /// survive that would not be a dismissal at all.
    func testADismissalSurvivesEveryRefreshWithinItsDay() {
        let row = item("birthday")
        let stored = MyDayDismissalPolicy.adding(row, to: .empty, on: date(9), calendar: calendar)

        for hour in [9, 12, 17, 23] {
            let active = MyDayDismissalPolicy.active(stored, on: date(hour), calendar: calendar)
            XCTAssertTrue(MyDayDismissalPolicy.isDismissed(row, in: active),
                          "The cleared row came back at \(hour):00")
        }
    }

    /// "Not today" is what the wearer meant, so tomorrow's card asks again.
    func testADismissalLapsesWhenTheDayRollsOver() {
        let row = item("birthday")
        let stored = MyDayDismissalPolicy.adding(row, to: .empty, on: date(23), calendar: calendar)

        let tomorrow = MyDayDismissalPolicy.active(stored, on: date(9, day: 31), calendar: calendar)
        XCTAssertTrue(tomorrow.isEmpty)
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(row, in: tomorrow))
    }

    /// Clearing a second row on a new day does not drag yesterday's record along with it.
    func testANewDaysDismissalDropsThePreviousDaysRecord() {
        let yesterday = MyDayDismissalPolicy.adding(item("old"), to: .empty,
                                                    on: date(9), calendar: calendar)
        let today = MyDayDismissalPolicy.adding(item("new"), to: yesterday,
                                                on: date(9, day: 31), calendar: calendar)
        XCTAssertEqual(Set(today.fingerprints.keys), ["calendar:new"])
        XCTAssertEqual(today.dayKey, "2026-08-31")
    }

    // MARK: - Identity

    /// The ids come from EventKit and are stable, which is what makes a dismissal stick — and would
    /// also keep a *rescheduled* event hidden. The fingerprint is what stops that.
    func testAChangedRowIsNoLongerCovered() {
        let original = item("standup", title: "Standup", dueAt: date(10))
        let stored = MyDayDismissalPolicy.adding(original, to: .empty, on: date(9),
                                                 calendar: calendar)
        let active = MyDayDismissalPolicy.active(stored, on: date(9), calendar: calendar)

        XCTAssertTrue(MyDayDismissalPolicy.isDismissed(original, in: active))
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(
            item("standup", title: "Standup", dueAt: date(15)), in: active),
            "A rescheduled row stayed hidden")
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(
            item("standup", title: "Standup — moved", dueAt: date(10)), in: active),
            "A renamed row stayed hidden")
    }

    /// Raw ids are only unique within their source, so the key carries the source too.
    func testKeysAreNamespacedBySource() {
        XCTAssertEqual(item("x", source: .calendar).id.dismissalKey, "calendar:x")
        XCTAssertEqual(item("x", source: .reminders).id.dismissalKey, "reminders:x")

        let stored = MyDayDismissalPolicy.adding(item("x", source: .calendar), to: .empty,
                                                 on: date(9), calendar: calendar)
        let active = MyDayDismissalPolicy.active(stored, on: date(9), calendar: calendar)
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(item("x", source: .reminders), in: active),
                       "Clearing a calendar row also cleared a reminder that shares its raw id")
    }

    /// Clearing one row says nothing about any other, so new information is never suppressed by an
    /// unrelated dismissal.
    func testClearingOneRowLeavesEveryOtherRowAlone() {
        let stored = MyDayDismissalPolicy.adding(item("birthday"), to: .empty,
                                                 on: date(9), calendar: calendar)
        let active = MyDayDismissalPolicy.active(stored, on: date(9), calendar: calendar)
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(item("standup"), in: active))
        XCTAssertEqual(active.count, 1)
    }

    // MARK: - Store

    func testTheStoreRoundTripsAndRollsOver() {
        let defaults = UserDefaults(suiteName: "MyDayDismissalTests-\(UUID().uuidString)")!
        let store = MyDayDismissalStore(defaults: defaults, calendar: { [self] in calendar })
        let row = item("birthday")

        XCTAssertTrue(store.active(on: date(9)).isEmpty)

        store.dismiss(row, on: date(9))
        XCTAssertTrue(MyDayDismissalPolicy.isDismissed(row, in: store.active(on: date(17))))
        XCTAssertFalse(MyDayDismissalPolicy.isDismissed(row, in: store.active(on: date(9, day: 31))))

        store.clearAll()
        XCTAssertTrue(store.active(on: date(9)).isEmpty)
    }
}
