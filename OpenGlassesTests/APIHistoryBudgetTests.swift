import XCTest
@testable import OpenGlasses

/// Plan GB P5 — the API request-copy history budget, the job floor, stale images and the fixed
/// `image_url` estimate.
final class APIHistoryBudgetTests: XCTestCase {

    private func exchange(_ i: Int, words: Int = 100) -> [[String: Any]] {
        let filler = String(repeating: "word ", count: words)
        return [["role": "user", "content": "question \(i) \(filler)"],
                ["role": "assistant", "content": "answer \(i) \(filler)"]]
    }

    private func toolExchange(_ i: Int) -> [[String: Any]] {
        [["role": "user", "content": "use a tool \(i)"],
         ["role": "assistant", "content": NSNull(),
          "tool_calls": [["id": "c\(i)", "type": "function",
                          "function": ["name": "get_weather", "arguments": "{}"]]]],
         ["role": "tool", "tool_call_id": "c\(i)", "content": "sunny"],
         ["role": "assistant", "content": "It's sunny."]]
    }

    private static let photo = "data:image/jpeg;base64," + String(repeating: "A", count: 880_000)

    // MARK: - Budget

    func testBudgetHoldsAt159Messages() {
        // The tester's second job ended at 159 messages; the request copy stays inside the allowance.
        var history: [[String: Any]] = []
        for i in 0..<79 { history += exchange(i) }
        history.append(["role": "user", "content": "current question"])
        XCTAssertEqual(history.count, 159)
        let selection = APIHistoryBudget.select(history: history, protectedStart: 158, allowance: 14_000)
        XCTAssertLessThanOrEqual(selection.estimatedTokens, 14_000)
        XCTAssertGreaterThan(selection.omittedMessages, 0)
        XCTAssertEqual(selection.history.last?["content"] as? String, "current question")
        XCTAssertEqual(selection.history.first?["role"] as? String, "user", "cuts land on a user turn")
        XCTAssertEqual(selection.history.count + selection.omittedMessages, 159)
    }

    func testCurrentTurnAndItsToolLoopAreNeverDropped() {
        var history: [[String: Any]] = []
        for i in 0..<5 { history += exchange(i) }
        let start = history.count
        history += toolExchange(99)
        let selection = APIHistoryBudget.select(history: history, protectedStart: start, allowance: 1)
        XCTAssertEqual(selection.history.count, 4, "only the protected turn remains, even over budget")
        XCTAssertEqual(selection.omittedMessages, start)
    }

    func testOlderToolExchangesAreDroppedWhole() {
        var history: [[String: Any]] = []
        history += toolExchange(1)
        history += exchange(2, words: 2000)
        let start = history.count
        history.append(["role": "user", "content": "now"])
        let selection = APIHistoryBudget.select(history: history, protectedStart: start, allowance: 600)
        // The first cut removes the whole tool exchange; no orphaned tool message leads the copy.
        XCTAssertNotEqual(selection.history.first?["role"] as? String, "tool")
        XCTAssertEqual(selection.history.first?["role"] as? String, "user")
    }

    func testFloorStartsTheJobFresh() {
        var history: [[String: Any]] = []
        for i in 0..<3 { history += exchange(i, words: 1) }   // the previous job
        let floor = history.count
        history += exchange(10, words: 1)                      // this job
        let start = history.count
        history.append(["role": "user", "content": "now"])
        let selection = APIHistoryBudget.select(history: history, protectedStart: start, floor: floor, allowance: 14_000)
        XCTAssertEqual(selection.omittedMessages, floor)
        XCTAssertTrue((selection.history.first?["content"] as? String)?.hasPrefix("question 10") ?? false)
    }

    func testFloorNeverCutsIntoTheProtectedTurn() {
        let history: [[String: Any]] = exchange(0) + [["role": "user", "content": "now"]]
        let selection = APIHistoryBudget.select(history: history, protectedStart: 2, floor: 10, allowance: 14_000)
        XCTAssertEqual(selection.history.count, 1)
    }

    func testZeroAllowanceDisablesTrimmingButKeepsTheFloor() {
        var history: [[String: Any]] = []
        for i in 0..<40 { history += exchange(i) }
        let selection = APIHistoryBudget.select(history: history, protectedStart: 79, floor: 2, allowance: 0)
        XCTAssertEqual(selection.history.count, 78)
        XCTAssertEqual(APIHistoryBudget.omissionNote(0), nil)
        XCTAssertNotNil(APIHistoryBudget.omissionNote(3))
    }

    // MARK: - Job floor

    func testJobFloorFollowsJobStarts() {
        var floor = JobHistoryFloor()
        floor.turnStarted(at: 0, sessionId: nil)
        floor.turnFinished(startedAt: 0, sessionId: nil)
        XCTAssertEqual(floor.floor(historyCount: 10), 0)

        // A spoken "start a job" at message 10: the job starts with that turn.
        floor.turnStarted(at: 10, sessionId: nil)
        floor.turnFinished(startedAt: 10, sessionId: "job-1010")
        XCTAssertEqual(floor.floor(historyCount: 20), 10)

        // Same job, later turns: unchanged.
        floor.turnStarted(at: 20, sessionId: "job-1010")
        floor.turnFinished(startedAt: 20, sessionId: "job-1010")
        XCTAssertEqual(floor.floor(historyCount: 40), 10)

        // Job ends; the conversation after it keeps the job's context.
        floor.turnStarted(at: 40, sessionId: nil)
        XCTAssertEqual(floor.floor(historyCount: 44), 10)

        // Next job started from the Job tab between turns.
        floor.turnStarted(at: 44, sessionId: "job-1011")
        XCTAssertEqual(floor.floor(historyCount: 46), 44)
    }

    func testJobFloorSurvivesCompactionAndReload() {
        var floor = JobHistoryFloor()
        floor.turnFinished(startedAt: 50, sessionId: "job")
        // 100 messages compacted to 1 summary + the newest 34: 66 removed from the front.
        floor.historyCompacted(before: 100, after: 35, insertedSummary: 1)
        XCTAssertEqual(floor.floor(historyCount: 35), 0, "the floor sat inside the compacted part")

        var later = JobHistoryFloor()
        later.turnFinished(startedAt: 80, sessionId: "job")
        later.historyCompacted(before: 100, after: 35, insertedSummary: 1)
        XCTAssertEqual(later.floor(historyCount: 35), 15)

        later.historyReplaced(sessionId: "job")
        XCTAssertEqual(later.floor(historyCount: 35), 0)
        later.turnStarted(at: 35, sessionId: "job")
        XCTAssertEqual(later.floor(historyCount: 36), 0, "a reloaded job thread is the job's own history")
    }

    // MARK: - Images

    func testImageURLIsEstimatedByItsPayload() {
        let message: [String: Any] = ["role": "user", "content": [
            ["type": "text", "text": "what is this"],
            ["type": "image_url", "image_url": ["url": Self.photo]],
        ]]
        XCTAssertGreaterThan(HistoryHygiene.estimatedTokens(forMessage: message), 500,
                             "an ~880 KB photo used to count as one token")
    }

    func testImagesRideOnlyAfterTheLastAssistantTurn() {
        let history: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "what is this"],
                                         ["type": "image_url", "image_url": ["url": Self.photo]]]],
            ["role": "assistant", "content": NSNull(),
             "tool_calls": [["id": "c1", "type": "function", "function": ["name": "capture_photo", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "captured"],
            ["role": "user", "content": [["type": "text", "text": "photo from capture_photo"],
                                         ["type": "image_url", "image_url": ["url": Self.photo]]]],
        ]
        let copy = HistoryHygiene.imagesOnlyAfterLastAssistant(history)
        let first = copy[0]["content"] as? [[String: Any]] ?? []
        XCTAssertFalse(first.contains { $0["type"] as? String == "image_url" },
                       "the user's photo is not resent on the tool round-trip")
        let last = copy[3]["content"] as? [[String: Any]] ?? []
        XCTAssertTrue(last.contains { $0["type"] as? String == "image_url" },
                      "the capture tool's new photo still reaches the model")
        // The first request of a turn (no assistant yet after it) keeps its image.
        let fresh = HistoryHygiene.imagesOnlyAfterLastAssistant([["role": "assistant", "content": "hi"], history[0]])
        XCTAssertTrue((fresh[1]["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" })
    }

    func testNoImageOnATurnThatDidNotAsk() {
        let history: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "what is this"],
                                         ["type": "image_url", "image_url": ["url": Self.photo]]]],
            ["role": "assistant", "content": "A furnace."],
        ]
        let pruned = HistoryHygiene.pruneImages(history, keepLast: 0)
        XCTAssertFalse(HistoryHygiene.estimatedTokens(pruned) > 500)
    }
}
