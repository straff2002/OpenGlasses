import WeatherKit
import XCTest
@testable import OpenGlasses

/// Plan KS — the `today` value built from what My Day gathered: which items, in what order, what a
/// Medical Compliance mode withholds, each section's stated reason, the weather in the wearer's
/// unit with its credit, and a locked look never hiding a good one.
final class WatchTodayBuilderTests: XCTestCase {

    private let calendar = WeatherFixtures.utcCalendar
    /// 2026-10-01 09:00 UTC.
    private let now = WeatherFixtures.now
    private let credit = WatchTodayAttribution(serviceName: "Apple Weather",
                                               legalPageURL: "https://weatherkit.apple.com/legal-attribution.html")

    private func inputs(medical: MedicalEgressGuard.Mode = .off,
                        unit: WatchTodayTemperatureUnit = .celsius,
                        at date: Date? = nil) -> WatchTodayBuilder.Inputs {
        .init(now: date ?? now, calendar: calendar, medical: medical, temperatureUnit: unit,
              attribution: credit, conditionText: { WeatherConditionPhrase.phrase($0) })
    }

    private func event(_ id: String, start: TimeInterval, end: TimeInterval, allDay: Bool = false,
                       title: String = "Site visit", location: String? = "12 Queen Street") -> MyDayCalendarEvent {
        MyDayCalendarEvent(id: id, title: title, startDate: now.addingTimeInterval(start),
                           endDate: now.addingTimeInterval(end), isAllDay: allDay, location: location)
    }

    private func gathered(events: [MyDayCalendarEvent] = [],
                          calendarState: MyDaySourceState? = .available(.calendar),
                          calendarIncluded: Bool = true,
                          weather: MyDayWeather? = .init(summary: "Mild.", isDecisionRelevant: false,
                                                         report: WeatherFixtures.report()),
                          weatherState: MyDaySourceState? = .available(.weather),
                          weatherIncluded: Bool = true,
                          locked: Bool = false,
                          at date: Date? = nil) -> MyDayGathered {
        MyDayGathered(generatedAt: date ?? now, locked: locked, calendarIncluded: calendarIncluded,
                      events: events, calendarState: calendarState, weatherIncluded: weatherIncluded,
                      weather: weather, weatherState: weatherState)
    }

    // MARK: - Calendar

    func testTheNextOfTodaysItemsAllDayFirstThenByStart() {
        let value = WatchTodayBuilder.payload(from: gathered(events: [
            event("later", start: 7200, end: 9000),
            event("over", start: -7200, end: -3600),
            event("tomorrow", start: 86_400, end: 90_000),
            event("now", start: -600, end: 1200),
            event("allday", start: -9 * 3600, end: 15 * 3600, allDay: true),
            event("yesterday", start: -2 * 86_400, end: -86_400 - 3600),
        ]), inputs())
        XCTAssertEqual(value.calendarStatus, .shown)
        XCTAssertEqual(value.events.map(\.id), ["allday", "now", "later"])
        XCTAssertEqual(value.moreEvents, 0)
        XCTAssertEqual(value.day, WatchTodayDay(year: 2026, month: 10, day: 1))
        XCTAssertEqual(value.events.first { $0.id == "now" }?.title, "Site visit")
        XCTAssertEqual(value.events.first { $0.id == "now" }?.location, "12 Queen Street")
        XCTAssertFalse(value.redacted)
    }

    func testAtMostSixAndTheRestCounted() {
        let many = (0..<9).map { event("e\($0)", start: Double($0) * 1800 + 60, end: Double($0) * 1800 + 900) }
        let value = WatchTodayBuilder.payload(from: gathered(events: many), inputs())
        XCTAssertEqual(value.events.map(\.id), ["e0", "e1", "e2", "e3", "e4", "e5"])
        XCTAssertEqual(value.moreEvents, 3)
    }

    func testAnyMedicalComplianceModeSendsTimesAndCountsOnly() {
        for mode in [MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false), .localOnly] {
            let many = (0..<8).map { event("e\($0)", start: Double($0) * 1800 + 60, end: Double($0) * 1800 + 900) }
            let value = WatchTodayBuilder.payload(from: gathered(events: many), inputs(medical: mode))
            XCTAssertTrue(value.redacted)
            XCTAssertEqual(value.events.count, 6)
            XCTAssertEqual(value.moreEvents, 2)
            XCTAssertTrue(value.events.allSatisfy { $0.title == nil && $0.location == nil })
            XCTAssertEqual(value.events.first?.start, many.first?.startDate)
            let data = try? WatchTodayCodec.encode(value).get().data
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            XCTAssertFalse(text.contains("Site visit") || text.contains("Queen Street"),
                           "nothing of a title or place is on the wire")
        }
    }

    func testLongTitlesAndPlacesAreShortenedToTheirFirstLine() {
        let value = WatchTodayBuilder.payload(from: gathered(events: [
            event("e", start: 60, end: 600, title: String(repeating: "a", count: 90),
                  location: "Unit 4, Long Industrial Estate Road Name\nAuckland 1010\nNew Zealand"),
        ]), inputs())
        let item = value.events.first
        XCTAssertEqual(item?.title?.count, WatchTodayBuilder.titleLimit)
        XCTAssertEqual(item?.title?.last, "\u{2026}")
        XCTAssertEqual(item?.location, "Unit 4, Long Industrial Estate Road Name")
        XCTAssertLessThanOrEqual(item?.location?.count ?? 0, WatchTodayBuilder.locationLimit)
    }

    func testEachCalendarStateHasItsReason() {
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathered(calendarIncluded: false), inputs()).calendarStatus,
                       .notIncluded)
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathered(calendarState: .denied(.calendar)), inputs()).calendarStatus,
                       .noAccess)
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathered(calendarState: .unavailable(.calendar)), inputs()).calendarStatus,
                       .unavailable)
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathered(locked: true), inputs()).calendarStatus, .locked)
        let empty = WatchTodayBuilder.payload(from: gathered(events: []), inputs())
        XCTAssertEqual(empty.calendarStatus, .shown, "an empty day is shown, as nothing else today")
        XCTAssertTrue(empty.events.isEmpty)
    }

    func testTheDayIsTheDayItWasGathered() {
        // Pushed again after midnight, yesterday's gathering still says yesterday — the watch then
        // reads it as stale rather than as today's.
        let value = WatchTodayBuilder.payload(from: gathered(events: [event("e", start: 3600, end: 7200)]),
                                              inputs(at: now.addingTimeInterval(86_400)))
        XCTAssertEqual(value.day, WatchTodayDay(year: 2026, month: 10, day: 1))
        XCTAssertTrue(value.events.isEmpty, "its items have all ended by then")
    }

    // MARK: - Weather

    func testWeatherInTheWearersUnitWithTheCredit() throws {
        let report = WeatherFixtures.report(
            current: .init(temperatureC: 14.4, apparentTemperatureC: 12, condition: .partlyCloudy,
                           windKmh: 10, humidity: 0.5, symbolName: "cloud.sun.fill"),
            days: [WeatherFixtures.day(0, high: 17.6, low: 9.2, chance: 0.34)])
        let gathering = gathered(weather: .init(summary: "", isDecisionRelevant: false, report: report))

        let metric = try XCTUnwrap(WatchTodayBuilder.payload(from: gathering, inputs()).weather)
        XCTAssertEqual(metric, WatchTodayWeather(symbolName: "cloud.sun.fill", temperature: 14, high: 18, low: 9,
                                                 precipitationChance: 34, condition: "partly cloudy",
                                                 unit: .celsius))
        let imperial = try XCTUnwrap(WatchTodayBuilder.payload(from: gathering, inputs(unit: .fahrenheit)).weather)
        XCTAssertEqual([imperial.temperature, imperial.high, imperial.low], [58, 64, 49])
        XCTAssertEqual(imperial.unit, .fahrenheit)
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathering, inputs()).attribution, credit)
    }

    func testAMissingSymbolFallsBackFromTheCondition() throws {
        let report = WeatherFixtures.report(current: WeatherFixtures.current(.heavyRain))
        let value = WatchTodayBuilder.payload(
            from: gathered(weather: .init(summary: "", isDecisionRelevant: true, report: report)), inputs())
        XCTAssertEqual(try XCTUnwrap(value.weather).symbolName, "cloud.heavyrain.fill")
    }

    func testEachWeatherStateHasItsReasonAndNoCreditWithoutWeather() {
        let off = WatchTodayBuilder.payload(from: gathered(weatherIncluded: false), inputs())
        XCTAssertEqual(off.weatherStatus, .notIncluded)
        XCTAssertNil(off.weather)
        XCTAssertNil(off.attribution)

        let localOnly = WatchTodayBuilder.payload(from: gathered(), inputs(medical: .localOnly))
        XCTAssertEqual(localOnly.weatherStatus, .medicalOff)
        XCTAssertNil(localOnly.weather)

        let complianceOnly = WatchTodayBuilder.payload(
            from: gathered(), inputs(medical: .init(hipaaMode: true, localOnly: false)))
        XCTAssertEqual(complianceOnly.weatherStatus, .shown, "weather is not about the wearer's day")

        let failed = WatchTodayBuilder.payload(from: gathered(weather: nil, weatherState: .unavailable(.weather)),
                                               inputs())
        XCTAssertEqual(failed.weatherStatus, .unavailable)
        let noReport = WatchTodayBuilder.payload(
            from: gathered(weather: .init(summary: "Mild.", isDecisionRelevant: false)), inputs())
        XCTAssertEqual(noReport.weatherStatus, .unavailable, "a summary without numbers draws nothing")
        XCTAssertNil(noReport.attribution)
        XCTAssertEqual(WatchTodayBuilder.payload(from: gathered(locked: true), inputs()).weatherStatus, .locked)
    }

    // MARK: - Holding

    func testALockedLookNeverHidesAGoodOneTheSameDay() {
        let good = gathered(events: [event("e", start: 60, end: 600)])
        let locked = gathered(locked: true, at: now.addingTimeInterval(1800))
        XCTAssertFalse(WatchTodayHoldPolicy.shouldReplace(held: good, with: locked, calendar: calendar))
        XCTAssertTrue(WatchTodayHoldPolicy.shouldReplace(held: nil, with: locked, calendar: calendar))
        XCTAssertTrue(WatchTodayHoldPolicy.shouldReplace(held: locked, with: good, calendar: calendar))
        let nextDayLocked = gathered(locked: true, at: now.addingTimeInterval(86_400))
        XCTAssertTrue(WatchTodayHoldPolicy.shouldReplace(held: good, with: nextDayLocked, calendar: calendar),
                      "a new day replaces yesterday's even when locked, so the watch says why")
    }
}
