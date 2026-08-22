import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23. Two failures in one session taught this type its shape.
///
/// The hard-coded default `gemini-2.0-flash-exp` had been retired upstream: "not found for API
/// version v1beta, or is not supported for bidiGenerateContent". Then the first fix — guessing
/// capability from the id's shape (`live` / `flash-exp`) — was killed by a real account's model
/// list, below, in which two live-capable models match neither marker. Names are not a capability
/// contract; `ListModels` is, and the app now asks.
final class GeminiLiveModelPolicyTests: XCTestCase {

    /// Verbatim from a real account (2026-08-23) — the fixture that disproved the name heuristic.
    private let offered = [
        "models/gemini-2.5-flash-native-audio-latest",
        "models/gemini-2.5-flash-native-audio-preview-09-2025",
        "models/gemini-2.5-flash-native-audio-preview-12-2025",
        "models/gemini-3.1-flash-live-preview",
        "models/gemini-robotics-er-2-streaming-preview",
        "models/gemini-3.5-live-translate-preview"
    ]

    /// The heuristic this replaced would have rejected these two as "not live models". They are.
    func testLiveCapabilityIsNotInferableFromTheName() {
        for id in ["gemini-2.5-flash-native-audio-latest", "gemini-robotics-er-2-streaming-preview"] {
            XCTAssertFalse(id.contains("live") || id.contains("flash-exp"),
                           "\(id) is live-capable yet carries neither marker — hence discovery")
        }
    }

    /// A model the account actually offers is always honoured: the wearer's choice wins wherever
    /// it can, and only a model the endpoint would refuse is replaced.
    func testAConfiguredModelTheAccountOffersIsHonoured() {
        let resolution = GeminiLiveModelPolicy.resolve(
            configured: "gemini-3.1-flash-live-preview", available: offered)
        XCTAssertEqual(resolution.model, "gemini-3.1-flash-live-preview")
        XCTAssertFalse(resolution.didSubstitute)
    }

    /// The failure that started this: a Direct-mode model, which the Live endpoint will not serve.
    func testADirectModeModelIsReplacedWithSomethingOffered() {
        let resolution = GeminiLiveModelPolicy.resolve(configured: "gemini-2.5-flash", available: offered)
        XCTAssertEqual(resolution.substitutedFor, "gemini-2.5-flash")
        XCTAssertTrue(offered.map(GeminiLiveModelPolicy.bareId).contains(resolution.model),
                      "the replacement must be a model this account can actually open")
    }

    /// Specialised models speak the same protocol but are not assistants. Defaulting a wearer into
    /// a translation model would be a stranger failure than none at all.
    func testTaskSpecialisedModelsAreNotChosenWhenGeneralOnesExist() {
        let chosen = GeminiLiveModelPolicy.choose(from: offered)
        XCTAssertNotNil(chosen)
        XCTAssertFalse(chosen!.contains("translate"))
        XCTAssertFalse(chosen!.contains("robotics"))
    }

    /// …but something is better than nothing if that is all the account has.
    func testASpecialisedModelIsBetterThanNoSession() {
        let chosen = GeminiLiveModelPolicy.choose(from: ["models/gemini-3.5-live-translate-preview"])
        XCTAssertEqual(chosen, "gemini-3.5-live-translate-preview")
    }

    /// Prefer a stable alias over a dated preview — a dated preview is exactly the kind of id that
    /// gets retired, which is the bug this type exists because of.
    func testAStableAliasBeatsADatedPreview() {
        let chosen = GeminiLiveModelPolicy.choose(from: [
            "models/gemini-2.5-flash-native-audio-preview-12-2025",
            "models/gemini-2.5-flash-native-audio-latest"
        ])
        XCTAssertEqual(chosen, "gemini-2.5-flash-native-audio-latest")
    }

    /// With no alias on offer, the newest family member wins.
    func testOtherwiseTheNewestVersionWins() {
        let chosen = GeminiLiveModelPolicy.choose(from: [
            "models/gemini-2.5-flash-native-audio-preview-09-2025",
            "models/gemini-3.1-flash-live-preview"
        ])
        XCTAssertEqual(chosen, "gemini-3.1-flash-live-preview")
    }

    /// An unreadable version must not sort as newest — "no version" is not evidence of newness.
    func testAnUnversionedIdDoesNotOutrankAVersionedOne() {
        XCTAssertEqual(GeminiLiveModelPolicy.version(of: "gemini-live-experimental"), 0)
        XCTAssertGreaterThan(GeminiLiveModelPolicy.version(of: "gemini-3.1-flash-live-preview"), 0)
    }

    /// Offline: no list, so the fallback is used and the caller is told the check never happened.
    func testAnEmptyListFallsBackAndSaysSo() {
        let resolution = GeminiLiveModelPolicy.resolve(configured: "gemini-2.5-flash", available: [])
        XCTAssertEqual(resolution.model, GeminiLiveModelPolicy.offlineFallbackModel)
        XCTAssertTrue(resolution.usedOfflineFallback)
    }

    /// The `models/` prefix is a wire detail; both forms compare equal and neither is doubled.
    func testThePrefixIsNormalised() {
        XCTAssertEqual(
            GeminiLiveModelPolicy.wireModel(configured: "models/gemini-3.1-flash-live-preview",
                                            available: offered),
            "models/gemini-3.1-flash-live-preview")
    }

    /// The choice must not wander between launches when two candidates tie.
    func testTheChoiceIsStable() {
        let first = GeminiLiveModelPolicy.choose(from: offered)
        XCTAssertEqual(first, GeminiLiveModelPolicy.choose(from: offered.reversed()))
    }
}
