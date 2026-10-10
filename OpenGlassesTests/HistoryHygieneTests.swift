import XCTest
@testable import OpenGlasses

/// Plan BF (docs/plans/BF-llm-turn-hygiene.md): the pure history-hygiene passes — dangling
/// tool_use repair (the "one bad tool call 400s the whole conversation" bug), image pruning, and
/// the image-aware token estimate.
final class HistoryHygieneTests: XCTestCase {

    // MARK: - Dangling tool_use repair

    func testAppendsSyntheticResultForUnansweredToolUse() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "what's the weather"],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "call_1", "name": "get_weather", "input": [:]]
            ]],
            // Execution was interrupted — no tool_result followed.
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        XCTAssertEqual(repaired.count, 3)
        let last = repaired[2]
        XCTAssertEqual(last["role"] as? String, "user")
        let blocks = last["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(blocks?.first?["tool_use_id"] as? String, "call_1")
    }

    func testLeavesAnsweredToolUseUntouched() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "call_1", "name": "get_weather", "input": [:]]
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call_1", "content": "Sunny, 20°C"]
            ]],
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        XCTAssertEqual(repaired.count, 2, "a fully-answered exchange must not gain synthetic results")
    }

    func testRepairsOnlyTheUnansweredIdInAMixedBlock() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "x", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "y", "input": [:]]
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "a", "content": "done"]
            ]],
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        // Assistant turn + one merged user turn carrying results for BOTH ids (Anthropic requires
        // all of a turn's tool_results in a single following user message).
        XCTAssertEqual(repaired.count, 2)
        let results = repaired[1]["content"] as? [[String: Any]]
        let answeredIds = Set(results?.compactMap { $0["tool_use_id"] as? String } ?? [])
        XCTAssertEqual(answeredIds, ["a", "b"])
        // "a" keeps its real result; "b" gets the synthetic interrupted result.
        let bResult = results?.first { $0["tool_use_id"] as? String == "b" }
        XCTAssertEqual(bResult?["content"] as? String, HistoryHygiene.interruptedToolResult)
    }

    /// The tool loop appends one user message per result. Two calls in one assistant turn are
    /// followed by two messages, and the repair has to read both before calling either unanswered.
    func testTwoResultsInSeparateMessagesAreBothRead() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "x", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "y", "input": [:]]
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "first"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "second"]]],
            ["role": "assistant", "content": "both done"],
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        XCTAssertEqual(repaired.count, 3, "the two result messages merge into one")
        let results = repaired[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["a", "b"])
        XCTAssertEqual(results.compactMap { $0["content"] as? String }, ["first", "second"],
                       "the second tool ran; it must not be reported as interrupted")
        XCTAssertEqual(repaired[2]["content"] as? String, "both done")
    }

    /// A turn that yields after its second of three calls leaves the third unanswered.
    func testSeparateMessagesStillGetASyntheticResultForTheMissingId() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "x", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "y", "input": [:]],
                ["type": "tool_use", "id": "c", "name": "z", "input": [:]]
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "first"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "second"]]],
            ["role": "user", "content": "done"],
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        XCTAssertEqual(repaired.count, 3)
        let results = repaired[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.compactMap { $0["content"] as? String },
                       ["first", "second", HistoryHygiene.interruptedToolResult])
        XCTAssertEqual(repaired[2]["content"] as? String, "done", "a plain user turn ends the run")
    }

    /// A history the single-message repair already wrote back: a synthetic result for `b` merged
    /// beside `a`, with `b`'s real result stranded in the next message.
    func testHealsAHistoryTheOldRepairDamaged() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "x", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "y", "input": [:]]
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "a", "content": "first"],
                ["type": "tool_result", "tool_use_id": "b", "content": HistoryHygiene.interruptedToolResult]
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "second"]]],
        ]
        let repaired = HistoryHygiene.repairDanglingToolUse(history)
        XCTAssertEqual(repaired.count, 2)
        let results = repaired[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["a", "b"], "one result per id")
        XCTAssertEqual(results.compactMap { $0["content"] as? String }, ["first", "second"])
    }

    func testRepairIsIdempotent() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "x", "input": [:]],
                ["type": "tool_use", "id": "b", "name": "y", "input": [:]]
            ]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": "first"]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "b", "content": "second"]]],
        ]
        let once = HistoryHygiene.repairDanglingToolUse(history)
        let twice = HistoryHygiene.repairDanglingToolUse(once)
        XCTAssertEqual(once as NSArray, twice as NSArray)
    }

    // MARK: - Image pruning

    private func imageMessage(_ text: String) -> [String: Any] {
        // ~200k base64 chars ≈ a real ~150KB JPEG frame — enough to weigh well past the text floor.
        ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                          "data": String(repeating: "A", count: 200_000)]],
            ["type": "text", "text": text],
        ]]
    }

    func testPruneKeepsNewestImageAndDropsOlder() {
        let history = [imageMessage("first"), imageMessage("second")]
        let pruned = HistoryHygiene.pruneImages(history, keepLast: 1)

        // First message: image replaced by placeholder, text preserved.
        let firstBlocks = pruned[0]["content"] as? [[String: Any]]
        XCTAssertFalse(firstBlocks?.contains { $0["type"] as? String == "image" } ?? true,
                       "old image should be pruned")
        XCTAssertTrue(firstBlocks?.contains { ($0["text"] as? String) == "first" } ?? false,
                      "old text is preserved")
        XCTAssertTrue(firstBlocks?.contains { ($0["text"] as? String) == HistoryHygiene.prunedImagePlaceholder } ?? false)

        // Second (newest) message keeps its image.
        let secondBlocks = pruned[1]["content"] as? [[String: Any]]
        XCTAssertTrue(secondBlocks?.contains { $0["type"] as? String == "image" } ?? false,
                      "newest image must be kept")
    }

    func testPruneNoOpWhenWithinKeepLimit() {
        let history = [imageMessage("only")]
        let pruned = HistoryHygiene.pruneImages(history, keepLast: 1)
        let blocks = pruned[0]["content"] as? [[String: Any]]
        XCTAssertTrue(blocks?.contains { $0["type"] as? String == "image" } ?? false)
    }

    /// The prune now runs for every provider, so it must recognise the OpenAI-compatible
    /// `image_url` block shape — an unpruned photo history overflowed Gemini-via-OpenAI context.
    func testPruneRecognisesOpenAIImageURLBlocks() {
        func openAIImageMessage(_ text: String) -> [String: Any] {
            ["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]],
                ["type": "text", "text": text],
            ]]
        }
        let pruned = HistoryHygiene.pruneImages(
            [openAIImageMessage("first"), openAIImageMessage("second")], keepLast: 1)
        let firstBlocks = pruned[0]["content"] as? [[String: Any]]
        XCTAssertFalse(firstBlocks?.contains { $0["type"] as? String == "image_url" } ?? true,
                       "old OpenAI-format image should be pruned")
        XCTAssertTrue(firstBlocks?.contains { ($0["text"] as? String) == HistoryHygiene.prunedImagePlaceholder } ?? false)
        let secondBlocks = pruned[1]["content"] as? [[String: Any]]
        XCTAssertTrue(secondBlocks?.contains { $0["type"] as? String == "image_url" } ?? false,
                      "newest image must be kept")
    }

    /// Gemini native turns store images as `inlineData` inside a `parts` array.
    func testPruneRecognisesGeminiInlineDataParts() {
        func geminiImageMessage(_ text: String) -> [String: Any] {
            ["role": "user", "parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": "AAAA"]],
                ["text": text],
            ]]
        }
        let pruned = HistoryHygiene.pruneImages(
            [geminiImageMessage("first"), geminiImageMessage("second")], keepLast: 1)
        let firstParts = pruned[0]["parts"] as? [[String: Any]]
        XCTAssertFalse(firstParts?.contains { $0["inlineData"] != nil } ?? true,
                       "old Gemini inlineData should be pruned")
        XCTAssertTrue(firstParts?.contains { ($0["text"] as? String) == HistoryHygiene.prunedImagePlaceholder } ?? false,
                      "placeholder lands as a bare-text part, not a typed block")
        let secondParts = pruned[1]["parts"] as? [[String: Any]]
        XCTAssertTrue(secondParts?.contains { $0["inlineData"] != nil } ?? false,
                      "newest image must be kept")
    }

    // MARK: - Token estimation

    func testImageBlockCountsMoreThanTheFloor() {
        // A big base64 image should be estimated well above the 50-token text floor.
        let msg = imageMessage("look")
        let tokens = HistoryHygiene.estimatedTokens(forMessage: msg)
        XCTAssertGreaterThan(tokens, 50, "image weight must exceed the flat floor so compaction can see it")
    }

    func testPlainTextMessageUsesCharCountFloor() {
        let msg: [String: Any] = ["role": "user", "content": "hi"]
        XCTAssertEqual(HistoryHygiene.estimatedTokens(forMessage: msg), 50)
    }
}
