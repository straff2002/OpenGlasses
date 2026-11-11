import Foundation

/// A single message in a conversation thread.
struct ConversationMessage: Codable, Identifiable, Sendable {
    let id: String
    let role: String          // "user", "assistant", "system"
    let content: String
    let imageAttached: Bool
    let timestamp: Date
    /// Plan GE: this reply was given on the phone while the connection was down — by the smaller
    /// on-device model, the deterministic router, or the hold line. Optional so threads saved before
    /// the field existed decode unchanged, and nil (not false) is what an ordinary reply stores, so
    /// the saved file only grows for the turns that carry it.
    let answeredOnDevice: Bool?
    /// The tools that produced this reply, so Insights can report what the assistant actually
    /// used rather than reading every turn as tool-free. Optional so threads saved before the
    /// field existed decode unchanged, and nil (not an empty list) is what a tool-free reply
    /// stores, so the saved file only grows for the turns that carry it.
    let toolNames: [String]?
    /// Plan KZ: the web pages this reply rests on — cited by the AI provider's own search or
    /// listed by Avenkin's — shown as **Sources (n)**. Optional so threads saved before the field
    /// existed decode unchanged, and nil for a reply without sources.
    let webSources: [WebSource]?
    /// Plan KZ: Google's Search Suggestions for a grounded Gemini reply, kept with it so they are
    /// shown under it in the thread however long after it landed. Nil for every other reply.
    let searchSuggestions: SearchSuggestions?

    /// Plan LA: this reply ended with the done tone rather than being spoken. Optional and nil for
    /// every ordinary reply, so threads saved before it existed decode unchanged and the file only
    /// grows for the turns that carry it.
    var endedQuietly: Bool?

    init(role: String, content: String, imageAttached: Bool = false, answeredOnDevice: Bool = false,
         toolNames: [String] = [], webSources: [WebSource] = [],
         searchSuggestions: SearchSuggestions? = nil, endedQuietly: Bool = false) {
        self.id = UUID().uuidString
        self.role = role
        self.content = content
        self.imageAttached = imageAttached
        self.timestamp = Date()
        self.answeredOnDevice = answeredOnDevice ? true : nil
        self.toolNames = toolNames.isEmpty ? nil : toolNames
        self.webSources = webSources.isEmpty ? nil : webSources
        self.searchSuggestions = searchSuggestions
        self.endedQuietly = endedQuietly ? true : nil
    }

    /// The reply's sources; empty when it has none.
    var sources: [WebSource] { webSources ?? [] }

    /// Whether this reply ended with the done tone (Plan LA).
    var isEndedQuietly: Bool { endedQuietly ?? false }

    /// Whether this reply was given on the phone while offline.
    var isAnsweredOnDevice: Bool { answeredOnDevice ?? false }
}

/// An assistant reply currently being streamed into a specific thread. Render-only — the
/// persisted `ConversationMessage` is still appended on completion. `threadId` keys the live
/// bubble to its thread so a reply never renders in the wrong conversation.
struct StreamingTurn: Equatable {
    let threadId: String
    /// What the live bubble shows.
    var text: String
    /// Everything the stream has delivered this iteration, `text` with any follow-ups tail.
    private(set) var received = ""

    init(threadId: String, text: String) {
        self.threadId = threadId
        self.text = text
        self.received = text
    }

    /// Plan KP P2: add a streamed chunk. The bubble shows the reply up to its follow-ups tail
    /// (`FollowUpTail.streamingVisible`), never the tail itself, not even a "<ne" of it.
    mutating func append(_ chunk: String) {
        received += chunk
        text = String(FollowUpTail.streamingVisible(received).visible)
    }

    /// A new tool-loop iteration: the bubble starts again.
    mutating func restart() {
        received = ""
        text = ""
    }
}

/// A conversation thread with metadata.
struct ConversationThread: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String?      // Auto-generated mini summary of what was discussed
    var messages: [ConversationMessage]
    let createdAt: Date
    var updatedAt: Date
    var mode: String          // AppMode rawValue
    /// LLM-generated summary of compressed messages. Prepended on session resume
    /// so the AI retains context from earlier in the conversation.
    var compressedSummary: String?
    /// Project (Persona) this thread belongs to, or `nil` for legacy/global threads
    /// (Plan AN). Optional so older persisted threads decode unchanged.
    var personaId: String?
    /// Stable manual identities chosen for this chat. Nil decodes legacy conversations unchanged.
    var manualIDs: [String]?
    /// The title the app last gave this thread as a job's (Plan KE), so a later correction moves the
    /// app's own title and leaves one the technician chose: they differ, whatever either says. Nil
    /// on every other thread and on a thread saved before this existed.
    var jobTitle: String?
    /// Plan KK: dated notes about the saved messages a request no longer carries word for word,
    /// oldest first. Derived from `messages`, never a record of them, and kept here so encryption,
    /// the save guards, retention and `deleteThread` all cover it. Nil on a thread saved before it
    /// existed, which decodes unchanged.
    var timeline: [TimelineEntry]?

    init(mode: String, title: String = "New Conversation", personaId: String? = nil) {
        self.id = UUID().uuidString
        self.title = title
        self.summary = nil
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.mode = mode
        self.compressedSummary = nil
        self.personaId = personaId
    }
}

/// Persists conversation threads to disk as JSON.
/// Supports saving, loading, resuming, and auto-titling via LLM.
/// When encryption is enabled, data is encrypted with ChaCha20-Poly1305
/// and the key is stored in Keychain behind Face ID / Touch ID.
///
/// Usage:
///   - Call `startThread(mode:)` at session start
///   - Call `appendMessage(role:content:)` after each user/assistant turn
///   - Call `endThread()` when the session ends (triggers auto-title)
///   - Call `replayMessages(for:)` to rebuild context on session resume
@MainActor
class ConversationStore: ObservableObject {
    @Published var threads: [ConversationThread] = []
    @Published var activeThreadId: String?
    @Published var isLocked: Bool = false

    /// When the active thread was last touched — a message, a start, or a resume (opening it is
    /// choosing to carry on with it). Feeds the idle-gap rule in `JobThreadPolicy`; nil whenever
    /// no thread is active.
    ///
    /// In memory, and deliberately not `updatedAt` alone: bumping that on a resume would reorder
    /// the history list just because a thread was looked at. Keyed by thread so a stale stamp can
    /// never be read against a different thread; with no stamp for the active one (a launch
    /// restore, say) the thread's own `updatedAt` is the answer.
    var activeThreadLastActivityAt: Date? {
        guard let id = activeThreadId else { return nil }
        if let lastActivity, lastActivity.threadId == id { return lastActivity.at }
        return threads.first { $0.id == id }?.updatedAt
    }
    private var lastActivity: (threadId: String, at: Date)?

    private let maxThreads = 200
    private let storageURL: URL
    private let encryption = ConversationEncryptionService.shared

    /// Lock-scoped disposable projection for cross-session recall. Set by `AppState`; nil keeps
    /// conversation persistence working with recall unavailable.
    weak var recallCoordinator: ConversationRecallCoordinator?

    /// Called with the id of the thread that has just stopped being the active one — whether it
    /// ended, or a new thread replaced it. One seam rather than a `distill` call scattered across
    /// the six places a thread changes; `AppState` wires it to the brain's distillation pass.
    var onThreadLeft: (@MainActor (String) -> Void)?

    var storageDirectory: URL { storageURL.deletingLastPathComponent() }

    /// Key for persisting the active thread ID across restarts.
    private static let activeThreadKey = "conversationStore_activeThreadId"

    /// True after a read failure on an existing conversations file (e.g. file protection while
    /// locked): the on-disk data may be intact, so saves are suppressed until a load succeeds.
    /// `private(set)` rather than `private` so the unlock retry can be asserted in tests.
    private(set) var saveBlocked = false

    /// True when the in-memory history holds changes the file does not: the last save failed (a
    /// glasses turn on a locked phone, for one) or was skipped. Cleared by the next save that
    /// lands, since every save writes the whole list. `flushPendingSave()` retries it when
    /// protected data comes back and when the app comes to the front, so a turn taken in a pocket
    /// is on disk before anything else can end the process. `private(set)` so tests can assert it.
    private(set) var needsSave = false

    /// The iOS protection class `conversations.json` is written with and re-stamped to.
    ///
    /// First-unlock, not `.complete`: the app declares the `audio` background mode and a glasses
    /// turn runs with the phone locked in a pocket, so a `.complete` file refused every one of
    /// those saves with Cocoa 513. The optional biometric encryption layer is the stronger guard
    /// for wearers who want one; it is unaffected by this class.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// The `Data.write` options that carry `fileProtection`. One place, so the write and the
    /// re-stamp in `protect(_:)` cannot drift apart.
    nonisolated static let writeOptions: Data.WritingOptions = [
        .atomic, .completeFileProtectionUntilFirstUserAuthentication,
    ]

    /// How a snapshot reaches disk. A seam so a test can make a write fail the way a locked phone
    /// does; production never replaces it.
    var writeData: @Sendable (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
        try data.write(to: url, options: options)
    }

    /// Serializes encrypted saves so an older snapshot can never finish after — and overwrite —
    /// a newer one.
    private var pendingSaveTask: Task<Void, Never>?

    /// `directory` is injectable so tests can point at a temp folder instead of the app's documents.
    init(directory: URL? = nil) {
        let docs = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("conversations.json")
        loadThreads()
        restoreActiveSession()
        // W03.3: a history that already exists on a device is excluded from backup by being
        // opened, not only by being written to again.
        Self.protect(storageURL)
    }

    /// Re-apply the at-rest posture after a write.
    ///
    /// `.atomic` replaces the file rather than rewriting it, and backup exclusion is a property of
    /// the file and not of the path — so without this every save would quietly put the wearer's
    /// conversation history back into iCloud. The class is `fileProtection` (first-unlock): this
    /// file is written from glasses turns that run while the phone is locked, which `.complete`
    /// refuses. Re-stamping also moves a file an older build left at `.complete` onto the new
    /// class — which can only happen while protected data is available, so `init` and
    /// `protectedDataDidBecomeAvailable()` both call it.
    private static func protect(_ url: URL) {
        StoreProtection.apply(fileProtection, backupExcluded: true, to: url)
    }

    // MARK: - Session Persistence

    /// Restore the last active session on app launch (if it was recent enough).
    private func restoreActiveSession() {
        guard let savedId = UserDefaults.standard.string(forKey: Self.activeThreadKey),
              let thread = threads.first(where: { $0.id == savedId }) else { return }

        // Only restore if the thread is less than 2 hours old
        let maxAge: TimeInterval = 2 * 60 * 60
        guard Date().timeIntervalSince(thread.updatedAt) < maxAge else {
            UserDefaults.standard.removeObject(forKey: Self.activeThreadKey)
            return
        }

        activeThreadId = savedId
        PrivacyLog.conversation(.conversations, .sessionRestored,
                                thread: PrivateIdentifier(savedId),
                                count: thread.messages.count,
                                minutes: Int(Date().timeIntervalSince(thread.updatedAt) / 60))
    }

    /// Persist the active thread ID for session restoration.
    private func persistActiveSession() {
        if let id = activeThreadId {
            UserDefaults.standard.set(id, forKey: Self.activeThreadKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeThreadKey)
        }
    }

    // MARK: - Thread Lifecycle

    /// Start a new conversation thread.
    @discardableResult
    func startThread(mode: String, personaId: String? = nil) -> ConversationThread {
        let replaced = activeThreadId
        let thread = ConversationThread(mode: mode, personaId: personaId)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        lastActivity = (thread.id, thread.createdAt)
        if trimOldThreads() {
            saveAndProject(.storeReplaced)
        } else {
            save()
        }
        persistActiveSession()
        // The persona id is omitted rather than fingerprinted: the set is small and the wearer
        // named them, so a hash would still say which assistant they were talking to.
        PrivacyLog.conversation(.conversations, .threadStarted,
                                thread: PrivateIdentifier(thread.id),
                                detail: PrivacyToken(personaId == nil ? "global" : "persona"))
        if let replaced, replaced != thread.id { onThreadLeft?(replaced) }
        return thread
    }

    /// Threads belonging to a given project (Persona), newest-first (Plan AN).
    /// Pass `nil` to get every thread (the "All" view). A non-nil id matches only
    /// threads explicitly tagged with it — legacy/global threads (`personaId == nil`)
    /// are excluded from a specific project's list.
    func threads(forPersona personaId: String?) -> [ConversationThread] {
        guard let personaId else { return threads }
        return threads.filter { $0.personaId == personaId }
    }

    /// The most recent completed exchange in the active thread — the last assistant
    /// reply and the user prompt that preceded it (Plan AW user-correction signal).
    /// `nil` when there's no assistant turn yet.
    func lastExchange() -> (prompt: String, response: String)? {
        guard let thread = threads.first(where: { $0.id == activeThreadId }) else { return nil }
        let msgs = thread.messages
        guard let assistantIdx = msgs.lastIndex(where: { $0.role == "assistant" }) else { return nil }
        let prompt = msgs[..<assistantIdx].last(where: { $0.role == "user" })?.content ?? ""
        return (prompt, msgs[assistantIdx].content)
    }

    /// Append a message to the active thread — or, with `threadId`, to that thread whichever one
    /// is active now.
    ///
    /// The second form is how a reply follows its question: a turn captures the thread its
    /// question went into and files the answer there, so nothing that moves the active thread
    /// while the model is thinking (a push-to-talk release, New conversation, a switch) can send
    /// the answer to another conversation or drop it on the floor.
    /// - Returns: the saved message's id, or nil when there was no thread to add it to. The
    ///   timeline pass names the turn it answered by this id (Plan KK P2).
    @discardableResult
    func appendMessage(role: String, content: String, imageAttached: Bool = false,
                       answeredOnDevice: Bool = false, toolNames: [String] = [],
                       webSources: [WebSource] = [],
                       searchSuggestions: SearchSuggestions? = nil,
                       endedQuietly: Bool = false,
                       toThread threadId: String? = nil) -> String? {
        let target = threadId ?? activeThreadId
        guard let idx = threads.firstIndex(where: { $0.id == target }) else { return nil }
        let msg = ConversationMessage(role: role, content: content, imageAttached: imageAttached,
                                      answeredOnDevice: answeredOnDevice, toolNames: toolNames,
                                      webSources: webSources,
                                      searchSuggestions: searchSuggestions,
                                      endedQuietly: endedQuietly)
        threads[idx].messages.append(msg)
        threads[idx].updatedAt = msg.timestamp
        if threads[idx].id == activeThreadId { lastActivity = (threads[idx].id, msg.timestamp) }
        if let turn = indexedTurn(msg, threadID: threads[idx].id) {
            saveAndProject(.messageUpsert(turn))
        } else {
            save()
        }
        return msg.id
    }

    // MARK: - Recall index (Memory & Recall Phase 2)

    /// Map a persisted user/assistant message to a projection event. System/blank messages save
    /// normally but never enter the recall projection.
    private func indexedTurn(_ msg: ConversationMessage, threadID: String) -> IndexedTurn? {
        let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (msg.role == "user" || msg.role == "assistant"), !trimmed.isEmpty else { return nil }
        return IndexedTurn(id: msg.id, threadID: threadID, role: msg.role,
                           text: msg.content, timestamp: msg.timestamp)
    }

    /// End the active thread and auto-generate a title and summary.
    func endThread() {
        guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }) else { return }
        // Generate a title from first user message
        if threads[idx].title == "New Conversation" {
            if let firstUser = threads[idx].messages.first(where: { $0.role == "user" }) {
                threads[idx].title = Self.generateTitle(from: firstUser.content)
            }
        }
        // Generate a mini summary from the conversation content
        if threads[idx].summary == nil {
            threads[idx].summary = Self.generateSummary(from: threads[idx].messages)
        }
        threads[idx].updatedAt = Date()
        let ended = threads[idx].id
        save()
        activeThreadId = nil
        persistActiveSession()
        PrivacyLog.conversation(.conversations, .threadEnded)
        onThreadLeft?(ended)
    }

    /// Rename a thread whose title is still machine-generated.
    ///
    /// A Field Assist job owns its conversation, and "Job 1005 — SLP99UH" is what a technician
    /// looks it up by a week later; the first sentence of the job ("start a job on the default
    /// vault") is not. But a title the *wearer* chose is theirs, so this replaces only the
    /// placeholder, the auto-title this store would have generated itself, and whatever
    /// `isOwnTitle` recognises as its own earlier work.
    ///
    /// Once the thread records the title the app wrote (`ConversationThread.jobTitle`) that record
    /// decides, not the caller: a corrected job number leaves a title that no longer looks like the
    /// job's own, and a rename can look exactly like one (Plan KE).
    ///
    /// - Parameter isOwnTitle: given the current title, whether the caller wrote it. Read only for a
    ///   thread saved before the record existed.
    func applyJobTitle(_ title: String, to threadId: String, isOwnTitle: (String) -> Bool) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let existing = threads[idx].title
        guard existing != title else {
            // Written before the record existed, or by the technician in the app's own words:
            // either way it is the job's title now, so a correction may move it.
            if threads[idx].jobTitle != title {
                threads[idx].jobTitle = title
                save()
            }
            return
        }
        let isOwn = threads[idx].jobTitle.map { $0 == existing } ?? isOwnTitle(existing)
        guard existing == "New Conversation" || isOwn || isAutoTitle(existing, in: threads[idx])
        else { return }
        threads[idx].title = title
        threads[idx].jobTitle = title
        save()
    }

    /// Whether `title` is what this store's own auto-titling would have produced for the thread —
    /// i.e. nobody has renamed it.
    private func isAutoTitle(_ title: String, in thread: ConversationThread) -> Bool {
        guard let firstUser = thread.messages.first(where: { $0.role == "user" }) else { return false }
        return title == Self.generateTitle(from: firstUser.content)
    }

    /// Give a still-default thread a title derived from its first user message. Safe to call
    /// repeatedly — it only acts while the title is the placeholder. Used by the live Chat tab,
    /// which never calls `endThread()` (the thread stays open as the user keeps chatting).
    func applyAutoTitleIfNeeded(_ threadId: String) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }),
              threads[idx].title == "New Conversation",
              let firstUser = threads[idx].messages.first(where: { $0.role == "user" }) else { return }
        threads[idx].title = Self.generateTitle(from: firstUser.content)
        save()
    }

    /// Selection follows the conversation through switching, encryption, relaunch and deletion.
    @discardableResult
    func setManualIDs(_ ids: [String], for threadID: String) -> Bool {
        guard !isLocked, !saveBlocked, let index = threads.firstIndex(where: { $0.id == threadID }) else { return false }
        let unique = Array(Set(ids)).sorted()
        threads[index].manualIDs = unique.isEmpty ? nil : unique
        threads[index].updatedAt = Date()
        if activeThreadId == threadID { noteActiveThreadActivity() }
        save()
        return true
    }

    // MARK: - Recency (one-shot entry points like Siri)

    /// True when `last` is within `window` seconds of `now`. Pure — unit-testable
    /// (nonisolated so it's callable off the main actor, e.g. from tests).
    nonisolated static func isWithinRecencyWindow(_ last: Date, now: Date, window: TimeInterval) -> Bool {
        now.timeIntervalSince(last) <= window
    }

    /// For one-shot entry points (e.g. the Siri ask intents): keep the active
    /// thread if its last turn was recent, otherwise start a fresh one so that
    /// unrelated asks minutes apart don't pile into a single thread.
    func continueRecentOrStartThread(mode: String, within window: TimeInterval, now: Date = Date()) {
        if let id = activeThreadId,
           let thread = threads.first(where: { $0.id == id }),
           Self.isWithinRecencyWindow(thread.updatedAt, now: now, window: window) {
            return  // reuse the recent active thread (conversational follow-up)
        }
        startThread(mode: mode)
    }

    /// Resume an existing thread (e.g. after app relaunch).
    func resumeThread(_ threadId: String) -> ConversationThread? {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return nil }
        activeThreadId = threadId
        noteActiveThreadActivity()
        PrivacyLog.conversation(.conversations, .threadResumed,
                                thread: PrivateIdentifier(threadId),
                                count: thread.messages.count)
        return thread
    }

    /// Count this moment as activity on the active thread — the wearer chose it (a resume, or
    /// re-opening the one already active), so the idle-gap rule measures from here.
    func noteActiveThreadActivity(at now: Date = Date()) {
        guard let id = activeThreadId else { return }
        lastActivity = (id, now)
    }

    /// Get messages for replay — returns (role, content) pairs for rebuilding LLM context.
    /// If a compressed summary exists from a prior session, it's prepended as context — but only
    /// on a thread with no timeline (Plan KK P3). The legacy summary was written about the same
    /// messages the replay hands over in full; once the timeline has notes, it is what stands in
    /// for whatever the request budget leaves out, and the summary would describe the same span a
    /// second time. It still decodes, and `truncate` and erasure still clear it.
    func replayMessages(for threadId: String) -> [(role: String, content: String)] {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        var result: [(role: String, content: String)] = []
        if (thread.timeline ?? []).isEmpty, let summary = thread.compressedSummary, !summary.isEmpty {
            result.append((role: "user", content: "[Prior conversation context]\n\(summary)"))
        }
        result.append(contentsOf: thread.messages.map { (role: $0.role, content: $0.content) })
        return result
    }

    /// Delete a thread.
    func deleteThread(_ threadId: String) {
        guard threads.contains(where: { $0.id == threadId }) else { return }
        threads.removeAll { $0.id == threadId }
        if activeThreadId == threadId {
            activeThreadId = nil
            persistActiveSession()
        }
        saveAndProject(.threadDelete(id: threadId))
        PrivacyLog.conversation(.conversations, .threadsDeleted,
                                thread: PrivateIdentifier(threadId), count: 1)
    }

    /// W03.3 — delete every thread last touched before `cutoff`. Returns how many went.
    ///
    /// Real deletion through the same `save()` the rest of the store uses, and the recall index is
    /// told about each one, so a purge cannot leave the derived projection holding turns whose
    /// thread is gone. Driven by the wearer's history retention setting, which is off unless they
    /// turned it on — this method does not decide, it carries out a decision.
    @discardableResult
    func deleteThreads(olderThan cutoff: Date) -> Int {
        let doomed = threads.filter { $0.updatedAt < cutoff && $0.id != activeThreadId }
        guard !doomed.isEmpty else { return 0 }
        for thread in doomed { deleteThread(thread.id) }
        return doomed.count
    }

    /// Delete every thread.
    ///
    /// Real deletion, like `deleteThread`: the threads leave memory, the file is rewritten from
    /// the now-empty list through the same `save()` that owns encryption, and the recall
    /// projection is rebuilt from nothing. It touches this store only — the brain, user memory
    /// and every other index have their own controls, and the confirm copy says so.
    /// - Returns: how many threads were removed.
    @discardableResult
    func deleteAllThreads() -> Int {
        let removed = threads.count
        guard removed > 0 else { return 0 }
        threads.removeAll()
        activeThreadId = nil
        persistActiveSession()
        saveAndProject(.storeReplaced)
        PrivacyLog.conversation(.conversations, .threadsDeleted, count: removed)
        return removed
    }

    /// Remove the message with `messageId` and every message after it in the thread. Used by the
    /// Chat tab's edit/regenerate, which truncate the thread back to a point and resend from there.
    ///
    /// What was derived from the removed messages goes with them (Plan KK): every timeline entry
    /// whose span reaches a removed message, and the legacy `compressedSummary`, whose span was
    /// never recorded and so may summarise exactly the words the wearer just took back.
    func truncate(from messageId: String, in threadId: String) {
        guard let tIdx = threads.firstIndex(where: { $0.id == threadId }),
              let mIdx = threads[tIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }
        let messageIDs = threads[tIdx].messages.map(\.id)
        let removedIDs = Array(messageIDs[mIdx...])
        threads[tIdx].messages.removeSubrange(mIdx...)
        if let timeline = threads[tIdx].timeline {
            let kept = TimelineInvalidation.afterRemoving(Set(removedIDs), from: messageIDs,
                                                          entries: timeline)
            threads[tIdx].timeline = kept.isEmpty ? nil : kept
        }
        threads[tIdx].compressedSummary = nil
        threads[tIdx].updatedAt = Date()
        saveAndProject(.messageDelete(ids: removedIDs))
    }

    /// Empty every timeline entry, in every thread, that names `token` as a whole word, and drop
    /// every legacy `compressedSummary` that does — the derived text a person erasure must not
    /// leave re-sending their name (Plan KK). The messages themselves are left; see
    /// `SubjectErasureCoordinator`.
    ///
    /// An entry is emptied rather than removed (P2): it keeps its span, so the summary pass counts
    /// that range as covered and never writes the name back from the thread text the erasure
    /// left. Nothing keeps the name. An edit or regenerate that removes part of the span drops the
    /// emptied entry like any other, and that range can then be summarised again.
    ///
    /// - Returns: how many entries and summaries were cleared, or nil when the store cannot be
    ///   searched honestly: locked (the threads in memory are not the history) or after a failed
    ///   read (the file may hold threads memory does not, and they would win a later merge).
    @discardableResult
    func dropTimelineEntries(naming token: String) -> Int? {
        guard !isLocked, !saveBlocked else { return nil }
        var removed = 0
        for index in threads.indices {
            if let timeline = threads[index].timeline {
                let result = TimelineInvalidation.redactingMentions(of: token, in: timeline)
                if result.redacted > 0 {
                    removed += result.redacted
                    threads[index].timeline = result.entries
                }
            }
            if let summary = threads[index].compressedSummary,
               TimelineInvalidation.mentions(summary, token) {
                threads[index].compressedSummary = nil
                removed += 1
            }
        }
        guard removed > 0 else { return 0 }
        save()
        PrivacyLog.conversation(.conversations, .timelineRedacted, count: removed)
        return removed
    }

    // MARK: - Timeline writes (Plan KK P2)

    /// Why the summary pass's write was refused. A closed set, safe to log.
    enum TimelineSaveOutcome: String, Equatable, Sendable {
        case saved
        /// Locked, or after a failed read: memory is not the history, so nothing is written.
        case storeUnavailable
        /// The thread was deleted or erased while the summary was being written.
        case threadGone
        /// The span's first or last message is gone, or the two are out of order: an edit or a
        /// regenerate took part of what was summarised.
        case spanChanged
        /// Another entry already covers part of the span.
        case alreadyCovered
        /// A merge's source entries are not all there, or one was redacted meanwhile.
        case sourcesChanged
    }

    /// Whether the timeline may be read and written now: unlocked, and not after a failed read.
    var isTimelineWritable: Bool { !isLocked && !saveBlocked }

    /// Add a chunk entry the summary pass wrote, re-checking everything that may have changed
    /// while the model was answering: the store is open, the thread is still there, both ends of
    /// the span still exist in order, and nothing already covers any of it. Entries are kept in
    /// span order. `updatedAt` is not touched: a note is not activity, and bumping it would move
    /// the thread in the history list.
    func saveTimelineChunk(_ entry: TimelineEntry, in threadId: String) -> TimelineSaveOutcome {
        guard isTimelineWritable else { return .storeUnavailable }
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return .threadGone }
        let ids = TimelineMessage.reduce(threads[index].messages).map(\.id)
        let positions = TimelineEntry.positions(of: ids)
        guard let span = entry.span(in: positions) else { return .spanChanged }
        var timeline = threads[index].timeline ?? []
        let overlaps = timeline.contains { existing in
            existing.span(in: positions).map { $0.overlaps(span) } ?? false
        }
        guard !overlaps else { return .alreadyCovered }
        timeline.append(entry)
        threads[index].timeline = Self.ordered(timeline, positions: positions)
        save()
        return .saved
    }

    /// Replace a merge's source entries with the merged one, if they are all still there,
    /// unchanged and unredacted, and the merged span still resolves.
    func applyTimelineMerge(_ plan: TimelineMergePlanner.Plan, merged: TimelineEntry,
                            in threadId: String, sources: [TimelineEntry]) -> TimelineSaveOutcome {
        guard isTimelineWritable else { return .storeUnavailable }
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return .threadGone }
        let timeline = threads[index].timeline ?? []
        let current = plan.sourceIDs.compactMap { id in timeline.first { $0.id == id } }
        guard current == sources, current.count == plan.sourceIDs.count,
              !current.contains(where: \.isRedacted) else { return .sourcesChanged }
        let ids = TimelineMessage.reduce(threads[index].messages).map(\.id)
        let positions = TimelineEntry.positions(of: ids)
        guard merged.span(in: positions) != nil else { return .spanChanged }
        threads[index].timeline = Self.ordered(plan.applying(merged, to: timeline), positions: positions)
        save()
        return .saved
    }

    /// Entries in the order of their spans; one whose span no longer resolves keeps its place at
    /// the end, where `truncate` or coverage deals with it.
    private static func ordered(_ entries: [TimelineEntry], positions: [String: Int]) -> [TimelineEntry] {
        entries.enumerated().sorted { lhs, rhs in
            let left = lhs.element.span(in: positions)?.lowerBound ?? Int.max
            let right = rhs.element.span(in: positions)?.lowerBound ?? Int.max
            return (left, lhs.offset) < (right, rhs.offset)
        }.map(\.element)
    }

    /// Most recent thread for a given mode.
    func mostRecentThread(for mode: String) -> ConversationThread? {
        return threads.first { $0.mode == mode && !$0.messages.isEmpty }
    }

    // MARK: - Title & Summary Generation

    /// Generate a short title from the first user message (local, no LLM needed).
    private static func generateTitle(from text: String) -> String {
        let words = text.split(separator: " ").prefix(6)
        var title = words.joined(separator: " ")
        if text.split(separator: " ").count > 6 {
            title += "…"
        }
        // Capitalize first letter
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        return title
    }

    /// Generate a mini summary from the conversation messages.
    /// Extracts the key user topics and what the assistant helped with.
    /// Purely local — no LLM call needed.
    static func generateSummary(from messages: [ConversationMessage]) -> String? {
        guard messages.count >= 2 else { return nil }

        // Collect distinct user intents (first few words of each user message, deduped)
        var topics: [String] = []
        var seenPrefixes = Set<String>()
        for msg in messages where msg.role == "user" {
            let cleaned = msg.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !cleaned.isEmpty else { continue }

            // Use first 6 words as a topic fingerprint
            let words = cleaned.split(separator: " ")
            let prefix = words.prefix(4).joined(separator: " ").lowercased()
            guard !seenPrefixes.contains(prefix) else { continue }
            seenPrefixes.insert(prefix)

            // Build a short topic phrase (up to 8 words)
            let topicWords = words.prefix(8)
            var topic = topicWords.joined(separator: " ")
            if words.count > 8 { topic += "…" }
            topics.append(topic)
        }

        guard !topics.isEmpty else { return nil }

        // Check for special content indicators
        let hasImages = messages.contains { $0.imageAttached }
        let hasToolUse = messages.contains { $0.role == "assistant" && $0.content.contains("tool_use") }
        let turnCount = messages.filter { $0.role == "user" }.count

        // Build a natural summary
        var parts: [String] = []

        // Main topics (up to 3)
        let topicList = topics.prefix(3)
        if topicList.count == 1 {
            parts.append(topicList[0])
        } else {
            parts.append(topicList.joined(separator: " · "))
        }

        // Metadata indicators
        var indicators: [String] = []
        if turnCount > 1 { indicators.append("\(turnCount) exchanges") }
        if hasImages { indicators.append("photos") }
        if hasToolUse { indicators.append("tools used") }

        if !indicators.isEmpty {
            parts.append(indicators.joined(separator: ", "))
        }

        let summary = parts.joined(separator: " — ")
        // Cap at a reasonable length
        if summary.count > 150 {
            return String(summary.prefix(147)) + "…"
        }
        return summary
    }

    // MARK: - Encryption Controls

    /// Enable encryption: authenticate, then encrypt existing conversations.
    func enableEncryption() async -> Bool {
        do {
            let authed = try await encryption.authenticate(reason: "Enable conversation encryption")
            guard authed else { return false }

            // Encrypt existing plaintext file
            if FileManager.default.fileExists(atPath: storageURL.path),
               !encryption.isFileEncrypted(at: storageURL) {
                try await encryption.encryptFile(at: storageURL)
            }
            Config.setConversationEncryptionEnabled(true)
            isLocked = false
            PrivacyLog.conversation(.conversations, .encryptionEnabled)
            return true
        } catch {
            PrivacyLog.conversation(.conversations, .encryptionFailed,
                                    detail: PrivacyToken("enable"), error: SafeErrorSummary(error))
            return false
        }
    }

    /// Disable encryption: authenticate, decrypt file, remove key.
    func disableEncryption() async -> Bool {
        do {
            let authed = try await encryption.authenticate(reason: "Disable conversation encryption")
            guard authed else { return false }

            // Decrypt file back to plaintext
            if FileManager.default.fileExists(atPath: storageURL.path),
               encryption.isFileEncrypted(at: storageURL) {
                let plaintext = try await encryption.decryptFile(at: storageURL)
                try writeData(plaintext, storageURL, Self.writeOptions)
                Self.protect(storageURL)
            }
            await encryption.deleteKey()
            Config.setConversationEncryptionEnabled(false)
            isLocked = false
            PrivacyLog.conversation(.conversations, .encryptionDisabled)
            return true
        } catch {
            PrivacyLog.conversation(.conversations, .encryptionFailed,
                                    detail: PrivacyToken("disable"), error: SafeErrorSummary(error))
            return false
        }
    }

    /// Unlock encrypted conversations via biometric auth.
    func unlock() async -> Bool {
        guard isLocked else { return true }
        do {
            let authed = try await encryption.authenticate(reason: "Unlock your conversations")
            guard authed else { return false }
            let data = try await encryption.decryptFile(at: storageURL)
            // The same repair every other load path makes: the chat list is a `List` keyed by id.
            let (decoded, repairedDuplicateIDs) = Self.repairingDuplicateThreadIDs(
                try JSONDecoder().decode([ConversationThread].self, from: data))
            threads = decoded
            saveBlocked = false
            // What was just read *is* the file; nothing in memory is newer than it — unless the
            // repair renamed a duplicate, which must be written back so the ids stay stable.
            needsSave = false
            isLocked = false
            recallCoordinator?.storeDidUnlock(threads: threads)
            if repairedDuplicateIDs { save() }
            return true
        } catch {
            PrivacyLog.conversation(.conversations, .unlockFailed,
                                    error: SafeErrorSummary(error))
            return false
        }
    }

    /// Lock conversations — clears in-memory data.
    func lock() {
        guard encryption.isEnabled else { return }
        recallCoordinator?.storeDidLock()
        threads = []
        activeThreadId = nil
        isLocked = true
        PrivacyLog.conversation(.conversations, .locked)
    }

    /// iOS can revoke access to complete-file-protected data independently of the app's optional
    /// biometric conversation lock. Destroy recall immediately even when encryption is disabled.
    func protectedDataWillBecomeUnavailable() {
        recallCoordinator?.storeDidLock()
    }

    /// Rebuild only from the still-authoritative in-memory snapshot. A biometrically locked store
    /// remains closed until its normal unlock flow supplies decrypted threads.
    ///
    /// One exception: if the launch-time read failed *because* the device was locked, the
    /// in-memory snapshot is not authoritative — it is empty, and saves have been refused ever
    /// since. Now that protected data is readable, re-run the load before rebuilding recall.
    ///
    /// It is also the moment to finish what the lock interrupted: re-stamp the file's protection
    /// class (an older build's `.complete` file cannot be re-stamped while locked) and write any
    /// history whose save failed while the phone was in a pocket.
    func protectedDataDidBecomeAvailable() {
        Self.protect(storageURL)
        guard !isLocked else { return }
        if saveBlocked, retryBlockedLoad() { return }
        flushPendingSave()
        recallCoordinator?.storeDidUnlock(threads: threads)
    }

    /// Write the history if a save failed or was skipped since the last one that landed.
    ///
    /// Called when protected data becomes available and when the app comes to the front. A no-op
    /// when nothing is pending, and `save()` keeps its own guards: a biometrically locked store or
    /// one whose launch read failed still refuses, and stays dirty for the next attempt.
    func flushPendingSave() {
        guard needsSave else { return }
        save()
    }

    /// Re-read a conversations file whose launch-time load failed under file protection.
    ///
    /// Field trace: the app launched before first unlock, `Data(contentsOf:)` returned Cocoa 257
    /// on the (then `.complete`-protected) file, `saveBlocked` latched, and **every** turn for the
    /// rest of the process was dropped with `saveSkipped detail=loadFailed` — the store only ever
    /// loaded from `init`, so nothing could clear the latch.
    ///
    /// - Returns: `true` when a retry succeeded, or when an asynchronous decrypt was started. The
    ///   caller must not fall through to `storeDidUnlock` on either: the plaintext branch has
    ///   already published the merged list, and the decrypt branch will publish its own once it
    ///   resolves — publishing here would hand recall the stale empty snapshot.
    @discardableResult
    private func retryBlockedLoad() -> Bool {
        // An encrypted file must never reach the plaintext reader. `isFileEncrypted(at:)` answers
        // `false` for a file it cannot *read*, so a locked-device launch with encryption on
        // latched `saveBlocked` down the plaintext branch of `loadThreads()` exactly like an
        // unencrypted store. Handing those `OGENC1` bytes to `JSONStore.loadArray` decodes as
        // `.corrupt`, which moves the user's whole history aside and starts empty — turning a
        // save outage into data loss for precisely the wearers who asked for more protection.
        if encryption.isEnabled, encryption.isFileEncrypted(at: storageURL) {
            retryBlockedDecrypt()
            return true
        }

        let decoded: [ConversationThread]
        switch JSONStore.loadArray(ConversationThread.self, at: storageURL, name: "conversations") {
        case .loaded(let loaded):
            decoded = loaded
        case .recovered(let loaded, _):
            decoded = loaded
        case .corrupt:
            // The original is preserved by StoreRecovery; the file is readable, so the latch has
            // done its job and can come off.
            decoded = []
        case .absent:
            decoded = []
        case .unreadable:
            // Still protected (or genuinely unreadable). Stay blocked rather than overwrite.
            return false
        }

        adoptReloadedThreads(decoded, detail: "retried")
        return true
    }

    /// The encrypted half of `retryBlockedLoad()`: decrypt off the main actor, then merge through
    /// the same path the plaintext branch uses.
    ///
    /// Mirrors `loadThreads()`'s encrypted branch, including holding `isLocked` for the window —
    /// `save()` refuses to write while locked, which is what keeps a half-finished decrypt from
    /// putting an empty history over the ciphertext. A failure leaves the store locked and the
    /// latch on, and reports `.awaitingAuthentication`: the file is intact and simply needs the
    /// normal unlock flow.
    private func retryBlockedDecrypt() {
        isLocked = true
        let url = storageURL
        let enc = encryption
        Task { @MainActor [weak self] in
            do {
                let data = try await enc.decryptFile(at: url)
                let decoded = try JSONDecoder().decode([ConversationThread].self, from: data)
                guard let self else { return }
                self.isLocked = false
                self.adoptReloadedThreads(decoded, detail: "retriedEncrypted")
            } catch {
                self?.isLocked = true
                PrivacyLog.conversation(.conversations, .awaitingAuthentication)
            }
        }
    }

    /// Merge a freshly re-read on-disk list into the in-memory one and reopen the store for writes.
    ///
    /// The merge is not a replace. Threads created while saves were blocked exist only in memory
    /// and have never been written, so discarding them would turn a save outage into data loss;
    /// on-disk threads win on id collision because they are the ones the store has been unable to
    /// touch. The merged list is re-sorted newest-first, which is the ordering
    /// `startThread`'s `insert(at: 0)` maintains everywhere else.
    private func adoptReloadedThreads(_ decoded: [ConversationThread], detail: String) {
        let (decoded, _) = Self.repairingDuplicateThreadIDs(decoded)
        let onDiskIds = Set(decoded.map(\.id))
        let unsaved = threads.filter { !onDiskIds.contains($0.id) }
        threads = (decoded + unsaved).sorted { $0.updatedAt > $1.updatedAt }
        trimOldThreads()
        saveBlocked = false
        PrivacyLog.conversation(.conversations, .loaded, count: threads.count,
                                detail: PrivacyToken(detail))
        recallCoordinator?.storeDidUnlock(threads: threads)
        save()
    }

    // MARK: - Persistence

    @discardableResult
    private func save(onPersisted: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        // While locked, `threads` is deliberately empty (or a lone session started pre-unlock) —
        // writing now would encrypt that over the user's full history. Same for the async
        // encrypted-load window, which also runs with `isLocked == true`.
        guard !isLocked else {
            needsSave = true
            PrivacyLog.conversation(.conversations, .saveSkipped,
                                    detail: PrivacyToken("locked"))
            return false
        }
        // After a failed read of an existing file, the on-disk data may be intact — never write.
        guard !saveBlocked else {
            needsSave = true
            PrivacyLog.conversation(.conversations, .saveSkipped,
                                    detail: PrivacyToken("loadFailed"))
            return false
        }
        do {
            let data = try JSONEncoder().encode(threads)

            if encryption.isEnabled {
                // Encrypt async on background, write result. Chained on the previous save so
                // writes land in submission order.
                let url = storageURL
                let enc = encryption
                let write = writeData
                // Because of that ordering, the save that finishes last decides `needsSave`: a
                // later success covers an earlier failure, and a later failure leaves it dirty.
                pendingSaveTask = Task { @MainActor [weak self, previous = pendingSaveTask] in
                    await previous?.value
                    do {
                        let encrypted = try await enc.encrypt(data)
                        var output = Data("OGENC1".utf8)
                        output.append(encrypted)
                        try write(output, url, Self.writeOptions)
                        Self.protect(url)
                        self?.needsSave = false
                        onPersisted?()
                    } catch {
                        // The existing ciphertext on disk is untouched — `encrypt` throws before
                        // the write, and a failed unlock no longer rotates the key out from under
                        // it. This save is dropped and the store marked dirty, so the unlock or
                        // the next foreground retries it rather than waiting for another turn.
                        self?.needsSave = true
                        PrivacyLog.conversation(.conversations, .saveSkipped,
                                                detail: PrivacyToken("encryptFailed"),
                                                error: SafeErrorSummary(error))
                    }
                }
                return true
            } else {
                // Conversation history can hold sensitive content — encrypt at rest even when
                // the optional biometric encryption layer is off.
                try writeData(data, storageURL, Self.writeOptions)
                Self.protect(storageURL)
                needsSave = false
                onPersisted?()
                return true
            }
        } catch {
            // The threads are still in memory; mark them so the next chance to write — protected
            // data returning, the app coming forward — persists them without waiting for a turn.
            needsSave = true
            PrivacyLog.conversation(.conversations, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    private func loadThreads() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        // If encrypted, attempt async decryption
        if encryption.isEnabled, encryption.isFileEncrypted(at: storageURL) {
            isLocked = true
            let url = storageURL
            let enc = encryption
            Task { @MainActor [weak self] in
                do {
                    let data = try await enc.decryptFile(at: url)
                    let (decoded, repairedDuplicateIDs) = Self.repairingDuplicateThreadIDs(
                        try JSONDecoder().decode([ConversationThread].self, from: data)
                    )
                    self?.threads = decoded
                    self?.saveBlocked = false
                    self?.isLocked = false
                    self?.recallCoordinator?.storeDidUnlock(threads: decoded)
                    PrivacyLog.conversation(.conversations, .loaded, count: decoded.count,
                                            detail: PrivacyToken("encrypted"))
                    if repairedDuplicateIDs { self?.save() }
                } catch {
                    self?.isLocked = true
                    PrivacyLog.conversation(.conversations, .awaitingAuthentication)
                }
            }
            return
        }

        switch JSONStore.loadArray(ConversationThread.self, at: storageURL, name: "conversations") {
        case .loaded(let decoded):
            let (loaded, repairedDuplicateIDs) = Self.repairingDuplicateThreadIDs(decoded)
            threads = loaded
            saveBlocked = false
            PrivacyLog.conversation(.conversations, .loaded, count: threads.count,
                                    detail: PrivacyToken("plaintext"))
            if repairedDuplicateIDs { save() }
        case .recovered(let decoded, _):
            let (loaded, repairedDuplicateIDs) = Self.repairingDuplicateThreadIDs(decoded)
            threads = loaded
            saveBlocked = false
            PrivacyLog.conversation(.conversations, .recovered, count: threads.count)
            if repairedDuplicateIDs { save() }
        case .corrupt:
            // Original preserved in StoreRecovery — start fresh rather than crash-loop.
            threads = []
            saveBlocked = false
        case .unreadable:
            saveBlocked = true
        case .absent:
            break
        }
    }

    /// A `ForEach`/`List` requires every row identity to be unique. Repair duplicate persisted ids
    /// before observers can render them. Every record is retained: the first keeps its id and each
    /// later collision receives a fresh one. Callers persist a repaired result so those identities
    /// remain stable across launches.
    static func repairingDuplicateThreadIDs(
        _ threads: [ConversationThread]
    ) -> (threads: [ConversationThread], repaired: Bool) {
        var seen = Set<String>()
        var repaired = false
        let result = threads.map { thread in
            guard !seen.insert(thread.id).inserted else { return thread }
            var copy = thread
            repeat { copy.id = UUID().uuidString } while !seen.insert(copy.id).inserted
            repaired = true
            return copy
        }
        return (result, repaired)
    }

    @discardableResult
    private func trimOldThreads() -> Bool {
        if threads.count > maxThreads {
            threads = Array(threads.prefix(maxThreads))
            return true
        }
        return false
    }

    private func saveAndProject(_ event: ConversationRecallProjectionEvent) {
        let persistedSnapshot = threads
        guard let coordinator = recallCoordinator else {
            save()
            return
        }
        save { [weak coordinator] in
            coordinator?.apply(event, persistedSnapshot: persistedSnapshot)
        }
    }
}
