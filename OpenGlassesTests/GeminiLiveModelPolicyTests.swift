import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23: a Gemini key that worked in Direct mode could not open a Live
/// session, because the id we sent to `BidiGenerateContent` was the user's Direct-mode model.
/// The endpoint serves a separate family and closed the socket — which presented as "the key
/// doesn't work" on a key that demonstrably did.
final class GeminiLiveModelPolicyTests: XCTestCase {

    /// The exact configuration that broke: a perfectly good general text model.
    func testAGeneralTextModelIsSubstituted() {
        let resolution = GeminiLiveModelPolicy.resolve(configured: "gemini-2.5-flash")
        XCTAssertEqual(resolution.model, GeminiLiveModelPolicy.defaultLiveModel)
        XCTAssertEqual(resolution.substitutedFor, "gemini-2.5-flash")
        XCTAssertTrue(resolution.didSubstitute)
    }

    /// A live-capable id is passed through untouched — the user's choice wins whenever it can.
    func testLiveCapableModelsArePassedThrough() {
        for id in ["gemini-live-2.5-flash-preview", "gemini-2.0-flash-exp", "GEMINI-LIVE-FUTURE"] {
            let resolution = GeminiLiveModelPolicy.resolve(configured: id)
            XCTAssertEqual(resolution.model, id.replacingOccurrences(of: "models/", with: ""),
                           "\(id) names the live family and must not be replaced")
            XCTAssertFalse(resolution.didSubstitute)
        }
    }

    /// The `models/` prefix is a wire detail, not part of the id — accepting both forms stops a
    /// double prefix reaching the socket.
    func testThePrefixIsNormalisedRatherThanDoubled() {
        XCTAssertEqual(GeminiLiveModelPolicy.wireModel(configured: "models/gemini-2.0-flash-exp"),
                       "models/gemini-2.0-flash-exp")
        XCTAssertEqual(GeminiLiveModelPolicy.wireModel(configured: "gemini-2.0-flash-exp"),
                       "models/gemini-2.0-flash-exp")
    }

    /// No model configured is not an error: it is the first-run path, and it must still produce a
    /// usable session rather than a swap notice about nothing.
    func testNoConfiguredModelUsesTheDefaultWithoutClaimingASubstitution() {
        for empty in [nil, "", "   "] {
            let resolution = GeminiLiveModelPolicy.resolve(configured: empty)
            XCTAssertEqual(resolution.model, GeminiLiveModelPolicy.defaultLiveModel)
            XCTAssertNil(resolution.substitutedFor)
        }
    }

    /// The substitution has to be reportable. A silent swap files the session's usage and latency
    /// cohorts under a model that never served it.
    func testSubstitutionNamesTheModelItReplaced() {
        let resolution = GeminiLiveModelPolicy.resolve(configured: "gemini-1.5-pro")
        XCTAssertEqual(resolution.substitutedFor, "gemini-1.5-pro")
        XCTAssertNotEqual(resolution.model, "gemini-1.5-pro")
    }

    /// Matched on shape, not an allow-list: the live family renames faster than we ship, and a
    /// stale list would refuse a model the user is entitled to use.
    func testCapabilityIsMatchedOnShapeNotAnAllowList() {
        XCTAssertTrue(GeminiLiveModelPolicy.isLiveCapable("some-future-live-model"))
        XCTAssertTrue(GeminiLiveModelPolicy.isLiveCapable("gemini-9.9-flash-exp"))
        XCTAssertFalse(GeminiLiveModelPolicy.isLiveCapable("gemini-2.5-pro"))
    }
}
