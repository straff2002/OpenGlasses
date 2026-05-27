import Foundation
import Combine
import UserNotifications

/// Listens to live captions during a meeting, periodically sends the transcript to an LLM,
/// and posts lock screen notifications with a running summary and suggested follow-up questions.
@MainActor
class MeetingAssistantService: ObservableObject {
    @Published var isActive = false
    @Published var lastSummary: String = ""

    // MARK: - Private state

    /// Closure injected at start — avoids a hard dependency on LLMService.
    private var llm: ((String) async throws -> String)?

    /// Combine subscription to caption history.
    private var captionSubscription: AnyCancellable?

    /// All caption text seen since the session started (ordered oldest → newest).
    private var fullTranscript: [String] = []

    /// Caption text accumulated since the last analysis round.
    private var bufferText: String = ""

    /// Number of caption entries we have already consumed from the history array.
    private var consumedCount: Int = 0

    /// Task managing the 60-second periodic trigger.
    private var timerTask: Task<Void, Never>?

    /// Prevents concurrent LLM calls.
    private var isAnalysing = false

    // MARK: - Public API

    /// Start the assistant.
    /// - Parameters:
    ///   - captionService: The ambient caption service whose `captionHistory` is observed.
    ///   - llm: Async closure that sends a prompt to the LLM and returns the response text.
    func start(captionService: AmbientCaptionService, llm: @escaping (String) async throws -> String) {
        guard !isActive else { return }
        isActive = true
        self.llm = llm
        fullTranscript = []
        bufferText = ""
        consumedCount = 0
        isAnalysing = false
        lastSummary = ""

        // Subscribe to caption history changes.
        captionSubscription = captionService.$captionHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.handleCaptionUpdate(history)
            }

        // Periodic 60-second analysis trigger.
        timerTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 s
                guard let self, self.isActive else { break }
                await self.analyseIfNeeded(force: true)
            }
        }

        NSLog("[MeetingAssistant] Started")
    }

    /// Stop the assistant and clean up resources.
    func stop() {
        guard isActive else { return }
        isActive = false
        captionSubscription?.cancel()
        captionSubscription = nil
        timerTask?.cancel()
        timerTask = nil
        llm = nil
        NSLog("[MeetingAssistant] Stopped")
    }

    // MARK: - Caption ingestion

    /// Called whenever `captionHistory` publishes a new value.
    /// `captionHistory` is newest-first; we need entries we haven't seen yet.
    private func handleCaptionUpdate(_ history: [AmbientCaptionService.CaptionEntry]) {
        let totalCount = history.count
        let newCount = totalCount - consumedCount
        guard newCount > 0 else { return }

        // The newest entries are at the front of the array.
        // We want only the ones we haven't consumed yet, in chronological order.
        let newEntries = Array(history.prefix(newCount).reversed())
        for entry in newEntries {
            fullTranscript.append(entry.text)
            bufferText += (bufferText.isEmpty ? "" : " ") + entry.text
        }
        consumedCount = totalCount

        // Trigger early if the buffer already has ≥ 100 words.
        let wordCount = bufferText.split(whereSeparator: \.isWhitespace).count
        if wordCount >= 100 {
            Task { await analyseIfNeeded(force: false) }
        }
    }

    // MARK: - Analysis

    /// Run an LLM analysis unless one is already in progress.
    /// - Parameter force: When `true`, run even if the buffer has very few words.
    private func analyseIfNeeded(force: Bool) async {
        guard isActive, !isAnalysing else { return }
        guard force || bufferText.split(whereSeparator: \.isWhitespace).count >= 100 else { return }
        guard !fullTranscript.isEmpty else { return }
        guard let llm else { return }

        isAnalysing = true
        defer { isAnalysing = false }

        // Snapshot and clear the buffer.
        bufferText = ""

        let transcript = fullTranscript.joined(separator: "\n")
        let prompt = """
            You are a live meeting assistant listening to a conversation. Here is the transcript so far:

            \(transcript)

            Provide:
            1. A 2-3 sentence running summary of the key points discussed
            2. 2-3 smart follow-up questions the listener could ask right now

            Format your response EXACTLY as:
            SUMMARY: [summary here]
            QUESTIONS:
            • [question 1]
            • [question 2]
            • [question 3 if relevant]

            Be concise. Focus on what's most actionable RIGHT NOW.
            """

        do {
            let response = try await llm(prompt)
            lastSummary = response
            postNotification(body: response)
            NSLog("[MeetingAssistant] Analysis complete (%d chars)", response.count)
        } catch {
            NSLog("[MeetingAssistant] LLM error: %@", error.localizedDescription)
        }
    }

    // MARK: - Notifications

    private func postNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Update"
        content.body = body
        content.categoryIdentifier = "meeting_assistant"
        content.sound = nil
        content.threadIdentifier = "meeting_assistant"

        let request = UNNotificationRequest(
            identifier: "meeting_assistant_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[MeetingAssistant] Notification error: %@", error.localizedDescription)
            }
        }
    }
}
