import XCTest
@testable import OpenGlasses

/// Tests for the rolling grounding context (Plan CV P2) — the half of continuous scene narration
/// that runs for every wearer in the mode, not only the one who asked for speech.
///
/// The bounds are the substance here. This is fed by a loop that never stops on its own, so
/// "unbounded" is not a theoretical failure: it is what happens by lunchtime.
final class NarrationContextTests: XCTestCase {

    private func makeContext() -> NarrationContext {
        NarrationContext()
    }

    // MARK: - Recording

    func testRecordsAFirstDescription() {
        var context = makeContext()
        XCTAssertEqual(context.record("A kitchen with a table and two chairs.", at: 0, spoken: false), .recorded)
        XCTAssertEqual(context.observations.count, 1)
        XCTAssertEqual(context.latest?.description, "A kitchen with a table and two chairs.")
    }

    func testRejectsEmptyAndContentFreeDescriptions() {
        var context = makeContext()
        XCTAssertEqual(context.record("", at: 0, spoken: false), .empty)
        XCTAssertEqual(context.record("   ", at: 0, spoken: false), .empty)
        // Pure vision-model boilerplate: every word is a stop word, so there is nothing to ground on.
        XCTAssertEqual(context.record("The image shows a view.", at: 0, spoken: false), .empty)
        XCTAssertTrue(context.isEmpty)
    }

    func testRephraseOfTheMostRecentSceneIsRedundant() {
        var context = makeContext()
        XCTAssertEqual(context.record("A man is sitting at a desk in front of a computer.", at: 0, spoken: false), .recorded)

        let admission = context.record("A person sitting at a desk working on a computer.", at: 10, spoken: false)
        guard case let .redundant(similarity) = admission else {
            return XCTFail("Expected a rephrase to be redundant, got \(admission)")
        }
        XCTAssertGreaterThanOrEqual(similarity, 0.5)
        XCTAssertEqual(context.observations.count, 1, "A rephrase must not crowd the budget")
    }

    func testGenuinelyDifferentSceneIsRecorded() {
        var context = makeContext()
        context.record("A man is sitting at a desk in front of a computer.", at: 0, spoken: false)
        XCTAssertEqual(context.record("A busy street crossing with traffic and a red light.", at: 10, spoken: false), .recorded)
        XCTAssertEqual(context.observations.count, 2)
    }

    /// Redundancy is checked against the most recent observation only, deliberately: a scene the
    /// wearer walks back into is where they are *now*, and grounding must say so.
    func testReturningToAnEarlierSceneRecordsAgain() {
        var context = makeContext()
        let desk = "A man is sitting at a desk in front of a computer."
        context.record(desk, at: 0, spoken: false)
        context.record("A busy street crossing with traffic and a red light.", at: 10, spoken: false)
        XCTAssertEqual(context.record(desk, at: 20, spoken: false), .recorded)
        XCTAssertEqual(context.observations.count, 3)
        XCTAssertEqual(context.latest?.description, desk)
    }

    func testSpokenFlagIsRetained() {
        var context = makeContext()
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: true)
        context.record("A stairwell going down with a handrail on the left.", at: 10, spoken: false)
        XCTAssertEqual(context.observations.map(\.wasSpoken), [true, false])
    }

    // MARK: - Bounds

    /// Six genuinely different places, not six rephrasings — a template with a counter in it shares
    /// enough content words to be suppressed as redundant, which is the redundancy check working
    /// rather than the cap failing.
    private let route = [
        "An entrance hall with a reception desk straight ahead.",
        "A lift lobby with call buttons on the right wall.",
        "A corridor with doorways on the right and a window at the end.",
        "A stairwell going down with a handrail on the left.",
        "A canteen with tables and a serving counter along the far side.",
        "A loading bay open to the outside with parked vans.",
    ]

    func testCountCapDropsTheOldest() {
        var context = makeContext()
        context.maxObservations = 3
        for (i, place) in route.enumerated() {
            XCTAssertEqual(context.record(place, at: Double(i), spoken: false), .recorded, place)
        }
        XCTAssertEqual(context.observations.count, 3)
        XCTAssertTrue(context.observations.first!.description.contains("stairwell"))
        XCTAssertTrue(context.latest!.description.contains("loading bay"))
    }

    func testAgeCapDropsStaleObservations() {
        var context = makeContext()
        context.maxAge = 100
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: false)
        context.record("A busy street crossing with traffic and a red light.", at: 50, spoken: false)

        context.prune(at: 120)
        XCTAssertEqual(context.observations.count, 1, "The 120s-old kitchen is not where the wearer is")
        XCTAssertTrue(context.latest!.description.contains("street"))
    }

    func testPruningIsAppliedOnRecordToo() {
        var context = makeContext()
        context.maxAge = 100
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: false)
        context.record("A busy street crossing with traffic and a red light.", at: 500, spoken: false)
        XCTAssertEqual(context.observations.count, 1)
    }

    // MARK: - Prompt fragment

    func testFragmentIsNilWhenEmpty() {
        let context = makeContext()
        XCTAssertNil(context.promptFragment(at: 0))
    }

    /// A heading with no body reads to a model as an assertion that the wearer has been somewhere
    /// featureless — worse than saying nothing.
    func testFragmentIsNilWhenEverythingHasAgedOut() {
        var context = makeContext()
        context.maxAge = 60
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: false)
        XCTAssertNil(context.promptFragment(at: 600))
    }

    func testFragmentReadsOldestFirst() {
        var context = makeContext()
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: false)
        context.record("A busy street crossing with traffic and a red light.", at: 30, spoken: false)

        guard let text = context.promptFragment(at: 40),
              let kitchen = text.range(of: "kitchen"),
              let street = text.range(of: "street") else {
            return XCTFail("Expected a fragment naming both scenes")
        }
        XCTAssertTrue(kitchen.lowerBound < street.lowerBound, "Oldest first reads as a chronology")
    }

    /// Trimming from the oldest end is the point: under pressure the wearer's *current* surroundings
    /// must survive, not the room they started in.
    func testCharacterBudgetKeepsTheNewest() {
        var context = makeContext()
        context.maxPromptCharacters = 120
        context.record("An entrance hall with a reception desk straight ahead.", at: 0, spoken: false)
        context.record("A corridor with doorways on the right and a window at the end.", at: 30, spoken: false)
        context.record("A stairwell going down with a handrail on the left.", at: 60, spoken: false)

        guard let text = context.promptFragment(at: 70) else { return XCTFail("Expected a fragment") }
        XCTAssertTrue(text.contains("stairwell"), "The newest observation must survive the budget")
        XCTAssertFalse(text.contains("entrance hall"), "The oldest is what gets trimmed")
    }

    func testRelativeAgeIsCoarse() {
        XCTAssertEqual(NarrationContext.relativeAge(5), "just now")
        XCTAssertEqual(NarrationContext.relativeAge(45), "a moment ago")
        XCTAssertEqual(NarrationContext.relativeAge(150), "a few minutes ago")
        XCTAssertEqual(NarrationContext.relativeAge(3000), "earlier")
    }

    func testResetClearsEverything() {
        var context = makeContext()
        context.record("A kitchen with a table and two chairs.", at: 0, spoken: true)
        context.reset()
        XCTAssertTrue(context.isEmpty)
        XCTAssertNil(context.promptFragment(at: 0))
    }
}
