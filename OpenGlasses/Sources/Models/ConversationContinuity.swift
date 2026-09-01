import Foundation

/// Continuing, switching and deleting conversations — the half of the conversation page that is
/// not a transcript.
///
/// The rules live here rather than in the page because two of them have teeth. Resuming a thread
/// is *two* steps, not one: the store learns which thread the next turn appends to, and the model
/// is handed that thread's history — do only the first and the wearer gets a conversation that
/// silently forgot everything in it. And deletion is real, so it is only reachable through a
/// `confirmed` flag: there is no path from this type to a removed thread that did not pass a
/// modal.
///
/// Everything here takes the store it acts on, so it is provable against a real
/// `ConversationStore` pointed at a temp directory, with no `AppState` and no live services.
@MainActor
enum ConversationContinuity {

    // MARK: - Reading

    /// Threads for the switcher: newest first, as the Chat tab sorts them, so the two surfaces
    /// can never disagree about what "most recent" means.
    static func recentThreads(in store: ConversationStore, limit: Int? = nil) -> [ConversationThread] {
        let sorted = store.threads.sorted { $0.updatedAt > $1.updatedAt }
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    /// The active thread, if there is one.
    static func activeThread(in store: ConversationStore) -> ConversationThread? {
        guard let id = store.activeThreadId else { return nil }
        return store.threads.first { $0.id == id }
    }

    /// What the page's header says. Not "Conversation": a header that never changes is a header
    /// nobody reads, and the whole point is to know which conversation the next thing said will
    /// join. With no active thread it says so plainly rather than naming the transcript still on
    /// screen — that conversation has ended, and pretending otherwise is the confusion this
    /// header exists to remove.
    static func headerTitle(for store: ConversationStore) -> String {
        activeThread(in: store)?.title ?? "New conversation"
    }

    /// The thread a "carry on" offer would resume: the most recent one, and only while nothing is
    /// active.
    ///
    /// This is the reported defect made reachable. A voice session ends its thread when it
    /// returns to the wake word (`AppState.returnToWakeWord` → `ConversationStore.endThread`), so
    /// the moment a reply finished, the conversation on screen was one the next turn would *not*
    /// join — it would silently open a new thread with none of the context. Nothing on the page
    /// said so and nothing could undo it. One tap does.
    static func resumableThread(in store: ConversationStore) -> ConversationThread? {
        guard store.activeThreadId == nil, !store.isLocked else { return nil }
        return recentThreads(in: store, limit: 1).first
    }

    // MARK: - Continuity

    /// Make `threadId` the thread the next turn appends to, with its full prior context loaded.
    ///
    /// `loadHistory` is the model's side of it — `LLMService.loadConversationHistory` in the app,
    /// a recorder in tests. Passed in rather than reached for, so the two-step contract is the
    /// thing being tested rather than an implementation detail of whoever calls it.
    @discardableResult
    static func resume(_ threadId: String, in store: ConversationStore,
                       loadHistory: ([(role: String, content: String)]) -> Void) -> Bool {
        guard store.threads.contains(where: { $0.id == threadId }) else { return false }
        guard store.activeThreadId != threadId else { return true }
        _ = store.resumeThread(threadId)
        loadHistory(store.replayMessages(for: threadId))
        return true
    }

    /// End the current conversation cleanly so the next turn starts a fresh one.
    ///
    /// It does not create a thread. The turn seam already opens one when there is no active
    /// thread, and creating an empty thread here would litter the switcher with conversations
    /// nobody had.
    static func startFresh(in store: ConversationStore, clearHistory: () -> Void) {
        if store.activeThreadId != nil { store.endThread() }
        clearHistory()
    }

    // MARK: - Deletion

    /// What is about to be deleted. Carried as a value so the modal's copy and the write agree on
    /// the scope — including the count, which is the only thing that makes "delete all" honest.
    enum DeletionScope: Equatable {
        case one(id: String, title: String)
        case all(count: Int)

        var confirmTitle: String {
            switch self {
            case .one: return "Delete this conversation?"
            case .all(let count): return "Delete all \(count) conversation\(count == 1 ? "" : "s")?"
            }
        }

        /// The copy has one job beyond naming the scope: say that this is deletion and not the
        /// view-level clearing My Day does, and say where the boundary is. A wearer who has used
        /// "Clear" on the day's cards has been taught the opposite contract.
        var confirmMessage: String {
            switch self {
            case .one(_, let title):
                return "\"\(title)\" is deleted for good, here and in Chat — including its "
                     + "encrypted copy. This isn't a hide. Your memories and brain are untouched."
            case .all(let count):
                return "All \(count) conversation\(count == 1 ? "" : "s") — every message in "
                     + "them — are deleted for good, here and in Chat, including their encrypted "
                     + "copies. This isn't a hide and it cannot be undone. Your memories and "
                     + "brain are untouched."
            }
        }

        var confirmButton: String {
            switch self {
            case .one: return "Delete"
            case .all: return "Delete All"
            }
        }
    }

    static func deletionScope(forThread thread: ConversationThread) -> DeletionScope {
        .one(id: thread.id, title: thread.title)
    }

    static func deleteAllScope(in store: ConversationStore) -> DeletionScope {
        .all(count: store.threads.count)
    }

    /// Perform a deletion the wearer confirmed.
    ///
    /// `confirmed` is a parameter rather than a promise the caller keeps, and the unconfirmed call
    /// is a no-op returning 0 — so "no unconfirmed deletion path" is a property of this seam
    /// rather than of every screen that reaches it.
    /// - Returns: how many threads were removed.
    @discardableResult
    static func delete(_ scope: DeletionScope, confirmed: Bool,
                       in store: ConversationStore) -> Int {
        guard confirmed else { return 0 }
        switch scope {
        case .one(let id, _):
            guard store.threads.contains(where: { $0.id == id }) else { return 0 }
            store.deleteThread(id)
            return 1
        case .all:
            return store.deleteAllThreads()
        }
    }

    // MARK: - VoiceOver

    /// A switcher row, spoken: the title, when it was last touched, and whether it is the one the
    /// next thing said will join.
    static func spokenLabel(for thread: ConversationThread, activeThreadId: String?,
                            relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: thread.updatedAt, relativeTo: now)
        let active = thread.id == activeThreadId ? ", current conversation" : ""
        return "\(thread.title), \(when)\(active)"
    }
}
