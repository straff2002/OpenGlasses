import XCTest
import WeatherKit
@testable import OpenGlasses

final class WeatherUnitsTests: XCTestCase {

    func testAUSPhoneGetsFahrenheitAndMilesPerHour() {
        let units = WeatherUnits.forLocale(Locale(identifier: "en_US"))
        XCTAssertEqual(units.temperature, .fahrenheit)
        XCTAssertEqual(units.speed, .milesPerHour)
        XCTAssertEqual(units.temperature(20), "68°F")
        XCTAssertEqual(units.speed(16.0934), "10 mph")
    }

    func testANewZealandPhoneGetsCelsiusAndKilometresPerHour() {
        let units = WeatherUnits.forLocale(Locale(identifier: "en_NZ"))
        XCTAssertEqual(units, .metric)
        XCTAssertEqual(units.temperature(14.6), "15°C")
        XCTAssertEqual(units.speed(18.4), "18 km/h")
    }

    /// The region alone would say Celsius; the phone's temperature setting says Fahrenheit.
    func testTheTemperatureSettingOutranksTheRegion() {
        let units = WeatherUnits.forLocale(Locale(identifier: "en_NZ@mu=fahrenhe"))
        XCTAssertEqual(units.temperature, .fahrenheit)
    }

    func testMetresPerSecondAndNoNegativeZero() {
        let units = WeatherUnits(temperature: .celsius, speed: .metresPerSecond)
        XCTAssertEqual(units.speed(36), "10 m/s")
        XCTAssertEqual(units.temperature(-0.3), "0°C")
    }
}

final class RainOutlookTests: XCTestCase {
    private let now = WeatherFixtures.now

    func testNoMinuteForecastSaysNothing() {
        XCTAssertEqual(RainOutlook.evaluate(minutes: nil, now: now), .unknown)
        XCTAssertNil(RainOutlook.unknown.sentence)
        XCTAssertEqual(RainOutlook.evaluate(minutes: [], now: now), .unknown)
    }

    func testADryHour() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: []), now: now)
        XCTAssertEqual(outlook, .dryForTheHour)
        XCTAssertEqual(outlook.sentence, "No rain expected in the next hour.")
    }

    func testRainStartingIsRoundedToFiveMinutes() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: Set(16..<60)), now: now)
        XCTAssertEqual(outlook, .starting(inMinutes: 16, kind: .rain))
        XCTAssertEqual(outlook.sentence, "Rain starting in about 15 minutes.")
    }

    func testRainStoppingSoon() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: Set(0..<4)), now: now)
        XCTAssertEqual(outlook, .stopping(inMinutes: 4, kind: .rain))
        XCTAssertEqual(outlook.sentence, "Rain stopping in about 4 minutes.")
    }

    func testRainAllHour() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: Set(0..<60)), now: now)
        XCTAssertEqual(outlook, .continuing(kind: .rain))
        XCTAssertEqual(outlook.sentence, "Rain for at least the next hour.")
    }

    /// One or two wet minutes are noise, not "rain starting".
    func testABriefBlipIsNotAChange() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: [10, 11]), now: now)
        XCTAssertEqual(outlook, .dryForTheHour)
    }

    func testLowChanceOrTraceIntensityIsDry() {
        var minutes = WeatherFixtures.hour(wet: Set(5..<60))
        minutes = minutes.map { var m = $0; m.precipitationChance = 0.3; return m }
        XCTAssertEqual(RainOutlook.evaluate(minutes: minutes, now: now), .dryForTheHour)

        var trace = WeatherFixtures.hour(wet: Set(5..<60))
        trace = trace.map { var m = $0; m.intensityMillimetresPerHour = 0.02; return m }
        XCTAssertEqual(RainOutlook.evaluate(minutes: trace, now: now), .dryForTheHour)
    }

    func testSnowIsNamedAsSnow() {
        let outlook = RainOutlook.evaluate(minutes: WeatherFixtures.hour(wet: Set(30..<60), kind: .snow), now: now)
        XCTAssertEqual(outlook.sentence, "Snow starting in about 30 minutes.")
    }

    /// Minutes already past are not the next hour.
    func testPastMinutesAreIgnored() {
        let past = (-30..<0).map { WeatherFixtures.minute($0, wet: true) }
        let outlook = RainOutlook.evaluate(minutes: past + WeatherFixtures.hour(wet: []), now: now)
        XCTAssertEqual(outlook, .dryForTheHour)
    }
}

final class WeatherAlertDigestTests: XCTestCase {

    func testNoCoverageAndNoAlertsAreBothSilent() {
        XCTAssertNil(WeatherAlertDigest.sentence(nil))
        XCTAssertNil(WeatherAlertDigest.sentence([]))
    }

    func testOneAlertNamesItsSource() {
        let sentence = WeatherAlertDigest.sentence([
            WeatherFixtures.alert("Heavy Rain Warning", source: "MetService", severity: .severe)
        ])
        XCTAssertEqual(sentence, "Weather alert: Heavy Rain Warning, from MetService.")
    }

    func testMostSevereFirstCappedAtTwo() {
        let sentence = WeatherAlertDigest.sentence([
            WeatherFixtures.alert("Wind Advisory", source: "NWS", severity: .minor),
            WeatherFixtures.alert("Flood Warning", source: "NWS", severity: .extreme),
            WeatherFixtures.alert("Heat Advisory", source: "NWS", severity: .moderate),
        ])
        XCTAssertEqual(sentence,
                       "Weather alerts: Flood Warning, from NWS; Heat Advisory, from NWS; and 1 more.")
    }

    func testDuplicatesAndBlanksAreDropped() {
        let ordered = WeatherAlertDigest.ordered([
            WeatherFixtures.alert("Flood Warning", source: "NWS"),
            WeatherFixtures.alert("flood warning", source: "nws"),
            WeatherFixtures.alert("   ", source: "NWS"),
        ])
        XCTAssertEqual(ordered.map(\.summary), ["Flood Warning"])
    }
}

final class WeatherPhraserTests: XCTestCase {
    private let now = WeatherFixtures.now

    func testTheFullAnswerInMetric() {
        let text = WeatherPhraser.answer(WeatherFixtures.report(), placeName: "Wellington",
                                         units: .metric, now: now, calendar: WeatherFixtures.utcCalendar)
        XCTAssertEqual(text,
            "Currently 14°C (feels like 12°C), partly cloudy in Wellington. Wind 18 km/h, humidity 62%. "
            + "Today's high 17°C, low 9°C. "
            + "Tomorrow: rain, 15°C/8°C. "
            + "Saturday: clear, 19°C/10°C.")
    }

    func testFahrenheitAndARainyToday() {
        let report = WeatherFixtures.report(days: [WeatherFixtures.day(0, .rain, high: 20, low: 10, chance: 0.64)])
        let units = WeatherUnits(temperature: .fahrenheit, speed: .milesPerHour)
        let text = WeatherPhraser.answer(report, placeName: nil, units: units, now: now)
        XCTAssertTrue(text.hasPrefix("Currently 57°F (feels like 54°F), partly cloudy. Wind 11 mph"), text)
        XCTAssertTrue(text.contains("Today's high 68°F, low 50°F, 60% chance of precipitation."), text)
        XCTAssertFalse(text.contains("Tomorrow"))
    }

    func testRainAndAlertsJoinTheAnswerInOrder() {
        let report = WeatherFixtures.report(
            minutes: WeatherFixtures.hour(wet: Set(20..<60)),
            alerts: [WeatherFixtures.alert("Heavy Rain Watch", source: "MetService")]
        )
        let text = WeatherPhraser.answer(report, placeName: nil, units: .metric, now: now,
                                         calendar: WeatherFixtures.utcCalendar)
        let rain = try? XCTUnwrap(text.range(of: "Rain starting in about 20 minutes."))
        let alert = try? XCTUnwrap(text.range(of: "Weather alert: Heavy Rain Watch, from MetService."))
        let tomorrow = try? XCTUnwrap(text.range(of: "Tomorrow:"))
        XCTAssertNotNil(rain); XCTAssertNotNil(alert); XCTAssertNotNil(tomorrow)
        if let rain, let alert, let tomorrow {
            XCTAssertLessThan(rain.lowerBound, alert.lowerBound)
            XCTAssertLessThan(alert.lowerBound, tomorrow.lowerBound)
        }
    }

    /// Where the region has no minute forecast, the answer does not mention rain in the next hour.
    func testNoMinuteForecastMeansNoRainSentence() {
        let text = WeatherPhraser.answer(WeatherFixtures.report(minutes: nil), placeName: nil,
                                         units: .metric, now: now)
        XCTAssertFalse(text.contains("next hour"))
    }

    /// A forecast fetched after a day has ended starts from the next day.
    func testAFinishedDayIsNotToday() {
        let days = [WeatherFixtures.day(-1, high: 30, low: 20), WeatherFixtures.day(0, high: 17, low: 9)]
        let text = WeatherPhraser.answer(WeatherFixtures.report(days: days), placeName: nil,
                                         units: .metric, now: now)
        XCTAssertTrue(text.contains("Today's high 17°C, low 9°C."), text)
    }

    func testDecisionRelevanceComesFromTheData() {
        XCTAssertFalse(WeatherPhraser.isDecisionRelevant(
            WeatherFixtures.report(days: [WeatherFixtures.day(0)]), now: now))
        XCTAssertTrue(WeatherPhraser.isDecisionRelevant(
            WeatherFixtures.report(current: WeatherFixtures.current(.thunderstorms), days: []), now: now))
        XCTAssertTrue(WeatherPhraser.isDecisionRelevant(
            WeatherFixtures.report(days: [WeatherFixtures.day(0, chance: 0.7)]), now: now))
        XCTAssertTrue(WeatherPhraser.isDecisionRelevant(
            WeatherFixtures.report(days: [WeatherFixtures.day(0)], minutes: WeatherFixtures.hour(wet: Set(40..<60))),
            now: now))
        XCTAssertTrue(WeatherPhraser.isDecisionRelevant(
            WeatherFixtures.report(days: [WeatherFixtures.day(0)], alerts: [WeatherFixtures.alert("Wind Warning")]),
            now: now))
    }

    func testEveryConditionHasALowercasePhrase() {
        for condition in WeatherCondition.allCases {
            let phrase = WeatherConditionPhrase.phrase(condition)
            XCTAssertFalse(phrase.isEmpty)
            XCTAssertEqual(phrase, phrase.lowercased(), "\(condition)")
            XCTAssertNotEqual(phrase, "mixed conditions", "\(condition) fell through to the default")
        }
    }

    func testCoordinatesAreCoarsenedToAboutAKilometre() {
        let coarse = WeatherLocationPrecision.coarsen(latitude: -41.286461, longitude: 174.776230)
        XCTAssertEqual(coarse.latitude, -41.29, accuracy: 1e-9)
        XCTAssertEqual(coarse.longitude, 174.78, accuracy: 1e-9)
    }

    func testPrecipitationIntensityConvertsToMillimetresPerHour() {
        let oneMillimetrePerHour = Measurement(value: 0.001 / 3600, unit: UnitSpeed.metersPerSecond)
        XCTAssertEqual(WeatherKitProvider.millimetresPerHour(oneMillimetrePerHour), 1, accuracy: 1e-9)
    }

    func testFailuresAreOneSentenceEach() {
        let failures: [WeatherFetchFailure] = [.serviceUnavailable, .offline, .noLocation, .placeNotFound("Atlantis")]
        for failure in failures {
            let message = failure.spokenMessage
            XCTAssertEqual(message.filter { $0 == "." }.count, message.hasSuffix("enabled.") ? 2 : 1, message)
            XCTAssertFalse(message.lowercased().contains("open-meteo"))
        }
        XCTAssertEqual(WeatherFetchFailure.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(WeatherFetchFailure.classify(WeatherError.permissionDenied), .serviceUnavailable)
    }
}
