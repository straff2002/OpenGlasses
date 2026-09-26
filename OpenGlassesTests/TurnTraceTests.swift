import XCTest
@testable import OpenGlasses

/// The support trace (2026-09-26): what a sealed turn becomes, how long it is kept, and the
/// recorder hooks that fill it.
@MainActor
final class TurnTraceTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnTraceTests-\(UUID().uuidString)", isDirectory: true)
        TurnRecorder.reset(ledger: TurnLedger(), now: { [epoch] in epoch }, micRoutePorts: { [] })
    }

    override func tearDown() {
        TurnRecorder.reset()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func trace(at date: Date, failed: Bool = false) -> TurnTrace {
        var timeline = TurnTimeline()
        timeline.mark(.commit, at: date)
        if failed { timeline.failure = SafeErrorSummary(category: .offline) }
        return TurnTrace(timeline, sealedAt: date)
    }

    // MARK: - From a timeline

    func testTheOutcomeIsReadFromTheTimelineWithAFailureWinning() {
        var timeline = TurnTimeline()
        XCTAssertEqual(TurnTrace(timeline, sealedAt: at(0)).outcome, .answered)
        timeline.abandoned = true
        XCTAssertEqual(TurnTrace(timeline, sealedAt: at(0)).outcome, .cancelled)
        timeline.interrupted = true
        XCTAssertEqual(TurnTrace(timeline, sealedAt: at(0)).outcome, .interrupted)
        timeline.failure = SafeErrorSummary(category: .timedOut)
        let failed = TurnTrace(timeline, sealedAt: at(0))
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.failure, "timedOut")
    }

    func testATraceIsDatedByItsHandOffAndNamesALocalModelByFile() {
        var timeline = TurnTimeline(backend: .direct(.local), model: "/private/var/mobile/Models/gemma-2b.gguf")
        timeline.mark(.speechEnd, at: at(10))
        timeline.mark(.commit, at: at(11))
        let trace = TurnTrace(timeline, sealedAt: at(20))
        XCTAssertEqual(trace.at, at(11))
        XCTAssertEqual(trace.model, "gemma-2b.gguf")
        XCTAssertEqual(trace.backend, "local")
    }

    func testATraceWithNoMarksIsDatedWhenItSealed() {
        XCTAssertEqual(TurnTrace(TurnTimeline(), sealedAt: at(5)).at, at(5))
    }

    // MARK: - Keeping them

    func testRetentionDropsOldTracesAndKeepsTheNewestWithinTheCap() {
        let now = at(30 * 24 * 60 * 60)
        let old = trace(at: now.addingTimeInterval(-15 * 24 * 60 * 60))
        let recent = (0..<5).map { trace(at: now.addingTimeInterval(TimeInterval(-$0 * 60))) }
        let kept = TurnTraceStore.retained([old] + recent, now: now, capacity: 3)
        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(kept.contains(old))
        XCTAssertEqual(kept.map(\.at), kept.map(\.at).sorted())
        XCTAssertEqual(kept.last?.at, now)
    }

    func testTheStoreWritesReadsBackAndErases() {
        let url = directory.appendingPathComponent("turn-traces.json")
        let store = TurnTraceStore(url: url, clock: { [epoch] in epoch })
        store.append(trace(at: at(-60)))
        store.append(trace(at: at(-30), failed: true))
        store.waitForPendingWrites()

        let reopened = TurnTraceStore(url: url, clock: { [epoch] in epoch })
        XCTAssertEqual(reopened.all.count, 2)
        XCTAssertEqual(reopened.traces(from: at(-40), to: at(0)).map(\.outcome), [.failed])

        reopened.removeAll()
        reopened.waitForPendingWrites()
        XCTAssertTrue(TurnTraceStore(url: url, clock: { [epoch] in epoch }).all.isEmpty)
    }

    // MARK: - The recorder

    func testASealedTurnReachesTheSinkWithItsContextAndItsFailure() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.traceContext = { ("thread-1", "job-1") }

        TurnRecorder.beginTurn()
        TurnRecorder.noteImageSent()
        TurnRecorder.notePromptBlocks([.init(name: "system prompt", characters: 100)])
        TurnRecorder.noteManualPassages(["Manual, page 3"], refused: false)
        TurnRecorder.noteToolCall(name: "lookup_part", outcome: "completed")
        TurnRecorder.noteFailure(URLError(.notConnectedToInternet))
        TurnRecorder.endTurn()

        XCTAssertEqual(sunk.count, 1)
        let turn = sunk[0]
        XCTAssertEqual(turn.threadId, "thread-1")
        XCTAssertEqual(turn.fieldSessionId, "job-1")
        XCTAssertTrue(turn.imageSent)
        XCTAssertEqual(turn.promptBlocks.map(\.name), ["system prompt"])
        XCTAssertEqual(turn.manualPassages, ["Manual, page 3"])
        XCTAssertEqual(turn.toolCalls.map(\.name), ["lookup_part"])
        XCTAssertEqual(turn.failure?.category, .offline)
    }

    func testTheTranscriberIsClaimedWithTheSpeechEndAndNotInheritedByALaterTurn() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }

        TurnRecorder.noteSpeechEnd(at: epoch)
        TurnRecorder.noteTranscriber(.onDevice)
        TurnRecorder.beginTurn()
        TurnRecorder.endTurn()

        TurnRecorder.beginTurn()   // typed: no utterance behind it
        TurnRecorder.endTurn()

        XCTAssertEqual(sunk.map(\.transcriber), [.onDevice, nil])
    }

    func testToolCallsAreCappedSoALongLoopCannotGrowATurn() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        for _ in 0..<(TurnRecorder.maxToolCalls + 10) {
            TurnRecorder.noteToolCall(name: "web_search", outcome: "completed")
        }
        TurnRecorder.endTurn()
        XCTAssertEqual(sunk.first?.toolCalls.count, TurnRecorder.maxToolCalls)
    }

    func testOffTurnWorkLeavesTheTraceAlone() async {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        await TurnRecorder.offTurn {
            TurnRecorder.noteFailure(URLError(.timedOut))
            TurnRecorder.noteToolCall(name: "summarise", outcome: "completed")
        }
        TurnRecorder.endTurn()
        XCTAssertNil(sunk.first?.failure)
        XCTAssertEqual(sunk.first?.toolCalls, [])
    }

    // MARK: - The banner's words

    func testTheBannerNamesTheCategoryInPlainWords() {
        XCTAssertEqual(AppState.plainReason("rateLimited#429"), "the AI service was busy (rate-limited)")
        XCTAssertEqual(AppState.plainReason("offline(NSURLErrorDomain)#-1009"), "no internet connection")
        XCTAssertEqual(AppState.plainReason(nil), "the AI didn't answer")
        XCTAssertEqual(AppState.plainReason("somethingNew"), "the AI didn't answer")
    }
}
