import XCTest
@testable import OpenGlasses

/// `ChatRunTracker` turns the gateway's `chat` event stream into per-run chunks, an awaitable
/// terminal outcome, and a *late* answer for a run whose waiter gave up. Time is the bridge's
/// business; here `park(runId:)` stands in for the timeout.
@MainActor
final class ChatRunTrackerTests: XCTestCase {

    private func delta(_ runId: String, seq: Int, text: String, replace: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "runId": runId, "sessionKey": "agent:main:glass", "seq": seq, "state": "delta",
            "deltaText": text,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]], "timestamp": 1],
        ]
        if replace { payload["replace"] = true }
        return payload
    }

    private func final(_ runId: String, seq: Int, text: String?) -> [String: Any] {
        var payload: [String: Any] = ["runId": runId, "sessionKey": "agent:main:glass", "seq": seq, "state": "final"]
        if let text {
            payload["message"] = ["role": "assistant", "content": [["type": "text", "text": text]], "timestamp": 1]
        }
        return payload
    }

    // MARK: - parsing

    func testParseCoversEveryState() {
        XCTAssertEqual(ChatRunEvent.parse(payload: delta("r", seq: 1, text: "Hel")),
                       .delta(runId: "r", seq: 1, bufferedText: "Hel", replace: false))
        XCTAssertEqual(ChatRunEvent.parse(payload: final("r", seq: 2, text: "Hello")),
                       .final(runId: "r", seq: 2, text: "Hello"))
        XCTAssertEqual(ChatRunEvent.parse(payload: ["runId": "r", "seq": 3, "state": "aborted", "errorMessage": "stop"]),
                       .aborted(runId: "r", seq: 3, message: "stop"))
        XCTAssertEqual(ChatRunEvent.parse(payload: ["runId": "r", "seq": 4, "state": "error", "errorMessage": "boom"]),
                       .error(runId: "r", seq: 4, message: "boom"))
        XCTAssertNil(ChatRunEvent.parse(payload: ["runId": "r", "state": "typing"]))
        XCTAssertNil(ChatRunEvent.parse(payload: ["state": "final"]), "no runId → not a run update")
    }

    func testMessageTextJoinsTextBlocksOnly() {
        XCTAssertEqual(ChatRunEvent.messageText(["content": [["type": "text", "text": "a"], ["type": "image"], ["type": "text", "text": "b"]]]), "ab")
        XCTAssertEqual(ChatRunEvent.messageText(["content": "plain"]), "plain")
        XCTAssertNil(ChatRunEvent.messageText(nil))
    }

    // MARK: - chunks

    func testDeltasEmitOnlyNewText() {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        XCTAssertEqual(tracker.handle(payload: delta("r", seq: 1, text: "The ")), .chunk(runId: "r", text: "The "))
        XCTAssertEqual(tracker.handle(payload: delta("r", seq: 2, text: "The tram")), .chunk(runId: "r", text: "tram"))
        XCTAssertNil(tracker.handle(payload: delta("r", seq: 3, text: "The tram")), "no new text, no chunk")
    }

    func testUnknownRunIsReportedNotSpoken() {
        let tracker = ChatRunTracker()
        XCTAssertEqual(tracker.handle(payload: delta("other", seq: 1, text: "x")), .unknownRun(runId: "other"))
    }

    func testControlLineIsWithheldThenStripped() {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        XCTAssertNil(tracker.handle(payload: delta("r", seq: 1, text: "{\"voice\":")), "might be a control line — hold")
        XCTAssertNil(tracker.handle(payload: delta("r", seq: 2, text: "{\"voice\": \"nova\"}")))
        XCTAssertEqual(tracker.handle(payload: delta("r", seq: 3, text: "{\"voice\": \"nova\"}\nHi")),
                       .chunk(runId: "r", text: "Hi"))
        XCTAssertEqual(tracker.handle(payload: delta("r", seq: 4, text: "{\"voice\": \"nova\"}\nHi there")),
                       .chunk(runId: "r", text: " there"))
    }

    func testReplaceRestartsEmission() {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        _ = tracker.handle(payload: delta("r", seq: 1, text: "Draft one"))
        XCTAssertEqual(tracker.handle(payload: delta("r", seq: 2, text: "Final", replace: true)),
                       .chunk(runId: "r", text: "Final"))
    }

    // MARK: - waiting

    func testWaitResolvesOnFinal() async {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        async let outcome = tracker.wait(runId: "r")
        await Task.yield()
        _ = tracker.handle(payload: delta("r", seq: 1, text: "{\"once\": true}\nDone."))
        XCTAssertEqual(tracker.handle(payload: final("r", seq: 2, text: "{\"once\": true}\nDone.")),
                       .completed(runId: "r", outcome: .answered("Done.")))
        let result = await outcome
        XCTAssertEqual(result, .answered("Done."))
        XCTAssertEqual(tracker.state(runId: "r"), ChatRunTracker.RunState(phase: .answered("Done.")))
    }

    func testWaitAfterTerminalReturnsImmediately() async {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        _ = tracker.handle(payload: ["runId": "r", "seq": 1, "state": "error", "errorMessage": "boom"])
        let outcome = await tracker.wait(runId: "r")
        XCTAssertEqual(outcome, .failed("boom"))
    }

    func testParkedRunAnswersLate() async {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        async let outcome = tracker.wait(runId: "r")
        await Task.yield()
        XCTAssertTrue(tracker.park(runId: "r"))
        let parked = await outcome
        XCTAssertEqual(parked, .timedOut)
        XCTAssertEqual(tracker.state(runId: "r"), ChatRunTracker.RunState(phase: .running), "still tracked")
        XCTAssertEqual(tracker.handle(payload: final("r", seq: 5, text: "Late but here.")),
                       .lateAnswer(runId: "r", text: "Late but here."))
        XCTAssertFalse(tracker.park(runId: "r"), "nothing left to park")
    }

    func testParkedRunThatAbortsCompletesQuietly() {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        tracker.park(runId: "r")
        XCTAssertEqual(tracker.handle(payload: ["runId": "r", "seq": 1, "state": "aborted"]),
                       .completed(runId: "r", outcome: .aborted(nil)))
        XCTAssertEqual(tracker.state(runId: "r"), ChatRunTracker.RunState(phase: .aborted))
    }

    func testEventsAfterTerminalAreIgnored() {
        let tracker = ChatRunTracker()
        tracker.register(runId: "r")
        _ = tracker.handle(payload: final("r", seq: 1, text: "Done"))
        XCTAssertNil(tracker.handle(payload: delta("r", seq: 2, text: "Done and more")))
    }

    func testTerminalRunsArePrunedButAwaitedOnesKept() async {
        let tracker = ChatRunTracker()
        tracker.register(runId: "keep")
        async let _ = tracker.wait(runId: "keep")
        await Task.yield()
        for i in 0..<80 {
            tracker.register(runId: "run-\(i)")
            _ = tracker.handle(payload: final("run-\(i)", seq: 1, text: "x"))
        }
        XCTAssertTrue(tracker.trackedRunIds.contains("keep"))
        XCTAssertLessThanOrEqual(tracker.trackedRunIds.count, 65)
        tracker.park(runId: "keep")
    }
}
