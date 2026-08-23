import XCTest
import CoreLocation
@testable import OpenGlasses

/// Local-model "location not found" fix: the where_am_i prompt nudge and the one-shot
/// fix await (fast-nil when unauthorized; no hangs headless).
final class LocalLocationFixTests: XCTestCase {

    func testLocalToolInstructionsNudgeToCallWhereAmI() {
        let block = LLMService.localToolInstructions(toolNames: ["get_weather", "where_am_i"])
        XCTAssertTrue(block.contains("where_am_i"))
        XCTAssertTrue(block.contains("never say you lack location access"),
                      "without the nudge, a 2B model claims it can't find the location instead of calling the tool")
    }

    func testLocalToolInstructionsWithoutWhereAmIHasNoNudge() {
        let block = LLMService.localToolInstructions(toolNames: ["get_weather", "calculate"])
        XCTAssertFalse(block.contains("location access"))
        XCTAssertTrue(block.contains("get_weather"))
    }

    func testLocalToolInstructionsEmptyForNoTools() {
        XCTAssertEqual(LLMService.localToolInstructions(toolNames: []), "")
    }

    // MARK: Tier-0 weather routing (live-traced: the 2B model announced the lookup
    // without emitting the tool call — bare weather questions now skip the LLM entirely)

    private let classifier = ConversationClassifier()

    func testBareWeatherQueriesRouteDirectToGetWeather() {
        for query in [
            "what is the weather where i am",
            "what's the weather like today",
            "what's the weather like outside",
            "weather forecast for tomorrow",
        ] {
            let result = classifier.classify(query)
            XCTAssertEqual(result.directToolCall?.toolName, "get_weather", "expected tier-0 for: \(query)")
        }
    }

    func testNamedPlaceWeatherStillReachesTheLLM() {
        for query in [
            "what's the weather in auckland",
            "will it rain in wellington this weekend",
            "should i pack an umbrella for the sydney trip",
        ] {
            let result = classifier.classify(query)
            XCTAssertNil(result.directToolCall, "named-place query must reach the LLM: \(query)")
        }
    }

    // MARK: Announce-without-action detection + tool-call parsing

    func testAnnouncesToolIntentDetection() {
        XCTAssertTrue(LLMService.announcesToolIntent("Hey, I can certainly check that for you. I'm looking up the current weather for your location."))
        XCTAssertTrue(LLMService.announcesToolIntent("Let me check the forecast."))
        XCTAssertFalse(LLMService.announcesToolIntent("It's 18 degrees and sunny in Hikurangi."))
        XCTAssertFalse(LLMService.announcesToolIntent(#"Checking now <tool_call>{"name": "get_weather", "arguments": {}}</tool_call>"#),
                       "a reply that DID emit the call is not an empty announcement")
    }

    /// Live-traced (Samoa/travel-guide): a search-flavoured announcement — "I will now search
    /// for popular tourist destinations in Samoa for you" — matched no intent phrase, so the
    /// corrective regen never fired and the promise was spoken as the final answer.
    func testSearchAnnouncementsDetected() {
        XCTAssertTrue(LLMService.announcesToolIntent(
            "I apologize, I should have used a tool to get that information. I will now search for popular tourist destinations in Samoa for you."))
        XCTAssertTrue(LLMService.announcesToolIntent("Let me search for that."))
        XCTAssertTrue(LLMService.announcesToolIntent("Searching for current exchange rates now."))
        XCTAssertFalse(LLMService.announcesToolIntent("You can search for cheap flights on several comparison sites."),
                       "mentioning that the USER can search is an answer, not an announcement")
    }

    func testClothingDecisionsClassifyAsLocationQuestions() {
        for query in ["do i take a jacket", "should i wear a coat today", "is it warm enough for shorts"] {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.location),
                          "clothing decision must pull USER LOCATION into the prompt: \(query)")
        }
    }

    func testWeatherDecisionQueriesSetWeatherSection() {
        for query in ["shall i take a jacket", "do i need an umbrella", "is it warm enough for shorts",
                      "with tomorrow's weather should i take a jacket"] {
            let result = classifier.classify(query)
            XCTAssertTrue(result.relevantSections.contains(.weather),
                          "weather-decision turn must trigger the pre-fetch: \(query)")
            XCTAssertTrue(result.relevantSections.contains(.location))
        }
        XCTAssertFalse(classifier.classify("remind me to call mum").relevantSections.contains(.weather))
    }

    func testAsksUserForLocationDetection() {
        // The exact live-traced ask-back.
        XCTAssertTrue(LLMService.asksUserForLocation(
            "That depends entirely on the weather where you are right now. If you tell me your current location, I can check the forecast for you and give you a better recommendation."))
        XCTAssertTrue(LLMService.asksUserForLocation("What city are you in?"))
        XCTAssertFalse(LLMService.asksUserForLocation("It's 15 degrees in Hikurangi — take a light jacket."))
        XCTAssertFalse(LLMService.asksUserForLocation(#"<tool_call>{"name": "where_am_i", "arguments": {}}</tool_call>"#))
    }

    func testParseLocalToolCall() {
        let reply = #"Sure. <tool_call>{"name": "get_weather", "arguments": {"latitude": -35.6}}</tool_call>"#
        let parsed = LLMService.parseLocalToolCall(reply)
        XCTAssertEqual(parsed?.name, "get_weather")
        XCTAssertEqual(parsed?.args["latitude"] as? Double, -35.6)
        XCTAssertNil(LLMService.parseLocalToolCall("I'm looking that up for you."))
    }

    func testVisionCapabilityByModelId() {
        XCTAssertTrue(LocalLLMService.isVisionCapable(modelId: "mlx-community/SmolVLM2-2.2B-Instruct-mlx"))
        XCTAssertTrue(LocalLLMService.isVisionCapable(modelId: "mlx-community/gemma-4-e2b-it-4bit"))
    }

    func testCurrentDateTimeLineFormat() {
        let tz = TimeZone(identifier: "Pacific/Auckland")!
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 7, 15, 18, 41)
        components.timeZone = tz
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let line = LLMService.currentDateTimeLine(now: date, timeZone: tz)
        XCTAssertTrue(line.contains("2026"), line)
        XCTAssertTrue(line.contains("July"), line)
        XCTAssertTrue(line.lowercased().contains("wednesday"), "15 July 2026 is a Wednesday: \(line)")
        XCTAssertTrue(line.contains("Pacific/Auckland"), line)
    }

    func testSpokenErrorPolicyHidesInternals() {
        struct Fake: LocalizedError { let errorDescription: String? }
        // The live-traced leak: a DecodingError path read aloud.
        XCTAssertFalse(SpokenErrorPolicy.looksHuman(
            #"keyNotFound(path: ["language_model", "model", "layers", "15", "self_attn", "k_norm", "weight"])"#))
        XCTAssertEqual(
            SpokenErrorPolicy.spokenReason(for: Fake(errorDescription: #"keyNotFound(path: ["language_model"])"#)),
            "Something went wrong on the device — check the debug log for details.")
        // Human messages pass through.
        XCTAssertEqual(
            SpokenErrorPolicy.spokenReason(for: Fake(errorDescription: "The glasses camera is not connected.")),
            "The glasses camera is not connected.")
    }

    @MainActor
    func testAwaitFixReturnsNilFastWhenUnauthorized() async {
        // Headless: no location permission → isAuthorized is false → awaitFix must return
        // nil immediately (no polling loop, no CLLocationManager start).
        let service = LocationService()
        let start = ContinuousClock.now
        let fix = await service.awaitFix(timeout: 1.5)
        XCTAssertNil(fix)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(300),
                          "unauthorized await must not burn the timeout")
        let context = await service.awaitLocationContext(timeout: 1.5)
        XCTAssertNil(context)
    }
}
