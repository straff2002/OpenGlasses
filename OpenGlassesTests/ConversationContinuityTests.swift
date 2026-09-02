import XCTest
@testable import OpenGlasses

/// Plan EB P3 — the conversation page's other half: which thread a turn joins, starting a fresh
/// one, and deletion that is real and confirmed.
///
/// Against a real `ConversationStore` pointed at a temp directory: the thing worth proving is what
/// the *store* does after each act, since that is what the turn seam, the switcher and the Chat
/// tab all read. No `AppState`, no `.shared` services.
@MainActor
final class ConversationContinuityTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eb-conversations-\(UUID().uuidString)")
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

    /// Two threads with a turn each. Returns them oldest-first.
    @discardableResult
    private func seedTwoThreads() -> (older: String, newer: String) {
        let older = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "About the roof")
        store.appendMessage(role: "assistant", content: "The roof needs flashing.")
        let newer = store.startThread(mode: "direct")
        store.appendMessage(role: "user", content: "About the fence")
        store.appendMessage(role: "assistant", content: "The fence is fine.")
        return (older.id, newer.id)
    }

    // MARK: Switching

    /// The one that matters: after a switch, the *next* turn appends to the chosen thread.
    func testSwitchingChangesTheThreadTheNextTurnAppendsTo() {
        let (older, newer) = seedTwoThreads()
        XCTAssertEqual(store.activeThreadId, newer)

        var loaded: [(role: String, content: String)] = []
        XCTAssertTrue(ConversationContinuity.resume(older, in: store) { loaded = $0 })
        XCTAssertEqual(store.activeThreadId, older)

        store.appendMessage(role: "user", content: "and the gutters?")
        XCTAssertEqual(store.threads.first { $0.id == older }?.messages.last?.content,
                       "and the gutters?")
        XCTAssertEqual(store.threads.first { $0.id == newer }?.messages.count, 2,
                       "The turn landed in the thread the wearer switched away from")
    }

    /// Resuming is two steps. Making it active without handing the model the history is a
    /// conversation that silently forgot itself — so the history goes with it.
    func testResumingHandsTheModelTheSameHistoryTheChatTabWould() {
        let (older, _) = seedTwoThreads()
        var loaded: [(role: String, content: String)] = []
        ConversationContinuity.resume(older, in: store) { loaded = $0 }

        let expected = store.replayMessages(for: older)
        XCTAssertEqual(loaded.count, expected.count)
        XCTAssertEqual(loaded.map(\.content), expected.map(\.content))
        XCTAssertEqual(loaded.map(\.content), ["About the roof", "The roof needs flashing."])
    }

    func testResumingAThreadThatIsGoneDoesNothing() {
        let (_, newer) = seedTwoThreads()
        var loadedCount = 0
        XCTAssertFalse(ConversationContinuity.resume("nope", in: store) { _ in loadedCount += 1 })
        XCTAssertEqual(loadedCount, 0)
        XCTAssertEqual(store.activeThreadId, newer)
    }

    func testResumingTheAlreadyActiveThreadIsANoOp() {
        let (_, newer) = seedTwoThreads()
        var loadedCount = 0
        XCTAssertTrue(ConversationContinuity.resume(newer, in: store) { _ in loadedCount += 1 })
        XCTAssertEqual(loadedCount, 0)
        XCTAssertEqual(store.activeThreadId, newer)
    }

    // MARK: New conversation

    /// The defect this page had: after a reply the voice session ends its thread, so the next
    /// turn silently opened a *new* one and there was no way to say which conversation you were
    /// in. Ending explicitly leaves no active thread — and the next turn's fresh thread is a new
    /// id, not the one just ended.
    func testNewConversationEndsTheCurrentThreadAndTheNextTurnStartsAFreshOne() {
        let (_, newer) = seedTwoThreads()
        var cleared = 0
        ConversationContinuity.startFresh(in: store) { cleared += 1 }

        XCTAssertEqual(cleared, 1)
        XCTAssertNil(store.activeThreadId)
        XCTAssertEqual(store.threads.count, 2, "Ending a conversation must never delete it")

        // What the turn seam does when nothing is active.
        let fresh = store.startThread(mode: "direct")
        XCTAssertNotEqual(fresh.id, newer)
        XCTAssertEqual(store.activeThreadId, fresh.id)
        XCTAssertTrue(fresh.messages.isEmpty)
    }

    /// The reported defect, as a state: a finished voice turn ends its thread, so nothing is
    /// active and the conversation on screen is one the next turn would not join. The page offers
    /// it back, and taking the offer makes the next turn continue it with full context.
    func testAFinishedVoiceTurnLeavesTheConversationResumable() {
        let (_, newer) = seedTwoThreads()
        XCTAssertNil(ConversationContinuity.resumableThread(in: store),
                     "Nothing to carry on with while a thread is still active")

        // What `AppState.returnToWakeWord` does once the reply has been spoken.
        store.endThread()
        XCTAssertNil(store.activeThreadId)
        XCTAssertEqual(ConversationContinuity.resumableThread(in: store)?.id, newer)

        var loaded: [(role: String, content: String)] = []
        ConversationContinuity.resume(newer, in: store) { loaded = $0 }
        XCTAssertEqual(store.activeThreadId, newer)
        XCTAssertEqual(loaded.map(\.content), ["About the fence", "The fence is fine."])

        store.appendMessage(role: "user", content: "and the gate?")
        XCTAssertEqual(store.threads.first { $0.id == newer }?.messages.count, 3)
        XCTAssertNil(ConversationContinuity.resumableThread(in: store))
    }

    /// It does not manufacture an empty thread — a switcher full of conversations nobody had is
    /// its own bug.
    func testNewConversationWithNothingActiveCreatesNothing() {
        ConversationContinuity.startFresh(in: store) {}
        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertNil(store.activeThreadId)
    }

    func testTheHeaderNamesTheActiveThread() {
        XCTAssertEqual(ConversationContinuity.headerTitle(for: store), "New conversation")
        let (older, _) = seedTwoThreads()
        ConversationContinuity.resume(older, in: store) { _ in }
        store.endThread()   // auto-titles from the first user message
        ConversationContinuity.resume(older, in: store) { _ in }
        XCTAssertEqual(ConversationContinuity.headerTitle(for: store),
                       store.threads.first { $0.id == older }?.title)
    }

    // MARK: Deletion

    func testUnconfirmedDeletionIsANoOpAtTheStoreSeam() {
        let (older, _) = seedTwoThreads()
        let one = ConversationContinuity.DeletionScope.one(id: older, title: "About the roof")

        XCTAssertEqual(ConversationContinuity.delete(one, confirmed: false, in: store), 0)
        XCTAssertEqual(ConversationContinuity.delete(.all(count: 2), confirmed: false, in: store), 0)
        XCTAssertEqual(store.threads.count, 2, "A deletion ran without confirmation")
    }

    func testConfirmedDeletionRemovesOneThreadFromTheStoreAndTheSwitcher() {
        let (older, newer) = seedTwoThreads()
        let scope = ConversationContinuity.deletionScope(
            forThread: store.threads.first { $0.id == older }!)

        XCTAssertEqual(ConversationContinuity.delete(scope, confirmed: true, in: store), 1)
        XCTAssertEqual(store.threads.map(\.id), [newer])
        XCTAssertFalse(ConversationContinuity.recentThreads(in: store).contains { $0.id == older })
        XCTAssertEqual(store.activeThreadId, newer, "Deleting another thread ended the live one")
    }

    func testDeletingTheActiveThreadLeavesNoActiveThread() {
        let (_, newer) = seedTwoThreads()
        ConversationContinuity.delete(.one(id: newer, title: "About the fence"),
                                      confirmed: true, in: store)
        XCTAssertNil(store.activeThreadId)
    }

    func testDeleteAllEmptiesTheStore() {
        seedTwoThreads()
        let scope = ConversationContinuity.deleteAllScope(in: store)
        XCTAssertEqual(scope, .all(count: 2))
        XCTAssertEqual(ConversationContinuity.delete(scope, confirmed: true, in: store), 2)
        XCTAssertTrue(store.threads.isEmpty)
        XCTAssertNil(store.activeThreadId)
        XCTAssertTrue(ConversationContinuity.recentThreads(in: store).isEmpty)
    }

    /// Real deletion, not a view-level hide: the persisted file is rewritten, so a store built
    /// fresh from the same directory does not bring the threads back.
    func testDeletionReachesTheFileNotJustMemory() {
        let (older, newer) = seedTwoThreads()
        ConversationContinuity.delete(.one(id: older, title: "About the roof"),
                                      confirmed: true, in: store)

        let reopened = ConversationStore(directory: directory)
        XCTAssertEqual(reopened.threads.map(\.id), [newer])

        ConversationContinuity.delete(.all(count: 1), confirmed: true, in: store)
        XCTAssertTrue(ConversationStore(directory: directory).threads.isEmpty,
                      "Deleted conversations came back from disk")
    }

    /// The switcher and the Chat tab sort the same list the same way, so after every operation
    /// the two surfaces name the same conversations in the same order.
    func testThePagerAndTheChatTabAgreeAfterEveryOperation() {
        func chatTabOrder() -> [String] {
            store.threads.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        }
        func pagerOrder() -> [String] {
            ConversationContinuity.recentThreads(in: store).map(\.id)
        }

        let (older, _) = seedTwoThreads()
        XCTAssertEqual(pagerOrder(), chatTabOrder())

        ConversationContinuity.resume(older, in: store) { _ in }
        store.appendMessage(role: "user", content: "one more")
        XCTAssertEqual(pagerOrder(), chatTabOrder())
        XCTAssertEqual(pagerOrder().first, older, "The freshly-touched thread isn't first")

        ConversationContinuity.startFresh(in: store) {}
        XCTAssertEqual(pagerOrder(), chatTabOrder())

        ConversationContinuity.delete(.one(id: older, title: "About the roof"),
                                      confirmed: true, in: store)
        XCTAssertEqual(pagerOrder(), chatTabOrder())

        ConversationContinuity.delete(ConversationContinuity.deleteAllScope(in: store),
                                      confirmed: true, in: store)
        XCTAssertEqual(pagerOrder(), chatTabOrder())
        XCTAssertTrue(pagerOrder().isEmpty)
    }

    func testRecentThreadsAreNewestFirstAndCanBeCapped() {
        let (older, newer) = seedTwoThreads()
        XCTAssertEqual(ConversationContinuity.recentThreads(in: store).map(\.id), [newer, older])
        XCTAssertEqual(ConversationContinuity.recentThreads(in: store, limit: 1).map(\.id), [newer])
    }

    // MARK: What the page draws (EB device round 2)

    /// The defect, at the seam that caused it: resuming a thread changed the store and the model's
    /// context and nothing else, because the page could only ever draw the live turn. A resumed
    /// thread has to *be* what the page draws.
    func testAResumedThreadIsWhatThePageDraws() {
        let (older, _) = seedTwoThreads()
        ConversationContinuity.resume(older, in: store) { _ in }

        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: ""),
            .history(threadId: older),
            "A resumed conversation with messages in it still isn't what the page shows"
        )
    }

    /// The empty state is for a conversation with nothing in it — not for one the page merely
    /// cannot render.
    func testTheEmptyStateOnlyAppliesWhenNothingHasBeenSaid() {
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: ""),
            .empty)

        let fresh = store.startThread(mode: "direct")
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: ""),
            .empty,
            "A thread with no messages is genuinely empty")

        store.appendMessage(role: "user", content: "first thing")
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: ""),
            .history(threadId: fresh.id))
    }

    /// Before the first turn is persisted — and after a voice session has ended its thread — the
    /// live cards are the only thing there is to draw, and the page keeps drawing them.
    func testTheLiveTurnStillShowsWhenNoThreadHoldsIt() {
        XCTAssertEqual(
            ConversationContinuity.pageContent(
                activeThreadId: nil, activeThreadMessageCount: 0, isRealtimeSession: false,
                hasLiveUserText: true, hasLiveAssistantText: false),
            .liveTurn,
            "A turn with conversation history switched off has nowhere else to be shown")

        let (_, newer) = seedTwoThreads()
        store.endThread()
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: "The fence is fine."),
            .liveTurn,
            "The reply the wearer is still reading vanished when its thread ended")
        // And taking the carry-on offer puts the conversation itself back on the page.
        ConversationContinuity.resume(newer, in: store) { _ in }
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "", liveAssistantText: "The fence is fine."),
            .history(threadId: newer))
    }

    /// A realtime session's transcript belongs to the session and is never persisted, so the live
    /// cards stay the honest view there however many stored threads exist.
    func testARealtimeSessionKeepsTheLiveCards() {
        let (older, _) = seedTwoThreads()
        ConversationContinuity.resume(older, in: store) { _ in }

        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: true,
                                               liveUserText: "what is this",
                                               liveAssistantText: "A fuse box."),
            .liveTurn)
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: true,
                                               liveUserText: "", liveAssistantText: ""),
            .empty)
    }

    /// Whitespace is not something said.
    func testBlankLiveTextIsNotATurn() {
        XCTAssertEqual(
            ConversationContinuity.pageContent(store: store, isRealtimeSession: false,
                                               liveUserText: "  ", liveAssistantText: "\n"),
            .empty)
    }

    // MARK: Copy

    /// Delete-all states the count, and neither modal blurs deletion with the view-level clearing
    /// the day's cards offer — nor claims more scope than it has.
    func testConfirmCopyStatesScopeAndBoundary() {
        let all = ConversationContinuity.DeletionScope.all(count: 7)
        XCTAssertTrue(all.confirmTitle.contains("7"))
        XCTAssertTrue(all.confirmMessage.contains("7"))
        for scope in [all, .one(id: "x", title: "About the roof")] {
            let message = scope.confirmMessage.lowercased()
            XCTAssertTrue(message.contains("deleted for good"), "\(scope) doesn't say it is deletion")
            XCTAssertTrue(message.contains("encrypted"), "\(scope) doesn't mention the encrypted copy")
            XCTAssertTrue(message.contains("isn't a hide"), "\(scope) reads like My Day's clear")
            XCTAssertTrue(message.contains("brain are untouched"),
                          "\(scope) doesn't state the boundary")
        }
        XCTAssertTrue(ConversationContinuity.DeletionScope.all(count: 1).confirmTitle
            .contains("1 conversation?"))
    }

    func testSwitcherRowsSpeakTitleDateAndWhichIsCurrent() {
        let (_, newer) = seedTwoThreads()
        let thread = store.threads.first { $0.id == newer }!
        let spoken = ConversationContinuity.spokenLabel(for: thread, activeThreadId: newer)
        XCTAssertTrue(spoken.hasPrefix(thread.title))
        XCTAssertTrue(spoken.contains("current conversation"))
        XCTAssertFalse(ConversationContinuity.spokenLabel(for: thread, activeThreadId: "other")
            .contains("current conversation"))
    }
}
