import XCTest
@testable import OpenGlasses

/// Plan LQ P2 — notes found again: `session_search` scores and returns them inside the untrusted
/// envelope, the recall index carries one row per note and drops it with its thread, and the Chat
/// list, the watch and Siri read the headline. The conversations are invented.
@MainActor
final class ConversationDigestRecallTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lq-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        PolicyEnvelope.clear()
        store = ConversationStore(directory: directory)
    }

    override func tearDown() async throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try await super.tearDown()
    }

    /// A conversation about a dripping faucet that never says "tap" or "decide": only its note does.
    @discardableResult
    private func seedFaucet(note: Bool = true) -> String {
        let thread = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "The faucet in the kitchen keeps dripping overnight.")
        store.appendMessage(role: "assistant", content: "A worn washer is the usual cause.")
        store.appendMessage(role: "user", content: "Then I'll get the plumber round on Thursday.")
        store.appendMessage(role: "assistant", content: "Sounds sensible.")
        if note {
            let last = store.threads.first { $0.id == thread.id }!.messages.last!.id
            let digest = ConversationDigest(headline: "Leaking kitchen tap: plumber on Thursday",
                                            points: [.init(kind: .decided, text: "Decided to call the plumber Thursday"),
                                                     .init(kind: .learned, text: "Washer size is 15 mm")],
                                            coversThroughMessageID: last, writtenAt: Date(), tier: .cloud)
            XCTAssertEqual(store.saveDigest(digest, for: thread.id), .saved)
        }
        return thread.id
    }

    // MARK: - session_search

    func testAQuestionFindsTheConversationByItsNoteAlone() async throws {
        seedFaucet()
        store.endThread()
        let tool = SessionSearchTool(conversationStore: store)
        let output = try await tool.execute(args: ["query": "what did we decide about the tap"])
        XCTAssertTrue(output.contains("Found 1 matching conversation"), output)
        XCTAssertTrue(output.contains("Note ("), "the note comes back, dated")
        XCTAssertTrue(output.contains("Leaking kitchen tap: plumber on Thursday"))
        XCTAssertTrue(output.contains("- Washer size is 15 mm"))
        XCTAssertTrue(output.contains("<untrusted_tool_output tool=\"conversation_note\">"),
                      "a note goes back inside the same envelope as saved memory")
        XCTAssertFalse(output.contains("Summary:"), "the note stands in for the word-prefix summary")
    }

    func testTheActiveThreadIsStillSkipped() async throws {
        seedFaucet()   // still the active thread
        let tool = SessionSearchTool(conversationStore: store)
        let output = try await tool.execute(args: ["query": "tap"])
        XCTAssertTrue(output.hasPrefix("No past conversations found"), output)
    }

    func testAThreadWithNoNoteFallsBackToItsSummary() async throws {
        seedFaucet(note: false)
        store.endThread()
        let tool = SessionSearchTool(conversationStore: store)
        let output = try await tool.execute(args: ["query": "faucet"])
        XCTAssertTrue(output.contains("Summary:"), output)
        XCTAssertFalse(output.contains("conversation_note"))
        let byNoteWords = try await tool.execute(args: ["query": "decide tap"])
        XCTAssertTrue(byNoteWords.hasPrefix("No past conversations found"), byNoteWords)
    }

    func testAForgottenNoteIsNoLongerSearched() async throws {
        let id = seedFaucet()
        store.endThread()
        XCTAssertTrue(store.forgetDigest(threadId: id))
        let output = try await SessionSearchTool(conversationStore: store)
            .execute(args: ["query": "decide tap"])
        XCTAssertTrue(output.hasPrefix("No past conversations found"), output)
    }

    // MARK: - The recall index

    private func readyCoordinator() async -> ConversationRecallCoordinator {
        let coordinator = ConversationRecallCoordinator()
        coordinator.start(threads: store.threads, isLocked: false, legacyDirectory: directory)
        await waitUntil { if case .ready = coordinator.state { return true }; return false }
        store.recallCoordinator = coordinator
        return coordinator
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<2000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held")
    }

    /// The note rows a phrase finds; the turns it also finds are not what these tests are about.
    private func hits(_ coordinator: ConversationRecallCoordinator, _ phrase: String) -> [RecallHit] {
        if case .ready(let hits, _) = coordinator.search(phrase) {
            return hits.filter { $0.role == ConversationDigest.recallRole }
        }
        return []
    }

    func testTheIndexCarriesOneRowPerNoteAndDropsItWithTheThread() async {
        let id = seedFaucet()
        store.endThread()
        let coordinator = await readyCoordinator()
        let rebuilt = hits(coordinator, "washer size")
        XCTAssertEqual(rebuilt.map(\.threadID), [id],
                       "a rebuild indexes the note, named by its thread")

        // A note written while the index is live replaces its row.
        let other = seedFaucet(note: false)
        store.endThread()
        let last = store.threads.first { $0.id == other }!.messages.last!.id
        _ = store.saveDigest(ConversationDigest(headline: "Garden shed roof felt", points: [],
                                                coversThroughMessageID: last, writtenAt: Date(), tier: .cloud),
                             for: other)
        await waitUntil { !self.hits(coordinator, "shed roof").isEmpty }
        XCTAssertEqual(hits(coordinator, "shed roof").map(\.threadID), [other])

        store.deleteThread(id)
        await waitUntil { self.hits(coordinator, "washer size").isEmpty }
        XCTAssertTrue(hits(coordinator, "washer size").isEmpty, "a deleted thread's note row is gone")
    }

    func testAForgottenNoteLeavesTheIndex() async {
        let id = seedFaucet()
        store.endThread()
        let coordinator = await readyCoordinator()
        XCTAssertFalse(hits(coordinator, "washer size").isEmpty)
        store.forgetDigest(threadId: id)
        await waitUntil { self.hits(coordinator, "washer size").isEmpty }
        XCTAssertTrue(hits(coordinator, "washer size").isEmpty)
    }

    // MARK: - Chat list, watch and Siri

    func testTheWatchPayloadCarriesTheHeadline() {
        seedFaucet()
        seedFaucet(note: false)
        store.endThread()
        let payload = WatchConnectivityManager.recentThreadsPayload(store.threads)
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload.last?["summary"], "Leaking kitchen tap: plumber on Thursday")
        XCTAssertNotEqual(payload.first?["summary"], "Leaking kitchen tap: plumber on Thursday",
                          "a thread with no note keeps its own summary")
        XCTAssertFalse(payload.flatMap(\.values).contains { $0.contains("Washer size") },
                       "the points never leave for the watch")
    }

    func testSiriIndexesTheHeadlineNotThePoints() {
        let id = seedFaucet()
        let thread = store.threads.first { $0.id == id }!
        let records = SiriContentAdapters.conversations([
            ConversationSummaryInput(id: thread.id, title: thread.title, summary: thread.listSummary,
                                     updatedAt: thread.updatedAt)])
        XCTAssertEqual(records.first?.text, "Leaking kitchen tap: plumber on Thursday")
    }
}
