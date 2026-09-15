import XCTest
@testable import OpenGlasses

/// Plan FC P3 — what one turn's prompt actually received from the wearer's saved memory.
///
/// The claim under test is narrow and checkable: every number a snapshot reports describes the
/// block that was appended to the prompt, not the block the store could have produced. So the
/// fixtures here render through the real `SemanticMemoryStore` and then compare against the real
/// prompt pieces (`LLMService.memoryPromptBlock`, `LLMService.leanCloudPrompt`), rather than
/// asserting a counter against itself.
///
/// The second claim is that none of it can carry content. Every fixture writes a distinctive
/// marker *value* — not a word from the query, so an absence assertion cannot pass by scoping —
/// and the report, the export and the encoded log line are each searched for it.
@MainActor
final class MemoryContextDiagnosticsTests: XCTestCase {

    /// A value no scoping accident could reproduce, and no query below contains.
    private let markerValue = "ZQXJVMARKERVALUE"
    private let markerKey = "zqxjvmarkerkey"

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private var ledger = TurnLedger()

    override func setUp() {
        super.setUp()
        ledger = TurnLedger()
        TurnRecorder.reset(ledger: ledger, now: { [epoch] in epoch }, micRoutePorts: { [] })
        MemoryContextRecorder.forgetLive()
    }

    override func tearDown() {
        TurnRecorder.reset()
        MemoryContextRecorder.forgetLive()
        super.tearDown()
    }

    private func makeStore() -> SemanticMemoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SemanticMemoryStore(directory: dir)
    }

    /// A store whose database cannot be opened: the parent is a file, not a directory, so SQLite
    /// has nowhere to create the database. No mock — the real failure path runs.
    private func makeUnreadableStore() -> SemanticMemoryStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).blocked")
        FileManager.default.createFile(atPath: file.path, contents: Data("not a directory".utf8))
        return SemanticMemoryStore(directory: file.appendingPathComponent("inside"))
    }

    private func bulletLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
    }

    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [String] = []
        func record(_ line: String) { lock.lock(); captured.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    }

    private func capturingEvents(_ body: () -> Void) -> [String] {
        let sink = EventSink()
        let token = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(token) }
        body()
        return sink.lines
    }

    // MARK: - The four ways a prompt carries no memory

    func testDisabledMemoryIsReportedAsDisabledRatherThanEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal(markerKey, value: markerValue))

        let rendered = store.renderedContext(query: nil, enabled: false, now: at(0))

        XCTAssertNil(rendered.text, "a disabled store must not hand a block to the prompt")
        XCTAssertEqual(rendered.snapshot.availability, .disabled)
        XCTAssertEqual(rendered.snapshot.renderedCharacters, 0)
        XCTAssertEqual(rendered.snapshot.included, 0)
        XCTAssertFalse(rendered.snapshot.reportLine.contains(markerValue),
                       "a disabled snapshot must not describe what was not read")
    }

    func testEmptyStoreIsReportedAsEmptyWithNothingStored() {
        let rendered = makeStore().renderedContext(query: nil, enabled: true, now: at(0))

        XCTAssertNil(rendered.text)
        XCTAssertEqual(rendered.snapshot.availability, .empty)
        XCTAssertEqual(rendered.snapshot.stored, 0)
        XCTAssertEqual(rendered.snapshot.retrieved, 0)
    }

    func testUnreadableStorageIsReportedAsUnavailableNotEmpty() {
        let store = makeUnreadableStore()
        XCTAssertFalse(store.isStorageAvailable,
                       "the fixture must actually fail to open, or it proves nothing")

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))

        XCTAssertNil(rendered.text)
        XCTAssertEqual(rendered.snapshot.availability, .unavailable(.storageUnreadable))
        XCTAssertEqual(rendered.snapshot.availability.unavailableReason, .storageUnreadable)
    }

    /// Gateway memory lives in memory rather than in the database, so an unreadable store that
    /// still renders a block must not be reported as unavailable — the block is real.
    func testUnreadableStorageStillReportsAvailableWhenAnotherSectionRendered() {
        let store = makeUnreadableStore()
        store.gatewayMemories = ["\(markerValue) from another device"]

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))

        XCTAssertEqual(rendered.snapshot.availability, .available)
        XCTAssertEqual(rendered.snapshot.included, 1)
    }

    // MARK: - Truncation

    func testEntriesBeyondTheCapAreCountedAsDropped() {
        let store = makeStore()
        for index in 0..<20 { XCTAssertTrue(store.rememberGlobal("fact\(index)", value: "value \(index)")) }

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        let snapshot = rendered.snapshot

        XCTAssertEqual(snapshot.stored, 20)
        XCTAssertEqual(snapshot.retrieved, 20)
        XCTAssertEqual(snapshot.included, SemanticMemoryStore.maxMemoryLines)
        XCTAssertEqual(snapshot.truncation.droppedEntries, 20 - SemanticMemoryStore.maxMemoryLines)
        XCTAssertEqual(snapshot.truncation.clampedValues, 0)
        XCTAssertEqual(snapshot.truncation.label, "cappedEntries")
        XCTAssertEqual(bulletLines(rendered.text ?? "").count, snapshot.included,
                       "included must equal the lines the prompt actually received")
    }

    func testOverLongValuesAreCountedAsClamped() {
        let store = makeStore()
        let long = markerValue + String(repeating: "x", count: SemanticMemoryStore.maxValueChars)
        XCTAssertTrue(store.rememberGlobal(markerKey, value: long))
        XCTAssertTrue(store.rememberGlobal("short", value: "brief"))

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        let snapshot = rendered.snapshot

        XCTAssertEqual(snapshot.included, 2)
        XCTAssertEqual(snapshot.truncation.droppedEntries, 0)
        XCTAssertEqual(snapshot.truncation.clampedValues, 1,
                       "one value was cut; a clamp is truncation because the model saw part of it")
        XCTAssertEqual(snapshot.truncation.label, "clampedValues")
        XCTAssertFalse(rendered.text?.contains(long) ?? true)
    }

    /// Gateway memory rather than the global store, because the global store evicts by total size
    /// before the render cap ever sees twelve long entries — and this fixture is about the render,
    /// not about eviction.
    func testCapAndClampAreBothReportedWhenTheyHappenTogether() {
        let store = makeStore()
        store.gatewayMemories = (0..<12).map { index in
            index == 0 ? String(repeating: "y", count: 400) : "fact \(index)"
        }

        let truncation = store.renderedContext(query: nil, enabled: true, now: at(0)).snapshot.truncation

        XCTAssertEqual(truncation.droppedEntries, 12 - SemanticMemoryStore.maxMemoryLines)
        XCTAssertEqual(truncation.clampedValues, 1)
        XCTAssertEqual(truncation.label, "cappedEntries.clampedValues",
                       "an enum would have to hide one of these; both happened")
    }

    // MARK: - The prompt actually sent

    func testReportedCharactersMatchTheBlockAppendedToTheSystemPrompt() {
        let store = makeStore()
        for index in 0..<4 { XCTAssertTrue(store.rememberGlobal("fact\(index)", value: "value \(index)")) }

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        let text = try! XCTUnwrap(rendered.text)
        let block = LLMService.memoryPromptBlock(text)

        XCTAssertTrue(block.contains(text), "the full prompt tier appends the block verbatim")
        XCTAssertEqual(rendered.snapshot.renderedCharacters, text.count)
        XCTAssertEqual(rendered.snapshot.estimatedTokens,
                       MemoryContextSnapshot.estimatedTokens(characters: text.count))
    }

    /// The lean cloud tier is the one place a prompt takes less than the store rendered.
    func testLeanCloudClipIsRecordedAsTruncationAndMatchesThePrompt() {
        let store = makeStore()
        for index in 0..<8 {
            XCTAssertTrue(store.rememberGlobal("fact\(index)",
                                               value: String(repeating: "z", count: 120)))
        }
        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        let text = try! XCTUnwrap(rendered.text)
        XCTAssertGreaterThan(text.count, LLMService.leanMemoryClipLimit,
                             "the fixture must exceed the lean budget, or it proves nothing")

        TurnRecorder.beginTurn()
        MemoryContextRecorder.record(rendered.snapshot)
        let prompt = LLMService.leanCloudPrompt(hasImage: false, memoryContext: text)
        TurnRecorder.endTurn()

        let recorded = try! XCTUnwrap(ledger.sealed.last?.memoryContext)
        let clip = LLMService.clipMemoryForLeanPrompt(text)
        XCTAssertTrue(prompt.contains(clip.text))
        XCTAssertFalse(prompt.contains(text), "the whole block did not reach this tier")
        XCTAssertEqual(recorded.renderedCharacters, clip.text.count,
                       "the turn must report what the backend received, not what the store rendered")
        XCTAssertEqual(recorded.truncation.omission,
                       .clippedForPromptBudget(droppedCharacters: text.count - LLMService.leanMemoryClipLimit))
        XCTAssertTrue(recorded.truncation.label.contains("clippedForPromptBudget"))
    }

    func testLeanCloudPromptLeavesAnInBudgetBlockWhole() {
        TurnRecorder.beginTurn()
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal("name", value: "short fact"))
        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        MemoryContextRecorder.record(rendered.snapshot)
        let text = try! XCTUnwrap(rendered.text)

        let prompt = LLMService.leanCloudPrompt(hasImage: false, memoryContext: text)
        TurnRecorder.endTurn()

        XCTAssertTrue(prompt.contains(text))
        XCTAssertNil(ledger.sealed.last?.memoryContext?.truncation.omission)
    }

    // MARK: - Determinism and Unicode

    func testTheSameStoreAndQueryReportTheSameCounts() {
        let store = makeStore()
        for index in 0..<15 { XCTAssertTrue(store.rememberGlobal("fact\(index)", value: "value \(index)")) }

        let first = store.renderedContext(query: "what do you know", enabled: true, now: at(0))
        let second = store.renderedContext(query: "what do you know", enabled: true, now: at(0))

        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.snapshot, second.snapshot)
    }

    /// Multi-byte values: characters are counted as characters, and no clamp splits one.
    func testUnicodeValuesAreCountedByCharacterAndNeverSplit() {
        let store = makeStore()
        let emoji = String(repeating: "🙂", count: 500)
        let accented = String(repeating: "e\u{0301}", count: 400)   // one character, two scalars
        XCTAssertTrue(store.rememberGlobal("emoji", value: emoji))
        XCTAssertTrue(store.rememberGlobal("accented", value: accented))

        let rendered = store.renderedContext(query: nil, enabled: true, now: at(0))
        let text = try! XCTUnwrap(rendered.text)

        XCTAssertEqual(rendered.snapshot.renderedCharacters, text.count)
        XCTAssertNotEqual(rendered.snapshot.renderedCharacters, text.utf8.count,
                          "the fixture must be multi-byte, or the distinction is untested")
        XCTAssertEqual(rendered.snapshot.truncation.clampedValues, 2)
        XCTAssertTrue(text.contains(String(repeating: "🙂", count: SemanticMemoryStore.maxValueChars) + "…"),
                      "the clamp must cut whole characters")
        XCTAssertTrue(text.contains(String(repeating: "e\u{0301}", count: SemanticMemoryStore.maxValueChars) + "…"))
        XCTAssertFalse(text.unicodeScalars.contains("\u{FFFD}"),
                       "a split grapheme would surface as a replacement character")
    }

    func testTheTokenEstimateIsMonotonicInCharacters() {
        var previous = -1
        for characters in [0, 1, 3, 4, 5, 100, 301, 4_000] {
            let estimate = MemoryContextSnapshot.estimatedTokens(characters: characters)
            XCTAssertGreaterThanOrEqual(estimate, previous)
            previous = estimate
        }
        XCTAssertEqual(MemoryContextSnapshot.estimatedTokens(characters: 0), 0)
        XCTAssertEqual(MemoryContextSnapshot.estimatedTokens(characters: 1), 1,
                       "a block that exists must never estimate at zero tokens")
    }

    // MARK: - Live sessions

    func testALiveSnapshotIsReportedWithItsAgeAndNeverAsPerTurn() {
        MemoryContextRecorder.recordLive(
            .notInjected(at: at(0), freshness: .connectSnapshot(age: 0)), route: .liveGemini)

        let aged = try! XCTUnwrap(MemoryContextRecorder.liveSnapshots(asOf: at(3_600))[.liveGemini])

        XCTAssertEqual(aged.freshness, .connectSnapshot(age: 3_600))
        XCTAssertNotEqual(aged.freshness, .perTurn)
        XCTAssertEqual(aged.availability, .notInjected,
                       "the live instruction carries no wearer-memory block")
        XCTAssertEqual(aged.assembledAt, at(0), "the snapshot keeps the moment it was built")
        XCTAssertTrue(aged.reportLine.contains("freshness=connectSnapshot"))
        XCTAssertTrue(aged.reportLine.contains("age=3600s"))
    }

    func testAPerTurnSnapshotIsNotAgedByBeingRead() {
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal("name", value: "a fact"))
        let snapshot = store.renderedContext(query: nil, enabled: true, now: at(0)).snapshot

        XCTAssertEqual(snapshot.asOf(at(10_000)).freshness, .perTurn)
        XCTAssertNil(snapshot.freshness.ageSeconds)
    }

    /// A clock that stepped backwards under a live session reads as "just now", not as a snapshot
    /// from the future.
    func testALiveSnapshotNeverReportsANegativeAge() {
        MemoryContextRecorder.recordLive(
            .notInjected(at: at(100), freshness: .connectSnapshot(age: 0)), route: .liveOpenAI)

        let aged = try! XCTUnwrap(MemoryContextRecorder.liveSnapshots(asOf: at(40))[.liveOpenAI])

        XCTAssertEqual(aged.freshness, .connectSnapshot(age: 0))
    }

    func testStoppingALiveSessionDropsItsSnapshot() {
        MemoryContextRecorder.recordLive(
            .notInjected(at: at(0), freshness: .connectSnapshot(age: 0)), route: .liveGemini)
        MemoryContextRecorder.forgetLive(.liveGemini)

        XCTAssertTrue(MemoryContextRecorder.liveSnapshots(asOf: at(1)).isEmpty)
    }

    // MARK: - Where it surfaces

    func testTheTurnExportCarriesTheSnapshotOfTheTurnAndOfTheLiveSession() {
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal(markerKey, value: markerValue))
        TurnRecorder.beginTurn()
        MemoryContextRecorder.record(store.renderedContext(query: nil, enabled: true, now: at(0)).snapshot)
        TurnRecorder.endTurn()
        MemoryContextRecorder.recordLive(
            .notInjected(at: at(0), freshness: .connectSnapshot(age: 0)), route: .liveGemini)

        let export = ledger.debugExport(now: at(60),
                                        liveMemory: MemoryContextRecorder.liveSnapshots(asOf: at(60)))

        XCTAssertTrue(export.contains("memory: availability=available"), export)
        XCTAssertTrue(export.contains("included=1"), export)
        XCTAssertTrue(export.contains("liveGemini: availability=notInjected"), export)
        XCTAssertFalse(export.contains(markerValue), "the export must not carry a memory value")
        XCTAssertFalse(export.contains(markerKey), "the export must not carry a memory key")
    }

    func testBackgroundWorkDoesNotRecordOntoTheWearersTurn() async {
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal("name", value: "a fact"))
        TurnRecorder.beginTurn()

        await TurnRecorder.offTurn {
            MemoryContextRecorder.record(store.renderedContext(query: nil, enabled: true, now: at(0)).snapshot)
        }
        TurnRecorder.endTurn()

        XCTAssertNil(ledger.sealed.last?.memoryContext,
                     "a scheduled agent run must not claim the turn in flight")
    }

    // MARK: - Privacy

    func testNoMemoryValueOrKeyReachesTheLogTheReportOrTheExport() {
        let store = makeStore()
        XCTAssertTrue(store.rememberGlobal(markerKey, value: markerValue))
        store.gatewayMemories = [markerValue]

        var snapshot: MemoryContextSnapshot?
        let lines = capturingEvents {
            TurnRecorder.beginTurn()
            let rendered = store.renderedContext(query: "unrelated question", enabled: true, now: at(0))
            snapshot = rendered.snapshot
            MemoryContextRecorder.record(rendered.snapshot)
            MemoryContextRecorder.noteClip(renderedCharacters: 10, droppedCharacters: 5)
            TurnRecorder.endTurn()
        }

        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("memoryContext"), "the event must actually have been emitted")
        XCTAssertTrue(joined.contains("state=available"), joined)
        XCTAssertTrue(joined.contains("event=clipped"), joined)
        XCTAssertFalse(joined.contains(markerValue), joined)
        XCTAssertFalse(joined.contains(markerKey), joined)
        XCTAssertFalse(joined.contains("unrelated"), "the query must not reach the log: \(joined)")
        XCTAssertFalse(try! XCTUnwrap(snapshot).reportLine.contains(markerValue))
        XCTAssertFalse(try! XCTUnwrap(snapshot).reportLine.contains(markerKey))
    }

    /// Every field of the snapshot is a number, a case name or a timestamp — pinned by driving the
    /// whole vocabulary through the report line and finding nothing that is not one of those.
    func testTheReportLineIsAFixedVocabulary() {
        let snapshot = MemoryContextSnapshot(
            availability: .unavailable(.storageUnreadable),
            stored: 3, retrieved: 2, included: 1, renderedCharacters: 40,
            truncation: .init(droppedEntries: 1, clampedValues: 1,
                              omission: .clippedForPromptBudget(droppedCharacters: 7)),
            assembledAt: at(0), freshness: .connectSnapshot(age: 12))

        XCTAssertEqual(snapshot.reportLine,
                       "availability=unavailable reason=storageUnreadable stored=3 retrieved=2 "
                       + "included=1 characters=40 tokens=10 "
                       + "truncation=cappedEntries.clampedValues.clippedForPromptBudget "
                       + "dropped=1 clamped=1 clippedCharacters=7 freshness=connectSnapshot age=12s")
    }
}
