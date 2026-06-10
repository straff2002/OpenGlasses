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
        guard let service = captionService else {
            return "Ambient caption service not available."
        }

        let history = await MainActor.run { service.captionHistory }

        guard !history.isEmpty else {
            return "No conversation transcript available. Start ambient captions first, then have a conversation. I'll be able to summarize it afterward."
        }

        let mode = (args["mode"] as? String)?.lowercased() ?? "full"
        let shouldSave = args["save"] as? Bool ?? true

        // Build transcript from caption history (most recent first, so reverse)
        let entries = history.reversed()
        let transcript = entries.map { entry in
            let time = formatTime(entry.timestamp)
            return "[\(time)] \(entry.text)"
        }.joined(separator: "\n")

        let duration = calculateDuration(entries: Array(entries))
        let wordCount = entries.reduce(0) { $0 + $1.text.split(separator: " ").count }

        // Extract key information locally
        let actionItems = extractActionItems(from: entries.map { $0.text })
        let decisions = extractDecisions(from: entries.map { $0.text })
        let topics = extractTopics(from: entries.map { $0.text })

        var summary = ""

        switch mode {
        case "brief":
            summary = buildBriefSummary(
                entryCount: entries.count,
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
            summary = buildFullSummary(
                transcript: transcript,
                entryCount: entries.count,
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

        return summary + "\n\nThe LLM should present this summary conversationally to the user, highlighting the most important points."
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

    private func buildFullSummary(transcript: String, entryCount: Int, duration: String,
                                   wordCount: Int, topics: [String], actionItems: [String],
                                   decisions: [String]) -> String {
        var parts: [String] = []

        parts.append("MEETING SUMMARY")
        parts.append("Duration: \(duration) | Segments: \(entryCount) | Words: ~\(wordCount)")
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
        parts.append("TRANSCRIPT (last \(min(entryCount, 20)) segments):")
        let recentTranscript = transcript.split(separator: "\n").suffix(20).joined(separator: "\n")
        parts.append(recentTranscript)

        return parts.joined(separator: "\n")
    }

    // MARK: - Local Extraction

    private func extractActionItems(from texts: [String]) -> [String] {
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

    private func extractDecisions(from texts: [String]) -> [String] {
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

    private func extractTopics(from texts: [String]) -> [String] {
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func calculateDuration(entries: [AmbientCaptionService.CaptionEntry]) -> String {
        guard let first = entries.first?.timestamp, let last = entries.last?.timestamp else {
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
        let key = "saved_notes"
        var notes = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        notes.append([
            "title": title,
            "content": content,
            "date": ISO8601DateFormatter().string(from: Date())
        ])
        // Keep max 50 notes
        if notes.count > 50 { notes = Array(notes.suffix(50)) }
        UserDefaults.standard.set(notes, forKey: key)

        // Feed the knowledge graph: typed edges from the summary, plus mentioned_in
        // edges linking known people to this meeting.
        BrainStore.shared.ingest(text: content, sourceRef: title, sourceKind: "meeting")
    }
}
