import XCTest
@testable import OpenGlasses

/// Tests for the Assistive Mode (A3) pure logic: lenient JSON advice parsing, urgency mapping, and
/// scene/social routing. The ambient loop itself (camera + live LLM) isn't unit-tested.
final class AssistiveModeTests: XCTestCase {

    // MARK: - AssistiveAdvice parsing

    func testParsesCleanJSON() {
        let raw = #"{"advice": "Steps ahead on your left.", "urgency": "medium", "followup": "Want me to guide you?"}"#
        let advice = AssistiveAdvice.parse(raw)
        XCTAssertEqual(advice?.advice, "Steps ahead on your left.")
        XCTAssertEqual(advice?.urgency, .medium)
        XCTAssertEqual(advice?.followup, "Want me to guide you?")
    }

    func testParsesJSONWrappedInCodeFenceAndProse() {
        let raw = """
        Here is the result:
        ```json
        {"advice": "The person looks calm.", "urgency": "low"}
        ```
        """
        let advice = AssistiveAdvice.parse(raw)
        XCTAssertEqual(advice?.advice, "The person looks calm.")
        XCTAssertEqual(advice?.urgency, .low)
        XCTAssertNil(advice?.followup)
    }

    func testParseToleratesMissingUrgency() {
        let raw = #"{"advice": "Doorway directly ahead."}"#
        let advice = AssistiveAdvice.parse(raw)
        XCTAssertEqual(advice?.advice, "Doorway directly ahead.")
        XCTAssertEqual(advice?.urgency, .low) // default
    }

    func testParseReturnsNilForNonJSON() {
        XCTAssertNil(AssistiveAdvice.parse("I cannot see anything useful."))
        XCTAssertNil(AssistiveAdvice.parse(""))
    }

    func testUrgencyMapsToSpeechUrgency() {
        XCTAssertEqual(AssistiveAdvice.Urgency.high.speechUrgency, .high)
        XCTAssertEqual(AssistiveAdvice.Urgency.medium.speechUrgency, .medium)
        XCTAssertEqual(AssistiveAdvice.Urgency.low.speechUrgency, .low)
    }

    // MARK: - AssistiveRouter

    func testRoutesToSocialOnPersonKeywords() {
        XCTAssertEqual(AssistiveRouter.route(transcription: "how is this person feeling"), .social)
        XCTAssertEqual(AssistiveRouter.route(transcription: "read their emotion"), .social)
        XCTAssertEqual(AssistiveRouter.route(transcription: "is he angry?"), .social)
    }

    func testRoutesToSceneOtherwise() {
        XCTAssertEqual(AssistiveRouter.route(transcription: "what's in front of me"), .scene)
        XCTAssertEqual(AssistiveRouter.route(transcription: "describe the room"), .scene)
    }

    func testDefaultsToSceneWhenNoTranscription() {
        XCTAssertEqual(AssistiveRouter.route(transcription: nil), .scene)
        XCTAssertEqual(AssistiveRouter.route(transcription: ""), .scene)
    }

    func testPromptsCarryJSONContractAndDiffer() {
        let scene = AssistiveRouter.systemPrompt(for: .scene)
        let social = AssistiveRouter.systemPrompt(for: .social)
        XCTAssertTrue(scene.contains("valid JSON"))
        XCTAssertTrue(social.contains("emotional state"))
        XCTAssertNotEqual(scene, social)
    }
}
