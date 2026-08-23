import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23. `contextWindowCompression` was nested inside `realtimeInputConfig`,
/// where the field does not exist, and the endpoint rejects a malformed payload wholesale:
///
///     code 1007: Invalid JSON payload received. Unknown name "contextWindowCompression"
///                at 'setup.realtime_input_config': Cannot find field.
///
/// The socket closed before the server looked at the model or the key, so every Live session failed
/// identically however it was configured — and since the same key worked in Direct mode, it read as
/// an auth problem. These tests pin the *shape*, which is the part no unit test covered and no
/// amount of desk reading caught.
final class GeminiLiveSetupTests: XCTestCase {

    private func body(modalities: [String] = ["AUDIO"]) -> [String: Any] {
        GeminiLiveSetup.body(
            model: "models/test-live",
            responseModalities: modalities,
            systemInstruction: "be brief",
            tools: [],
            sessionResumption: [:])
    }

    /// The regression itself: a sibling of `realtimeInputConfig`, never a member.
    func testContextWindowCompressionSitsAtTheTopLevelOfSetup() {
        let setup = body()
        XCTAssertNotNil(setup["contextWindowCompression"],
                        "must be a top-level field of `setup`")

        let realtime = setup["realtimeInputConfig"] as? [String: Any]
        XCTAssertNotNil(realtime)
        XCTAssertNil(realtime?["contextWindowCompression"],
                     "nesting it here is the exact payload the endpoint refused with 1007")
    }

    func testTheCompressionWindowCarriesItsTargetTokens() {
        let compression = body()["contextWindowCompression"] as? [String: Any]
        let sliding = compression?["slidingWindow"] as? [String: Any]
        XCTAssertEqual(sliding?["targetTokens"] as? Int, GeminiLiveSetup.contextTargetTokens)
    }

    /// The fields that *do* belong to `realtimeInputConfig` must stay there — the fix moves one
    /// field out, and moving a second would break turn-taking rather than the handshake.
    func testActivityDetectionStaysInsideRealtimeInputConfig() {
        let realtime = body()["realtimeInputConfig"] as? [String: Any]
        XCTAssertNotNil(realtime?["automaticActivityDetection"])
        XCTAssertEqual(realtime?["activityHandling"] as? String, "START_OF_ACTIVITY_INTERRUPTS")
        XCTAssertEqual(realtime?["turnCoverage"] as? String, "TURN_INCLUDES_ALL_INPUT")
    }

    /// Whatever else changes, the payload has to survive JSON serialisation — an unencodable value
    /// would fail silently in `sendJSON`, which returns without sending and without complaining.
    func testTheWholeSetupIsJSONSerialisable() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["setup": body()]))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["setup": body()]))
    }

    func testModelAndInstructionAreCarriedThrough() {
        let setup = body()
        XCTAssertEqual(setup["model"] as? String, "models/test-live")
        let instruction = setup["systemInstruction"] as? [String: Any]
        let parts = instruction?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "be brief")
    }

    /// Modalities are passed through untouched: a text-only session must not be handed AUDIO.
    func testResponseModalitiesArePassedThrough() {
        let generation = body(modalities: ["TEXT"])["generationConfig"] as? [String: Any]
        XCTAssertEqual(generation?["responseModalities"] as? [String], ["TEXT"])
    }

    // MARK: - thinkingConfig is family-specific (2026-08-23)

    /// The 2.5 family takes a token budget; 3.x takes a level. We hard-coded the 2.5 form back when
    /// the model was hard-coded too — it is now chosen at runtime from whatever the account offers.
    func testThinkingConfigMatchesTheModelFamily() {
        XCTAssertEqual(
            GeminiLiveThinkingConfig.forModel("gemini-2.5-flash-native-audio-latest")?["thinkingBudget"] as? Int, 0)
        XCTAssertEqual(
            GeminiLiveThinkingConfig.forModel("gemini-3.1-flash-live-preview")?["thinkingLevel"] as? String, "minimal")
    }

    /// An unknown family sends nothing at all. This endpoint refuses a whole setup over one
    /// unrecognised field — the 1007 that made every session fail identically — so the server's
    /// default beats a guessed shape.
    func testAnUnknownFamilySendsNoThinkingConfigAtAll() {
        XCTAssertNil(GeminiLiveThinkingConfig.forModel("gemini-robotics-er-2-streaming-preview"))

        let setup = GeminiLiveSetup.body(model: "models/gemini-robotics-er-2-streaming-preview",
                                         responseModalities: ["AUDIO"], systemInstruction: "hi",
                                         tools: [], sessionResumption: [:])
        let generation = setup["generationConfig"] as? [String: Any]
        XCTAssertNil(generation?["thinkingConfig"])
        XCTAssertNotNil(generation?["responseModalities"], "the rest of the config still goes")
    }
}
