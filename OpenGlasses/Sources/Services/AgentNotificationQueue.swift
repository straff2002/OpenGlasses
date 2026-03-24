import Foundation

/// Queues agent notifications when glasses are disconnected, delivers them
/// when glasses reconnect — after checking relevance of older items.
///
/// Flow:
/// 1. Agent task produces a result that needs user attention
/// 2. If glasses connected → speak immediately + listen for response
/// 3. If glasses disconnected → queue notification with timestamp + context
/// 4. On glasses reconnect → review queue, discard stale items, deliver relevant ones
@MainActor
class AgentNotificationQueue: ObservableObject {
    @Published var pendingCount: Int = 0

    struct QueuedNotification: Codable, Identifiable {
        let id: String
        let message: String
        let source: String       // Which task/trigger produced this
        let createdAt: Date
        let priority: Priority
        var delivered: Bool = false

        enum Priority: String, Codable {
            case low       // Can be discarded if stale (weather, routine check-ins)
            case medium    // Deliver if <2 hours old (calendar reminders, email summaries)
            case high      // Always deliver (urgent alerts, security, user-requested)
        }

        /// Whether this notification is still relevant based on age.
        var isStale: Bool {
            let age = Date().timeIntervalSince(createdAt)
            switch priority {
            case .low: return age > 1800      // 30 minutes
            case .medium: return age > 7200   // 2 hours
            case .high: return false          // Never stale
            }
        }
    }

    private var queue: [QueuedNotification] = []
    private let storageURL: URL

    weak var appState: AppState?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("agent_notification_queue.json")
        load()
    }

    // MARK: - Queue Management

    /// Add a notification to the queue. If glasses are connected, deliver immediately.
    func enqueue(message: String, source: String, priority: QueuedNotification.Priority = .medium) {
        guard let appState else { return }

        if appState.isConnected && !appState.isProcessing && !appState.isListening {
            // Glasses connected and idle — deliver immediately
            Task {
                await deliverImmediately(message: message, waitForResponse: priority != .low)
            }
        } else {
            // Queue for later
            let notification = QueuedNotification(
                id: UUID().uuidString,
                message: message,
                source: source,
                createdAt: Date(),
                priority: priority
            )
            queue.append(notification)
            pendingCount = queue.filter { !$0.delivered }.count
            save()
            NSLog("[AgentQueue] Queued: %@ (priority: %@, pending: %d)",
                  source, priority.rawValue, pendingCount)
        }
    }

    /// Called when glasses reconnect. Reviews the queue and delivers relevant items.
    func onGlassesReconnected() {
        guard !queue.isEmpty else { return }

        // Remove stale notifications
        let before = queue.count
        queue.removeAll { $0.isStale || $0.delivered }
        let removed = before - queue.count
        if removed > 0 {
            NSLog("[AgentQueue] Pruned %d stale notifications", removed)
        }

        guard !queue.isEmpty else {
            pendingCount = 0
            save()
            return
        }

        NSLog("[AgentQueue] Delivering %d queued notifications", queue.count)

        // Deliver queued notifications
        Task {
            // If there's more than one, summarize instead of reading each one
            if queue.count > 3 {
                await deliverSummary()
            } else {
                for notification in queue where !notification.delivered {
                    await deliverImmediately(
                        message: notification.message,
                        waitForResponse: notification.priority == .high
                    )
                    // Small gap between notifications
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            // Mark all as delivered
            for i in queue.indices { queue[i].delivered = true }
            queue.removeAll { $0.delivered }
            pendingCount = 0
            save()
        }
    }

    // MARK: - Delivery

    /// Speak a message and optionally wait for the user's response.
    private func deliverImmediately(message: String, waitForResponse: Bool) async {
        guard let appState else { return }

        await appState.speechService.speak(message)
        appState.lastResponse = message

        if waitForResponse {
            // Turn on mic to listen for response, then turn off when done
            NSLog("[AgentQueue] Waiting for operator response...")
            appState.inConversation = true
            appState.isListening = true
            appState.transcriptionService.startRecording()
            appState.updateLiveActivity()
            // The transcription callback will handle the response naturally
            // and returnToWakeWord (or stay silent in silent mode)
        }
    }

    /// When there are many queued items, ask the LLM to summarize them.
    private func deliverSummary() async {
        guard let appState else { return }

        let items = queue.filter { !$0.delivered }
        let bulletPoints = items.map { "- [\($0.source)] \($0.message)" }.joined(separator: "\n")

        let prompt = """
        While the user was away, these notifications queued up. \
        Summarize them briefly into 2-3 spoken sentences, prioritizing the most important items:

        \(bulletPoints)
        """

        appState.speechService.startThinkingSound()
        do {
            let response = try await appState.llmService.sendMessage(
                prompt,
                locationContext: appState.locationService.locationContext,
                memoryContext: Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil,
                agentContext: appState.currentAgentContext
            )
            appState.lastResponse = response
            appState.speechService.stopThinkingSound()
            await appState.speechService.speak(response)

            // Listen for response after summary
            appState.inConversation = true
            appState.isListening = true
            appState.transcriptionService.startRecording()
        } catch {
            appState.speechService.stopThinkingSound()
            NSLog("[AgentQueue] Summary failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([QueuedNotification].self, from: data) else { return }
        queue = loaded
        pendingCount = queue.filter { !$0.delivered }.count
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    /// Clear all queued notifications.
    func clearAll() {
        queue.removeAll()
        pendingCount = 0
        save()
    }
}
