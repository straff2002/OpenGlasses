import XCTest
@testable import OpenGlasses

/// Plan KK P1 — entries go when their source changes: on an edit or regenerate, on a person's
/// erasure, and with the legacy summary whose span nobody recorded. Pure cases first, then the
/// store, against a temp directory.
@MainActor
final class TimelineInvalidationTests: XCTestCase {

    private typealias F = TimelineFixtures

    private var directory: URL!
    private var store: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kk-timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        store = ConversationStore(directory: directory)
    }

    override func tearDown() async throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try await super.tearDown()
    }

    private func note(_ id: String, _ first: String, _ last: String, _ text: String = "notes") -> TimelineEntry {
        TimelineEntry(id: id, firstMessageID: first, lastMessageID: last, startedAt: F.start,
                      endedAt: F.start, tier: .chunk, text: text)
    }

    // MARK: - Removal (pure)

    func testAnEntryReachingARemovedMessageGoesAndOneBeforeItStays() {
        let ids = F.conversation(6).map(\.id)
        let entries = [note("before", "u0", "a2"), note("across", "u2", "a4"), note("stale", "x", "y")]
        let kept = TimelineInvalidation.afterRemoving(Set(ids[8...]), from: ids, entries: entries)
        XCTAssertEqual(kept.map(\.id), ["before"], "the overlap goes, and so does the unresolvable")
    }

    func testARemovedMessageInsideASpanIsCaught() {
        let ids = F.conversation(6).map(\.id)
        let kept = TimelineInvalidation.afterRemoving(["a1"], from: ids,
                                                      entries: [note("e1", "u0", "a3")])
        XCTAssertTrue(kept.isEmpty, "neither end was removed, but a message inside the span was")
    }

    // MARK: - Erasure (pure)

    func testErasureMatchesAWholeWordWhateverItsCaseOrAccents() {
        let entries = [note("e1", "u0", "a0", "Called Zoë Marsh about the compressor."),
                       note("e2", "u1", "a1", "zoe marsh's unit is the LX-4410B."),
                       note("e3", "u2", "a2", "Annual service on the walk-in."),
                       note("e4", "u3", "a3", "Ann confirmed the access code.")]
        func cleared(_ token: String) -> [String] {
            TimelineInvalidation.redactingMentions(of: token, in: entries).entries
                .filter(\.isRedacted).map(\.id)
        }
        XCTAssertEqual(cleared("Zoe Marsh"), ["e1", "e2"])
        XCTAssertEqual(cleared("ann"), ["e4"], "Ann is not in Annual")
        XCTAssertEqual(cleared("  "), [], "an empty name matches nobody")
    }

    /// P2: an erased person's entry keeps its id, span and dates and loses its text, so coverage
    /// still counts the range and the pass never writes the name back from the thread.
    func testARedactedEntryKeepsItsSpanAndLosesItsText() throws {
        let entries = [note("e1", "u0", "a2", "Called Zoë Marsh about the compressor."),
                       note("e2", "u3", "a3", "Topped up the refrigerant.")]
        let result = TimelineInvalidation.redactingMentions(of: "Zoe Marsh", in: entries)
        XCTAssertEqual(result.redacted, 1)
        let redacted = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(redacted.id, "e1")
        XCTAssertEqual(redacted.firstMessageID, "u0")
        XCTAssertEqual(redacted.lastMessageID, "a2")
        XCTAssertEqual(redacted.startedAt, entries[0].startedAt)
        XCTAssertEqual(redacted.text, "")
        XCTAssertTrue(redacted.isRedacted)
        XCTAssertEqual(result.entries[1], entries[1])
        XCTAssertEqual(TimelineInvalidation.redactingMentions(of: "Zoe Marsh", in: result.entries).redacted, 0,
                       "an entry already cleared is not counted again")

        let coverage = TimelineCoverage.compute(messages: F.conversation(6), keptUserTurns: 2,
                                                entries: result.entries, minimumTokens: 0)
        XCTAssertEqual(coverage.covered, [0..<8], "the cleared span still counts as covered")
        XCTAssertNil(coverage.nextChunk, "so nothing in it is summarised again")
    }

    func testAnEntrySavedBeforeRedactionExistedDecodesAsNotRedacted() throws {
        let entry = note("e1", "u0", "a0", "Topped up the refrigerant.")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertNil(json["redacted"], "an ordinary entry does not write the field")
        json.removeValue(forKey: "redacted")
        let decoded = try JSONDecoder().decode(TimelineEntry.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.isRedacted)
        XCTAssertEqual(decoded, entry)
        let cleared = try JSONDecoder().decode(TimelineEntry.self,
                                               from: JSONEncoder().encode(entry.redacting()))
        XCTAssertTrue(cleared.isRedacted)
    }

    // MARK: - The thread

    func testAThreadSavedBeforeTheTimelineDecodesUnchanged() throws {
        let thread = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "Starting the job at the depot.")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(store.threads[0])) as? [String: Any])
        XCTAssertNil(legacy["timeline"], "an empty timeline is not written at all")
        legacy.removeValue(forKey: "timeline")
        let decoded = try JSONDecoder().decode(ConversationThread.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.timeline)
        XCTAssertEqual(decoded.id, thread.id)
        XCTAssertEqual(decoded.messages.map(\.content), ["Starting the job at the depot."])
    }

    func testATimelineRoundTrips() throws {
        store.startThread(mode: "direct")
        store.threads[0].timeline = [note("e1", "u0", "a3", "Arrived; unit short-cycling.")]
        let decoded = try JSONDecoder().decode(ConversationThread.self,
                                               from: JSONEncoder().encode(store.threads[0]))
        XCTAssertEqual(decoded.timeline, store.threads[0].timeline)
    }

    // MARK: - Truncate

    func testTruncateDropsTheEntriesItInvalidatesAndTheLegacySummary() throws {
        let thread = store.startThread(mode: "direct")
        for turn in 0..<4 {
            store.appendMessage(role: "user", content: "question \(turn)")
            store.appendMessage(role: "assistant", content: "answer \(turn)")
        }
        let ids = store.threads[0].messages.map(\.id)
        store.threads[0].timeline = [note("kept", ids[0], ids[3]), note("gone", ids[4], ids[6])]
        store.threads[0].compressedSummary = "question 3 was about the fan"

        store.truncate(from: ids[6], in: thread.id)

        let truncated = try XCTUnwrap(store.threads.first { $0.id == thread.id })
        XCTAssertEqual(truncated.messages.count, 6)
        XCTAssertEqual(truncated.timeline?.map(\.id), ["kept"])
        XCTAssertNil(truncated.compressedSummary, "its span is unknown, so it may summarise what went")

        let reopened = ConversationStore(directory: directory)
        let saved = try XCTUnwrap(reopened.threads.first { $0.id == thread.id })
        XCTAssertEqual(saved.timeline?.map(\.id), ["kept"])
        XCTAssertNil(saved.compressedSummary)
    }

    func testTruncatingEverythingTheTimelineCoveredLeavesNoTimeline() throws {
        let thread = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "question")
        store.appendMessage(role: "assistant", content: "answer")
        let ids = store.threads[0].messages.map(\.id)
        store.threads[0].timeline = [note("e1", ids[0], ids[1])]
        store.truncate(from: ids[0], in: thread.id)
        XCTAssertNil(try XCTUnwrap(store.threads.first { $0.id == thread.id }).timeline)
    }

    // MARK: - Dropping a person's entries

    func testDroppingAPersonsEntriesReachesEveryThreadAndIsSaved() throws {
        let first = store.startThread(mode: "direct")
        store.threads[0].timeline = [note("a", "u0", "a0", "Met Corvina Hale at the plant room."),
                                     note("b", "u1", "a1", "Topped up the refrigerant.")]
        let second = store.startThread(mode: "direct")
        store.threads[0].timeline = [note("c", "u0", "a0", "corvina hale signed off the job.")]
        store.threads[0].compressedSummary = "Corvina Hale asked for a quote."

        XCTAssertEqual(store.dropTimelineEntries(naming: "Corvina Hale"), 3,
                       "two entries and one legacy summary")

        let reopened = ConversationStore(directory: directory)
        let firstTimeline = reopened.threads.first { $0.id == first.id }?.timeline
        XCTAssertEqual(firstTimeline?.map(\.id), ["a", "b"], "cleared in place, not removed")
        XCTAssertEqual(firstTimeline?.map(\.isRedacted), [true, false])
        XCTAssertEqual(firstTimeline?.first?.text, "")
        XCTAssertEqual(reopened.threads.first { $0.id == second.id }?.timeline?.map(\.isRedacted), [true])
        XCTAssertNil(reopened.threads.first { $0.id == second.id }?.compressedSummary)
    }

    /// The documented edge: an edit or regenerate that removes part of a cleared span drops the
    /// cleared entry like any other, and that range may then be summarised again.
    func testTruncateDropsARedactedEntryLikeAnyOther() throws {
        let thread = store.startThread(mode: "direct")
        for turn in 0..<3 {
            store.appendMessage(role: "user", content: "question \(turn)")
            store.appendMessage(role: "assistant", content: "answer \(turn)")
        }
        let ids = store.threads[0].messages.map(\.id)
        store.threads[0].timeline = [note("kept", ids[0], ids[1]).redacting(),
                                     note("gone", ids[2], ids[3]).redacting()]
        store.truncate(from: ids[3], in: thread.id)
        XCTAssertEqual(store.threads.first { $0.id == thread.id }?.timeline?.map(\.id), ["kept"])
    }

    func testDroppingANameNobodyMentionsChangesNothing() {
        store.startThread(mode: "direct")
        store.threads[0].timeline = [note("a", "u0", "a0", "Topped up the refrigerant.")]
        XCTAssertEqual(store.dropTimelineEntries(naming: "Corvina Hale"), 0)
        XCTAssertEqual(store.threads[0].timeline?.count, 1)
    }

    func testALockedStoreSaysItCouldNotLook() {
        store.startThread(mode: "direct")
        store.threads[0].timeline = [note("a", "u0", "a0", "Met Corvina Hale.")]
        store.isLocked = true
        XCTAssertNil(store.dropTimelineEntries(naming: "Corvina Hale"),
                     "a locked store's memory is not the history; answering 0 would be a false all-clear")
        store.isLocked = false
    }
}
