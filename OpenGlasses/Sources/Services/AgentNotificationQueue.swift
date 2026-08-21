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
        let personaId: String?   // Which persona/agent produced this (nil = default)
        let personaName: String? // Display name for "Claude here — ..."
        let createdAt: Date
        let priority: Priority
        var delivered: Bool = false

        /// Shared with the notification digest (Plan BZ) — same raw values, so persisted
        /// queue JSON keeps decoding; same staleness numbers, covered by this queue's tests.
        typealias Priority = NotificationPriority

        /// Whether this notification is still relevant based on age.
        var isStale: Bool {
            priority.isStale(age: Date().timeIntervalSince(createdAt))
        }
    }

    private var queue: [QueuedNotification] = []
    private let storageURL: URL

    weak var appState: AppState?

    /// Plan BZ: fires when a notification is queued (not delivered immediately), so the
    /// digest can aggregate it. Wired by AppState.
    var onQueued: ((QueuedNotification) -> Void)?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageURL = docs.appendingPathComponent("agent_notification_queue.json")
        load()
    }

    // MARK: - Queue Management

    /// Add a notification to the queue. If glasses are connected, deliver immediately.
    func enqueue(message: String, source: String, priority: QueuedNotification.Priority = .medium, personaId: String? = nil, personaName: String? = nil) {
        guard let appState else { return }

        // Check chattiness — quiet mode suppresses non-high notifications
        if Config.agentChattiness == .quiet && priority != .high { return }

        if appState.isConnected && !appState.glassesIdle && !appState.isProcessing && !appState.isListening {
            // Glasses connected, worn, and idle — deliver immediately
            Task {
                await deliverImmediately(message: message, waitForResponse: priority != .low, personaId: personaId, personaName: personaName)
            }
        } else {
            // Queue for later
            let notification = QueuedNotification(
                id: UUID().uuidString,
                message: message,
                source: source,
                personaId: personaId,
                personaName: personaName,
                createdAt: Date(),
                priority: priority
            )
            queue.append(notification)
            pendingCount = queue.filter { !$0.delivered }.count
            save()
            onQueued?(notification)
            NSLog("[AgentQueue] Queued: %@ (priority: %@, pending: %d)",
                  source, priority.rawValue, pendingCount)
        }
    }

    /// Called when glasses reconnect. Reviews the queue and delivers relevant items.
    func onGlassesReconnected() {
        guard !queue.isEmpty else { return }
        guard appState?.glassesIdle != true else { return }

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
    /// If from a specific persona, announce which agent and activate that persona's wake word.
    private func deliverImmediately(message: String, waitForResponse: Bool, personaId: String? = nil, personaName: String? = nil) async {
        guard let appState else { return }

        // Don't speak to glasses in the case
        guard !appState.glassesIdle else {
            NSLog("[AgentQueue] Skipping delivery — glasses idle (in case)")
            return
        }

        // During a live voice session, route through the session's own model instead of speaking
        // over it with TTS in a different voice (Plan CB). completeTurn: true is load-bearing —
        // without it the injection appends silently and the user hears nothing. The message is
        // framed as the delivery of an earlier request, not fresh news, so the model presents it
        // as the answer it is.
        if let injector = appState.activeLiveInjector {
            let framed = AsyncDeliveryPhrasing.resultInstruction(question: nil, answer: message)
            injector.injectText(framed, completeTurn: true)
            appState.lastResponse = message
            NSLog("[AgentQueue] Delivered via live session injection")
            return
        }

        // Play soft notification chime
        appState.speechService.playAcknowledgmentTone()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // If from a specific persona, activate it and prefix the message
        if let personaId, let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
            appState.activePersona = persona
            Config.setActiveModelId(persona.modelId)
            Config.setActivePresetId(persona.presetId)
            appState.llmService.refreshActiveModel()
        }

        let spokenMessage: String
        if let name = personaName {
            spokenMessage = "\(name) here. \(message)"
        } else {
            spokenMessage = message
        }

        await appState.speechService.speak(spokenMessage)
        appState.lastResponse = message

        if waitForResponse {
            // Turn on mic — the active persona's wake word is now listening
            NSLog("[AgentQueue] Waiting for operator response (persona: %@)...",
                  personaName ?? "default")
            appState.inConversation = true
            appState.isListening = true
            appState.transcriptionService.startRecording()
            appState.updateLiveActivity()
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
            // Off-turn (Plan CU P1): the digest fires on the queue's own schedule and shares the
            // turn path's `sendMessage` / `runToolLoop` — see `TurnRecorder.offTurn`.
            let response = try await TurnRecorder.offTurn {
                try await appState.llmService.sendMessage(
                    prompt,
                    locationContext: appState.locationService.locationContext,
                    memoryContext: Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil,
                    agentContext: appState.currentAgentContext
                )
            }
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

    /// Plan BZ P3: dismissing a digest acknowledges the agent items it showed — mark them
    /// delivered so the reconnect path doesn't speak what the user already read.
    func markDelivered(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for index in queue.indices where ids.contains(queue[index].id) && !queue[index].delivered {
            queue[index].delivered = true
            changed = true
        }
        guard changed else { return }
        queue.removeAll { $0.delivered }
        pendingCount = queue.count
        save()
    }
}
