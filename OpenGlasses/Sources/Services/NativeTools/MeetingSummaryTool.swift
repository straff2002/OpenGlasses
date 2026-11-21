import Foundation

/// Generates meeting/conversation summaries from ambient captions.
/// Detects when a meeting ends (prolonged silence after multi-speaker session)
/// and offers a summary with action items.
struct MeetingSummaryTool: NativeTool {
    let name = "meeting_summary"
    let description = "Generate a summary of a recent meeting or conversation from ambient captions. Extracts key points, decisions, and action items. Use when the user says 'summarize the meeting', 'what happened in that conversation?', or 'meeting notes'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "description": "Output mode: 'full' (summary + action items + decisions), 'brief' (short summary), 'action_items' (just action items)"
            ],
            "save": [
                "type": "boolean",
                "description": "Whether to save the summary as a note (default: true)"
            ]
        ],
        "required": []
    ]

    weak var captionService: AmbientCaptionService?

    init(captionService: AmbientCaptionService) {
        self.captionService = captionService
    }

    func execute(args: [String: Any]) async throws -> String {
        await summarize(args: args).text
    }

    /// The summary as the tool says it, and — when there was a conversation to summarise — the
    /// same extraction as a value (Plan KT P0), so a prepared card reads action items without
    /// parsing the prose.
    func summarize(args: [String: Any], now: Date = Date()) async -> MeetingSummaryOutput {
        guard let service = captionService else {
            return MeetingSummaryOutput(text: "Ambient caption service not available.", facts: nil)
        }

        // The whole session's transcript, oldest first (not the screen's capped history), with each
        // diarized line named as the registry names it now, and the model's window for the budget.
        let snapshot = await MainActor.run { () -> (transcript: MeetingTranscriptBuffer, labeled: [String], budget: Int) in
            let transcript = service.meetingTranscript
            let registry = service.speakerRegistry
            let labeled = transcript.lines.map { line in
                line.speaker.map { "\(registry.displayLabel(for: $0)): \(line.text)" } ?? line.text
            }
            return (transcript, labeled, Self.excerptBudget())
        }
        let lines = snapshot.transcript.lines

        guard !lines.isEmpty else {
            return MeetingSummaryOutput(
                text: "No conversation transcript available. Start ambient captions first, then have a conversation. I'll be able to summarize it afterward.",
                facts: nil)
        }

        let mode = (args["mode"] as? String)?.lowercased() ?? "full"
        let shouldSave = args["save"] as? Bool ?? true

        let duration = Self.duration(of: lines.map(\.timestamp))
        let wordCount = lines.reduce(0) { $0 + $1.text.split(separator: " ").count }

        // Extract key information locally, over the whole meeting
        let facts = Self.facts(from: lines.map { (text: $0.text, timestamp: $0.timestamp) },
                               savedAt: now)
        // Held in memory for the My Day cards' meeting follow-up (Plan KT P1); never written down.
        if let facts { LatestMeetingSummary.shared.record(facts) }
        let actionItems = facts?.actionItems ?? []
        let decisions = facts?.decisions ?? []
        let topics = facts?.topics ?? []

        var summary = ""

        switch mode {
        case "brief":
            summary = buildBriefSummary(
                entryCount: lines.count,
                duration: duration,
                wordCount: wordCount,
                topics: topics
            )

        case "action_items":
            if actionItems.isEmpty {
                summary = "No clear action items detected in the conversation."
            } else {
                summary = "Action items from the conversation:\n" + actionItems.map { "• \($0)" }.joined(separator: "\n")
            }

        default: // "full"
            let pinned = MeetingTranscriptExcerpt.pinnedIndices(
                texts: lines.map(\.text), actionItems: actionItems, decisions: decisions)
            let excerpt = MeetingTranscriptExcerpt.make(
                lines: zip(snapshot.labeled, lines).map { .init(text: $0, timestamp: $1.timestamp) },
                pinned: pinned, budget: snapshot.budget)
            summary = buildFullSummary(
                excerpt: excerpt,
                droppedLines: snapshot.transcript.dropped,
                entryCount: lines.count,
                duration: duration,
                wordCount: wordCount,
                topics: topics,
                actionItems: actionItems,
                decisions: decisions
            )
        }

        // Save as a note if requested
        if shouldSave {
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            saveNote(title: "Meeting Summary — \(dateStr)", content: summary)
        }

        return MeetingSummaryOutput(
            text: summary + "\n\nThe LLM should present this summary conversationally to the user, highlighting the most important points.",
            facts: facts)
    }

    /// The extraction as a value, over caption entries in time order. Nil for no entries.
    nonisolated static func facts(from entries: [(text: String, timestamp: Date)], savedAt: Date) -> MeetingSummaryFacts? {
        guard let first = entries.first, let last = entries.last else { return nil }
        let texts = entries.map(\.text)
        return MeetingSummaryFacts(
            actionItems: extractActionItems(from: texts),
            decisions: extractDecisions(from: texts),
            topics: extractTopics(from: texts),
            startedAt: min(first.timestamp, last.timestamp),
            endedAt: max(first.timestamp, last.timestamp),
            savedAt: savedAt,
            transcript: texts.joined(separator: "\n"))
    }

    // MARK: - Summary Building

    private func buildBriefSummary(entryCount: Int, duration: String, wordCount: Int, topics: [String]) -> String {
        var parts: [String] = []
        parts.append("Conversation: \(entryCount) segments over \(duration) (~\(wordCount) words).")
        if !topics.isEmpty {
            parts.append("Topics discussed: \(topics.prefix(5).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }

    private func buildFullSummary(excerpt: MeetingTranscriptExcerpt, droppedLines: Int,
                                   entryCount: Int, duration: String,
                                   wordCount: Int, topics: [String], actionItems: [String],
                                   decisions: [String]) -> String {
        var parts: [String] = []

        parts.append("MEETING SUMMARY")
        parts.append("Duration: \(duration) | Segments: \(entryCount) | Words: ~\(wordCount)")
        if droppedLines > 0 {
            parts.append("(This session ran past what is held in memory: its first \(MeetingTranscriptExcerpt.grouped(droppedLines)) lines are no longer available, so everything here starts after them.)")
        }
        parts.append("")

        if !topics.isEmpty {
            parts.append("KEY TOPICS: \(topics.prefix(5).joined(separator: ", "))")
        }

        if !decisions.isEmpty {
            parts.append("")
            parts.append("DECISIONS:")
            for d in decisions.prefix(5) { parts.append("• \(d)") }
        }

        if !actionItems.isEmpty {
            parts.append("")
            parts.append("ACTION ITEMS:")
            for a in actionItems.prefix(5) { parts.append("• \(a)") }
        }

        parts.append("")
        parts.append(excerpt.header)
        parts.append(excerpt.text)

        return parts.joined(separator: "\n")
    }

    // MARK: - Local Extraction

    nonisolated static func extractActionItems(from texts: [String]) -> [String] {
        let actionPatterns = [
            "need to", "should", "will", "going to", "have to", "must",
            "let's", "let me", "i'll", "we'll", "please", "make sure",
            "don't forget", "remember to", "follow up", "send", "schedule",
            "set up", "prepare", "call", "email", "check", "review",
            "update", "fix", "create", "book", "arrange"
        ]

        var items: [String] = []
        for text in texts {
            let lower = text.lowercased()
            for pattern in actionPatterns {
                if lower.contains(pattern) {
                    // Extract the sentence containing the action pattern
                    let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    for sentence in sentences {
                        if sentence.lowercased().contains(pattern) {
                            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed.count > 10 && !items.contains(trimmed) {
                                items.append(trimmed)
                            }
                        }
                    }
                    break
                }
            }
        }
        return Array(items.prefix(10))
    }

    nonisolated static func extractDecisions(from texts: [String]) -> [String] {
        let decisionPatterns = [
            "decided", "agreed", "we're going with", "the plan is",
            "let's go with", "final answer", "confirmed", "approved",
            "we'll do", "settled on"
        ]

        var decisions: [String] = []
        for text in texts {
            let lower = text.lowercased()
            for pattern in decisionPatterns {
                if lower.contains(pattern) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !decisions.contains(trimmed) {
                        decisions.append(trimmed)
                    }
                    break
                }
            }
        }
        return Array(decisions.prefix(5))
    }

    nonisolated static func extractTopics(from texts: [String]) -> [String] {
        // Simple word frequency analysis for topic extraction
        let stopWords: Set<String> = ["the", "a", "an", "is", "it", "to", "and", "of", "in", "for",
                                       "that", "this", "with", "on", "at", "by", "from", "or", "but",
                                       "not", "be", "are", "was", "were", "been", "have", "has", "had",
                                       "do", "does", "did", "will", "would", "could", "should", "may",
                                       "can", "just", "so", "like", "yeah", "ok", "okay", "um", "uh",
                                       "i", "you", "we", "they", "he", "she", "my", "your", "our",
                                       "me", "him", "her", "them", "what", "how", "when", "where",
                                       "about", "going", "think", "know", "want", "need", "get", "got",
                                       "really", "very", "well", "also", "then", "than", "more", "some"]

        var wordCounts: [String: Int] = [:]
        for text in texts {
            let words = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stopWords.contains($0) }
            for word in words {
                wordCounts[word, default: 0] += 1
            }
        }

        return wordCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    // MARK: - Helpers

    /// The excerpt's character budget, from the active model's context window where the app
    /// knows it (`ModelContextWindow`), else the conservative budget that fits a 4k model.
    @MainActor
    static func excerptBudget() -> Int {
        guard let config = Config.activeModel else {
            return MeetingTranscriptExcerpt.characterBudget(contextTokens: nil)
        }
        let catalogContext = config.llmProvider == .chatgpt
            ? ChatGPTContextCatalog.context(model: config.model, accountID: ChatGPTOAuthService.shared.accountID)
            : nil
        let window = ModelContextWindow.resolve(provider: config.llmProvider, model: config.model,
                                                baseURL: config.baseURL, chatGPTCatalogContext: catalogContext)
        return MeetingTranscriptExcerpt.characterBudget(contextTokens: window?.tokens)
    }

    /// From the first line to the last, in words.
    nonisolated static func duration(of timestamps: [Date]) -> String {
        guard let first = timestamps.min(), let last = timestamps.max() else {
            return "unknown"
        }
        let seconds = Int(last.timeIntervalSince(first))
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let remainingMins = minutes % 60
        return "\(hours)h \(remainingMins)m"
    }

    private func saveNote(title: String, content: String) {
        SavedNotesStore.append(
            title: title,
            content: content,
            date: ISO8601DateFormatter().string(from: Date())
        )

        // Feed the knowledge graph: typed edges from the summary, plus mentioned_in
        // edges linking known people to this meeting.
        BrainStore.shared.ingest(text: content, sourceRef: title, sourceKind: "meeting", origin: .fromMeeting)
    }
}

/// What `MeetingSummaryTool` said, as text for the model and as a value for code.
struct MeetingSummaryOutput {
    let text: String
    let facts: MeetingSummaryFacts?
}

/// One summarised conversation (Plan KT P0): the action items, decisions and topics the tool
/// extracted, the span of the captions it read and when the summary was made.
///
/// `transcript` is caption text — other people's words. It is held only so a draft built from the
/// action items can be checked for having copied anything else (`DraftValidator`); it is never
/// stored, logged or put in a prompt by anything in Plan KT.
struct MeetingSummaryFacts: Equatable, Sendable {
    let actionItems: [String]
    let decisions: [String]
    let topics: [String]
    let startedAt: Date
    let endedAt: Date
    let savedAt: Date
    let transcript: String
}

/// The last meeting summary this run made, for the My Day cards' meeting follow-up (Plan KT P1).
/// In memory only, and only the latest: caption text is other people's words, so it is never
/// written to disk, logged or kept past the process.
final class LatestMeetingSummary: @unchecked Sendable {
    static let shared = LatestMeetingSummary()

    private let lock = NSLock()
    private var facts: MeetingSummaryFacts?

    func record(_ facts: MeetingSummaryFacts) {
        lock.lock()
        defer { lock.unlock() }
        self.facts = facts
    }

    var latest: MeetingSummaryFacts? {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        facts = nil
    }
}
