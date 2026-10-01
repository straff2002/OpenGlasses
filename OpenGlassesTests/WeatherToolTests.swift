import CoreLocation
import XCTest
@testable import OpenGlasses

@MainActor
final class WeatherToolTests: XCTestCase {

    func testAnswersForTheCurrentFixWithCoarsenedCoordinates() async throws {
        let provider = FakeWeatherProvider()
        let tool = WeatherTool.testing(provider: provider)
        let text = try await tool.execute(args: [:])
        XCTAssertTrue(text.hasPrefix("Currently 14°C (feels like 12°C), partly cloudy in Wellington."), text)

        let sent = try XCTUnwrap(provider.requestedLocations.first)
        XCTAssertEqual(sent.coordinate.latitude, -41.29, accuracy: 1e-9)
        XCTAssertEqual(sent.coordinate.longitude, 174.78, accuracy: 1e-9)
    }

    /// The old tool treated `location` as a label and answered for wherever the wearer stood.
    func testANamedPlaceIsGeocodedAndNamedInTheAnswer() async throws {
        let provider = FakeWeatherProvider()
        let paris = CLLocation(latitude: 48.8566, longitude: 2.3522)
        let tool = WeatherTool.testing(provider: provider, fix: nil, geocoded: ["Paris": paris])
        let text = try await tool.execute(args: ["location": "Paris"])
        XCTAssertTrue(text.contains("partly cloudy in Paris."), text)
        XCTAssertEqual(try XCTUnwrap(provider.requestedLocations.first).coordinate.latitude, 48.86, accuracy: 1e-9)
    }

    func testAPlaceThatCannotBeFoundIsSaidAndNotGuessed() async throws {
        let provider = FakeWeatherProvider()
        let tool = WeatherTool.testing(provider: provider)
        let text = try await tool.execute(args: ["location": "Atlantis"])
        XCTAssertEqual(text, WeatherFetchFailure.placeNotFound("Atlantis").spokenMessage)
        XCTAssertTrue(provider.requestedLocations.isEmpty)
    }

    func testExplicitCoordinatesWinAndMayArriveAsStrings() async throws {
        let provider = FakeWeatherProvider()
        let tool = WeatherTool.testing(provider: provider, fix: nil)
        _ = try await tool.execute(args: ["latitude": "51.5074", "longitude": -0.1278])
        let sent = try XCTUnwrap(provider.requestedLocations.first)
        XCTAssertEqual(sent.coordinate.latitude, 51.51, accuracy: 1e-9)
        XCTAssertEqual(sent.coordinate.longitude, -0.13, accuracy: 1e-9)
    }

    func testHereMeansTheCurrentFix() async throws {
        let provider = FakeWeatherProvider()
        let tool = WeatherTool.testing(provider: provider)
        _ = try await tool.execute(args: ["location": "current location"])
        XCTAssertEqual(try XCTUnwrap(provider.requestedLocations.first).coordinate.latitude, -41.29, accuracy: 1e-9)
    }

    func testNoFixIsOneSentence() async throws {
        let provider = FakeWeatherProvider()
        let tool = WeatherTool.testing(provider: provider, fix: nil)
        let text = try await tool.execute(args: [:])
        XCTAssertEqual(text, WeatherFetchFailure.noLocation.spokenMessage)
        XCTAssertTrue(provider.requestedLocations.isEmpty)
    }

    /// WeatherKit not activated yet, or no network: say so, with no other source tried.
    func testAProviderFailureIsOneSentenceWithNoFallback() async throws {
        let refused = FakeWeatherProvider(.failure(NSError(domain: "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors", code: 2)))
        let refusedText = try await WeatherTool.testing(provider: refused).execute(args: [:])
        XCTAssertEqual(refusedText, WeatherFetchFailure.serviceUnavailable.spokenMessage)

        let offline = FakeWeatherProvider(.failure(URLError(.notConnectedToInternet)))
        let offlineText = try await WeatherTool.testing(provider: offline).execute(args: [:])
        XCTAssertEqual(offlineText, WeatherFetchFailure.offline.spokenMessage)
    }

    /// Medical Local Only: refused before the location is read or the provider is asked.
    func testLocalOnlyRefusesBeforeAnythingLeaves() async throws {
        let provider = FakeWeatherProvider()
        var answered = false
        let tool = WeatherTool.testing(provider: provider, allowed: false, onAnswered: { answered = true })
        let text = try await tool.execute(args: ["location": "Paris"])
        XCTAssertEqual(text, MedicalEgressRefusal.userMessage)
        XCTAssertTrue(provider.requestedLocations.isEmpty)
        XCTAssertFalse(answered)
    }

    /// The conversation path tells the app an answer landed (so the chat carries Apple's credit);
    /// My Day's path does not, because My Day draws its own.
    func testOnlyTheConversationPathRecordsAnAnswer() async throws {
        var answers = 0
        let tool = WeatherTool.testing(onAnswered: { answers += 1 })
        _ = await tool.lookUp(args: [:])
        XCTAssertEqual(answers, 0)
        _ = try await tool.execute(args: [:])
        XCTAssertEqual(answers, 1)

        let failing = WeatherTool.testing(provider: FakeWeatherProvider(.failure(URLError(.timedOut))),
                                          onAnswered: { answers += 1 })
        _ = try await failing.execute(args: [:])
        XCTAssertEqual(answers, 1, "a failure is not weather data on screen")
    }
}

@MainActor
final class NativeWeatherDaySourceTests: XCTestCase {

    func testAnAnswerBecomesTheMyDayWeatherWithRelevanceFromTheData() async {
        let rainy = WeatherFixtures.report(days: [WeatherFixtures.day(0)],
                                           minutes: WeatherFixtures.hour(wet: Set(10..<60)))
        let source = NativeWeatherDaySource(weatherTool: .testing(provider: FakeWeatherProvider(.success(rainy))),
                                            now: { WeatherFixtures.now })
        let load = await source.loadWeather()
        XCTAssertEqual(load.state, .available(.weather))
        XCTAssertEqual(load.value?.isDecisionRelevant, true)
        XCTAssertTrue(load.value?.summary.contains("Rain starting in about 10 minutes.") ?? false)
    }

    func testAFailureIsUnavailableNotASummary() async {
        let source = NativeWeatherDaySource(
            weatherTool: .testing(provider: FakeWeatherProvider(.failure(URLError(.notConnectedToInternet)))))
        let load = await source.loadWeather()
        XCTAssertNil(load.value)
        XCTAssertEqual(load.state, .unavailable(.weather, message: "Weather needs a connection."))
    }

    /// Before, the Local Only refusal sentence was shown as if it were the forecast.
    func testLocalOnlyIsUnavailableWithItsReason() async {
        let source = NativeWeatherDaySource(weatherTool: .testing(allowed: false))
        let load = await source.loadWeather()
        XCTAssertNil(load.value)
        XCTAssertEqual(load.state, .unavailable(.weather, message: "Weather is off while Medical Local Only is on."))
    }
}
