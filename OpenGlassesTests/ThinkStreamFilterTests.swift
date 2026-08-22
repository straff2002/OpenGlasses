import XCTest
@testable import OpenGlasses

/// ThinkStreamFilter — incremental `<think>` suppression for local reasoning models (LFM2.5).
/// The stream starts INSIDE a template-opened think block (the opening tag never appears in
/// the completion), and tags can straddle chunk boundaries. All pure/headless.
final class ThinkStreamFilterTests: XCTestCase {

    /// Drive a filter with chunks and collect what it would emit to the UI/TTS preview.
    private func emitted(_ chunks: [String], startsInThink: Bool = true) -> String {
        let filter = ThinkStreamFilter(startsInThink: startsInThink)
        var out = chunks.map { filter.ingest($0) }.joined()
        out += filter.flush()
        return out
    }

    // MARK: - Template-opened reasoning (the LFM2.5 shape)

    func testSuppressesReasoningUntilBareCloseTag() {
        let out = emitted(["The user asks 2+2.", " Simple arithmetic.", "</think>\n\n", "It's 4."])
        XCTAssertEqual(out, "It's 4.")
    }

    func testCloseTagSplitAcrossChunksAtEveryBoundary() {
        let stream = "reasoning here</think>\n\nAnswer text."
        // Split the stream at every index — the tag must be found regardless of chunking.
        for i in stream.indices {
            let chunks = [String(stream[..<i]), String(stream[i...])]
            XCTAssertEqual(emitted(chunks), "Answer text.", "failed splitting at \(stream.distance(from: stream.startIndex, to: i))")
        }
    }

    func testSingleCharacterChunks() {
        let stream = "think think</think>\nAnswer."
        let chunks = stream.map(String.init)
        XCTAssertEqual(emitted(chunks), "Answer.")
    }

    func testWhitespaceAfterCloseTagArrivingInLaterChunksIsSwallowed() {
        let out = emitted(["reasoning</think>", "\n", "\n", "Answer."])
        XCTAssertEqual(out, "Answer.")
    }

    func testAllThinkCompletionEmitsNothingAndKeepsReasoning() {
        // Reserve exhausted mid-think: nothing speakable; reasoning is preserved for the log.
        let filter = ThinkStreamFilter()
        var out = filter.ingest("endless reasoning that never closes")
        out += filter.flush()
        XCTAssertEqual(out, "")
        XCTAssertEqual(filter.reasoning, "endless reasoning that never closes")
    }

    func testReasoningAccumulatesAcrossChunks() {
        let filter = ThinkStreamFilter()
        _ = filter.ingest("part one, ")
        _ = filter.ingest("part two</think>answer")
        XCTAssertEqual(filter.reasoning, "part one, part two")
    }

    // MARK: - Explicit paired tags (re-entry, or a non-template-opened model)

    func testPairedThinkBlockMidAnswerIsSuppressed() {
        let out = emitted(["first</think>Start. ", "<think>hidden</think>", " End."],
                          startsInThink: true)
        // Whitespace right after a think block is swallowed, so the join stays single-spaced.
        XCTAssertEqual(out, "Start. End.")
    }

    func testStartsInAnswerModePassesTextThrough() {
        let out = emitted(["Plain answer, ", "no tags at all."], startsInThink: false)
        XCTAssertEqual(out, "Plain answer, no tags at all.")
    }

    func testOpenTagSplitAcrossChunksSuppressesFromTagStart() {
        let out = emitted(["Visible. <thi", "nk>hidden</think>", "More."], startsInThink: false)
        XCTAssertEqual(out, "Visible. More.")
    }

    func testPartialTagLookalikeAtEndOfStreamIsReleasedByFlush() {
        // "<th" held back in case it grows into <think> — flush must release it as real text.
        let out = emitted(["Compare a < b <th"], startsInThink: false)
        XCTAssertEqual(out, "Compare a < b <th")
    }

    func testAngleBracketMathIsNotSwallowed() {
        let out = emitted(["x < y and y <= z."], startsInThink: false)
        XCTAssertEqual(out, "x < y and y <= z.")
    }

    // MARK: - Whole-completion strip (the non-streamed path)

    func testStripSeparatesSpokenAndReasoning() {
        let (spoken, reasoning) = ThinkStreamFilter.strip("chain of thought</think>\n\nThe answer.")
        XCTAssertEqual(spoken, "The answer.")
        XCTAssertEqual(reasoning, "chain of thought")
    }

    func testStripAllThinkReturnsEmptySpoken() {
        // The caller's empty-completion guard turns this into a catchable error — not dead air.
        let (spoken, reasoning) = ThinkStreamFilter.strip("never stopped thinking")
        XCTAssertEqual(spoken, "")
        XCTAssertEqual(reasoning, "never stopped thinking")
    }

    func testStripWithNoThinkContentInAnswerMode() {
        let (spoken, reasoning) = ThinkStreamFilter.strip("Just an answer.", startsInThink: false)
        XCTAssertEqual(spoken, "Just an answer.")
        XCTAssertNil(reasoning)
    }
}

/// LLMService.stripThinkTags — the caller-side safety net now also normalizes the
/// template-opened shape (bare `</think>`, no opener).
@MainActor
final class StripThinkTagsTemplateOpenedTests: XCTestCase {

    func testPairedTagsStillStripped() {
        let (spoken, reasoning) = LLMService.stripThinkTags("<think>why</think>Answer.")
        XCTAssertEqual(spoken, "Answer.")
        XCTAssertEqual(reasoning, "why")
    }

    func testBareCloseTagTreatedAsTemplateOpened() {
        let (spoken, reasoning) = LLMService.stripThinkTags("reasoning first</think>\n\nAnswer.")
        XCTAssertEqual(spoken, "Answer.")
        XCTAssertEqual(reasoning, "reasoning first")
    }

    func testNoTagsPassThrough() {
        let (spoken, reasoning) = LLMService.stripThinkTags("No tags here.")
        XCTAssertEqual(spoken, "No tags here.")
        XCTAssertNil(reasoning)
    }

    func testUnclosedThinkBlockIsDropped() {
        let dump = """
        <think>
        The user wants a detailed description of the image.
        I need to synthesize this into 1-2
        """
        let (spoken, reasoning) = LLMService.stripThinkTags(dump)
        XCTAssertEqual(spoken, "")
        XCTAssertNotNil(reasoning)
        XCTAssertFalse(reasoning!.contains("<think>"))
    }
}
