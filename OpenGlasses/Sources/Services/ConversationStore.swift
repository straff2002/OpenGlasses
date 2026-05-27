import Foundation

/// A single message in a conversation thread.
struct ConversationMessage: Codable, Identifiable {
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

/// A conversation thread with metadata.
struct ConversationThread: Codable, Identifiable {
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

    init(mode: String, title: String = "New Conversation") {
        self.id = UUID().uuidString
        self.title = title
        self.summary = nil
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.mode = mode
        self.compressedSummary = nil
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

    /// Key for persisting the active thread ID across restarts.
    private static let activeThreadKey = "conversationStore_activeThreadId"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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
        NSLog("[ConversationStore] Restored active session %@ (%d messages, %.0f min old)",
              savedId, thread.messages.count,
              Date().timeIntervalSince(thread.updatedAt) / 60)
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
    func startThread(mode: String) -> ConversationThread {
        let thread = ConversationThread(mode: mode)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        trimOldThreads()
        save()
        persistActiveSession()
        NSLog("[ConversationStore] Started thread %@", thread.id)
        return thread
    }

    /// Append a message to the active thread.
    func appendMessage(role: String, content: String, imageAttached: Bool = false) {
        guard let idx = threads.firstIndex(where: { $0.id == activeThreadId }) else { return }
        let msg = ConversationMessage(role: role, content: content, imageAttached: imageAttached)
        threads[idx].messages.append(msg)
        threads[idx].updatedAt = Date()
        save()
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
        NSLog("[ConversationStore] Ended thread")
    }

    /// Resume an existing thread (e.g. after app relaunch).
    func resumeThread(_ threadId: String) -> ConversationThread? {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return nil }
        activeThreadId = threadId
        NSLog("[ConversationStore] Resumed thread %@ (%d messages)", threadId, thread.messages.count)
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
        NSLog("[ConversationStore] Updated compressed summary for thread %@ (%d chars)", threadId, summary.count)
    }

    /// Delete a thread.
    func deleteThread(_ threadId: String) {
        threads.removeAll { $0.id == threadId }
        if activeThreadId == threadId { activeThreadId = nil }
        save()
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
            NSLog("[ConversationStore] Encryption enabled")
            return true
        } catch {
            NSLog("[ConversationStore] Failed to enable encryption: %@", error.localizedDescription)
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
                try plaintext.write(to: storageURL, options: .atomic)
            }
            await encryption.deleteKey()
            Config.setConversationEncryptionEnabled(false)
            isLocked = false
            NSLog("[ConversationStore] Encryption disabled")
            return true
        } catch {
            NSLog("[ConversationStore] Failed to disable encryption: %@", error.localizedDescription)
            return false
        }
    }

    /// Unlock encrypted conversations via biometric auth.
    func unlock() async -> Bool {
        guard isLocked else { return true }
        do {
            let authed = try await encryption.authenticate(reason: "Unlock your conversations")
            guard authed else { return false }
            loadThreads()
            isLocked = false
            return true
        } catch {
            NSLog("[ConversationStore] Unlock failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Lock conversations — clears in-memory data.
    func lock() {
        guard encryption.isEnabled else { return }
        threads = []
        activeThreadId = nil
        isLocked = true
        NSLog("[ConversationStore] Locked")
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(threads)

            if encryption.isEnabled {
                // Encrypt async on background, write result
                let url = storageURL
                let enc = encryption
                Task {
                    do {
                        let encrypted = try await enc.encrypt(data)
                        var output = Data("OGENC1".utf8)
                        output.append(encrypted)
                        try output.write(to: url, options: .atomic)
                    } catch {
                        NSLog("[ConversationStore] Encrypted save failed: %@", error.localizedDescription)
                    }
                }
            } else {
                try data.write(to: storageURL, options: .atomic)
            }
        } catch {
            NSLog("[ConversationStore] Save failed: %@", error.localizedDescription)
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
                    self?.isLocked = false
                    NSLog("[ConversationStore] Loaded %d encrypted threads", decoded.count)
                } catch {
                    self?.isLocked = true
                    NSLog("[ConversationStore] Conversations locked — awaiting authentication")
                }
            }
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            threads = try JSONDecoder().decode([ConversationThread].self, from: data)
            NSLog("[ConversationStore] Loaded %d threads", threads.count)
        } catch {
            NSLog("[ConversationStore] Load failed: %@", error.localizedDescription)
        }
    }

    private func trimOldThreads() {
        if threads.count > maxThreads {
            threads = Array(threads.prefix(maxThreads))
        }
    }
}
