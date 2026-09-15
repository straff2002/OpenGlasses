import XCTest
@testable import OpenGlasses

/// Plan FC P1 — the pure half of local-output containment: what a completion *is*, what of it may
/// be spoken, and what the streaming preview is allowed to show before the answer can be
/// classified at all.
///
/// The end-to-end half (the real `sendLocal`, a recording tool, history) is
/// `LocalTurnContainmentTests`. This file is where the boundary shapes live, because they are
/// character-level and there are a lot of them.
final class LocalOutputPolicyTests: XCTestCase {

    private let validFrame = #"<tool_call>{"name": "get_weather", "arguments": {"city": "Auckland"}}</tool_call>"#

    // MARK: - Valid calls

    func testCompleteFrameIsAUsableCall() {
        let result = LocalOutputPolicy.classify(validFrame)
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.invocation?.name, "get_weather")
        XCTAssertEqual(result.invocation?.arguments["city"] as? String, "Auckland")
        XCTAssertEqual(result.text, "", "the frame itself is never speakable")
    }

    func testProseAroundAValidCallSurvives() {
        let result = LocalOutputPolicy.classify("Sure. \(validFrame) One moment.")
        XCTAssertEqual(result.kind, .toolCall)
        XCTAssertEqual(result.text, "Sure. One moment.")
        XCTAssertFalse(result.text.contains("<tool_call>"))
    }

    func testNestedArgumentObjectsParse() {
        let raw = #"<tool_call>{"name": "calculate", "arguments": {"expr": {"a": 1}}}</tool_call>"#
        XCTAssertEqual(LocalOutputPolicy.classify(raw).invocation?.name, "calculate")
    }

    func testSecondFrameIsStrippedButNeverBecomesTheCall() {
        let second = #"<tool_call>{"name": "set_timer", "arguments": {}}</tool_call>"#
        let result = LocalOutputPolicy.classify(validFrame + " and " + second)
        XCTAssertEqual(result.invocation?.name, "get_weather", "first usable call wins")
        XCTAssertEqual(result.text, "and")
    }

    // MARK: - Broken protocol

    func testUnterminatedFrameIsIncompleteAndEatsTheTailNotThePreamble() {
        let result = LocalOutputPolicy.classify(#"Checking now. <tool_call>{"name": "get_we"#)
        XCTAssertEqual(result.kind, .incompleteFrame)
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "Checking now.")
    }

    func testMalformedJSONInsideAFrameIsNeverACall() {
        for payload in [#"{"name": "get_weather", "arguments": }"#,
                        #"{"name": "get_weather"}"#,
                        #"{"tool": "get_weather", "arguments": {}}"#,
                        "{}",
                        "get_weather"] {
            let result = LocalOutputPolicy.classify("<tool_call>\(payload)</tool_call>")
            XCTAssertNil(result.invocation, "\(payload) must not parse into an action")
            XCTAssertTrue(result.text.isEmpty, "\(payload) must not be speakable")
            XCTAssertTrue(result.carriesProtocol)
        }
    }

    func testOrphanCloseTagIsProtocolNotSpeech() {
        let result = LocalOutputPolicy.classify("The forecast is fine.</tool_call>")
        XCTAssertEqual(result.kind, .incompleteFrame)
        XCTAssertEqual(result.text, "The forecast is fine.")
    }

    func testEmptyFrameIsProseWithProtocol() {
        let result = LocalOutputPolicy.classify("Right away.<tool_call></tool_call>")
        XCTAssertEqual(result.kind, .proseWithProtocol)
        XCTAssertEqual(result.text, "Right away.")
    }

    func testBareCallObjectIsRemovedAndNeverExecuted() {
        let result = LocalOutputPolicy.classify(#"{"name": "get_weather", "arguments": {"city": "Oslo"}}"#)
        XCTAssertEqual(result.kind, .malformedCall, "untagged output is not the protocol this app offers")
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "")
    }

    func testBareCallObjectFollowedByAnOrphanCloseTag() {
        let raw = "Sure.\n" + #"{"name": "get_weather", "arguments": {}}</tool_call>"#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertNil(result.invocation)
        XCTAssertEqual(result.text, "Sure.")
    }

    // MARK: - Positive controls: ordinary English must survive untouched

    func testOrdinarySentencesArePassedThroughUnchanged() {
        let sentences = [
            "Face the window and the light will be behind you.",
            "The web_search tool accepts a query, and returns a short summary.",
            #"A tool call looks like {"name": "x"} in JSON, but you don't need to write one."#,
            "Es ist heute sonnig in Auckland, mit leichtem Wind.",
            "今日は晴れです。",
            "tool_call is just a word here; so is arguments.",
        ]
        for sentence in sentences {
            let result = LocalOutputPolicy.classify(sentence)
            XCTAssertEqual(result.kind, .prose, sentence)
            XCTAssertEqual(result.text, sentence, sentence)
        }
    }

    func testQuotedCallObjectInsideASentenceIsNotProtocol() {
        let raw = #"You would send {"name": "get_weather", "arguments": {}} to the tool runner."#
        let result = LocalOutputPolicy.classify(raw)
        XCTAssertEqual(result.kind, .prose, "a mid-sentence object is an explanation, not a call")
        XCTAssertEqual(result.text, raw)
    }

    func testLineInitialObjectThatKeepsTalkingIsNotACall() {
        let raw = #"{"name": "get_weather", "arguments": {}} is what the model should emit."#
        XCTAssertEqual(LocalOutputPolicy.classify(raw).kind, .prose)
    }

    /// Documented limitation: a *truncated* bare object cannot be told apart from a code fragment
    /// someone is asking about, so it stays prose. Tagged truncation — what a cut-off generation
    /// actually produces — is caught.
    func testTruncatedBareObjectIsADocumentedGap() {
        let result = LocalOutputPolicy.classify(#"{"name": "get_we"#)
        XCTAssertEqual(result.kind, .prose)
    }

    // MARK: - Speaker labels and tidying

    func testSpeakerLabelIsStrippedAndSeamsAreTidied() {
        XCTAssertEqual(LocalOutputPolicy.classify("OpenGlasses: It's sunny.").text, "It's sunny.")
        XCTAssertEqual(LocalOutputPolicy.classify("Note: bring an umbrella").text,
                       "Note: bring an umbrella")
        XCTAssertEqual(LocalOutputPolicy.classify("It is \(validFrame) sunny.").text, "It is sunny.")
    }

    // MARK: - cleanedNonEmptyLocalAnswer, now a wrapper over the policy

    func testValidatorRejectsAnUnterminatedFrameItUsedToLetThrough() {
        // The old regex only matched a *complete* frame, so this reached the speaker verbatim.
        XCTAssertThrowsError(try LLMService.cleanedNonEmptyLocalAnswer(#"<tool_call>{"name": "get_we"#)) { error in
            guard case LLMError.invalidResponse(let who) = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
            XCTAssertEqual(who, "Local")
        }
    }

    // MARK: - Streaming filter

    /// Feed chunks one at a time; returns everything the preview sink would have seen.
    private func streamed(_ chunks: [String]) -> String {
        let filter = LocalProtocolStreamFilter()
        var seen = ""
        for chunk in chunks { seen += filter.ingest(chunk) }
        seen += filter.flush()
        return seen
    }

    func testOrdinaryTextStreamsThroughUnchanged() {
        XCTAssertEqual(streamed(["It is ", "sunny ", "in Auckland."]), "It is sunny in Auckland.")
    }

    func testTagSplitAcrossChunksNeverReachesThePreview() {
        let chunks = ["Sure. ", "<tool_", "call>{\"na", "me\": \"get_weather\", ", "\"arguments\": {}}", "</tool_", "call>"]
        let seen = streamed(chunks)
        XCTAssertFalse(seen.contains("<tool_call>"))
        XCTAssertFalse(seen.contains("tool_"))
        XCTAssertFalse(seen.contains("get_weather"))
        XCTAssertEqual(seen.trimmingCharacters(in: .whitespaces), "Sure.")
    }

    func testUnterminatedFrameIsNeverReleasedAtFlush() {
        let seen = streamed(["Checking. ", "<tool_call>{\"name\": \"get_we"])
        XCTAssertEqual(seen.trimmingCharacters(in: .whitespaces), "Checking.")
    }

    func testBareCallObjectIsHeldBackAndSuppressed() {
        let seen = streamed([#"{"name": "#, #""get_weather", "arguments""#, #": {}}"#])
        XCTAssertEqual(seen, "")
    }

    func testLineInitialBraceThatIsNotACallIsReleased() {
        let raw = #"{"city": "Auckland"} is the payload."#
        XCTAssertEqual(streamed([raw]), raw)
    }

    func testMidSentenceBraceIsNeverHeld() {
        let raw = #"Send {"name": "x"} to the runner."#
        XCTAssertEqual(streamed([raw]), raw)
    }

    func testHoldbackIsAtMostAFewCharactersForOrdinaryText() {
        // The only thing a chunk ending in "<" can be is an unfinished tag, so one character is
        // held; everything before it is released immediately.
        let filter = LocalProtocolStreamFilter()
        XCTAssertEqual(filter.ingest("The answer is 42 <"), "The answer is 42 ")
        XCTAssertEqual(filter.ingest("b>bold"), "<b>bold")
    }

    func testPreviewResumesAfterAFrameCloses() {
        let seen = streamed(["Checking. ", validFrame, " Done."])
        XCTAssertEqual(seen, "Checking. Done.")
    }
}
