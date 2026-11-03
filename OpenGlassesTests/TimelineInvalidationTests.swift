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
        XCTAssertEqual(TimelineInvalidation.withoutMentions(of: "Zoe Marsh", in: entries).map(\.id),
                       ["e3", "e4"])
        XCTAssertEqual(TimelineInvalidation.withoutMentions(of: "ann", in: entries).map(\.id),
                       ["e1", "e2", "e3"], "Ann is not in Annual")
        XCTAssertEqual(TimelineInvalidation.withoutMentions(of: "  ", in: entries).count, 4,
                       "an empty name matches nobody")
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
        store.updateCompressedSummary("question 3 was about the fan", for: thread.id)

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
        store.updateCompressedSummary("Corvina Hale asked for a quote.", for: second.id)

        XCTAssertEqual(store.dropTimelineEntries(naming: "Corvina Hale"), 3,
                       "two entries and one legacy summary")

        let reopened = ConversationStore(directory: directory)
        XCTAssertEqual(reopened.threads.first { $0.id == first.id }?.timeline?.map(\.id), ["b"])
        XCTAssertNil(reopened.threads.first { $0.id == second.id }?.timeline)
        XCTAssertNil(reopened.threads.first { $0.id == second.id }?.compressedSummary)
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
