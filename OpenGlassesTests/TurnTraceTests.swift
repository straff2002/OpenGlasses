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

    /// A service's `vendor/model` id is not a path: the report names Groq's `qwen/qwen3.8-27b` in
    /// full (support report, 2026-10-29 read `qwen3.8-27b` as a model Groq does not serve).
    func testAServicesVendorQualifiedModelIdIsKeptWhole() {
        XCTAssertEqual(TurnTrace.modelName("qwen/qwen3.8-27b"), "qwen/qwen3.8-27b")
        XCTAssertEqual(TurnTrace.modelName("anthropic/claude-sonnet-5"), "anthropic/claude-sonnet-5")
        XCTAssertEqual(TurnTrace.modelName("gemini-3.5-flash-lite"), "gemini-3.5-flash-lite")
        XCTAssertEqual(TurnTrace.modelName("/private/var/mobile/Models/gemma-2b.gguf"), "gemma-2b.gguf")
        XCTAssertEqual(TurnTrace.modelName("file:///private/var/mobile/Models/gemma-2b.gguf"), "gemma-2b.gguf")
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

    /// The turn that closes a job ends its conversation and the job before it seals; it still
    /// belongs to both. A turn that starts a job takes the ids it ends with.
    func testATurnThatClosesTheJobKeepsTheJobItBeganIn() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        var context: (threadId: String?, fieldSessionId: String?) = ("thread-1027", "job-1027")
        TurnRecorder.traceContext = { context }

        TurnRecorder.beginTurn()
        context = (nil, nil)            // field_session end: the job and its thread close mid-turn
        TurnRecorder.endTurn()

        TurnRecorder.beginTurn()
        context = ("thread-2", "job-2") // a turn that opens a job
        TurnRecorder.endTurn()

        XCTAssertEqual(sunk.map(\.threadId), ["thread-1027", "thread-2"])
        XCTAssertEqual(sunk.map(\.fieldSessionId), ["job-1027", "job-2"])
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

    /// Plan KE: a refused search went nowhere, so the line says so and there is nothing to record.
    func testARefusedSearchIsAToolLineWithNoSearchEvidence() throws {
        let url = directory.appendingPathComponent("refused-traces.json")
        let store = TurnTraceStore(url: url, clock: { [epoch] in epoch })
        TurnRecorder.traceSink = { store.record($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.noteToolResult(name: "web_search", outcome: "refused", query: "QX100 fan will not start",
                                    result: VaultOnlyPolicy.refusal(tool: "web_search"),
                                    turnID: TurnRecorder.toolTraceID)
        TurnRecorder.endTurn()
        store.waitForPendingWrites()
        let call = try XCTUnwrap(store.all.last?.toolCalls.first)
        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(call.outcome, "refused")
        XCTAssertNil(call.search)
    }

    func testSearchQueryAndReturnedSourcesSurviveSealingAndPersistence() throws {
        let url = directory.appendingPathComponent("search-traces.json")
        let store = TurnTraceStore(url: url, clock: { [epoch] in epoch })
        TurnRecorder.traceSink = { store.record($0) }
        TurnRecorder.beginTurn()
        TurnRecorder.noteToolResult(name: "web_search", outcome: "completed",
                                    query: "Sporting today password=super-secret",
                                    result: "Kickoff 20:30\nSources: https://example.com/fixture?token=private-token",
                                    turnID: TurnRecorder.toolTraceID, secrets: { ["super-secret", "private-token"] })
        TurnRecorder.endTurn()
        store.waitForPendingWrites()

        let search = try XCTUnwrap(TurnTraceStore(url: url, clock: { [epoch] in epoch })
            .all.first?.toolCalls.first?.search)
        XCTAssertTrue(search.query.contains("Sporting today"))
        XCTAssertTrue(search.result.contains("Kickoff 20:30\nSources: https://example.com/fixture"))
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("super-secret"))
        XCTAssertFalse(saved.contains("private-token"))
        XCTAssertFalse(search.queryTruncated)
        XCTAssertFalse(search.resultTruncated)
    }

    func testSearchContentIsBoundedAcrossMultipleCallsAndMarksTruncation() {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        for _ in 0..<5 {
            TurnRecorder.noteToolResult(name: "web_search", outcome: "completed",
                                        query: String(repeating: "q", count: 2_000),
                                        result: String(repeating: "r", count: 20_000),
                                        turnID: TurnRecorder.toolTraceID, secrets: { [] })
        }
        TurnRecorder.endTurn()
        let searches = sunk[0].toolCalls.compactMap(\.search)
        XCTAssertEqual(searches.count, 5)
        XCTAssertTrue(searches.allSatisfy { $0.query.count == TurnTimeline.SearchEvidence.queryLimit })
        XCTAssertTrue(searches.allSatisfy { $0.result.count <= TurnTimeline.SearchEvidence.resultLimit })
        XCTAssertEqual(searches.reduce(0) { $0 + $1.result.count }, TurnTimeline.SearchEvidence.turnResultLimit)
        XCTAssertTrue(searches.allSatisfy { $0.queryTruncated && $0.resultTruncated })
        XCTAssertTrue(searches.last?.result.isEmpty == true)
    }

    func testOtherToolsOffTurnAndLateSearchesCannotCaptureContents() async {
        var sunk: [TurnTimeline] = []
        TurnRecorder.traceSink = { sunk.append($0) }
        TurnRecorder.beginTurn()
        let oldID = TurnRecorder.toolTraceID
        TurnRecorder.endTurn()
        TurnRecorder.beginTurn()
        TurnRecorder.noteToolResult(name: "web_search", outcome: "completed", query: "late",
                                    result: "stale result", turnID: oldID)
        TurnRecorder.noteToolResult(name: "save_note", outcome: "completed", query: "private",
                                    result: "private note", turnID: TurnRecorder.toolTraceID,
                                    secrets: { XCTFail("Other tool contents must not be processed"); return [] })
        await TurnRecorder.offTurn {
            XCTAssertNil(TurnRecorder.toolTraceID)
            TurnRecorder.noteToolResult(name: "web_search", outcome: "completed", query: "background",
                                        result: "background result", turnID: nil)
        }
        TurnRecorder.endTurn()
        XCTAssertEqual(sunk[1].toolCalls.map(\.name), ["save_note"])
        XCTAssertNil(sunk[1].toolCalls.first?.search)
    }

    func testLegacyToolNotesDecodeWithoutSearchEvidence() throws {
        let old = Data(#"{"name":"web_search","outcome":"completed"}"#.utf8)
        let note = try JSONDecoder().decode(TurnTimeline.ToolNote.self, from: old)
        XCTAssertNil(note.search)
    }

    func testTraceStorageByteCapKeepsNewestAndAccountsForJSONEscaping() throws {
        var older = trace(at: at(-1))
        older.toolCalls = [.init(name: "web_search", outcome: "completed",
                                 search: .init(query: "old", result: String(repeating: "\"\n", count: 100)))]
        var newer = trace(at: at(0))
        newer.toolCalls = [.init(name: "web_search", outcome: "completed",
                                 search: .init(query: "new", result: "新しい結果"))]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let budget = try encoder.encode([newer]).count
        let kept = TurnTraceStore.retained([older, newer], now: epoch, capacity: 2, maxBytes: budget)
        XCTAssertEqual(kept.map(\.id), [newer.id])
        XCTAssertLessThanOrEqual(try encoder.encode(kept).count, budget)
    }

    func testTheBannerNamesTheCategoryInPlainWords() {
        XCTAssertEqual(AppState.plainReason("rateLimited#429"), "the AI service was busy (rate-limited)")
        XCTAssertEqual(AppState.plainReason("offline(NSURLErrorDomain)#-1009"), "no internet connection")
        XCTAssertEqual(AppState.plainReason(nil), "the AI didn't answer")
        XCTAssertEqual(AppState.plainReason("somethingNew"), "the AI didn't answer")
    }
}
