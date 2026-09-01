import Foundation

/// A single message in a conversation thread.
struct ConversationMessage: Codable, Identifiable, Sendable {
    let id: String
    let role: String          // "user", "assistant", "system"
    let content: String
    let imageAttached: Bool
    let timestamp: Date

    init(role: String, content: String, imageAttached: Bool = false) {
        self.id = UUID().uuidString
        self.role = role
        self.content = content
        self.imageAttached = imageAttached
        self.timestamp = Date()
    }
}

/// An assistant reply currently being streamed into a specific thread. Render-only — the
/// persisted `ConversationMessage` is still appended on completion. `threadId` keys the live
/// bubble to its thread so a reply never renders in the wrong conversation.
struct StreamingTurn: Equatable {
    let threadId: String
    var text: String
}

/// A conversation thread with metadata.
struct ConversationThread: Codable, Identifiable, Sendable {
    let id: String
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

    private let maxThreads = 200
    private let storageURL: URL
    private let encryption = ConversationEncryptionService.shared

    /// Lock-scoped disposable projection for cross-session recall. Set by `AppState`; nil keeps
    /// conversation persistence working with recall unavailable.
    weak var recallCoordinator: ConversationRecallCoordinator?

    var storageDirectory: URL { storageURL.deletingLastPathComponent() }

    /// Key for persisting the active thread ID across restarts.
    private static let activeThreadKey = "conversationStore_activeThreadId"

    /// True after a read failure on an existing conversations file (e.g. file protection while
    /// locked): the on-disk data may be intact, so saves are suppressed until a load succeeds.
    private var saveBlocked = false

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
        let thread = ConversationThread(mode: mode, personaId: personaId)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
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

    /// Append a message to the active thread.
    func appendMessage(role: String, content: String, imageAttached: Bool = false) {
        guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }) else { return }
        let msg = ConversationMessage(role: role, content: content, imageAttached: imageAttached)
        threads[idx].messages.append(msg)
        threads[idx].updatedAt = Date()
        if let turn = indexedTurn(msg, threadID: threads[idx].id) {
            saveAndProject(.messageUpsert(turn))
        } else {
            save()
        }
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
        save()
        activeThreadId = nil
        persistActiveSession()
        PrivacyLog.conversation(.conversations, .threadEnded)
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
        PrivacyLog.conversation(.conversations, .threadResumed,
                                thread: PrivateIdentifier(threadId),
                                count: thread.messages.count)
        return thread
    }

    /// Get messages for replay — returns (role, content) pairs for rebuilding LLM context.
    /// If a compressed summary exists from a prior session, it's prepended as context.
    func replayMessages(for threadId: String) -> [(role: String, content: String)] {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        var result: [(role: String, content: String)] = []
        if let summary = thread.compressedSummary, !summary.isEmpty {
            result.append((role: "user", content: "[Prior conversation context]\n\(summary)"))
        }
        result.append(contentsOf: thread.messages.map { (role: $0.role, content: $0.content) })
        return result
    }

    /// Store an LLM-generated summary for a thread (called when context window is compressed).
    func updateCompressedSummary(_ summary: String, for threadId: String) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[idx].compressedSummary = summary
        save()
        PrivacyLog.conversation(.conversations, .summaryUpdated,
                                thread: PrivateIdentifier(threadId), characters: summary.count)
    }

    /// Delete a thread.
    func deleteThread(_ threadId: String) {
        guard threads.contains(where: { $0.id == threadId }) else { return }
        threads.removeAll { $0.id == threadId }
        if activeThreadId == threadId { activeThreadId = nil }
        saveAndProject(.threadDelete(id: threadId))
    }

    /// Remove the message with `messageId` and every message after it in the thread. Used by the
    /// Chat tab's edit/regenerate, which truncate the thread back to a point and resend from there.
    func truncate(from messageId: String, in threadId: String) {
        guard let tIdx = threads.firstIndex(where: { $0.id == threadId }),
              let mIdx = threads[tIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }
        let removedIDs = threads[tIdx].messages[mIdx...].map(\.id)
        threads[tIdx].messages.removeSubrange(mIdx...)
        threads[tIdx].updatedAt = Date()
        saveAndProject(.messageDelete(ids: removedIDs))
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
                try plaintext.write(to: storageURL, options: [.atomic, .completeFileProtection])
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
            threads = try JSONDecoder().decode([ConversationThread].self, from: data)
            saveBlocked = false
            isLocked = false
            recallCoordinator?.storeDidUnlock(threads: threads)
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
    func protectedDataDidBecomeAvailable() {
        guard !isLocked else { return }
        recallCoordinator?.storeDidUnlock(threads: threads)
    }

    // MARK: - Persistence

    @discardableResult
    private func save(onPersisted: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        // While locked, `threads` is deliberately empty (or a lone session started pre-unlock) —
        // writing now would encrypt that over the user's full history. Same for the async
        // encrypted-load window, which also runs with `isLocked == true`.
        guard !isLocked else {
            PrivacyLog.conversation(.conversations, .saveSkipped,
                                    detail: PrivacyToken("locked"))
            return false
        }
        // After a failed read of an existing file, the on-disk data may be intact — never write.
        guard !saveBlocked else {
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
                pendingSaveTask = Task { @MainActor [previous = pendingSaveTask] in
                    await previous?.value
                    do {
                        let encrypted = try await enc.encrypt(data)
                        var output = Data("OGENC1".utf8)
                        output.append(encrypted)
                        try output.write(to: url, options: [.atomic, .completeFileProtection])
                        onPersisted?()
                    } catch {
                        // The existing ciphertext on disk is untouched — `encrypt` throws before
                        // the write, and a failed unlock no longer rotates the key out from under
                        // it. This save is simply dropped; the next one retries.
                        PrivacyLog.conversation(.conversations, .saveSkipped,
                                                detail: PrivacyToken("encryptFailed"),
                                                error: SafeErrorSummary(error))
                    }
                }
                return true
            } else {
                // Conversation history can hold sensitive content — encrypt at rest even when
                // the optional biometric encryption layer is off.
                try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
                onPersisted?()
                return true
            }
        } catch {
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
                    let decoded = try JSONDecoder().decode([ConversationThread].self, from: data)
                    self?.threads = decoded
                    self?.saveBlocked = false
                    self?.isLocked = false
                    self?.recallCoordinator?.storeDidUnlock(threads: decoded)
                    PrivacyLog.conversation(.conversations, .loaded, count: decoded.count,
                                            detail: PrivacyToken("encrypted"))
                } catch {
                    self?.isLocked = true
                    PrivacyLog.conversation(.conversations, .awaitingAuthentication)
                }
            }
            return
        }

        switch JSONStore.loadArray(ConversationThread.self, at: storageURL, name: "conversations") {
        case .loaded(let decoded):
            threads = decoded
            saveBlocked = false
            PrivacyLog.conversation(.conversations, .loaded, count: decoded.count,
                                    detail: PrivacyToken("plaintext"))
        case .recovered(let decoded, _):
            threads = decoded
            saveBlocked = false
            PrivacyLog.conversation(.conversations, .recovered, count: decoded.count)
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
