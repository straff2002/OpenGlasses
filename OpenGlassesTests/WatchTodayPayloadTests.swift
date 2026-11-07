import XCTest
@testable import OpenGlasses

/// Plan KS — the shared `today` payload: its codec and budget, the is-it-today rule, which item is
/// now, and when the phone looks again. All pure; the watch runs the same code.
final class WatchTodayPayloadTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private var utc: Calendar { calendar("UTC") }

    /// 2026-10-01 09:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_845_200)

    private func event(_ id: String, start: TimeInterval, end: TimeInterval, allDay: Bool = false,
                       title: String? = "Meeting", location: String? = nil) -> WatchTodayEvent {
        WatchTodayEvent(id: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                        isAllDay: allDay, title: title, location: location)
    }

    private func payload(events: [WatchTodayEvent] = [], at date: Date? = nil) -> WatchTodayPayload {
        let at = date ?? now
        return WatchTodayPayload(day: WatchTodayDay(at, calendar: utc), generatedAt: at,
                                 calendarStatus: .shown, events: events, moreEvents: 0, redacted: false,
                                 weatherStatus: .shown,
                                 weather: WatchTodayWeather(symbolName: "cloud.sun.fill", temperature: 14,
                                                            high: 17, low: 9, precipitationChance: 10,
                                                            condition: "Partly Cloudy", unit: .celsius),
                                 attribution: WatchTodayAttribution(
                                    serviceName: "Apple Weather",
                                    legalPageURL: "https://weatherkit.apple.com/legal-attribution.html"))
    }

    // MARK: - Codec

    func testRoundTripsAndStaysFarUnderBudget() throws {
        let full = payload(events: (0..<6).map {
            event("e\($0)", start: Double($0) * 3600, end: Double($0) * 3600 + 1800,
                  title: String(repeating: "T", count: 60), location: String(repeating: "L", count: 40))
        })
        let encoded = try WatchTodayCodec.encode(full).get()
        XCTAssertEqual(encoded.payload, full)
        XCTAssertLessThan(encoded.data.count, 2 * 1024, "six full items and the weather are well under 2 KB")
        XCTAssertEqual(WatchTodayCodec.decode(encoded.data), full)
    }

    func testOverBudgetDropsTrailingItemsAndCountsThem() throws {
        let big = payload(events: (0..<6).map {
            event("e\($0)", start: Double($0) * 60, end: Double($0) * 60 + 30,
                  // Distinct: a binary property list stores a repeated string once.
                  title: "\($0)" + String(repeating: "x", count: 2_000))
        })
        let encoded = try WatchTodayCodec.encode(big, budget: 7_000).get()
        XCTAssertLessThan(encoded.payload.events.count, 6)
        XCTAssertEqual(encoded.payload.events.count + encoded.payload.moreEvents, 6,
                       "every dropped item is still counted")
        XCTAssertLessThanOrEqual(encoded.data.count, 7_000)
        XCTAssertEqual(encoded.payload.events.map(\.id), Array(big.events.map(\.id).prefix(encoded.payload.events.count)),
                       "the trailing (latest) items go first")
    }

    func testRefusedWhenEvenNoItemsFit() {
        guard case .failure(.overBudget(_, let limit)) = WatchTodayCodec.encode(payload(), budget: 10) else {
            return XCTFail("a payload over budget with nothing to drop is refused")
        }
        XCTAssertEqual(limit, 10)
    }

    func testAnUnknownVersionDecodesToNothing() throws {
        var newer = payload()
        newer.version = WatchTodayWire.version + 1
        let data = try PropertyListEncoder().encode(newer)
        XCTAssertNil(WatchTodayCodec.decode(data))
        XCTAssertNil(WatchTodayCodec.decode(Data("not a plist".utf8)))
    }

    // MARK: - Is it today?

    func testTodayIsCurrentAndYesterdayIsStale() {
        let today = payload()
        XCTAssertEqual(WatchTodayFreshness.evaluate(today, now: now.addingTimeInterval(3600), calendar: utc),
                       .current(today))
        let yesterday = payload(at: now.addingTimeInterval(-86_400))
        XCTAssertEqual(WatchTodayFreshness.evaluate(yesterday, now: now, calendar: utc), .stale)
        XCTAssertEqual(WatchTodayFreshness.evaluate(nil, now: now, calendar: utc), .absent)
    }

    func testTheDayTurnsAtTheWatchesOwnMidnight() {
        // Built at 23:50 in Auckland; at 00:05 there it is yesterday's.
        let auckland = calendar("Pacific/Auckland")
        var parts = DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 50)
        let built = auckland.date(from: parts)!
        parts.day = 2; parts.hour = 0; parts.minute = 5
        let after = auckland.date(from: parts)!
        let value = WatchTodayPayload(day: WatchTodayDay(built, calendar: auckland), generatedAt: built,
                                      calendarStatus: .shown, events: [], moreEvents: 0, redacted: false,
                                      weatherStatus: .unavailable, weather: nil, attribution: nil)
        XCTAssertEqual(WatchTodayFreshness.evaluate(value, now: built.addingTimeInterval(300), calendar: auckland),
                       .current(value))
        XCTAssertEqual(WatchTodayFreshness.evaluate(value, now: after, calendar: auckland), .stale)
    }

    func testSettingOffIsItsOwnState() {
        XCTAssertEqual(WatchTodayFreshness.evaluate(.settingOff(at: now, calendar: utc), now: now, calendar: utc),
                       .settingOff)
    }

    // MARK: - Which item is now

    func testMarksNowThenNextAndDropsWhatHasEnded() {
        let rows = WatchTodayTimeline.rows([
            event("allday", start: -9 * 3600, end: 15 * 3600, allDay: true),
            event("over", start: -7200, end: -3600),
            event("now", start: -600, end: 1200),
            event("next", start: 3600, end: 5400),
            event("later", start: 7200, end: 9000),
        ], now: now)
        XCTAssertEqual(rows.map(\.id), ["allday", "now", "next", "later"])
        XCTAssertEqual(rows.map(\.mark), [.allDay, .now, .next, .later])
    }

    func testAnItemEndingThisMinuteIsGone() {
        XCTAssertTrue(WatchTodayTimeline.rows([event("e", start: -600, end: 0)], now: now).isEmpty)
        XCTAssertEqual(WatchTodayTimeline.rows([event("e", start: 0, end: 600)], now: now).first?.mark, .now)
    }

    // MARK: - When to look again

    func testNextMidnightIsJustPastTheNextLocalMidnight() {
        let fire = WatchTodaySchedule.nextMidnight(after: now, calendar: utc)
        XCTAssertEqual(fire, utc.startOfDay(for: now).addingTimeInterval(86_400 + 5))
        // Already past midnight by a second: the next one, not the one just gone.
        let justAfter = utc.startOfDay(for: now).addingTimeInterval(1)
        XCTAssertEqual(WatchTodaySchedule.nextMidnight(after: justAfter, calendar: utc),
                       utc.startOfDay(for: now).addingTimeInterval(86_400 + 5))
    }

    func testNextMidnightAcrossADaylightSavingChange() {
        // New Zealand springs forward at 02:00 on 2026-09-27; that day is 23 hours long.
        let auckland = calendar("Pacific/Auckland")
        let noon = auckland.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
        let fire = WatchTodaySchedule.nextMidnight(after: noon, calendar: auckland)
        let parts = auckland.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        XCTAssertEqual([parts.month, parts.day, parts.hour, parts.minute, parts.second], [9, 28, 0, 0, 5])
    }

    func testRefreshIsDueOnNothingANewDayOrAfterTheInterval() {
        XCTAssertTrue(WatchTodaySchedule.isRefreshDue(lastGeneratedAt: nil, now: now, calendar: utc))
        XCTAssertFalse(WatchTodaySchedule.isRefreshDue(lastGeneratedAt: now.addingTimeInterval(-60),
                                                       now: now, calendar: utc))
        XCTAssertTrue(WatchTodaySchedule.isRefreshDue(lastGeneratedAt: now.addingTimeInterval(-15 * 60),
                                                      now: now, calendar: utc))
        let lateLastNight = utc.startOfDay(for: now).addingTimeInterval(-60)
        XCTAssertTrue(WatchTodaySchedule.isRefreshDue(lastGeneratedAt: lateLastNight,
                                                      now: utc.startOfDay(for: now).addingTimeInterval(30),
                                                      calendar: utc),
                      "a new day is due at once, whatever the interval")
        XCTAssertTrue(WatchTodaySchedule.isRefreshDue(lastGeneratedAt: now.addingTimeInterval(60),
                                                      now: now, calendar: utc),
                      "a clock set back is due")
    }
}
