import XCTest
@testable import OpenGlasses

/// Before anything is searched: already covered, reaching private data, or needing a built-in tool.
final class AddOnAuthoringPreflightTests: XCTestCase {

    private let currency = AddOnAuthoringPreflight.Capability(
        name: "convert_currency",
        summary: "Convert an amount between currencies using live exchange rates. No API key needed.")
    private let weather = AddOnAuthoringPreflight.Capability(name: "get_weather",
                                                             summary: "Get the current weather and forecast.")

    func testTheNativeCurrencyToolCoversCurrency() {
        let verdict = AddOnAuthoringPreflight.check(goal: "convert fifty euros to dollars", native: [currency, weather],
                                                    installed: [])
        XCTAssertEqual(verdict, .covered(currency))
        XCTAssertTrue(AddOnAuthoringPreflight.message(for: verdict)?.hasPrefix("I can already do that") == true)
    }

    func testAnInjectedMatcherDecides() {
        let always: AddOnAuthoringPreflight.Matcher = { _, capability in capability.name == "get_weather" ? 0.9 : 0 }
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "tide times", native: [currency, weather], installed: [],
                                                     matcher: always), .covered(weather))
        let never: AddOnAuthoringPreflight.Matcher = { _, _ in 0.59 }
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "convert euros to dollars", native: [currency], installed: [],
                                                     matcher: never), .proceed)
    }

    func testAnInstalledAddOnCountsAsCoverage() {
        let tides = AddOnAuthoringPreflight.Capability(name: "Tide times", summary: "Tide times for the coast.")
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "tide times at Plimmerton", native: [], installed: [tides]),
                       .covered(tides))
    }

    func testANewKindOfLookupProceeds() {
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "what's the tide at Plimmerton", native: [currency, weather],
                                                     installed: []), .proceed)
    }

    func testGeneralToolsNeverCountAsCoverage() {
        let search = AddOnAuthoringPreflight.Capability(name: "web_search", summary: "Search the web for tide times.")
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "search tide times", native: [search], installed: []), .proceed)
    }

    func testPrivateDataIsRefused() {
        let cases: [(String, AddOnAuthoringPreflight.PrivateSource)] = [
            ("look up my contacts' birthdays", .contacts),
            ("read my text messages from work", .messages),
            ("check my heart rate", .health),
            ("what's on my calendar tomorrow", .calendar),
            ("describe what the camera sees", .camera),
            ("back up my photos", .photos),
            ("use the microphone to measure noise", .microphone),
        ]
        for (goal, source) in cases {
            let verdict = AddOnAuthoringPreflight.check(goal: goal, native: [], installed: [])
            XCTAssertEqual(verdict, .reachesPrivateData(source), goal)
            XCTAssertTrue(AddOnAuthoringPreflight.message(for: verdict)?.contains("can never reach") == true)
        }
    }

    func testArithmeticAndLoopsNeedABuiltInTool() {
        for goal in ["calculate my mortgage repayments", "average the last five tide heights",
                     "keep checking the ferry status", "for each station read the level"] {
            XCTAssertEqual(AddOnAuthoringPreflight.check(goal: goal, native: [], installed: []), .needsBuiltIn, goal)
        }
        XCTAssertEqual(AddOnAuthoringPreflight.message(for: .needsBuiltIn),
                       "That needs a built-in tool; I can't build it as an add-on.")
    }

    func testAnEmptyGoalAsksWhatItShouldDo() {
        XCTAssertEqual(AddOnAuthoringPreflight.check(goal: "   ", native: [], installed: []), .empty)
    }
}
